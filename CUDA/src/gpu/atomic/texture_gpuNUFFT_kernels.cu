#ifndef TEXTURE_GPUNUFFT_KERNELS_H
#define TEXTURE_GPUNUFFT_KERNELS_H
#include "gpuNUFFT_kernels.hpp"
#include "../std_gpuNUFFT_kernels.cu"
#include "cuda_utils.cuh"

// ----------------------------------------------------------------------------
// convolutionKernel: NUFFT^H kernel
//
// Performs the gpuNUFFT step by convolution of sample points with 
// interpolation function and resampling onto grid. Basic concept based on Zwart
// et al. 
//
// parameters:
//  * data           : complex input sample points
//  * crds           : coordinates of data points (x,y,z)
//  * gdata          : output grid data 
//  * sectors        : mapping of sample indices according to each sector
//  * sector_centers : coordinates (x,y,z) of sector centers
//  * temp_gdata     : temporary grid data
//  * N              : number of threads
__device__ void textureConvolutionFunction(int* sec, int sec_max, int sec_offset, DType2* sdata, DType2* data, DType* crds, CufftType* gdata, IndType* sectors, IndType* sector_centers)
{
  //start convolution
  int ind, k, i, j, x, y, z;
  int imin, imax,jmin,jmax,kmin,kmax;

  DType dx_sqr, dy_sqr, dz_sqr, val, ix, jy, kz;

  __shared__ IndType3 center;
  center.x = sector_centers[sec[threadIdx.x] * 3];
  center.y = sector_centers[sec[threadIdx.x] * 3 + 1];
  center.z = sector_centers[sec[threadIdx.x] * 3 + 2];

  //Grid Points over Threads
  int data_cnt = sectors[sec[threadIdx.x]] + threadIdx.x + sec_offset;
  //loop over all data points of the current sector, and check if grid position lies inside 
  //affected region, if so, add data point weighted to grid position value
  while (data_cnt < sec_max)
  {
    DType3 data_point; //datapoint per thread
    data_point.x = crds[data_cnt];
    data_point.y = crds[data_cnt +GI.data_count];
    data_point.z = crds[data_cnt +2*GI.data_count];

    // set the boundaries of final dataset for gpuNUFFT this point
    ix = (data_point.x + 0.5f) * (GI.gridDims.x) - center.x + GI.sector_offset;
    set_minmax(&ix, &imin, &imax, GI.sector_pad_max, GI.kernel_radius);
    jy = (data_point.y + 0.5f) * (GI.gridDims.y) - center.y + GI.sector_offset;
    set_minmax(&jy, &jmin, &jmax, GI.sector_pad_max, GI.kernel_radius);
    kz = (data_point.z + 0.5f) * (GI.gridDims.z) - center.z + GI.sector_offset;
    set_minmax(&kz, &kmin, &kmax, GI.sector_pad_max, GI.kernel_radius);

    // grid this point onto its cartesian points neighbors
    k =kmin;
    while (k<=kmax && k>=kmin)
    {
      kz = static_cast<DType>((k + center.z - GI.sector_offset)) / static_cast<DType>((GI.gridDims.z)) - 0.5f;//(k - center_z) *width_inv;
      dz_sqr = (kz - data_point.z)*GI.aniso_z_scale;
      dz_sqr *= dz_sqr;
      j=jmin;
      while (j<=jmax && j>=jmin)
      {
        jy = static_cast<DType>(j + center.y - GI.sector_offset) / static_cast<DType>((GI.gridDims.y)) - 0.5f;   //(j - center_y) *width_inv;
        dy_sqr = (jy - data_point.y) * GI.aniso_y_scale;
        dy_sqr *= dy_sqr;
        i= imin;						
        while (i<=imax && i>=imin)
        {
          ix = static_cast<DType>(i + center.x - GI.sector_offset) / static_cast<DType>((GI.gridDims.x)) - 0.5f;// (i - center_x) *width_inv;
          dx_sqr = (ix - data_point.x)*GI.aniso_x_scale;
          dx_sqr *= dx_sqr;
          //get kernel value
          val = computeTextureLookup(dx_sqr*GI.radiusSquared_inv,dy_sqr*GI.radiusSquared_inv,dz_sqr*GI.radiusSquared_inv);

          ind = getIndex(i,j,k,GI.sector_pad_width);

          // multiply data by current kernel val 
          // grid complex or scalar 
          atomicAdd(&(sdata[ind].x),val * tex1Dfetch(texDATA,data_cnt).x);
          atomicAdd(&(sdata[ind].y),val * tex1Dfetch(texDATA,data_cnt).y);
          i++;
        } // x 	 
        j++;
      } // y 
      k++;
    } // z
    data_cnt = data_cnt + blockDim.x;
  } //grid points per sector

  //write shared data to output grid
  __syncthreads();
  //int sector_ind_offset = sec * GI.sector_dim;
  __shared__ int sector_ind_offset;
  sector_ind_offset  = computeXYZ2Lin(center.x - GI.sector_offset,center.y - GI.sector_offset,center.z - GI.sector_offset,GI.gridDims);

  //each thread writes one position from shared mem to global mem
  for (int s_ind=threadIdx.x;s_ind<GI.sector_dim; s_ind += blockDim.x)
  {
    getCoordsFromIndex(s_ind,&x,&y,&z,GI.sector_pad_width);

    if (isOutlier(x,y,z,center.x,center.y,center.z,GI.gridDims,GI.sector_offset))
      //calculate opposite index
      ind = computeXYZ2Lin(calculateOppositeIndex(x,center.x,GI.gridDims.x,GI.sector_offset),
      calculateOppositeIndex(y,center.y,GI.gridDims.y,GI.sector_offset),
      calculateOppositeIndex(z,center.z,GI.gridDims.z,GI.sector_offset),
      GI.gridDims);
    else
      ind = sector_ind_offset + computeXYZ2Lin(x,y,z,GI.gridDims);//index in output grid

    atomicAdd(&(gdata[ind].x),sdata[s_ind].x);//Re
    atomicAdd(&(gdata[ind].y),sdata[s_ind].y);//Im

    //reset shared mem
    sdata[s_ind].x = (DType)0.0;
    sdata[s_ind].y = (DType)0.0;
  }
}

