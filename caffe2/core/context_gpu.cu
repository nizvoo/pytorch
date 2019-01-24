#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <string>
#include <unordered_map>

#include <c10/cuda/CUDACachingAllocator.h>

#include "cub/util_allocator.cuh"

// Needed to be included first to check the CAFFE2_USE_CUDNN macros.
#include "caffe2/core/macros.h"

#include "caffe2/core/asan.h"
#include "caffe2/core/blob_stats.h"
#ifdef CAFFE2_USE_CUDNN
#include "caffe2/core/common_cudnn.h"
#endif // CAFFE2_USE_CUDNN
#include "caffe2/core/context_gpu.h"
#include "caffe2/core/init.h"
#include "caffe2/core/logging.h"
#include "caffe2/core/tensor.h"
#include "caffe2/utils/string_utils.h"

C10_DEFINE_string(
    caffe2_cuda_memory_pool,
    "thc",
    "Sets the memory pool used by caffe2. Possible values are "
    "none, cnmem, thc and cub.");

// For description of CUB caching allocator configuration, see
// https://nvlabs.github.io/cub/structcub_1_1_caching_device_allocator.html
C10_DEFINE_int(
    caffe2_cub_bin_growth,
    8,
    "If using cub as the memory allocator, sets the growth of bins "
    "used by the cub pool.");
C10_DEFINE_int(
    caffe2_cub_min_bin,
    3,
    "If using cub as the memory allocator, sets the min number of "
    "bins.");
C10_DEFINE_int(
    caffe2_cub_max_bin,
    10,
    "If using cub as the memory allocator, sets the max number of "
    "bins.");
C10_DEFINE_int(
    caffe2_cub_max_managed_mb,
    10 * 1024,
    "If using cub as the memory allocators, sets the maximum amount "
    "of memory managed in gigabytes");

C10_DEFINE_bool(
    caffe2_cub_print_allocation_events,
    false,
    "If true CachingDeviceAllocator will print allocation and deallocation "
    "events to stdout.");

C10_DEFINE_bool(
    caffe2_gpu_memory_tracking,
    false,
    "If set, logs changes in GPU memory allocations");
C10_DEFINE_int(
    caffe2_gpu_memory_report_interval_mb,
    128,
    "The threshold in MB on how frequently to report memory changes");

namespace at {

REGISTER_CONTEXT(DeviceType::CUDA, caffe2::CUDAContext);
} // namespace at

namespace caffe2 {

// Generic implementation - CUDA will handle the right function to call for us
void CUDAContext::CopyBytesAsync(
    size_t nbytes,
    const void* src,
    Device src_device,
    void* dst,
    Device dst_device) {
  // TODO: verify that the CUDA handles copy from device to device correctly
  // even without SetDevice()
  // TODO: verify whether source or dest device should be a priority in picking
  // the stream
  // NB: right now the cross-device copy logic is invoked only in the contexts
  // when surrounding code explicitly manages data dependencies and sets up
  // events, so it's fine.  In order to make it a standalone function proper
  // synchronization between stream is required
  int gpu_id = 0;
  if (dst_device.type() == DeviceType::CUDA) {
    gpu_id = dst_device.index();
  } else if (src_device.type() == DeviceType::CUDA) {
    gpu_id = src_device.index();
  } else {
    LOG(FATAL) << "shouldn't be called with non-cuda device";
  }
  CUDA_ENFORCE(cudaMemcpyAsync(
      dst,
      src,
      nbytes,
      cudaMemcpyDefault,
      CUDAContext::getCudaObjects().GetStream(gpu_id)));
}

void CUDAContext::CopyBytesSync(
    size_t nbytes,
    const void* src,
    Device src_device,
    void* dst,
    Device dst_device) {
  // This emulates Caffe2 original behavior where sync copy doesn't change the
  // device. It's probably better for clarity to switch to the target device
  // explicitly here, but in the worst case CUDA would sync for us.
  // TODO: change it to DeviceGuard
  CUDAContext context(-1); // take current device
  CUDA_ENFORCE(cudaMemcpyAsync(
      dst, src, nbytes, cudaMemcpyDefault, context.cuda_stream()));
  // destructor of context synchronizes
}

// For the CPU context, we also allow a (probably expensive) function
// to copy the data from a cuda context. Inside the function, we create
// a temporary CUDAContext object to carry out the copy. From the caller's
// side, these functions are synchronous with respect to the host, similar
// to a normal CPUContext::CopyBytes<CPUContext, CPUContext> call.
template <>
inline void CPUContext::CopyBytes<CUDAContext, CPUContext>(
    size_t nbytes,
    const void* src,
    void* dst) {
  CUDAContext context(GetGPUIDForPointer(src));
  context.CopyBytes<CUDAContext, CPUContext>(nbytes, src, dst);
}
template <>
inline void CPUContext::CopyBytes<CPUContext, CUDAContext>(
    size_t nbytes,
    const void* src,
    void* dst) {
  CUDAContext context(GetGPUIDForPointer(dst));
  context.CopyBytes<CPUContext, CUDAContext>(nbytes, src, dst);
}

} // namespace caffe2

