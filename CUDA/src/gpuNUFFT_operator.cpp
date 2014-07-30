
#include "gpuNUFFT_operator.hpp"
#include "gpuNUFFT_kernels.hpp"
#include "cufft_config.hpp"
#include "cuda_utils.hpp"
#include "precomp_kernels.hpp"

#include <iostream>

template <typename T>
T* gpuNUFFT::GpuNUFFTOperator::selectOrdered(gpuNUFFT::Array<T>& dataArray,int offset)
{
  T* dataSorted = (T*) calloc(dataArray.count(),sizeof(T)); //2* re + im

  for (IndType i=0; i<dataIndices.count();i++)
  {
    for (IndType chn=0; chn<dataArray.dim.channels; chn++)
    {
      dataSorted[i+chn*offset] = dataArray.data[dataIndices.data[i]+chn*offset];
    }
  }
  return dataSorted;
}

template <typename T>
void gpuNUFFT::GpuNUFFTOperator::writeOrdered(gpuNUFFT::Array<T>& destArray, T* sortedArray, int offset)
{
  for (IndType i=0; i<dataIndices.count();i++)
  {
    for (IndType chn=0; chn<destArray.dim.channels; chn++)
    {
      destArray.data[dataIndices.data[i]+chn*offset] = sortedArray[i+chn*offset];
    }
  }
}

void gpuNUFFT::GpuNUFFTOperator::initKernel()
{
  IndType kernelSize = calculateGrid3KernelSize(osf, kernelWidth/2.0f);
  this->kernel.dim.length = kernelSize;
  this->kernel.data = (DType*) calloc(this->kernel.count(),sizeof(DType));
  load1DKernel(this->kernel.data,(int)kernelSize,(int)kernelWidth,osf);
}

gpuNUFFT::GpuNUFFTInfo* gpuNUFFT::GpuNUFFTOperator::initGpuNUFFTInfo()
{
  gpuNUFFT::GpuNUFFTInfo* gi_host = (gpuNUFFT::GpuNUFFTInfo*)malloc(sizeof(gpuNUFFT::GpuNUFFTInfo));

  gi_host->data_count = (int)this->kSpaceTraj.count();
  gi_host->sector_count = (int)this->gridSectorDims.count();
  gi_host->sector_width = (int)sectorDims.width;

  gi_host->kernel_width = (int)this->kernelWidth; 
  gi_host->kernel_widthSquared = (int)(this->kernelWidth * this->kernelWidth);
  gi_host->kernel_count = (int)this->kernel.count();

  gi_host->grid_width_dim = (int)this->getGridDims().count();
  gi_host->grid_width_offset= (int)(floor(this->getGridDims().width / (DType)2.0));

  gi_host->im_width_dim = (int)imgDims.count();
  gi_host->im_width_offset.x = (int)(floor(imgDims.width / (DType)2.0));
  gi_host->im_width_offset.y = (int)(floor(imgDims.height / (DType)2.0));
  gi_host->im_width_offset.z = (int)(floor(imgDims.depth / (DType)2.0));

  gi_host->imgDims.x = imgDims.width;
  gi_host->imgDims.y = imgDims.height;
  gi_host->imgDims.z = imgDims.depth;
  gi_host->imgDims_count = imgDims.width*imgDims.height*DEFAULT_VALUE(imgDims.depth);//TODO check why not imgDims.count()

  gi_host->gridDims.x = this->getGridDims().width;
  gi_host->gridDims.y = this->getGridDims().height;
  gi_host->gridDims.z = this->getGridDims().depth;
  gi_host->gridDims_count = this->getGridDims().width*this->getGridDims().height*DEFAULT_VALUE(this->getGridDims().depth);//s.a.

  //The largest value of the grid dimensions determines the kernel radius (resolution) in k-space units
  int max_grid_dim = MAX(MAX(this->getGridDims().width,this->getGridDims().height),this->getGridDims().depth);

  double kernel_radius = static_cast<double>(this->kernelWidth) / 2.0;
  double radius = kernel_radius / static_cast<double>(max_grid_dim);

  DType kernel_width_inv = (DType)1.0 / static_cast<DType>(this->kernelWidth);

  double radiusSquared = radius * radius;
  double kernelRadius_invSqr = 1.0 / radiusSquared;
  DType dist_multiplier = (DType)((this->kernel.count() - 1) * kernelRadius_invSqr);

  if (DEBUG)
    printf("radius rel. to grid width %f\n",radius);

  gpuNUFFT::Dimensions sectorPadDims = sectorDims + 2*(int)(floor(this->kernelWidth / (DType)2.0));

  int sector_pad_width = (int)sectorPadDims.width;
  int sector_dim = (int)sectorPadDims.count();
  int sector_offset = (int)(floor(sector_pad_width / (DType)2.0));

  gi_host->grid_width_inv.x = (DType)1.0 / static_cast<DType>(this->getGridDims().width);
  gi_host->grid_width_inv.y = (DType)1.0 / static_cast<DType>(this->getGridDims().height);
  gi_host->grid_width_inv.z = (DType)1.0 / static_cast<DType>(this->getGridDims().depth);
  gi_host->kernel_widthInvSquared = kernel_width_inv * kernel_width_inv;
  gi_host->osr = this->osf;

  gi_host->kernel_radius = (DType)kernel_radius;
  gi_host->sector_pad_width = sector_pad_width;
  gi_host->sector_pad_max = sector_pad_width - 1;
  gi_host->sector_dim = sector_dim;
  gi_host->sector_offset = sector_offset;

  gi_host->aniso_x_scale = ((DType)this->getGridDims().width/(DType)max_grid_dim);
  gi_host->aniso_y_scale = ((DType)this->getGridDims().height/(DType)max_grid_dim);
  gi_host->aniso_z_scale = ((DType)this->getGridDims().depth/(DType)max_grid_dim);

  gi_host->radiusSquared = (DType)radiusSquared;
  gi_host->radiusSquared_inv = (DType)kernelRadius_invSqr;
  gi_host->dist_multiplier = dist_multiplier;

  gi_host->is2Dprocessing = this->is2DProcessing();
  return gi_host;
}