__global__ void textureConvolutionKernel(DType2* data, 
  DType* crds, 
  CufftType* gdata,
  IndType* sectors, 
  IndType* sector_centers,
  int N
  )
{
  extern __shared__ DType2 sdata[];//externally managed shared memory
  
  //init shared memory
  for (int s_ind=threadIdx.x;s_ind<GI.sector_dim; s_ind+= blockDim.x)
  {
    sdata[s_ind].x = (DType)0.0;//Re
    sdata[s_ind].y = (DType)0.0;//Im
  }
  __syncthreads();

  __shared__ int sec[THREAD_BLOCK_SIZE];
  sec[threadIdx.x] = blockIdx.x;
  while (sec[threadIdx.x] < N)
  {
    __shared__ int data_max;
    data_max = sectors[sec[threadIdx.x]+1];
    textureConvolutionFunction(sec,data_max,0,sdata,data,crds,gdata,sectors,sector_centers);
    __syncthreads();
    sec[threadIdx.x] = sec[threadIdx.x]+ gridDim.x;
  }//sec < sector_count	
}

__global__ void balancedTextureConvolutionKernel(DType2* data, 
  DType* crds, 
  CufftType* gdata,
  IndType* sectors, 
  IndType2* sector_processing_order,
  IndType* sector_centers,
  int N
  )
{
  extern __shared__ DType2 sdata[];//externally managed shared memory

  //init shared memory
  for (int s_ind=threadIdx.x;s_ind<GI.sector_dim; s_ind+= blockDim.x)
  {
    sdata[s_ind].x = (DType)0.0;//Re
    sdata[s_ind].y = (DType)0.0;//Im
  }
  __syncthreads();

  int sec_cnt = blockIdx.x;
  __shared__ int sec[THREAD_BLOCK_SIZE];
  
  while (sec_cnt < N)
  {
    sec[threadIdx.x] = sector_processing_order[sec_cnt].x;
    __shared__ int data_max;
    data_max = min(sectors[sec[threadIdx.x]+1],sectors[sec[threadIdx.x]] + threadIdx.x + sector_processing_order[sec_cnt].y+MAXIMUM_PAYLOAD);
    textureConvolutionFunction(sec,data_max,sector_processing_order[sec_cnt].y,sdata,data,crds,gdata,sectors,sector_centers);
    __syncthreads();
    sec_cnt = sec_cnt + gridDim.x;
  }//sec < sector_count	
}


