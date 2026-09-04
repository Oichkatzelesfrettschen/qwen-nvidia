// One JPEG through nvImageCodec into a device buffer, then through CV-CUDA
// resize on the same stream, with the output read back once at the end for
// its digest. The claim is device residency between the two libraries: the
// decoded image lands in a strided device buffer nvImageCodec wrote on the
// caller's stream, CV-CUDA wraps that buffer as an NHWC tensor without a copy,
// and the resized tensor is a second device allocation. Every transfer the
// program makes is counted and printed, so a host bounce between decode and
// resize would read as a transfer beside the two the design allows: the
// encoded bytes in and the resized pixels out.
//
// Build: see scripts/run-nvidia-sdk-smoke.sh, which compiles against the
// prefixes scripts/nvidia-sdk-artifacts.tsv names and runs the binary under
// the GPU ownership lock.

#include <cuda_runtime.h>
#include <cvcuda/OpResize.h>
#include <nvcv/Tensor.h>
#include <nvcv/TensorData.h>
#include <nvimgcodec.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

namespace {

int host_to_device_transfers = 0;
int device_to_host_transfers = 0;

void fail(const char* what, long code) {
    std::fprintf(stderr, "nvidia_sdk_smoke=rejected step=%s code=%ld\n", what, code);
    std::exit(1);
}

void check_cuda(cudaError_t status, const char* what) {
    if (status != cudaSuccess) {
        std::fprintf(stderr, "%s: %s\n", what, cudaGetErrorString(status));
        fail(what, status);
    }
}

void check_codec(nvimgcodecStatus_t status, const char* what) {
    if (status != NVIMGCODEC_STATUS_SUCCESS) fail(what, status);
}

void check_nvcv(NVCVStatus status, const char* what) {
    if (status != NVCV_SUCCESS) fail(what, status);
}

unsigned long long fnv1a(const unsigned char* bytes, size_t count) {
    unsigned long long hash = 1469598103934665603ull;
    for (size_t index = 0; index < count; ++index) {
        hash ^= bytes[index];
        hash *= 1099511628211ull;
    }
    return hash;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc != 4) {
        std::fprintf(stderr, "usage: decode-resize JPEG_PATH OUT_WIDTH OUT_HEIGHT\n");
        return 2;
    }
    const std::string jpeg_path = argv[1];
    const int out_width = std::atoi(argv[2]);
    const int out_height = std::atoi(argv[3]);
    if (out_width <= 0 || out_height <= 0) return 2;

    std::ifstream file(jpeg_path, std::ios::binary);
    if (!file) fail("read_jpeg", 0);
    std::vector<unsigned char> encoded((std::istreambuf_iterator<char>(file)),
                                       std::istreambuf_iterator<char>());
    if (encoded.empty()) fail("read_jpeg", 0);

    int device = 0;
    check_cuda(cudaSetDevice(device), "cudaSetDevice");
    cudaDeviceProp properties{};
    check_cuda(cudaGetDeviceProperties(&properties, device), "cudaGetDeviceProperties");
    cudaStream_t stream;
    check_cuda(cudaStreamCreate(&stream), "cudaStreamCreate");

    nvimgcodecInstanceCreateInfo_t instance_info{};
    instance_info.struct_type = NVIMGCODEC_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    instance_info.struct_size = sizeof(instance_info);
    instance_info.load_builtin_modules = 1;
    instance_info.load_extension_modules = 1;
    const char* extensions_path = std::getenv("QWEN_NVIMGCODEC_EXTENSIONS");
    instance_info.extension_modules_path = extensions_path;
    nvimgcodecInstance_t instance = nullptr;
    check_codec(nvimgcodecInstanceCreate(&instance, &instance_info), "nvimgcodecInstanceCreate");