gpuNUFFT::GpuNUFFTInfo* gpuNUFFT::GpuNUFFTOperator::initAndCopyGpuNUFFTInfo()
{
  GpuNUFFTInfo* gi_host = initGpuNUFFTInfo();
    if (DEBUG)
    printf("copy GpuNUFFT Info to symbol memory... size = %ld \n",sizeof(gpuNUFFT::GpuNUFFTInfo));

  initConstSymbol("GI",gi_host,sizeof(gpuNUFFT::GpuNUFFTInfo));

  //free(gi_host);
  if (DEBUG)
    printf("...done!\n");
  return gi_host;
}

void gpuNUFFT::GpuNUFFTOperator::adjConvolution(DType2* data_d, 
      DType* crds_d, 
      CufftType* gdata_d,
      DType* kernel_d, 
      IndType* sectors_d,
      IndType* sector_centers_d,
  gpuNUFFT::GpuNUFFTInfo* gi_host)
{
  performConvolution(data_d,crds_d,gdata_d,kernel_d,sectors_d,sector_centers_d,gi_host);
}

void gpuNUFFT::GpuNUFFTOperator::forwardConvolution(CufftType*		data_d, 
  DType*			crds_d, 
  CufftType*		gdata_d,
  DType*			kernel_d, 
  IndType*		sectors_d, 
  IndType*		sector_centers_d,
  gpuNUFFT::GpuNUFFTInfo* gi_host)
{
  performForwardConvolution(data_d,crds_d,gdata_d,kernel_d,sectors_d,sector_centers_d,gi_host);
}

void gpuNUFFT::GpuNUFFTOperator::initLookupTable()
{
  initConstSymbol("KERNEL",(void*)this->kernel.data,this->kernel.count()*sizeof(DType));
}
  
void gpuNUFFT::GpuNUFFTOperator::freeLookupTable()
{
    
}