namespace caffe2 {

ThreadLocalCUDAObjects& CUDAContext::getCudaObjects() {
  static thread_local ThreadLocalCUDAObjects cuda_objects_;
  return cuda_objects_;
}

// TODO(jiayq): these variables shouldn't be currently accessed during static
// initialization. We should consider moving them to a Mayer's singleton to
// be totally safe against SIOF.

// Static global variables for setting up the memory pool.
CudaMemoryPoolType g_cuda_memory_pool_type;

std::unique_ptr<cub::CachingDeviceAllocator> g_cub_allocator;

// an unordered map that holds the map from the cuda memory pointer to the
// device id that it is allocated from. This is used in the cuda memory pool
// cases, where we need the device id to carry out the deletion.
// Note(jiayq): an alternate approach is to use cudaGetPointerAttributes, but
// that is usually quite slow. We might want to benchmark the speed difference
// though.
// Note(jiayq): another alternate approach is to augment the Tensor class that
// would allow one to record the device id. However, this does not address any
// non-tensor allocation and deallocation.
// Ideally, a memory pool should already have the device id information, as
// long as we are using UVA (as of CUDA 5 and later) so the addresses are
// unique.
static std::unordered_map<void*, uint8_t> g_cuda_device_affiliation;

// Data structures for optional memory tracking. Access to these structures
// is garded by the CUDAContext::mutex.
static std::unordered_map<void*, long> g_size_map;
static std::vector<long> g_total_by_gpu_map(C10_COMPILE_TIME_MAX_GPUS, 0);
static std::vector<long> g_max_by_gpu_map(C10_COMPILE_TIME_MAX_GPUS, 0);

static long g_total_mem = 0;
static long g_last_rep = 0;

CudaMemoryPoolType GetCudaMemoryPoolType() {
  return g_cuda_memory_pool_type;
}

///////////////////////////////////////////////////////////////////////////////
// A wrapper to allow us to lazily initialize all cuda environments that Caffe
// uses. This gets done the first time a caffe2::CUDAContext::New() gets called
// which is probably the decisive indication that this caffe2 run is going to
// use GPUs. We avoid cuda initialization with core/init.h functionalities so
// that we have minimal resource impact in case we will need to run multiple
// caffe2 instances on a GPU machine.
///////////////////////////////////////////////////////////////////////////////

static void Caffe2InitializeCuda() {
  // If the current run does not have any cuda devices, do nothing.
  if (!HasCudaGPU()) {
    VLOG(1) << "No cuda gpu present. Skipping.";
    return;
  }
  // Check if the number of GPUs matches the expected compile-time max number
  // of GPUs.
  CAFFE_ENFORCE_LE(
      NumCudaDevices(),
      C10_COMPILE_TIME_MAX_GPUS,
      "Number of CUDA devices on the machine is larger than the compiled "
      "max number of gpus expected (",
      C10_COMPILE_TIME_MAX_GPUS,
      "). Increase that and recompile.");

  for (DeviceIndex i = 0; i < NumCudaDevices(); ++i) {
    DeviceGuard g(i);
    // Enable peer access.
    const int peer_group = i / CAFFE2_CUDA_MAX_PEER_SIZE;
    const int peer_start = peer_group * CAFFE2_CUDA_MAX_PEER_SIZE;
    const int peer_end = std::min(
        NumCudaDevices(), (peer_group + 1) * CAFFE2_CUDA_MAX_PEER_SIZE);
    VLOG(1) << "Enabling peer access within group #" << peer_group
            << ", from gpuid " << peer_start << " to " << peer_end - 1
            << ", for gpuid " << i << ".";

    for (int j = peer_start; j < peer_end; ++j) {
      if (i == j) continue;
      int can_access;
      CUDA_ENFORCE(cudaDeviceCanAccessPeer(&can_access, i, j));
      if (can_access) {
        VLOG(1) << "Enabling peer access from " << i << " to " << j;
        // Note: just for future reference, the 0 here is not a gpu id, it is
        // a reserved flag for cudaDeviceEnablePeerAccess that should always be
        // zero currently.
        CUDA_ENFORCE(cudaDeviceEnablePeerAccess(j, 0));
      }
    }
  }

#ifdef CAFFE2_USE_CUDNN
  // Check the versions of cuDNN that were compiled and linked with are compatible
  CheckCuDNNVersions();
#endif // CAFFE2_USE_CUDNN
}

static void SetUpCub() {
  VLOG(1) << "Setting up cub memory pool.";
  // Sets up the cub memory pool
  try {
    g_cub_allocator.reset(new cub::CachingDeviceAllocator(
        FLAGS_caffe2_cub_bin_growth,
        FLAGS_caffe2_cub_min_bin,
        FLAGS_caffe2_cub_max_bin,
        size_t(FLAGS_caffe2_cub_max_managed_mb) * 1024L * 1024L,
        false,
        FLAGS_caffe2_cub_print_allocation_events));
  } catch (...) {
    CAFFE_THROW("Some error happened at cub initialization.");
  }
  VLOG(1) << "Done setting up cub memory pool.";
}

static void Caffe2SetCUDAMemoryPool() {
  if (FLAGS_caffe2_cuda_memory_pool == "" ||
      FLAGS_caffe2_cuda_memory_pool == "none") {
    g_cuda_memory_pool_type = CudaMemoryPoolType::NONE;
  } else if (FLAGS_caffe2_cuda_memory_pool == "cnmem") {
    CAFFE_THROW("CNMEM is no longer used by Caffe2. Use cub instead. "
                "This error message may go away in the future.");
  } else if (FLAGS_caffe2_cuda_memory_pool == "cub") {
    // Sets up cub.
    g_cuda_memory_pool_type = CudaMemoryPoolType::CUB;
    SetUpCub();
  } else if (FLAGS_caffe2_cuda_memory_pool == "thc") {
    g_cuda_memory_pool_type = CudaMemoryPoolType::THC;
  } else {
    CAFFE_THROW(
        "Unrecognized cuda memory pool type: ", FLAGS_caffe2_cuda_memory_pool);
  }
}

static PinnedCPUAllocator g_pinned_cpu_alloc;

// An initialization function that sets the CPU side to use pinned cpu
// allocator.
void Caffe2UsePinnedCPUAllocator() {
#if CAFFE2_ASAN_ENABLED
  // Note(jiayq): for more details, see
  //     https://github.com/google/sanitizers/issues/629
  LOG(WARNING) << "There are known issues between address sanitizer and "
                  "cudaMallocHost. As a result, caffe2 will not enable pinned "
                  "memory allocation in asan mode. If you are expecting any "
                  "behavior that depends on asan, be advised that it is not "
                  "turned on.";
#else
  if (!HasCudaGPU()) {
    VLOG(1) << "No GPU present. I won't use pinned allocator then.";
    return;
  }
  VLOG(1) << "Caffe2 gpu: setting CPUAllocator to PinnedCPUAllocator.";
  SetCPUAllocator(&g_pinned_cpu_alloc);
#endif
}

// Caffe2CudaInitializerHelper is a minimal struct whose sole purpose is to
// detect the first hint that this Caffe2 run is going to use GPU: either
// CUDAContext is initialized or CUDAContext::New is called. It then runs
// all the related cuda initialization functions.
namespace {
struct Caffe2CudaInitializerHelper {
  Caffe2CudaInitializerHelper() {
    // We cannot use bool because nvcc changes bool to __nv_bool which does
    // not have a std::atomic instantiation.
    static std::atomic<char> first_call(1);
    if (first_call.fetch_and((char)0)) {
      Caffe2InitializeCuda();
      Caffe2SetCUDAMemoryPool();
      Caffe2UsePinnedCPUAllocator();
    }
  }
};
} // namespace

/**
 * A utility function to rectify the gpu id. If the context specifies the
 * gpu id to be -1, it means that we will just use the current gpu id when
 * the function is being called.
 */
static inline DeviceIndex RectifyGPUID(DeviceIndex gpu_id) {
  return gpu_id == -1 ? CaffeCudaGetDevice() : gpu_id;
}

CUDAContext::CUDAContext(DeviceIndex gpu_id)
    : gpu_id_(RectifyGPUID(gpu_id)), random_seed_(RandomNumberSeed()) {
  static Caffe2CudaInitializerHelper g_cuda_initializer_;
}

CUDAContext::CUDAContext(const DeviceOption& option)
    : gpu_id_(
          option.has_device_id() ? RectifyGPUID(option.device_id())
                                   : CaffeCudaGetDevice()),
      random_seed_(
          option.has_random_seed() ? option.random_seed()
                                   : RandomNumberSeed()) {
  static Caffe2CudaInitializerHelper g_cuda_initializer_;
  DCHECK_EQ(option.device_type(), PROTO_CUDA);
}

// shared mutex to lock out alloc / free during NCCL launches
std::mutex& CUDAContext::mutex() {
  static std::mutex m;
  return m;
}

std::vector<long> CUDAContext::TotalMemoryByGpu() {
  std::lock_guard<std::mutex> lock(CUDAContext::mutex());
  CAFFE_ENFORCE(
      FLAGS_caffe2_gpu_memory_tracking,
      "Pass --caffe2_gpu_memory_tracking to enable memory stats");
  return g_total_by_gpu_map;
}

std::vector<long> CUDAContext::MaxMemoryByGpu() {
  std::lock_guard<std::mutex> lock(CUDAContext::mutex());
  CAFFE_ENFORCE(
      FLAGS_caffe2_gpu_memory_tracking,
      "Pass --caffe2_gpu_memory_tracking to enable memory stats");
  return g_max_by_gpu_map;
}

namespace {
void TrackMemoryAlloc(size_t nbytes) {
  int this_gpu = CaffeCudaGetDevice();
  g_total_by_gpu_map[this_gpu] += nbytes;
  g_max_by_gpu_map[this_gpu] =
      max(g_max_by_gpu_map[this_gpu], g_total_by_gpu_map[this_gpu]);
  g_total_mem += nbytes;
  if (g_total_mem - g_last_rep >
      FLAGS_caffe2_gpu_memory_report_interval_mb * 1024 * 1024) {
    for (int gpu = 0; gpu < g_total_by_gpu_map.size(); gpu++) {
      long t = g_total_by_gpu_map[gpu];
      long max_t = g_max_by_gpu_map[gpu];
      if (max_t > 0) {
        if (max_t != t) {
          VLOG(1) << "GPU " << gpu << ": " << t / 1024 / 1024 << " MB"
                  << " (max: " << max_t / 1024 / 1024 << " MB)";
        } else {
          VLOG(1) << "GPU " << gpu << ": " << t / 1024 / 1024 << " MB";
        }
      }
    }
    VLOG(1) << "Total: " << g_total_mem / 1024 / 1024 << " MB";
    g_last_rep = g_total_mem;
  }
}
}

struct DefaultCUDAAllocator final : public at::Allocator {
  DefaultCUDAAllocator() {}
  ~DefaultCUDAAllocator() override {}
  at::DataPtr allocate(size_t nbytes) const override {
    // Lock the mutex
    std::lock_guard<std::mutex> lock(CUDAContext::mutex());
    // A one-time caffe2 cuda initializer.
    static Caffe2CudaInitializerHelper g_cuda_initializer_;
    at::DataPtr r;

    if (FLAGS_caffe2_gpu_memory_tracking) {
      TrackMemoryAlloc(nbytes);
    }
    void* ptr = nullptr;  // scrap space

    // WARNING: If you update this switch statement, you must
    // also update the switch statement in raw_deleter.
    switch (g_cuda_memory_pool_type) {
      case CudaMemoryPoolType::NONE:
        CUDA_ENFORCE(cudaMalloc(&ptr, nbytes));
        r = {ptr, ptr, &DeleteNONE, at::Device(CUDA, CaffeCudaGetDevice())};
        if (FLAGS_caffe2_gpu_memory_tracking) {
          g_cuda_device_affiliation[r.get()] = CaffeCudaGetDevice();
        }
        break;
      case CudaMemoryPoolType::CUB:
        CUDA_ENFORCE(g_cub_allocator->DeviceAllocate(&ptr, nbytes));
        r = {ptr, ptr, &DeleteCUB, at::Device(CUDA, CaffeCudaGetDevice())};
        // NB: device affiliation tracking is mandatory for CUB, as
        // deleter must know what device a pointer lives on to free it.
        g_cuda_device_affiliation[r.get()] = CaffeCudaGetDevice();
        VLOG(2) << "CUB allocating pointer " << r.get() << " on device "
                << CaffeCudaGetDevice();
        break;
      case CudaMemoryPoolType::THC:
        r = c10::cuda::CUDACachingAllocator::get()->allocate(nbytes);
        if (FLAGS_caffe2_gpu_memory_tracking) {
          g_cuda_device_affiliation[r.get()] = CaffeCudaGetDevice();
          auto b = r.compare_exchange_deleter(
            &c10::cuda::CUDACachingAllocator::raw_delete,
            &DeleteTHCWithTracking
          );
          AT_ASSERT(b);
        }
        break;
    }
    if (FLAGS_caffe2_gpu_memory_tracking) {
      g_size_map[r.get()] = nbytes;
    }
    return r;
  }