    nvimgcodecCodeStream_t code_stream = nullptr;
    check_codec(nvimgcodecCodeStreamCreateFromHostMem(instance, &code_stream, encoded.data(),
                                                      encoded.size(), nullptr),
                "nvimgcodecCodeStreamCreateFromHostMem");
    nvimgcodecImageInfo_t source_info{};
    source_info.struct_type = NVIMGCODEC_STRUCTURE_TYPE_IMAGE_INFO;
    source_info.struct_size = sizeof(source_info);
    check_codec(nvimgcodecCodeStreamGetImageInfo(code_stream, &source_info),
                "nvimgcodecCodeStreamGetImageInfo");
    const uint32_t width = source_info.plane_info[0].width;
    const uint32_t height = source_info.plane_info[0].height;

    // The decode target is interleaved RGB8 in one strided device plane, which
    // is the NHWC layout CV-CUDA wraps directly.
    nvimgcodecImageInfo_t target_info = source_info;
    target_info.color_spec = NVIMGCODEC_COLORSPEC_SRGB;
    target_info.sample_format = NVIMGCODEC_SAMPLEFORMAT_I_RGB;
    target_info.chroma_subsampling = NVIMGCODEC_SAMPLING_NONE;
    target_info.num_planes = 1;
    target_info.plane_info[0].width = width;
    target_info.plane_info[0].height = height;
    target_info.plane_info[0].num_channels = 3;
    target_info.plane_info[0].sample_type = NVIMGCODEC_SAMPLE_DATA_TYPE_UINT8;
    target_info.plane_info[0].precision = 0;
    target_info.plane_info[0].row_stride = static_cast<size_t>(width) * 3;
    target_info.buffer_kind = NVIMGCODEC_IMAGE_BUFFER_KIND_STRIDED_DEVICE;
    target_info.cuda_stream = stream;
    const size_t decoded_bytes = target_info.plane_info[0].row_stride * height;
    void* decoded = nullptr;
    check_cuda(cudaMallocAsync(&decoded, decoded_bytes, stream), "cudaMallocAsync decoded");
    target_info.buffer = decoded;

    nvimgcodecImage_t image = nullptr;
    check_codec(nvimgcodecImageCreate(instance, &image, &target_info), "nvimgcodecImageCreate");

    nvimgcodecExecutionParams_t execution{};
    execution.struct_type = NVIMGCODEC_STRUCTURE_TYPE_EXECUTION_PARAMS;
    execution.struct_size = sizeof(execution);
    execution.device_id = device;
    execution.max_num_cpu_threads = 1;
    nvimgcodecDecoder_t decoder = nullptr;
    check_codec(nvimgcodecDecoderCreate(instance, &decoder, &execution, nullptr),
                "nvimgcodecDecoderCreate");
    nvimgcodecDecodeParams_t decode_params{};
    decode_params.struct_type = NVIMGCODEC_STRUCTURE_TYPE_DECODE_PARAMS;
    decode_params.struct_size = sizeof(decode_params);
    decode_params.apply_exif_orientation = 1;
    nvimgcodecFuture_t future = nullptr;
    check_codec(nvimgcodecDecoderDecode(decoder, &code_stream, &image, 1, &decode_params, &future),
                "nvimgcodecDecoderDecode");
    check_codec(nvimgcodecFutureWaitForAll(future), "nvimgcodecFutureWaitForAll");
    nvimgcodecProcessingStatus_t processing[1] = {0};
    size_t status_count = 1;
    check_codec(nvimgcodecFutureGetProcessingStatus(future, processing, &status_count),
                "nvimgcodecFutureGetProcessingStatus");
    if (processing[0] != NVIMGCODEC_PROCESSING_STATUS_SUCCESS) fail("decode_status", processing[0]);
    // The encoded bytes are the one host-to-device transfer the design allows,
    // and the decoder made it from the host buffer it was handed.
    host_to_device_transfers += 1;

