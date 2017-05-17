#include <limits>
#include "Scan.h"

#define WARPSIZE 32
#define SCAN_WARPS 4

namespace {
  

  template<bool inclusive, bool writeSum0, bool writeSum1>
  __global__
  __launch_bounds__(SCAN_WARPS * WARPSIZE)
  void
  scan(uint32_t* output,
       uint32_t* sum0,
       uint32_t* sum1,
       const uint32_t* input,
       uint32_t N)
  {
    const uint32_t lane = threadIdx.x % WARPSIZE;
    const uint32_t warp = threadIdx.x / WARPSIZE;
    const uint32_t blockOffset = 4 * SCAN_WARPS * WARPSIZE * blockIdx.x;
    const uint32_t threadOffset = blockOffset + 4 * threadIdx.x;

    // Fetch
    uint4 a;
    if (threadOffset + 3 < N) {
       a = *reinterpret_cast<const uint4*>(input + threadOffset);
    }
    else if (N <= threadOffset) {
      a = make_uint4(0, 0, 0, 0);
    }
    else {
      a.x = input[threadOffset];
      a.y = threadOffset + 1 < N ? input[threadOffset + 1] : 0;
      a.z = threadOffset + 2 < N ? input[threadOffset + 2] : 0;
      a.w = 0;
    }
    uint32_t s = a.x + a.y + a.z + a.w;
    uint32_t q = s;

    // Per-warp reduce
    #pragma unroll
    for (uint32_t i = 1; i < WARPSIZE; i*=2) {
      uint32_t t = __shfl_up(s, i);
      if (i <= lane) {
        s += t;
      }
    }

    __shared__ uint32_t warpSum[SCAN_WARPS];
    if (lane == (WARPSIZE - 1)) {
      warpSum[warp] = s;
    }

    __syncthreads();

    #pragma unroll
    for (uint32_t w = 0; w < SCAN_WARPS - 1; w++) {
      if (w < warp) s += warpSum[w];
    }

    if (threadIdx.x == (SCAN_WARPS*WARPSIZE - 1)) {
      if (writeSum0) *sum0 = s;
      if (writeSum1) *sum1 = s;
    }

    if (inclusive == false) {
      s -= q; // exclusive scan
    }

    // Store
    if (threadOffset + 3 < N) {
      *reinterpret_cast<uint4*>(output + threadOffset) = make_uint4(s,
                                                                    s + a.x,
                                                                    s + a.x + a.y,
                                                                    s + a.x + a.y + a.z);
    }
    else if(threadOffset < N) {
      output[threadOffset + 0] = s;
      s += a.x;
      if (threadOffset + 1 < N) output[threadOffset + 1] = s;
      s += a.y;
      if (threadOffset + 2 < N) output[threadOffset + 2] = s;
    }

    
  }

}



template<>
size_t ComputeStuff::Scan::scratchByteSize<uint32_t>(size_t N)
{
  return sizeof(uint32_t)*42;
}

void ComputeStuff::Scan::calcOffsets(uint32_t* offsets_d,
                                     uint32_t* sum_d,
                                     uint32_t* scratch_d,
                                     const uint32_t* counts_d,
                                     size_t N,
                                     cudaStream_t stream)
{
  if (N <= std::numeric_limits<uint32_t>::max()) {
    uint32_t n = static_cast<uint32_t>(N);

    uint32_t blockSize = 4 * WARPSIZE;
    uint32_t blocks = (n + 4 * blockSize - 1) / (4 * blockSize);

    if (sum_d == nullptr) {
      scan<false, true, false> << <blocks, blockSize, 0, stream >> > (offsets_d, offsets_d + N, sum_d, counts_d, n);
    }
    else {
      scan<false, true, true> << <blocks, blockSize, 0, stream >> > (offsets_d, offsets_d + N, sum_d, counts_d, n);
    }
  }
}

void ComputeStuff::Scan::calcOffsets(uint32_t* offsets_d,
                                     uint32_t* scratch_d,
                                     const uint32_t* counts_d,
                                     size_t N,
                                     cudaStream_t stream)
{
  calcOffsets(offsets_d,
              nullptr,
              scratch_d,
              counts_d,
              N,
              stream);
}