// ----------------------------------------------------------------------------
// convolutionKernel: NUFFT^H kernel
//
// Performs the gpuNUFFT step by convolution of sample points with 
// interpolation function and resampling onto grid. Basic concept based on Zwart
// et al. 
//
// parameters:
//  * data           : complex input sample points
//  * crds           : coordinates of data points (x,y,z)
//  * gdata          : output grid data 
//  * sectors        : mapping of sample indices according to each sector
//  * sector_centers : coordinates (x,y,z) of sector centers
//  * temp_gdata     : temporary grid data
//  * N              : number of threads
__device__ void textureConvolutionFunction2D(DType2* sdata,int* sec, int sec_max, int sec_offset, DType2* data, DType* crds, CufftType* gdata,IndType* sectors, IndType* sector_centers)
{
  //start convolution
  int ind, i, j, x, y;
  int imin, imax,jmin,jmax;

  DType dx_sqr, dy_sqr, val, ix, jy;

  __shared__ IndType2 center;
  center.x = sector_centers[sec[threadIdx.x] * 2];
  center.y = sector_centers[sec[threadIdx.x] * 2 + 1];

  //Grid Points over Threads
  int data_cnt = sectors[sec[threadIdx.x]] + threadIdx.x + sec_offset;
  //loop over all data points of the current sector, and check if grid position lies inside 
  //affected region, if so, add data point weighted to grid position value
  while (data_cnt < sec_max)
  {
    DType2 data_point; //datapoint per thread
    data_point.x = crds[data_cnt];
    data_point.y = crds[data_cnt +GI.data_count];

    // set the boundaries of final dataset for gpuNUFFT this point
    ix = (data_point.x + 0.5f) * (GI.gridDims.x) - center.x + GI.sector_offset;
    set_minmax(&ix, &imin, &imax, GI.sector_pad_max, GI.kernel_radius);
    jy = (data_point.y + 0.5f) * (GI.gridDims.y) - center.y + GI.sector_offset;
    set_minmax(&jy, &jmin, &jmax, GI.sector_pad_max, GI.kernel_radius);

    // grid this point onto its cartesian points neighbors
    j=jmin;
    while (j<=jmax && j>=jmin)
    {
      jy = static_cast<DType>(j + center.y - GI.sector_offset) / static_cast<DType>((GI.gridDims.y)) - 0.5f;   //(j - center_y) *width_inv;
      dy_sqr = (jy - data_point.y) * GI.aniso_y_scale;
      dy_sqr *= dy_sqr;
      i= imin;						
      while (i<=imax && i>=imin)
      {
        ix = static_cast<DType>(i + center.x - GI.sector_offset) / static_cast<DType>((GI.gridDims.x)) - 0.5f;// (i - center_x) *width_inv;
        dx_sqr = (ix - data_point.x)*GI.aniso_x_scale;
        dx_sqr *= dx_sqr;
        //get kernel value
        //Calculate Separable Filters 
        val = computeTextureLookup(dx_sqr*GI.radiusSquared_inv,dy_sqr*GI.radiusSquared_inv);

        ind = getIndex2D(i,j,GI.sector_pad_width);

        // multiply data by current kernel val 
        // grid complex or scalar
        atomicAdd(&(sdata[ind].x),val * tex1Dfetch(texDATA,data_cnt).x);
        atomicAdd(&(sdata[ind].y),val * tex1Dfetch(texDATA,data_cnt).y);
        i++;
      } // x 	 
      j++;
    } // y 
    data_cnt = data_cnt + blockDim.x;
  } //grid points per sector

  //write shared data to output grid
  __syncthreads();
  //int sector_ind_offset = sec * GI.sector_dim;
  __shared__ int sector_ind_offset;
  sector_ind_offset  = computeXY2Lin(center.x - GI.sector_offset,center.y - GI.sector_offset,GI.gridDims);

  //each thread writes one position from shared mem to global mem
  for (int s_ind=threadIdx.x;s_ind<GI.sector_dim; s_ind += blockDim.x)
  {
    getCoordsFromIndex2D(s_ind,&x,&y,GI.sector_pad_width);

    if (isOutlier2D(x,y,center.x,center.y,GI.gridDims,GI.sector_offset))
      //calculate opposite index
      ind = computeXY2Lin(calculateOppositeIndex(x,center.x,GI.gridDims.x,GI.sector_offset),
      calculateOppositeIndex(y,center.y,GI.gridDims.y,GI.sector_offset),
      GI.gridDims);
    else
      ind = sector_ind_offset + computeXY2Lin(x,y,GI.gridDims);//index in output grid

    atomicAdd(&(gdata[ind].x),sdata[s_ind].x);//Re
    atomicAdd(&(gdata[ind].y),sdata[s_ind].y);//Im
    
    //reset shared mem
    sdata[s_ind].x = (DType)0.0;
    sdata[s_ind].y = (DType)0.0;
  }
}
__global__ void textureConvolutionKernel2D(DType2* data, 
  DType* crds, 
  CufftType* gdata,
  IndType* sectors, 
  IndType* sector_centers,
  int N
  )
{
  extern __shared__ DType2 sdata[];//externally managed shared memory
  
  //init shared memory
  for (int s_ind=threadIdx.x;s_ind<GI.sector_dim; s_ind+= blockDim.x)
  {
    sdata[s_ind].x = (DType)0.0;//Re
    sdata[s_ind].y = (DType)0.0;//Im
  }
  __syncthreads();

  __shared__ int sec[THREAD_BLOCK_SIZE];
  sec[threadIdx.x] = blockIdx.x;
  while (sec[threadIdx.x] < N)
  {
    __shared__ int data_max;
    data_max = sectors[sec[threadIdx.x]+1];
    textureConvolutionFunction2D(sdata,sec,data_max,0,data,crds,gdata,sectors,sector_centers);
    __syncthreads();
    sec[threadIdx.x] = sec[threadIdx.x]+ gridDim.x;
  }//sec < sector_count	
}