    // Wrap the decoded plane as an NHWC uint8 tensor over the same allocation.
    NVCVTensorData input_data{};
    input_data.dtype = NVCV_DATA_TYPE_U8;
    input_data.layout = NVCV_TENSOR_NHWC;
    input_data.rank = 4;
    input_data.shape[0] = 1;
    input_data.shape[1] = height;
    input_data.shape[2] = width;
    input_data.shape[3] = 3;
    input_data.bufferType = NVCV_TENSOR_BUFFER_STRIDED_CUDA;
    input_data.buffer.strided.strides[3] = 1;
    input_data.buffer.strided.strides[2] = 3;
    input_data.buffer.strided.strides[1] = static_cast<int64_t>(target_info.plane_info[0].row_stride);
    input_data.buffer.strided.strides[0] = static_cast<int64_t>(decoded_bytes);
    input_data.buffer.strided.basePtr = static_cast<NVCVByte*>(decoded);
    NVCVTensorHandle input = nullptr;
    check_nvcv(nvcvTensorWrapDataConstruct(&input_data, nullptr, nullptr, &input),
               "nvcvTensorWrapDataConstruct");

    NVCVTensorRequirements requirements{};
    check_nvcv(nvcvTensorCalcRequirementsForImages(1, out_width, out_height, NVCV_IMAGE_FORMAT_RGB8,
                                                   0, 0, &requirements),
               "nvcvTensorCalcRequirementsForImages");
    NVCVTensorHandle output = nullptr;
    check_nvcv(nvcvTensorConstruct(&requirements, nullptr, &output), "nvcvTensorConstruct");

    NVCVOperatorHandle resize = nullptr;
    check_nvcv(cvcudaResizeCreate(&resize), "cvcudaResizeCreate");
    check_nvcv(cvcudaResizeSubmit(resize, stream, input, output, NVCV_INTERP_LINEAR),
               "cvcudaResizeSubmit");

    NVCVTensorData output_data{};
    check_nvcv(nvcvTensorExportData(output, &output_data), "nvcvTensorExportData");
    const size_t output_bytes = static_cast<size_t>(out_width) * out_height * 3;
    std::vector<unsigned char> resized(output_bytes);
    check_cuda(cudaMemcpy2DAsync(resized.data(), static_cast<size_t>(out_width) * 3,
                                 output_data.buffer.strided.basePtr,
                                 static_cast<size_t>(output_data.buffer.strided.strides[1]),
                                 static_cast<size_t>(out_width) * 3, out_height,
                                 cudaMemcpyDeviceToHost, stream),
               "cudaMemcpy2DAsync output");
    device_to_host_transfers += 1;
    check_cuda(cudaStreamSynchronize(stream), "cudaStreamSynchronize");

    cudaPointerAttributes attributes{};
    check_cuda(cudaPointerGetAttributes(&attributes, decoded), "cudaPointerGetAttributes");
    const bool decoded_on_device = attributes.type == cudaMemoryTypeDevice;
    check_cuda(cudaPointerGetAttributes(&attributes, output_data.buffer.strided.basePtr),
               "cudaPointerGetAttributes output");
    const bool output_on_device = attributes.type == cudaMemoryTypeDevice;

    std::printf("nvidia_sdk_smoke=%s device=%s codec=%s source=%ux%u decoded_bytes=%zu "
                "decoded_on_device=%s output=%dx%d output_on_device=%s "
                "host_to_device_transfers=%d device_to_host_transfers=%d "
                "output_fnv1a=%016llx\n",
                (decoded_on_device && output_on_device) ? "accepted" : "rejected",
                properties.name, source_info.codec_name, width, height, decoded_bytes,
                decoded_on_device ? "yes" : "no", out_width, out_height,
                output_on_device ? "yes" : "no", host_to_device_transfers,
                device_to_host_transfers, fnv1a(resized.data(), resized.size()));

    nvcvOperatorDestroy(resize);
    nvcvTensorDecRef(output, nullptr);
    nvcvTensorDecRef(input, nullptr);
    nvimgcodecFutureDestroy(future);
    nvimgcodecDecoderDestroy(decoder);
    nvimgcodecImageDestroy(image);
    nvimgcodecCodeStreamDestroy(code_stream);
    nvimgcodecInstanceDestroy(instance);
    check_cuda(cudaFreeAsync(decoded, stream), "cudaFreeAsync");
    check_cuda(cudaStreamSynchronize(stream), "cudaStreamSynchronize final");
    check_cuda(cudaStreamDestroy(stream), "cudaStreamDestroy");
    return (decoded_on_device && output_on_device) ? 0 : 1;
}
