#ifndef MINIGUN_CUDA_ADVANCE_ALL_CUH_
#define MINIGUN_CUDA_ADVANCE_ALL_CUH_

#include "./cuda_common.cuh"

namespace minigun {
namespace advance {

#define MAX_NTHREADS 1024
#define PER_THREAD_WORKLOAD 1
#define MAX_NBLOCKS 65535

// Binary search the row_offsets to find the source node of the edge id.
__device__ __forceinline__ mg_int BinarySearchSrc(const IntArray1D& array, mg_int eid) {
  mg_int lo = 0, hi = array.length - 1;
  while (lo < hi) {
    mg_int mid = (lo + hi) >> 1;
    if (_ldg(array.data + mid) <= eid) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  // INVARIANT: lo == hi
  if (_ldg(array.data + hi) == eid) {
    return hi;
  } else {
    return hi - 1;
  }
}

template <typename Config,
          typename GData,
          typename Functor>
__global__ void CudaAdvanceAllGunrockLBOutKernel(
    Csr csr,
    GData gdata,
    IntArray1D output_frontier) {
  mg_int ty = blockIdx.y * blockDim.y + threadIdx.y;
  mg_int stride_y = blockDim.y * gridDim.y;
  mg_int eid = ty;
  while (eid < csr.column_indices.length) {
    // TODO(minjie): this is pretty inefficient; binary search is needed only
    //   when the thread is processing the neighbor list of a new node.
    mg_int src = BinarySearchSrc(csr.row_offsets, eid);
    mg_int dst = _ldg(csr.column_indices.data + eid);
    if (Functor::CondEdge(src, dst, eid, &gdata)) {
      Functor::ApplyEdge(src, dst, eid, &gdata);
      // Add dst/eid to output frontier
      if (Config::kMode == kV2V || Config::kMode == kE2V) {
        output_frontier.data[eid] = dst;
      } else if (Config::kMode == kV2E || Config::kMode == kE2E) {
        output_frontier.data[eid] = eid;
      }
    } else {
      if (Config::kMode != kV2N && Config::kMode != kE2N) {
        // Add invalid to output frontier
        output_frontier.data[eid] = kInvalid;
      }
    }
    eid += stride_y;
  }
};

template <typename Config,
          typename GData,
          typename Functor,
          typename Alloc>
void CudaAdvanceAllGunrockLBOut(
    const RuntimeConfig& rtcfg,
    const Csr& csr,
    GData* gdata,
    IntArray1D output_frontier,
    Alloc* alloc) {
  CHECK_GT(rtcfg.data_num_blocks, 0);
  CHECK_GT(rtcfg.data_num_threads, 0);
  const mg_int M = csr.column_indices.length;
  const int ty = MAX_NTHREADS / rtcfg.data_num_threads;
  const int ny = ty * PER_THREAD_WORKLOAD;
  const int by = std::min((M + ny - 1) / ny, static_cast<mg_int>(MAX_NBLOCKS));
  const dim3 nblks(rtcfg.data_num_blocks, by);
  const dim3 nthrs(rtcfg.data_num_threads, ty);
  //LOG(INFO) << "Blocks: (" << nblks.x << "," << nblks.y << ") Threads: ("
    //<< nthrs.x << "," << nthrs.y << ")";
  CudaAdvanceAllGunrockLBOutKernel<Config, GData, Functor>
    <<<nblks, nthrs, 0, rtcfg.stream>>>(csr, *gdata, output_frontier);
}

template <typename Config,
          typename GData,
          typename Functor,
          typename Alloc>
void CudaAdvanceAll(
    AdvanceAlg algo,
    const RuntimeConfig& rtcfg,
    const Csr& csr,
    GData* gdata,
    IntArray1D* output_frontier,
    Alloc* alloc) {
  mg_int out_len = csr.column_indices.length;
  if (output_frontier) {
    if (output_frontier->data == nullptr) {
      // Allocate output frointer buffer, the length is equal to the number
      // of edges.
      output_frontier->length = out_len;
      output_frontier->data = alloc->template AllocateData<mg_int>(
          output_frontier->length * sizeof(mg_int));
    } else {
      CHECK_GE(output_frontier->length, out_len)
        << "Require output frontier of length " << out_len
        << " but only got a buffer of length " << output_frontier->length;
    }
  }
  IntArray1D outbuf = (output_frontier)? *output_frontier : IntArray1D();
  switch (algo) {
    case kGunrockLBOut :
      CudaAdvanceAllGunrockLBOut<Config, GData, Functor, Alloc>(
          rtcfg, csr, gdata, outbuf, alloc);
      break;
    default:
      LOG(FATAL) << "Algorithm " << algo << " is not supported.";
  }
}

#undef MAX_NTHREADS
#undef PER_THREAD_WORKLOAD
#undef MAX_NBLOCKS

}  // namespace advance
}  // namespace minigun

#endif  // MINIGUN_CUDA_ADVANCE_ALL_CUH_