__global__ void balancedTextureConvolutionKernel2D(DType2* data, 
  DType* crds, 
  CufftType* gdata,
  IndType* sectors, 
  IndType2* sector_processing_order,
  IndType* sector_centers,
  int N
  )
{
  extern __shared__ DType2 sdata[];//externally managed shared memory
  
  //init shared memory
  for (int s_ind=threadIdx.x;s_ind<GI.sector_dim; s_ind+= blockDim.x)
  {
    sdata[s_ind].x = (DType)0.0;//Re
    sdata[s_ind].y = (DType)0.0;//Im
  }
  __syncthreads();

  int sec_cnt = blockIdx.x;
  __shared__ int sec[THREAD_BLOCK_SIZE];
  
  while (sec_cnt < N)
  {
    sec[threadIdx.x] = sector_processing_order[sec_cnt].x; 
    __shared__ int data_max;
    data_max = min(sectors[sec[threadIdx.x]+1],sectors[sec[threadIdx.x]] + threadIdx.x + sector_processing_order[sec_cnt].y + MAXIMUM_PAYLOAD);
    textureConvolutionFunction2D(sdata,sec,data_max,sector_processing_order[sec_cnt].y,data,crds,gdata,sectors,sector_centers);
    __syncthreads();
    sec_cnt = sec_cnt+ gridDim.x;
  }//sec < sector_count	
}

void performTextureConvolution( DType2* data_d, 
  DType* crds_d, 
  CufftType* gdata_d,
  DType*			kernel_d, 
  IndType* sectors_d, 
  IndType* sector_centers_d,
  gpuNUFFT::GpuNUFFTInfo* gi_host
  )
{
  long shared_mem_size = (gi_host->sector_dim)*sizeof(DType2);
  int thread_size =THREAD_BLOCK_SIZE;

  dim3 block_dim(thread_size);
  dim3 grid_dim(getOptimalGridDim(gi_host->sector_count,1));
  if (DEBUG)
  {
    printf("adjoint texture convolution requires %d bytes of shared memory!\n",shared_mem_size);
    printf("grid dim %d, block dim %d \n",grid_dim.x, block_dim.x); 
  }
  if (gi_host->is2Dprocessing)
    textureConvolutionKernel2D<<<grid_dim,block_dim,shared_mem_size>>>(data_d,crds_d,gdata_d,sectors_d,sector_centers_d,gi_host->sector_count);
  else
    textureConvolutionKernel<<<grid_dim,block_dim,shared_mem_size>>>(data_d,crds_d,gdata_d,sectors_d,sector_centers_d,gi_host->sector_count);

  if (DEBUG)
    printf("...finished with: %s\n", cudaGetErrorString(cudaGetLastError()));
}

void performTextureConvolution( DType2* data_d, 
  DType* crds_d, 
  CufftType* gdata_d,
  DType*			kernel_d, 
  IndType* sectors_d, 
  IndType2* sector_processing_order_d,
  IndType* sector_centers_d,
  gpuNUFFT::GpuNUFFTInfo* gi_host
  )
{
  long shared_mem_size = (gi_host->sector_dim)*sizeof(DType2);
  int thread_size =THREAD_BLOCK_SIZE;

  dim3 block_dim(thread_size);
  dim3 grid_dim(getOptimalGridDim(gi_host->sector_count,1));
  if (DEBUG)
  {
    printf("adjoint balanced texture convolution requires %d bytes of shared memory!\n",shared_mem_size);
    printf("grid dim %d, block dim %d \n",grid_dim.x, block_dim.x); 
  }
  if (gi_host->is2Dprocessing)
    balancedTextureConvolutionKernel2D<<<grid_dim,block_dim,shared_mem_size>>>(data_d,crds_d,gdata_d,sectors_d,sector_processing_order_d,sector_centers_d,gi_host->sectorsToProcess);
  else
    balancedTextureConvolutionKernel<<<grid_dim,block_dim,shared_mem_size>>>(data_d,crds_d,gdata_d,sectors_d,sector_processing_order_d,sector_centers_d,gi_host->sectorsToProcess);

  if (DEBUG)
    printf("...finished with: %s\n", cudaGetErrorString(cudaGetLastError()));
}