void gpuNUFFT::GpuNUFFTOperator::initDeviceMemory(int n_coils)
{
  if (gpuMemAllocated)
    return;

  gi_host = initAndCopyGpuNUFFTInfo();//

  int			data_count          = (int)this->kSpaceTraj.count();
  IndType imdata_count        = this->imgDims.count();
  int			sector_count        = (int)this->gridSectorDims.count();
    
  if (DEBUG)
    printf("allocate and copy data indices of size %d...\n",dataIndices.count());
  allocateAndCopyToDeviceMem<IndType>(&data_indices_d,dataIndices.data,dataIndices.count());
  
  if (DEBUG)
    printf("allocate and copy data of size %d...\n",data_count);
  allocateDeviceMem<DType2>(&data_sorted_d,data_count);
  
  if (DEBUG)
    printf("allocate and copy gdata of size %d...\n",gi_host->grid_width_dim);
  allocateDeviceMem<CufftType>(&gdata_d,gi_host->grid_width_dim);

  if (DEBUG)
    printf("allocate and copy coords of size %d...\n",getImageDimensionCount()*data_count);
  allocateAndCopyToDeviceMem<DType>(&crds_d,this->kSpaceTraj.data,getImageDimensionCount()*data_count);

  if (DEBUG)
    printf("allocate and copy kernel in const memory of size %d...\n",this->kernel.count());

  initLookupTable();

  //allocateAndCopyToDeviceMem<DType>(&kernel_d,kernel,kernel_count);
  if (DEBUG)
    printf("allocate and copy sectors of size %d...\n",sector_count+1);
  allocateAndCopyToDeviceMem<IndType>(&sectors_d,this->sectorDataCount.data,sector_count+1);

  if (DEBUG)
    printf("allocate and copy sector_centers of size %d...\n",getImageDimensionCount()*sector_count);
  allocateAndCopyToDeviceMem<IndType>(&sector_centers_d,(IndType*)this->getSectorCentersData(),getImageDimensionCount()*sector_count);

  if (this->applyDensComp())	
  {
    if (DEBUG)
      printf("allocate and copy density compensation of size %d...\n",data_count);
    allocateAndCopyToDeviceMem<DType>(&density_comp_d,this->dens.data,data_count);
  }

  if (this->applySensData())	
  {
    if (DEBUG)
      printf("allocate sens data of size %d...\n",imdata_count);
    allocateDeviceMem<DType2>(&sens_d,imdata_count);
  }
  
  if (n_coils > 1)
  {
    if (DEBUG)
      printf("allocate precompute deapofunction of size %d...\n",imdata_count);
    allocateDeviceMem<DType>(&deapo_d,imdata_count);
    precomputeDeapodization(deapo_d,gi_host);
  }
  if (DEBUG)
    printf("sector pad width: %d\n",gi_host->sector_pad_width);

  //Inverse fft plan and execution
  if (DEBUG)
    printf("creating cufft plan with %d,%d,%d dimensions\n",DEFAULT_VALUE(gi_host->gridDims.z),gi_host->gridDims.y,gi_host->gridDims.x);
  cufftResult res = cufftPlan3d(&fft_plan, (int)DEFAULT_VALUE(gi_host->gridDims.z),(int)gi_host->gridDims.y,(int)gi_host->gridDims.x, CufftTransformType) ;
  if (res != CUFFT_SUCCESS) 
    fprintf(stderr,"error on CUFFT Plan creation!!! %d\n",res);
  gpuMemAllocated = true;
}

void gpuNUFFT::GpuNUFFTOperator::freeDeviceMemory(int n_coils)
{
  if (!gpuMemAllocated)
    return;

  cufftDestroy(fft_plan);
  // Destroy the cuFFT plan.
  if (DEBUG && (cudaThreadSynchronize() != cudaSuccess))
    printf("error at thread synchronization 9: %s\n",cudaGetErrorString(cudaGetLastError()));
  freeLookupTable();
  
  freeTotalDeviceMemory(data_indices_d,data_sorted_d,crds_d,gdata_d,sectors_d,sector_centers_d,NULL);//NULL as stop
  
  if (n_coils > 1 && deapo_d != NULL)
    cudaFree(deapo_d);
  
  if (this->applySensData())
    cudaFree(sens_d);
  
  if (this->applyDensComp())
    cudaFree(density_comp_d);

  showMemoryInfo();
  gpuMemAllocated = false;
}


