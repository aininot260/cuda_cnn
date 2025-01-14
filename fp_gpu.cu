#include "fp_gpu.cuh"

__global__ void fp_conv_pool(int idx,bool flag)
{
    int i,j,k,l,m;
    i=threadIdx.x+blockDim.x*blockIdx.x;
    j=threadIdx.y+blockDim.y*blockIdx.y;

    __shared__ float tile[CONV_W_NUM][CONV_SIZE][CONV_SIZE];

    if(i<ROW&&j<COL)
    {
        if(flag)
            _input[idx%N_STREAM][i][j]=train_image[idx][i][j];
        else
            _input[idx%N_STREAM][i][j]=test_image[idx][i][j];
        __syncthreads();
    }

    if(i<CONV_W_NUM&&j<CONV_SIZE)
    {
        for(k=0;k<CONV_SIZE;k++)
        {
            tile[i][j][k]=0;
            for(l=0;l<CONV_W_SIZE;l++)
            for(m=0;m<CONV_W_SIZE;m++)
                tile[i][j][k]+=_input[idx%N_STREAM][j+l][k+m]*conv_w[i][l][m];
            tile[i][j][k]+=conv_b[i];
            // tile[i][j][k]=sigmoid(tile[i][j][k]);
            tile[i][j][k]=tanh(tile[i][j][k]);
        }
        __syncthreads();
    }

    if(i<CONV_W_NUM&&j<POOL_SIZE)
    {
        for(k=0;k<POOL_SIZE;k++)
        {
            float _max=tile[i][j*2][k*2];
            _pool_pos[idx%N_STREAM][i][j][k]=0;
            if(tile[i][j*2][k*2+1]>_max)
            {
                _max=tile[i][j*2][k*2+1];
                _pool_pos[idx%N_STREAM][i][j][k]=1;
            }
            if(tile[i][j*2+1][k*2]>_max)
            {
                _max=tile[i][j*2+1][k*2];
                _pool_pos[idx%N_STREAM][i][j][k]=2;
            }
            if(tile[i][j*2+1][k*2+1]>_max)
            {
                _max=tile[i][j*2+1][k*2+1];
                _pool_pos[idx%N_STREAM][i][j][k]=3;
            }
            _pool[idx%N_STREAM][i][j][k]=_max;
        }
        __syncthreads();
    }
}

void fp_conv_pool_gpu(int idx,bool flag)
{
    dim3 block(32,32);
    dim3 grid(1,1);
    fp_conv_pool<<<grid,block,0,stream[idx%N_STREAM]>>>(idx,flag);
}

__global__ void fp_fc_answer(int idx,bool flag)
{
    int i,j,k,l;
    i=threadIdx.x+blockDim.x*blockIdx.x;

    __shared__ float tile1[FC1_SIZE];
    __shared__ float tile2[FC2_SIZE];
    __shared__ int tile3[FC2_SIZE];

    if(i<FC1_SIZE)
    {
        tile1[i]=0;
        for(j=0;j<CONV_W_NUM;j++)
        for(k=0;k<POOL_SIZE;k++)
        for(l=0;l<POOL_SIZE;l++)
            tile1[i]+=_pool[idx%N_STREAM][j][k][l]*fc1_w[i][j][k][l];
        tile1[i]+=fc1_b[i];
        tile1[i]=sigmoid(tile1[i]);
        // tile1[i]=tanh(tile1[i]);
        _fc1_a[idx%N_STREAM][i]=tile1[i];
        __syncthreads();
    }

    if(i<FC2_SIZE)
    {
        tile2[i]=0;
        for(j=0;j<FC1_SIZE;j++)
            tile2[i]+=tile1[j]*fc2_w[i][j];
        tile2[i]+=fc2_b[i];
        tile2[i]=sigmoid(tile2[i]);
        _fc2_a[idx%N_STREAM][i]=tile2[i];
 
        if(flag)
            tile3[i]=(train_label[idx]==i)?1:0;
        else
            tile3[i]=(test_label[idx]==i)?1:0;
        __syncthreads();
    }
    
    if(i==0)
    {
        float _max=tile2[0];
        int max_pos=0;
        for(i=0;i<FC2_SIZE;i++)
        {
            if(_max<tile2[i])
            {
                _max=tile2[i];
                max_pos=i;
            }
        }
        if(tile3[max_pos])
            atomicAdd(&correct_cnt,1);
        for(i=0;i<FC2_SIZE;i++)
        {
            _C[idx%N_STREAM][i]=tile2[i]-tile3[i];
            atomicExch(&avg_error,avg_error+_C[idx%N_STREAM][i]*_C[idx%N_STREAM][i]*0.5);
        }
    }
}

void fp_fc_answer_gpu(int idx,bool flag)
{
    dim3 block(64);
    dim3 grid(1);
    fp_fc_answer<<<grid,block,0,stream[idx%N_STREAM]>>>(idx,flag);
}