// ----------------------------------------------------------------------------
// forwardConvolutionKernel: NUFFT kernel
//
// Performs the inverse gpuNUFFT step by convolution of grid points with 
// interpolation function and resampling onto trajectory. 
//
// parameters:
//  * data           : complex output sample points
//  * crds           : coordinates of data points (x,y,z)
//  * gdata          : input grid data 
//  * sectors        : mapping of sample indices according to each sector
//  * sector_centers : coordinates (x,y,z) of sector centers
//  * N              : number of threads

__device__ void textureForwardConvolutionFunction(int* sec, int sec_max, int sec_offset, DType2* sdata, CufftType* gdata_cache, DType2* data, DType* crds, CufftType* gdata, IndType* sectors, IndType* sector_centers)
{
  int ind, imin, imax, jmin, jmax,kmin,kmax, k, i, j;
  DType dx_sqr, dy_sqr, dz_sqr, val, ix, jy, kz;

  __shared__ IndType3 center;
  center.x = sector_centers[sec[threadIdx.x] * 3];
  center.y = sector_centers[sec[threadIdx.x] * 3 + 1];
  center.z = sector_centers[sec[threadIdx.x] * 3 + 2];

  __shared__ int sector_ind_offset;
  sector_ind_offset = computeXYZ2Lin(center.x - GI.sector_offset,center.y - GI.sector_offset,center.z - GI.sector_offset,GI.gridDims);

  // init sector cache 
  // preload sector grid data into cache
  for (int ind=threadIdx.x; ind<GI.sector_dim; ind+=blockDim.x)
  {
    int grid_index;
    getCoordsFromIndex(ind,&i,&j,&k,GI.sector_pad_width);

    if (isOutlier(i,j,k,center.x,center.y,center.z,GI.gridDims,GI.sector_offset))
      //calculate opposite index
      grid_index = computeXYZ2Lin(calculateOppositeIndex(i,center.x,GI.gridDims.x,GI.sector_offset),
      calculateOppositeIndex(j,center.y,GI.gridDims.y,GI.sector_offset),
      calculateOppositeIndex(k,center.z,GI.gridDims.z,GI.sector_offset),
      GI.gridDims);
    else
      grid_index = (sector_ind_offset + computeXYZ2Lin(i,j,k,GI.gridDims));

    gdata_cache[ind].x = tex1Dfetch(texGDATA,grid_index).x;
    gdata_cache[ind].y = tex1Dfetch(texGDATA,grid_index).y;
  }
    
  __syncthreads();

  //Grid Points over Threads
  int data_cnt = sectors[sec[threadIdx.x]] + threadIdx.x + sec_offset;
   
  while (data_cnt < sec_max)
  {
    DType3 data_point; //datapoint per thread
    data_point.x = crds[data_cnt];
    data_point.y = crds[data_cnt + GI.data_count];
    data_point.z = crds[data_cnt + 2*GI.data_count];

    // set the boundaries of final dataset for gpuNUFFT this point
    ix = (data_point.x + 0.5f) * (GI.gridDims.x) - center.x + GI.sector_offset;
    set_minmax(&ix, &imin, &imax, GI.sector_pad_max, GI.kernel_radius);
    jy = (data_point.y + 0.5f) * (GI.gridDims.y) - center.y + GI.sector_offset;
    set_minmax(&jy, &jmin, &jmax, GI.sector_pad_max, GI.kernel_radius);
    kz = (data_point.z + 0.5f) * (GI.gridDims.z) - center.z + GI.sector_offset;
    set_minmax(&kz, &kmin, &kmax, GI.sector_pad_max, GI.kernel_radius);

    // convolve neighboring cartesian points to this data point
    k = kmin;
    while (k<=kmax && k>=kmin)
    {
      kz = static_cast<DType>((k + center.z - GI.sector_offset)) / static_cast<DType>((GI.gridDims.z)) - 0.5f;
      dz_sqr = (kz - data_point.z)*GI.aniso_z_scale;
      dz_sqr *= dz_sqr;

      j=jmin;
      while (j<=jmax && j>=jmin)
      {
        jy = static_cast<DType>(j + center.y - GI.sector_offset) / static_cast<DType>((GI.gridDims.y)) - 0.5f;
        dy_sqr = (jy - data_point.y) * GI.aniso_y_scale;
        dy_sqr *= dy_sqr;
        i=imin;								
        while (i<=imax && i>=imin)
        {
          ix = static_cast<DType>(i + center.x - GI.sector_offset) / static_cast<DType>((GI.gridDims.x)) - 0.5f;
          dx_sqr = (ix - data_point.x)*GI.aniso_x_scale;
          dx_sqr *= dx_sqr;
          
          // get kernel value
          val = computeTextureLookup(dx_sqr*GI.radiusSquared_inv,dy_sqr*GI.radiusSquared_inv,dz_sqr*GI.radiusSquared_inv);

          ind = getIndex(i,j,k,GI.sector_pad_width);

          sdata[threadIdx.x].x += gdata_cache[ind].x * val; 
          sdata[threadIdx.x].y += gdata_cache[ind].y * val;									

          i++;
        } // x loop
        j++;
      } // y loop
      k++;
    } // z loop
    atomicAdd(&(data[data_cnt].x),sdata[threadIdx.x].x);
    atomicAdd(&(data[data_cnt].y),sdata[threadIdx.x].y);

    data_cnt = data_cnt + blockDim.x;

    sdata[threadIdx.x].x = (DType)0.0;//Re
    sdata[threadIdx.x].y = (DType)0.0;//Im
  } //data points per sector
}