  at::DeleterFnPtr raw_deleter() const override {
    // WARNING: This must be kept up-to-date the switch statement in allocate
    switch (g_cuda_memory_pool_type) {
      case CudaMemoryPoolType::NONE:
        return &DeleteNONE;
      case CudaMemoryPoolType::CUB:
        return &DeleteCUB;
      case CudaMemoryPoolType::THC:
        if (FLAGS_caffe2_gpu_memory_tracking) {
          return &DeleteTHCWithTracking;
        } else {
          return &c10::cuda::CUDACachingAllocator::raw_delete;
        }
    }
    return nullptr;
  }

 private:
  // WARNING: You MUST take CUDAContext::mutex() before calling this function.
  // NB: This should only be called when FLAGS_caffe2_gpu_memory_tracking is
  // true.
  static void UpdateSizeMapOnDelete(void* ptr) {
    auto sz_it = g_size_map.find(ptr);
    DCHECK(sz_it != g_size_map.end());
    auto aff_it = g_cuda_device_affiliation.find(ptr);
    DCHECK(aff_it != g_cuda_device_affiliation.end());
    g_total_mem -= sz_it->second;
    g_total_by_gpu_map[aff_it->second] -= sz_it->second;
    g_size_map.erase(sz_it);
  }

  static void DeleteTHCWithTracking(void* ptr) {
    std::lock_guard<std::mutex> lock(CUDAContext::mutex());
    AT_ASSERT(FLAGS_caffe2_gpu_memory_tracking);
    UpdateSizeMapOnDelete(ptr);
    c10::cuda::CUDACachingAllocator::raw_delete(ptr);
    g_cuda_device_affiliation.erase(g_cuda_device_affiliation.find(ptr));
  }