// ----------------------------------------------------------------------------
// performGpuNUFFTAdj: NUFFT^H
//
// GpuNUFFT implementation - interpolation from nonuniform k-space data onto 
//                           oversampled grid based on optimized gpuNUFFT kernel
//                           with minimal oversampling ratio (see Beatty et al.)
//
// Basic steps: - density compensation
//              - convolution with interpolation function
//              - iFFT
//              - cropping due to oversampling ratio
//              - apodization correction
//
// parameters:
//	* data		     : input kspace data 
//  * data_count   : number of samples on trajectory
//  * n_coils      : number of channels or coils
//  * crds         : coordinate array on trajectory
//  * imdata       : output image data
//  * imdata_count : number of image data points
//  * grid_width   : size of grid 
//  * kernel       : precomputed convolution kernel as lookup table
//  * kernel_count : number of kernel lookup table entries
//  * sectors      : mapping of start and end points of each sector
//  * sector_count : number of sectors
//  * sector_centers: coordinates (x,y,z) of sector centers
//  * sector_width : width of sector 
//  * im_width     : dimension of image
//  * osr          : oversampling ratio
//  * do_comp      : true, if density compensation has to be done
//  * density_comp : densiy compensation array
//  * gpuNUFFT_out : enum indicating how far gpuNUFFT has to be processed
//  
void gpuNUFFT::GpuNUFFTOperator::performGpuNUFFTAdj(gpuNUFFT::Array<DType2> kspaceData, gpuNUFFT::Array<CufftType>& imgData, GpuNUFFTOutput gpuNUFFTOut)
{
  if (DEBUG)
  {
    std::cout << "performing gpuNUFFT adjoint!!!" << std::endl;
    std::cout << "dataCount: " << kspaceData.count() << " chnCount: " << kspaceData.dim.channels << std::endl;
    std::cout << "imgCount: " << imgData.count() << " gridWidth: " << this->getGridWidth() << std::endl;
    std::cout << "apply density comp: " << this->applyDensComp() << std::endl;
    std::cout << "apply sens data: " << this->applySensData() << std::endl;
  }
  if (debugTiming)
    startTiming();

  showMemoryInfo();

  int			data_count          = (int)this->kSpaceTraj.count();
  int			n_coils             = (int)kspaceData.dim.channels;
  IndType imdata_count        = this->imgDims.count();
  int			sector_count        = (int)this->gridSectorDims.count();

  // select data ordered and leave it on gpu
  DType2* data_d;

  if (DEBUG)
    printf("allocate data of size %d...\n",data_count);
  allocateDeviceMem<DType2>(&data_d,data_count);

  CufftType *imdata_d, *imdata_sum_d = NULL;

  if (DEBUG)
    printf("allocate and copy imdata of size %d...\n",imdata_count);
  allocateDeviceMem<CufftType>(&imdata_d,imdata_count);

  if (this->applySensData())
  {
    if (DEBUG)
      printf("allocate and copy temp imdata of size %d...\n",imdata_count);
    allocateDeviceMem<CufftType>(&imdata_sum_d,imdata_count);
    cudaMemset(imdata_sum_d,0,imdata_count*sizeof(CufftType));
  }

  initDeviceMemory(n_coils);
  int err;

  if (debugTiming)
    printf("Memory allocation: %.2f ms\n",stopTiming());

  //iterate over coils and compute result
  for (int coil_it = 0; coil_it < n_coils; coil_it++)
  {
    int data_coil_offset = coil_it * data_count;
    int im_coil_offset = coil_it * (int)imdata_count;//gi_host->width_dim;

    cudaMemset(gdata_d,0, sizeof(CufftType)*gi_host->grid_width_dim);
    //copy coil data to device and select ordered
    copyToDevice(kspaceData.data + data_coil_offset,data_d,data_count);
    selectOrderedGPU(data_d,data_indices_d,data_sorted_d,data_count);

    if (this->applyDensComp())
      performDensityCompensation(data_sorted_d,density_comp_d,gi_host);

    if (DEBUG && (cudaThreadSynchronize() != cudaSuccess))
      printf("error at adj thread synchronization 1: %s\n",cudaGetErrorString(cudaGetLastError()));
    
    if (debugTiming)
      startTiming();

    adjConvolution(data_sorted_d,crds_d,gdata_d,NULL,sectors_d,sector_centers_d,gi_host);

    if (debugTiming)
      printf("Adjoint convolution: %.2f ms\n",stopTiming());

    if (DEBUG && (cudaThreadSynchronize() != cudaSuccess))
      fprintf(stderr,"error at adj  thread synchronization 2: %s\n",cudaGetErrorString(cudaGetLastError()));
    if (gpuNUFFTOut == CONVOLUTION)
    {
      if (DEBUG)
        printf("stopping output after CONVOLUTION step\n");
      //get output
      copyFromDevice<CufftType>(gdata_d,imgData.data,gi_host->grid_width_dim);
      if (DEBUG)
        printf("test value at point zero: %f\n",(imgData.data)[0].x);

      free(gi_host);
      freeTotalDeviceMemory(data_d,imdata_d,imdata_sum_d,NULL);
      freeDeviceMemory(n_coils);
      return;
    }
    if ((cudaThreadSynchronize() != cudaSuccess))
      fprintf(stderr,"error at adj thread synchronization 3: %s\n",cudaGetErrorString(cudaGetLastError()));
    
    if (debugTiming)
      startTiming();

    performFFTShift(gdata_d,INVERSE,getGridDims(),gi_host);

    //Inverse FFT
    if (err=pt2CufftExec(fft_plan, gdata_d, gdata_d, CUFFT_INVERSE) != CUFFT_SUCCESS)
    {
      fprintf(stderr,"cufft has failed at adj with err %i \n",err);
      showMemoryInfo(true,stderr);
    }
    if (DEBUG && (cudaThreadSynchronize() != cudaSuccess))
      fprintf(stderr,"error at adj thread synchronization 4: %s\n",cudaGetErrorString(cudaGetLastError()));

    if (gpuNUFFTOut == FFT)
    {
      if (DEBUG)
        printf("stopping output after FFT step\n");
      //get output
      copyFromDevice<CufftType>(gdata_d,imgData.data,gi_host->grid_width_dim);

      free(gi_host);
      
      freeTotalDeviceMemory(data_d,imdata_d,imdata_sum_d,NULL);
      freeDeviceMemory(n_coils);
      
      printf("last cuda error: %s\n", cudaGetErrorString(cudaGetLastError()));
      return;
    }
    if (DEBUG && (cudaThreadSynchronize() != cudaSuccess))
      printf("error at adj thread synchronization 5: %s\n",cudaGetErrorString(cudaGetLastError()));
    performFFTShift(gdata_d,INVERSE,getGridDims(),gi_host);
    
    if (debugTiming)
      printf("iFFT (incl. shift) : %.2f ms\n",stopTiming());

    if (DEBUG && (cudaThreadSynchronize() != cudaSuccess))
      printf("error at adj thread synchronization 6: %s\n",cudaGetErrorString(cudaGetLastError()));
    performCrop(gdata_d,imdata_d,gi_host);

    if (DEBUG && (cudaThreadSynchronize() != cudaSuccess))
      printf("error at adj thread synchronization 7: %s\n",cudaGetErrorString(cudaGetLastError()));
    //check if precomputed deapo function can be used
    if (n_coils > 1 && deapo_d != NULL)
      performDeapodization(imdata_d,deapo_d,gi_host);
    else
      performDeapodization(imdata_d,gi_host);
    if (DEBUG && (cudaThreadSynchronize() != cudaSuccess))
      printf("error at adj thread synchronization 8: %s\n",cudaGetErrorString(cudaGetLastError()));

    performFFTScaling(imdata_d,gi_host->im_width_dim,gi_host);
    if (DEBUG && (cudaThreadSynchronize() != cudaSuccess))
      printf("error: at adj  thread synchronization 9: %s\n",cudaGetErrorString(cudaGetLastError()));

    if (this->applySensData())
    {
      copyToDevice(this->sens.data + im_coil_offset, sens_d,imdata_count);
      performSensMul(imdata_d,sens_d,gi_host,true);
      performSensSum(imdata_d,imdata_sum_d,gi_host);
    }
    else
    {
      // get result per coil
      // no summation is performed in absence of sensitity data
      copyFromDevice<CufftType>(imdata_d,imgData.data+im_coil_offset,imdata_count);
    }

    if (DEBUG && (cudaThreadSynchronize() != cudaSuccess))
      printf("error: at adj  thread synchronization 10: %s\n",cudaGetErrorString(cudaGetLastError()));
  }//iterate over coils
  
  if (this->applySensData())
  {
    // get result of combined coils
    copyFromDevice<CufftType>(imdata_sum_d,imgData.data,imdata_count);
  }

  if (DEBUG && (cudaThreadSynchronize() != cudaSuccess))
    printf("error: at adj  thread synchronization 11: %s\n",cudaGetErrorString(cudaGetLastError()));
  
  freeTotalDeviceMemory(data_d,imdata_d,imdata_sum_d,NULL);
  freeDeviceMemory(n_coils);
  if ((cudaThreadSynchronize() != cudaSuccess))
    fprintf(stderr,"error in gpuNUFFT_gpu_adj function: %s\n",cudaGetErrorString(cudaGetLastError()));
  free(gi_host);
}