__global__ void textureForwardConvolutionKernel(CufftType* data, 
  DType*     crds, 
  CufftType* gdata,
  IndType* sectors, 
  IndType* sector_centers,
  int N)
{
  extern __shared__ CufftType shared[];//externally managed shared memory
  CufftType* shared_out_data =(CufftType*) &shared[0];  
  CufftType* gdata_cache =(CufftType*) &shared[blockDim.x]; 

  __shared__ int sec[THREAD_BLOCK_SIZE];
  sec[threadIdx.x]= blockIdx.x;
  
  //init shared memory
  shared_out_data[threadIdx.x].x = (DType)0.0;//Re
  shared_out_data[threadIdx.x].y = (DType)0.0;//Im

  __syncthreads();
  //start convolution
  while (sec[threadIdx.x] < N)
  {
    __shared__ int data_max;
    data_max = sectors[sec[threadIdx.x]+1];	

    textureForwardConvolutionFunction(sec,data_max,0,shared_out_data,gdata_cache,data,crds,gdata,sectors,sector_centers);
    __syncthreads();
    sec[threadIdx.x]= sec[threadIdx.x] + gridDim.x;
  } //sector check
}

__global__ void balancedTextureForwardConvolutionKernel(CufftType* data, 
  DType*     crds, 
  CufftType* gdata,
  IndType* sectors, 
  IndType2* sector_processing_order,
  IndType* sector_centers,
  int N)
{
  extern __shared__ CufftType shared[];//externally managed shared memory
  CufftType* shared_out_data =(CufftType*) &shared[0];  
  CufftType* gdata_cache =(CufftType*) &shared[blockDim.x]; 
  
  int sec_cnt = blockIdx.x;
  __shared__ int sec[THREAD_BLOCK_SIZE];

  //init shared memory
  shared_out_data[threadIdx.x].x = (DType)0.0;//Re
  shared_out_data[threadIdx.x].y = (DType)0.0;//Im

  __syncthreads();
  //start convolution
  while (sec_cnt < N)
  {
    sec[threadIdx.x] = sector_processing_order[sec_cnt].x;
    __shared__ int data_max;
    data_max = min(sectors[sec[threadIdx.x]+1],sectors[sec[threadIdx.x]] + threadIdx.x + sector_processing_order[sec_cnt].y+MAXIMUM_PAYLOAD);
       
    textureForwardConvolutionFunction(sec,data_max,sector_processing_order[sec_cnt].y,shared_out_data,gdata_cache,data,crds,gdata,sectors,sector_centers);
    __syncthreads();
    sec_cnt = sec_cnt + gridDim.x;
  } //sector check
}