  static void DeleteNONE(void* ptr) {
    std::lock_guard<std::mutex> lock(CUDAContext::mutex());
    if (FLAGS_caffe2_gpu_memory_tracking) {
      UpdateSizeMapOnDelete(ptr);
    }
    // If memory pool is not set up, use simple cudaFree.
    cudaError_t error = cudaFree(ptr);
    // For some reason, in Python runtime we sometimes delete a data pointer
    // after the cuda runtime exits - this is odd but is probably caused by
    // a static workspace that pycaffe2 uses, and the destruction got
    // entangled in some race condition. Anyway, since cuda runtime is
    // exiting anyway, we will not need to worry about memory leak, so we
    // basically ignore it. This is definitely not ideal but works for now.
    if (error != cudaSuccess && error != cudaErrorCudartUnloading) {
      LOG(FATAL) << "Error at: " << __FILE__ << ":" << __LINE__ << ": "
                 << cudaGetErrorString(error);
    }
    if (FLAGS_caffe2_gpu_memory_tracking) {
      g_cuda_device_affiliation.erase(g_cuda_device_affiliation.find(ptr));
    }
  }

  static void DeleteCUB(void* ptr) {
    std::lock_guard<std::mutex> lock(CUDAContext::mutex());
    if (FLAGS_caffe2_gpu_memory_tracking) {
      UpdateSizeMapOnDelete(ptr);
    }
    auto it = g_cuda_device_affiliation.find(ptr);
    DCHECK(it != g_cuda_device_affiliation.end());
    VLOG(2) << "CUB freeing pointer " << ptr << " on device " << it->second;
    CUDA_ENFORCE(g_cub_allocator->DeviceFree(it->second, ptr));
    g_cuda_device_affiliation.erase(it);
  }
};

static DefaultCUDAAllocator g_cuda_alloc;
REGISTER_ALLOCATOR(CUDA, &g_cuda_alloc);

} // namespace caffe2

namespace at {
REGISTER_COPY_BYTES_FUNCTION(
    DeviceType::CUDA,
    DeviceType::CUDA,
    caffe2::CUDAContext::CopyBytesSync,
    caffe2::CUDAContext::CopyBytesAsync);

REGISTER_COPY_BYTES_FUNCTION(
    DeviceType::CUDA,
    DeviceType::CPU,
    caffe2::CUDAContext::CopyBytesSync,
    caffe2::CUDAContext::CopyBytesAsync);

REGISTER_COPY_BYTES_FUNCTION(
    DeviceType::CPU,
    DeviceType::CUDA,
    caffe2::CUDAContext::CopyBytesSync,
    caffe2::CUDAContext::CopyBytesAsync);
} // namespace at