gpuNUFFT::Array<CufftType> gpuNUFFT::GpuNUFFTOperator::performGpuNUFFTAdj(gpuNUFFT::Array<DType2> kspaceData, GpuNUFFTOutput gpuNUFFTOut)
{
  // init result
  gpuNUFFT::Array<CufftType> imgData;

  if (gpuNUFFTOut == gpuNUFFT::CONVOLUTION)
  {
    imgData.dim = this->getGridDims();
    imgData.dim.channels = kspaceData.dim.channels;
    imgData.data = (CufftType*)calloc(imgData.count(),sizeof(CufftType));
  }
  else
  {
    imgData.dim = this->getImageDims();
    // if sens data is present a summation over all coils is performed automatically
    // thus the output only contains one channel
    imgData.dim.channels = this->applySensData() ? 1 : kspaceData.dim.channels;
    imgData.data = (CufftType*)calloc(imgData.count(),sizeof(CufftType));
  }
  performGpuNUFFTAdj(kspaceData,imgData,gpuNUFFTOut);

  return imgData;
}

gpuNUFFT::Array<CufftType> gpuNUFFT::GpuNUFFTOperator::performGpuNUFFTAdj(gpuNUFFT::Array<DType2> kspaceData)
{
  return performGpuNUFFTAdj(kspaceData,DEAPODIZATION);
}