__device__ void textureForwardConvolutionFunction2D(int* sec, int sec_max, int sec_offset, DType2* sdata, CufftType* gdata_cache, DType2* data, DType* crds, CufftType* gdata, IndType* sectors, IndType* sector_centers)
{
  int ind, imin, imax, jmin, jmax, i, j;
  DType dx_sqr, dy_sqr, val, ix, jy;

  __shared__ IndType2 center;
  center.x = sector_centers[sec[threadIdx.x] * 2];
  center.y = sector_centers[sec[threadIdx.x] * 2 + 1];

  __shared__ int sector_ind_offset;
  sector_ind_offset = computeXY2Lin(center.x - GI.sector_offset,center.y - GI.sector_offset,GI.gridDims);

    // init sector cache 
  // preload sector grid data into cache
  for (int ind=threadIdx.x; ind<GI.sector_dim; ind+=blockDim.x)
  {
    int grid_index;
    getCoordsFromIndex2D(ind,&i,&j,GI.sector_pad_width);

    // multiply data by current kernel val 
    // grid complex or scalar 
    if (isOutlier2D(i,j,center.x,center.y,GI.gridDims.x,GI.sector_offset))
      //calculate opposite index
      grid_index = getIndex2D(calculateOppositeIndex(i,center.x,GI.gridDims.x,GI.sector_offset),
      calculateOppositeIndex(j,center.y,GI.gridDims.y,GI.sector_offset),
      GI.gridDims.x);
    else
      grid_index = (sector_ind_offset + getIndex2D(i,j,GI.gridDims.x));

    gdata_cache[ind].x = tex1Dfetch(texGDATA,grid_index).x;
    gdata_cache[ind].y = tex1Dfetch(texGDATA,grid_index).y;
  }
  __syncthreads();

  //Grid Points over Threads
  int data_cnt = sectors[sec[threadIdx.x]] + threadIdx.x + sec_offset;
    
  while (data_cnt < sec_max)
  {
    DType2 data_point; //datapoint per thread
    data_point.x = crds[data_cnt];
    data_point.y = crds[data_cnt + GI.data_count];

    // set the boundaries of final dataset for gpuNUFFT this point
    ix = (data_point.x + 0.5f) * (GI.gridDims.x) - center.x + GI.sector_offset;
    set_minmax(&ix, &imin, &imax, GI.sector_pad_max, GI.kernel_radius);
    jy = (data_point.y + 0.5f) * (GI.gridDims.y) - center.y + GI.sector_offset;
    set_minmax(&jy, &jmin, &jmax, GI.sector_pad_max, GI.kernel_radius);

    // convolve neighboring cartesian points to this data point
    j=jmin;
    while (j<=jmax && j>=jmin)
    {
      jy = static_cast<DType>(j + center.y - GI.sector_offset) / static_cast<DType>((GI.gridDims.y)) - 0.5f;   //(j - center_y) *width_inv;
      dy_sqr = (jy - data_point.y) * GI.aniso_y_scale;
      dy_sqr *= dy_sqr;
      i=imin;								
      while (i<=imax && i>=imin)
      {
        ix = static_cast<DType>(i + center.x - GI.sector_offset) / static_cast<DType>((GI.gridDims.x)) - 0.5f;// (i - center_x) *width_inv;
        dx_sqr = (ix - data_point.x)*GI.aniso_x_scale;
        dx_sqr *= dx_sqr;
        // get kernel value
        // calc as separable filter
        val = computeTextureLookup(dx_sqr*GI.radiusSquared_inv,dy_sqr*GI.radiusSquared_inv);
   
        ind = getIndex2D(i,j,GI.sector_pad_width);

        sdata[threadIdx.x].x += gdata_cache[ind].x * val; 
        sdata[threadIdx.x].y += gdata_cache[ind].y * val;									
        i++;
      } // x loop
    j++;
    } // y loop
    atomicAdd(&(data[data_cnt].x),sdata[threadIdx.x].x);
    atomicAdd(&(data[data_cnt].y),sdata[threadIdx.x].y);

    data_cnt = data_cnt + blockDim.x;

    sdata[threadIdx.x].x = (DType)0.0;//Re
    sdata[threadIdx.x].y = (DType)0.0;//Im
  } //data points per sector
}

__global__ void textureForwardConvolutionKernel2D(CufftType* data, 
  DType*     crds, 
  CufftType* gdata,
  IndType* sectors, 
  IndType* sector_centers,
  int N)
{
  extern __shared__ CufftType shared[];//externally managed shared memory
  CufftType* shared_out_data =(CufftType*) &shared[0];  
  CufftType* gdata_cache =(CufftType*) &shared[blockDim.x]; 

  __shared__ int sec[THREAD_BLOCK_SIZE];
  sec[threadIdx.x]= blockIdx.x;

  //init shared memory
  shared_out_data[threadIdx.x].x = (DType)0.0;//Re
  shared_out_data[threadIdx.x].y = (DType)0.0;//Im
  __syncthreads();
  //start convolution
  while (sec[threadIdx.x] < N)
  {
    __shared__ int data_max;
    data_max = sectors[sec[threadIdx.x]+1];

    textureForwardConvolutionFunction2D(sec,data_max,0,shared_out_data,gdata_cache,data,crds,gdata,sectors,sector_centers);

    __syncthreads();
    sec[threadIdx.x]= sec[threadIdx.x] + gridDim.x;
  } //sector check
}

