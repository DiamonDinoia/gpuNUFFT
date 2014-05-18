TODOs gpuNUFFT: + ... done, - ... TODO
 + kernel in const mem + tests
 + coordinate structe as float3 + coalesced read instructions via shared memory 
   (http://www.scribd.com/doc/37932042/CUDA-Performance-Optimization, 
    http://www.cs.nthu.edu.tw/~cherung/teaching/2010gpucell/CUDA02.pdf)
 + streams for per channel operation in order to avoid out of mem -> due to pinned mem not possible
 + shared approach evaluation
 + density compensation via gpu
 + scaling (after fft) on gpu
 - measure, correct and conserve TILED access kernels
 - comment code
 - evaluate norm 
 - ensure single precision CPU tests