// ----------------------------------------------------------------------------
// gpuNUFFT_gpu: NUFFT
//
// Inverse gpuNUFFT implementation - interpolation from uniform grid data onto 
//                                   nonuniform k-space data based on optimized 
//                                   gpuNUFFT kernel with minimal oversampling
//                                   ratio (see Beatty et al.)
//
// Basic steps: - apodization correction
//              - zero padding with osf
//              - FFT
//							- convolution and resampling
//
// parameters:
//	* data		     : output kspace data 
//  * data_count   : number of samples on trajectory
//  * n_coils      : number of channels or coils
//  * crds         : coordinates on trajectory, passed as SoA
//  * imdata       : input image data
//  * imdata_count : number of image data points
//  * grid_width   : size of grid 
//  * kernel       : precomputed convolution kernel as lookup table
//  * kernel_count : number of kernel lookup table entries
//  * sectors      : mapping of data indices according to each sector
//  * sector_count : number of sectors
//  * sector_centers: coordinates (x,y,z) of sector centers
//  * sector_width : width of sector 
//  * im_width     : dimension of image
//  * osr          : oversampling ratio
//  * gpuNUFFT_out : enum indicating how far gpuNUFFT has to be processed
//  
void gpuNUFFT::GpuNUFFTOperator::performForwardGpuNUFFT(gpuNUFFT::Array<DType2> imgData,gpuNUFFT::Array<CufftType>& kspaceData, GpuNUFFTOutput gpuNUFFTOut)
{
  if (DEBUG)
  {
    std::cout << "performing forward gpuNUFFT!!!" << std::endl;
    std::cout << "dataCount: " << kspaceData.count() << " chnCount: " << kspaceData.dim.channels << std::endl;
    std::cout << "imgCount: " << imgData.count() << " gridWidth: " << this->getGridWidth() << std::endl;
  }
  showMemoryInfo();
  
  if (debugTiming)
    startTiming();

  int			data_count          = (int)this->kSpaceTraj.count();
  int			n_coils             = (int)kspaceData.dim.channels;
  IndType	imdata_count        = this->imgDims.count();
  int			sector_count        = (int)this->gridSectorDims.count();

  //cuda mem allocation
  DType2 *imdata_d;
  CufftType *data_d;

  if (DEBUG)
    printf("allocate and copy imdata of size %d...\n",imdata_count);
  allocateDeviceMem<DType2>(&imdata_d,imdata_count);

  if (DEBUG)
    printf("allocate and copy data of size %d...\n",data_count);
  allocateDeviceMem<CufftType>(&data_d,data_count);

  initDeviceMemory(n_coils);
    
  if (debugTiming)
    printf("Memory allocation: %.2f ms\n",stopTiming());

  int err;

  //iterate over coils and compute result
  for (int coil_it = 0; coil_it < n_coils; coil_it++)
  {
    int data_coil_offset = coil_it * data_count;
    int im_coil_offset = coil_it * (int)imdata_count;

    if (this->applySensData())
      // perform automatically "repeating" of input image in case
      // of existing sensitivity data
      copyToDevice(imgData.data,imdata_d,imdata_count);
    else
      copyToDevice(imgData.data + im_coil_offset,imdata_d,imdata_count);

    //reset temp arrays
    cudaMemset(gdata_d,0, sizeof(CufftType)*gi_host->grid_width_dim);
    cudaMemset(data_d,0, sizeof(CufftType)*data_count);

    if (DEBUG && (cudaThreadSynchronize() != cudaSuccess))
      printf("error at thread synchronization 1: %s\n",cudaGetErrorString(cudaGetLastError()));
    
    if (this->applySensData())
    {
      copyToDevice(this->sens.data + im_coil_offset, sens_d,imdata_count);
      performSensMul(imdata_d,sens_d,gi_host,false);
    }

    // apodization Correction
    if (n_coils > 1 && deapo_d != NULL)
      performForwardDeapodization(imdata_d,deapo_d,gi_host);
    else
      performForwardDeapodization(imdata_d,gi_host);

    if (DEBUG && (cudaThreadSynchronize() != cudaSuccess))
      printf("error at thread synchronization 2: %s\n",cudaGetErrorString(cudaGetLastError()));
    // resize by oversampling factor and zero pad
    performPadding(imdata_d,gdata_d,gi_host);

    if (debugTiming)
      startTiming();

    if (DEBUG && (cudaThreadSynchronize() != cudaSuccess))
      printf("error at thread synchronization 3: %s\n",cudaGetErrorString(cudaGetLastError()));
    // shift image to get correct zero frequency position
    performFFTShift(gdata_d,INVERSE,getGridDims(),gi_host);

    if (DEBUG && (cudaThreadSynchronize() != cudaSuccess))
      printf("error at thread synchronization 4: %s\n",cudaGetErrorString(cudaGetLastError()));
    // eventually free imdata_d
    // Forward FFT to kspace domain
    if (err=pt2CufftExec(fft_plan, gdata_d, gdata_d, CUFFT_FORWARD) != CUFFT_SUCCESS)
    {
      fprintf(stderr,"cufft has failed with err %i \n",err);
      showMemoryInfo(true,stderr);
    }

    if (DEBUG && (cudaThreadSynchronize() != cudaSuccess))
      printf("error at thread synchronization 5: %s\n",cudaGetErrorString(cudaGetLastError()));
    performFFTShift(gdata_d,FORWARD,getGridDims(),gi_host);

    if (DEBUG && (cudaThreadSynchronize() != cudaSuccess))
      printf("error at thread synchronization 6: %s\n",cudaGetErrorString(cudaGetLastError()));

    if (debugTiming)
      printf("FFT (incl. shift): %.2f ms\n",stopTiming());

    if (debugTiming)
      startTiming();

    // convolution and resampling to non-standard trajectory
    forwardConvolution(data_d,crds_d,gdata_d,NULL,sectors_d,sector_centers_d,gi_host);
    if (DEBUG && (cudaThreadSynchronize() != cudaSuccess))
      printf("error at thread synchronization 7: %s\n",cudaGetErrorString(cudaGetLastError()));
    
    if (debugTiming)
      printf("Forward Convolution: %.2f ms\n",stopTiming());

    performFFTScaling(data_d,gi_host->data_count,gi_host);
    if (DEBUG && (cudaThreadSynchronize() != cudaSuccess))
      printf("error: at thread synchronization 8: %s\n",cudaGetErrorString(cudaGetLastError()));
    
    //write result in correct order back into output array
    writeOrderedGPU(data_sorted_d,data_indices_d,data_d,(int)this->kSpaceTraj.count());
    copyFromDevice(data_sorted_d,kspaceData.data + data_coil_offset,data_count);
  }//iterate over coils
  
  freeTotalDeviceMemory(data_d,imdata_d,NULL);
  freeDeviceMemory(n_coils);

  if ((cudaThreadSynchronize() != cudaSuccess))
    fprintf(stderr,"error in performForwardGpuNUFFT function: %s\n",cudaGetErrorString(cudaGetLastError()));
  free(gi_host);
}