__global__ void balancedTextureForwardConvolutionKernel2D(CufftType* data, 
  DType*     crds, 
  CufftType* gdata,
  IndType* sectors, 
  IndType2* sector_processing_order,
  IndType* sector_centers,
  int N)
{
  extern __shared__ CufftType shared[];//externally managed shared memory
  CufftType* shared_out_data =(CufftType*) &shared[0];  
  CufftType* gdata_cache =(CufftType*) &shared[blockDim.x]; 

  int sec_cnt= blockIdx.x;
  __shared__ int sec[THREAD_BLOCK_SIZE];
  
  //init shared memory
  shared_out_data[threadIdx.x].x = (DType)0.0;//Re
  shared_out_data[threadIdx.x].y = (DType)0.0;//Im
  __syncthreads();
  //start convolution
  while (sec_cnt < N)
  {
    sec[threadIdx.x] = sector_processing_order[sec_cnt].x;
    __shared__ int data_max;
    data_max = min(sectors[sec[threadIdx.x]+1],sectors[sec[threadIdx.x]] + threadIdx.x + sector_processing_order[sec_cnt].y+MAXIMUM_PAYLOAD);
    
    textureForwardConvolutionFunction2D(sec,data_max,sector_processing_order[sec_cnt].y,shared_out_data,gdata_cache,data,crds,gdata,sectors,sector_centers);

    __syncthreads();
    sec_cnt = sec_cnt + gridDim.x;
  } //sector check
}


void performTextureForwardConvolution( CufftType*		data_d, 
  DType*			crds_d, 
  CufftType*		gdata_d,
  DType*			kernel_d, 
  IndType*		sectors_d, 
  IndType*		sector_centers_d,
  gpuNUFFT::GpuNUFFTInfo*	gi_host
  )
{
  int thread_size =THREAD_BLOCK_SIZE;
  long shared_mem_size = (thread_size + gi_host->sector_dim) * sizeof(CufftType);//empiric

  dim3 block_dim(thread_size);
  dim3 grid_dim(getOptimalGridDim(gi_host->sector_count,thread_size));

  if (DEBUG)
    printf("texture forward convolution requires %d bytes of shared memory!\n",shared_mem_size);
  if (gi_host->is2Dprocessing)
    textureForwardConvolutionKernel2D<<<grid_dim,block_dim,shared_mem_size>>>(data_d,crds_d,gdata_d,sectors_d,sector_centers_d,gi_host->sector_count);
  else
    textureForwardConvolutionKernel<<<grid_dim,block_dim,shared_mem_size>>>(data_d,crds_d,gdata_d,sectors_d,sector_centers_d,gi_host->sector_count);
}

void performTextureForwardConvolution( CufftType*		data_d, 
  DType*			crds_d, 
  CufftType*  gdata_d,
  DType*			kernel_d, 
  IndType*		sectors_d, 
  IndType2*   sector_processing_order_d,
  IndType*		sector_centers_d,
  gpuNUFFT::GpuNUFFTInfo*	gi_host
  )
{
  int thread_size =THREAD_BLOCK_SIZE;
  long shared_mem_size = (thread_size + gi_host->sector_dim) * sizeof(CufftType);//empiric

  dim3 block_dim(thread_size);
  dim3 grid_dim(getOptimalGridDim(gi_host->sector_count,thread_size));

  if (DEBUG)
    printf("balanced texture forward convolution requires %d bytes of shared memory!\n",shared_mem_size);
  if (gi_host->is2Dprocessing)
    balancedTextureForwardConvolutionKernel2D<<<grid_dim,block_dim,shared_mem_size>>>(data_d,crds_d,gdata_d,sectors_d,sector_processing_order_d,sector_centers_d,gi_host->sectorsToProcess);
  else
    balancedTextureForwardConvolutionKernel<<<grid_dim,block_dim,shared_mem_size>>>(data_d,crds_d,gdata_d,sectors_d,sector_processing_order_d,sector_centers_d,gi_host->sectorsToProcess);
}

#endif