gpuNUFFT::Array<CufftType> gpuNUFFT::GpuNUFFTOperator::performForwardGpuNUFFT(Array<DType2> imgData,GpuNUFFTOutput gpuNUFFTOut)
{
  gpuNUFFT::Array<CufftType> kspaceData;
  kspaceData.data = (CufftType*)calloc(this->kSpaceTraj.count()*imgData.dim.channels,sizeof(CufftType));
  kspaceData.dim = this->kSpaceTraj.dim;
  //TODO adapt size of channels depending on sens data
  kspaceData.dim.channels = imgData.dim.channels;

  performForwardGpuNUFFT(imgData,kspaceData,gpuNUFFTOut);

  return kspaceData;
}

gpuNUFFT::Array<CufftType> gpuNUFFT::GpuNUFFTOperator::performForwardGpuNUFFT(Array<DType2> imgData)
{
  return performForwardGpuNUFFT(imgData,CONVOLUTION);
}

void gpuNUFFT::GpuNUFFTOperator::startTiming()
{
  HANDLE_ERROR( cudaEventCreate(&start) );
  HANDLE_ERROR( cudaEventCreate(&stop) );
  HANDLE_ERROR( cudaEventRecord(start, 0) );
}

float gpuNUFFT::GpuNUFFTOperator::stopTiming()
{
  float time;

  HANDLE_ERROR( cudaEventRecord(stop, 0) );
  HANDLE_ERROR( cudaEventSynchronize(stop) );
  HANDLE_ERROR( cudaEventElapsedTime(&time, start, stop) );
  return time;
}
