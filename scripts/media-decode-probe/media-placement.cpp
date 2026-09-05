// Where an encoded image's decode runs, where its pixels land, and what a
// CV-CUDA resize changes against the projector's own preprocessing.
//
// The pinned mtmd path decodes every image with stb_image on the host
// (tools/mtmd/mtmd-helper.cpp, stbi_load_from_memory), resizes it with a
// Pillow-exact fixed-point kernel on the host (tools/mtmd/mtmd-image.cpp,
// img_tool::resize_pillow), normalizes it to F32, and uploads the planar
// tensor as the encoder's inp_raw. This program asks, per fixture, what a
// device-side replacement of the first two stages would carry:
//
//  decode   nvImageCodec decodes the same bytes under five backend policies
//           (any, gpu, hw, hybrid, cpu), each a separate decoder created with
//           that allowed-backend list. The library names the codec from the
//           bitstream and the debug messenger names the extension that took
//           the image; the arm that succeeds under a restricted policy is
//           what proves where the decode ran. The decoded plane's memory
//           kind is read back from cudaPointerGetAttributes, and its pixels
//           are compared byte for byte against the stb_image decode the
//           served path performs.
//
//  preproc  libmtmd's own preprocessor for the projector, built by clip_init
//           on the host from the mmproj file, is the reference: its entries
//           are the exact F32 tensors the encoder would read. Four CV-CUDA
//           resizes of the device plane to the reference entry's size are
//           normalized with the same arithmetic and compared element by
//           element, so a difference here is a preprocessing-contract
//           difference and a decode difference is kept out of it by
//           resizing the reference's own pixels where the decodes disagree.
//
// Transfers the program itself issues are counted; what the libraries move
// is read from an Nsight Systems capture by the runner, since a CPU decoder
// asked for a device target uploads inside the library where this program
// cannot see it.
//
// Build and run: scripts/run-media-decode-placement.sh.

#include <cuda_runtime.h>
#include <cvcuda/OpHQResize.h>
#include <cvcuda/OpResize.h>
#include <nvcv/Tensor.h>
#include <nvcv/TensorData.h>
#include <nvcv/Version.h>
#include <nvimgcodec.h>
#include <nvimgcodec_version.h>

#include "clip.h"
#include "clip-impl.h"
#include "clip-model.h"
#include "mtmd-image.h"

#define STB_IMAGE_IMPLEMENTATION
#include "stb/stb_image.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iterator>
#include <memory>
#include <string>
#include <vector>

namespace {

unsigned long long fnv1a(const void * bytes, size_t count) {
    const unsigned char * p = static_cast<const unsigned char *>(bytes);
    unsigned long long hash = 1469598103934665603ull;
    for (size_t index = 0; index < count; ++index) {
        hash ^= p[index];
        hash *= 1099511628211ull;
    }
    return hash;
}

std::string hex16(unsigned long long value) {
    char buffer[32];
    std::snprintf(buffer, sizeof(buffer), "%016llx", value);
    return buffer;
}

std::string basename_of(const std::string & path) {
    const size_t slash = path.find_last_of('/');
    return slash == std::string::npos ? path : path.substr(slash + 1);
}

[[noreturn]] void fail(const std::string & what) {
    std::fprintf(stderr, "media_placement=rejected step=%s\n", what.c_str());
    std::exit(1);
}

void check_cuda(cudaError_t status, const char * what) {
    if (status != cudaSuccess) {
        std::fprintf(stderr, "%s: %s\n", what, cudaGetErrorString(status));
        fail(what);
    }
}

void check_codec(nvimgcodecStatus_t status, const char * what) {
    if (status != NVIMGCODEC_STATUS_SUCCESS) {
        std::fprintf(stderr, "%s: nvimgcodec status %d\n", what, static_cast<int>(status));
        fail(what);
    }
}

void check_nvcv(NVCVStatus status, const char * what) {
    if (status != NVCV_SUCCESS) {
        std::fprintf(stderr, "%s: nvcv status %d\n", what, static_cast<int>(status));
        fail(what);
    }
}

const char * memory_kind_name(const void * pointer) {
    cudaPointerAttributes attributes{};
    if (cudaPointerGetAttributes(&attributes, pointer) != cudaSuccess) {
        cudaGetLastError();
        return "unregistered_host";
    }
    switch (attributes.type) {
        case cudaMemoryTypeDevice: return "device";
        case cudaMemoryTypeHost: return "pinned_host";
        case cudaMemoryTypeManaged: return "managed";
        default: return "unregistered_host";
    }
}

// The debug messenger is the one channel through which nvImageCodec names the
// extension that handled an image, so every message is retained verbatim in
// the messages file with the arm that produced it.
struct messenger_sink {
    std::FILE * file = nullptr;
    std::string arm;
    std::vector<std::string> codecs_seen;
    std::string processing_decoder; // the decoder a "<name> process #N" message names
};

int messenger_callback(const nvimgcodecDebugMessageSeverity_t severity,
                       const nvimgcodecDebugMessageCategory_t category,
                       const nvimgcodecDebugMessageData_t * data, void * user_data) {
    auto * sink = static_cast<messenger_sink *>(user_data);
    if (sink->file != nullptr) {
        std::fprintf(sink->file, "%s\tseverity=0x%x\tcategory=0x%x\tcodec=%s\tcodec_id=%s\t%s\n",
                     sink->arm.c_str(), static_cast<unsigned>(severity), static_cast<unsigned>(category),
                     data->codec != nullptr ? data->codec : "-", data->codec_id != nullptr ? data->codec_id : "-",
                     data->message != nullptr ? data->message : "");
        std::fflush(sink->file);
    }
    if (data->message != nullptr) {
        const std::string text = data->message;
        const size_t mark = text.find(" process #");
        if (mark != std::string::npos) {
            const size_t start = text.rfind(' ', mark - 1);
            sink->processing_decoder = text.substr(start == std::string::npos ? 0 : start + 1, mark - (start == std::string::npos ? 0 : start + 1));
        }
    }
    if (data->codec_id != nullptr) {
        const std::string id = data->codec_id;
        if (std::find(sink->codecs_seen.begin(), sink->codecs_seen.end(), id) == sink->codecs_seen.end()) {
            sink->codecs_seen.push_back(id);
        }
    }
    return 0;
}

struct backend_policy {
    const char * name;
    std::vector<nvimgcodecBackendKind_t> kinds; // empty means every backend
};

const std::vector<backend_policy> POLICIES = {
    {"any", {}},
    {"gpu", {NVIMGCODEC_BACKEND_KIND_GPU_ONLY}},
    {"hw", {NVIMGCODEC_BACKEND_KIND_HW_GPU_ONLY}},
    {"hybrid", {NVIMGCODEC_BACKEND_KIND_HYBRID_CPU_GPU}},
    {"cpu", {NVIMGCODEC_BACKEND_KIND_CPU_ONLY}},
};

struct decoded_plane {
    bool ok = false;
    std::string status;      // success, or the processing status name
    std::string codec;       // from the code stream header
    uint32_t width = 0, height = 0;
    void * device = nullptr; // interleaved RGB8, row stride width*3
    size_t bytes = 0;
    std::vector<unsigned char> host; // read back once for the comparison
    std::vector<std::string> extensions;
    std::string decoder = "-";
};

const char * processing_status_name(nvimgcodecProcessingStatus_t status) {
    switch (status) {
        case NVIMGCODEC_PROCESSING_STATUS_SUCCESS: return "success";
        case NVIMGCODEC_PROCESSING_STATUS_SATURATED: return "saturated";
        case NVIMGCODEC_PROCESSING_STATUS_FAIL: return "fail";
        case NVIMGCODEC_PROCESSING_STATUS_IMAGE_CORRUPTED: return "image_corrupted";
        case NVIMGCODEC_PROCESSING_STATUS_CODEC_UNSUPPORTED: return "codec_unsupported";
        case NVIMGCODEC_PROCESSING_STATUS_BACKEND_UNSUPPORTED: return "backend_unsupported";
        default: break;
    }
    static char buffer[32];
    std::snprintf(buffer, sizeof(buffer), "status_0x%x", static_cast<unsigned>(status));
    return buffer;
}

const char * api_status_name(nvimgcodecStatus_t status) {
    switch (status) {
        case NVIMGCODEC_STATUS_INVALID_PARAMETER: return "invalid_parameter";
        case NVIMGCODEC_STATUS_ARCH_MISMATCH: return "arch_mismatch";
        case NVIMGCODEC_STATUS_IMPLEMENTATION_UNSUPPORTED: return "implementation_unsupported";
        case NVIMGCODEC_STATUS_MISSED_DEPENDENCIES: return "missed_dependencies";
        case NVIMGCODEC_STATUS_EXECUTION_FAILED: return "execution_failed";
        default: break;
    }
    static char buffer[32];
    std::snprintf(buffer, sizeof(buffer), "status_%d", static_cast<int>(status));
    return buffer;
}

decoded_plane decode_under_policy(nvimgcodecInstance_t instance, int device_id, cudaStream_t stream,
                                  const std::vector<unsigned char> & encoded, const backend_policy & policy,
                                  messenger_sink & sink, const std::string & arm) {
    decoded_plane out;
    sink.arm = arm;
    sink.codecs_seen.clear();
    sink.processing_decoder.clear();

    nvimgcodecCodeStream_t code_stream = nullptr;
    check_codec(nvimgcodecCodeStreamCreateFromHostMem(instance, &code_stream, encoded.data(), encoded.size(), nullptr),
                "nvimgcodecCodeStreamCreateFromHostMem");
    nvimgcodecImageInfo_t source_info{};
    source_info.struct_type = NVIMGCODEC_STRUCTURE_TYPE_IMAGE_INFO;
    source_info.struct_size = sizeof(source_info);
    check_codec(nvimgcodecCodeStreamGetImageInfo(code_stream, &source_info), "nvimgcodecCodeStreamGetImageInfo");
    out.codec = source_info.codec_name;
    out.width = source_info.plane_info[0].width;
    out.height = source_info.plane_info[0].height;

    nvimgcodecImageInfo_t target_info = source_info;
    target_info.color_spec = NVIMGCODEC_COLORSPEC_SRGB;
    target_info.sample_format = NVIMGCODEC_SAMPLEFORMAT_I_RGB;
    target_info.chroma_subsampling = NVIMGCODEC_SAMPLING_NONE;
    target_info.num_planes = 1;
    target_info.plane_info[0].width = out.width;
    target_info.plane_info[0].height = out.height;
    target_info.plane_info[0].num_channels = 3;
    target_info.plane_info[0].sample_type = NVIMGCODEC_SAMPLE_DATA_TYPE_UINT8;
    target_info.plane_info[0].precision = 0;
    target_info.plane_info[0].row_stride = static_cast<size_t>(out.width) * 3;
    target_info.buffer_kind = NVIMGCODEC_IMAGE_BUFFER_KIND_STRIDED_DEVICE;
    target_info.cuda_stream = stream;
    out.bytes = target_info.plane_info[0].row_stride * out.height;
    check_cuda(cudaMalloc(&out.device, out.bytes), "cudaMalloc decoded");
    check_cuda(cudaMemset(out.device, 0, out.bytes), "cudaMemset decoded");
    target_info.buffer = out.device;

    nvimgcodecImage_t image = nullptr;
    check_codec(nvimgcodecImageCreate(instance, &image, &target_info), "nvimgcodecImageCreate");

    std::vector<nvimgcodecBackend_t> backends;
    for (auto kind : policy.kinds) {
        nvimgcodecBackend_t backend{};
        backend.struct_type = NVIMGCODEC_STRUCTURE_TYPE_BACKEND;
        backend.struct_size = sizeof(backend);
        backend.kind = kind;
        backend.params.struct_type = NVIMGCODEC_STRUCTURE_TYPE_BACKEND_PARAMS;
        backend.params.struct_size = sizeof(backend.params);
        backend.params.load_hint = 1.0f;
        backend.params.load_hint_policy = NVIMGCODEC_LOAD_HINT_POLICY_FIXED;
        backends.push_back(backend);
    }
    nvimgcodecExecutionParams_t execution{};
    execution.struct_type = NVIMGCODEC_STRUCTURE_TYPE_EXECUTION_PARAMS;
    execution.struct_size = sizeof(execution);
    execution.device_id = device_id;
    execution.max_num_cpu_threads = 1;
    execution.num_backends = static_cast<int>(backends.size());
    execution.backends = backends.empty() ? nullptr : backends.data();
    nvimgcodecDecoder_t decoder = nullptr;
    const nvimgcodecStatus_t created = nvimgcodecDecoderCreate(instance, &decoder, &execution, nullptr);

    nvimgcodecDecodeParams_t decode_params{};
    decode_params.struct_type = NVIMGCODEC_STRUCTURE_TYPE_DECODE_PARAMS;
    decode_params.struct_size = sizeof(decode_params);
    // stb_image reads no EXIF, so orientation stays off for the pixels to be
    // the same image the served path decodes
    decode_params.apply_exif_orientation = 0;

    nvimgcodecProcessingStatus_t can_status = NVIMGCODEC_PROCESSING_STATUS_UNKNOWN;
    nvimgcodecStatus_t can = NVIMGCODEC_STATUS_SUCCESS;
    if (created == NVIMGCODEC_STATUS_SUCCESS) {
        can = nvimgcodecDecoderCanDecode(decoder, &code_stream, &image, 1, &decode_params, &can_status, 1);
    }
    if (created != NVIMGCODEC_STATUS_SUCCESS) {
        // A policy no loaded extension can serve on this device refuses at
        // creation; the status is the finding rather than an error.
        out.status = std::string("decoder_create:") + api_status_name(created);
    } else if (can != NVIMGCODEC_STATUS_SUCCESS || can_status != NVIMGCODEC_PROCESSING_STATUS_SUCCESS) {
        out.status = std::string("can_decode:") + (can == NVIMGCODEC_STATUS_SUCCESS ? processing_status_name(can_status) : "api_error");
    } else {
        nvimgcodecFuture_t future = nullptr;
        const nvimgcodecStatus_t submitted = nvimgcodecDecoderDecode(decoder, &code_stream, &image, 1, &decode_params, &future);
        if (submitted != NVIMGCODEC_STATUS_SUCCESS) {
            out.status = "decode:api_error";
        } else {
            check_codec(nvimgcodecFutureWaitForAll(future), "nvimgcodecFutureWaitForAll");
            nvimgcodecProcessingStatus_t processing[1] = {NVIMGCODEC_PROCESSING_STATUS_UNKNOWN};
            size_t status_count = 1;
            check_codec(nvimgcodecFutureGetProcessingStatus(future, processing, &status_count), "nvimgcodecFutureGetProcessingStatus");
            nvimgcodecFutureDestroy(future);
            out.status = processing_status_name(processing[0]);
            out.ok = processing[0] == NVIMGCODEC_PROCESSING_STATUS_SUCCESS;
        }
    }
    check_cuda(cudaStreamSynchronize(stream), "cudaStreamSynchronize decode");
    if (out.ok) {
        out.host.resize(out.bytes);
        check_cuda(cudaMemcpy(out.host.data(), out.device, out.bytes, cudaMemcpyDeviceToHost), "cudaMemcpy readback");
    }
    out.extensions = sink.codecs_seen;
    if (!sink.processing_decoder.empty()) out.decoder = sink.processing_decoder;
    if (decoder != nullptr) nvimgcodecDecoderDestroy(decoder);
    nvimgcodecImageDestroy(image);
    nvimgcodecCodeStreamDestroy(code_stream);
    return out;
}

struct pixel_diff {
    size_t compared = 0;
    size_t differing = 0;
    int max_abs = 0;
};

pixel_diff compare_u8(const unsigned char * a, const unsigned char * b, size_t count) {
    pixel_diff diff;
    diff.compared = count;
    for (size_t index = 0; index < count; ++index) {
        const int delta = std::abs(static_cast<int>(a[index]) - static_cast<int>(b[index]));
        if (delta != 0) diff.differing += 1;
        if (delta > diff.max_abs) diff.max_abs = delta;
    }
    return diff;
}

// A CV-CUDA resize of an NHWC RGB8 device plane to (width, height).
struct resize_arm {
    const char * name;
    bool hq;
    NVCVInterpolationType interpolation;
    bool antialias;
};

const std::vector<resize_arm> RESIZE_ARMS = {
    {"resize_linear", false, NVCV_INTERP_LINEAR, false},
    {"resize_cubic", false, NVCV_INTERP_CUBIC, false},
    {"hqresize_linear_aa", true, NVCV_INTERP_LINEAR, true},
    {"hqresize_cubic_aa", true, NVCV_INTERP_CUBIC, true},
};

NVCVTensorHandle wrap_rgb8(void * device, uint32_t width, uint32_t height) {
    NVCVTensorData data{};
    data.dtype = NVCV_DATA_TYPE_U8;
    data.layout = NVCV_TENSOR_NHWC;
    data.rank = 4;
    data.shape[0] = 1;
    data.shape[1] = height;
    data.shape[2] = width;
    data.shape[3] = 3;
    data.bufferType = NVCV_TENSOR_BUFFER_STRIDED_CUDA;
    data.buffer.strided.strides[3] = 1;
    data.buffer.strided.strides[2] = 3;
    data.buffer.strided.strides[1] = static_cast<int64_t>(width) * 3;
    data.buffer.strided.strides[0] = static_cast<int64_t>(width) * 3 * height;
    data.buffer.strided.basePtr = static_cast<NVCVByte *>(device);
    NVCVTensorHandle handle = nullptr;
    check_nvcv(nvcvTensorWrapDataConstruct(&data, nullptr, nullptr, &handle), "nvcvTensorWrapDataConstruct");
    return handle;
}

std::vector<unsigned char> cvcuda_resize(cudaStream_t stream, void * device, uint32_t width, uint32_t height,
                                         int out_width, int out_height, const resize_arm & arm,
                                         int & device_to_host_copies) {
    NVCVTensorHandle input = wrap_rgb8(device, width, height);
    const size_t out_bytes = static_cast<size_t>(out_width) * out_height * 3;
    void * out_device = nullptr;
    check_cuda(cudaMalloc(&out_device, out_bytes), "cudaMalloc resized");
    NVCVTensorHandle output = wrap_rgb8(out_device, out_width, out_height);
    NVCVOperatorHandle op = nullptr;
    if (!arm.hq) {
        check_nvcv(cvcudaResizeCreate(&op), "cvcudaResizeCreate");
        check_nvcv(cvcudaResizeSubmit(op, stream, input, output, arm.interpolation), "cvcudaResizeSubmit");
    } else {
        check_nvcv(cvcudaHQResizeCreate(&op), "cvcudaHQResizeCreate");
        HQResizeTensorShapeI in_shape{};
        in_shape.extent[0] = static_cast<int32_t>(height);
        in_shape.extent[1] = static_cast<int32_t>(width);
        in_shape.ndim = 2;
        in_shape.numChannels = 3;
        HQResizeTensorShapeI out_shape{};
        out_shape.extent[0] = out_height;
        out_shape.extent[1] = out_width;
        out_shape.ndim = 2;
        out_shape.numChannels = 3;
        NVCVWorkspaceRequirements requirements{};
        check_nvcv(cvcudaHQResizeTensorGetWorkspaceRequirements(op, 1, in_shape, out_shape, arm.interpolation,
                                                                arm.interpolation, arm.antialias, nullptr, &requirements),
                   "cvcudaHQResizeTensorGetWorkspaceRequirements");
        NVCVWorkspace workspace{};
        workspace.hostMem.req = requirements.hostMem;
        workspace.pinnedMem.req = requirements.pinnedMem;
        workspace.cudaMem.req = requirements.cudaMem;
        std::vector<unsigned char> host_mem(requirements.hostMem.size + requirements.hostMem.alignment);
        if (requirements.hostMem.size > 0) {
            uintptr_t address = reinterpret_cast<uintptr_t>(host_mem.data());
            address = (address + requirements.hostMem.alignment - 1) / requirements.hostMem.alignment * requirements.hostMem.alignment;
            workspace.hostMem.data = reinterpret_cast<void *>(address);
        }
        if (requirements.pinnedMem.size > 0) {
            check_cuda(cudaHostAlloc(&workspace.pinnedMem.data, requirements.pinnedMem.size, cudaHostAllocDefault), "cudaHostAlloc workspace");
        }
        if (requirements.cudaMem.size > 0) {
            check_cuda(cudaMalloc(&workspace.cudaMem.data, requirements.cudaMem.size), "cudaMalloc workspace");
        }
        check_nvcv(cvcudaHQResizeSubmit(op, stream, &workspace, input, output, arm.interpolation, arm.interpolation,
                                        arm.antialias, nullptr),
                   "cvcudaHQResizeSubmit");
        check_cuda(cudaStreamSynchronize(stream), "cudaStreamSynchronize hqresize");
        if (workspace.pinnedMem.data != nullptr) cudaFreeHost(workspace.pinnedMem.data);
        if (workspace.cudaMem.data != nullptr) cudaFree(workspace.cudaMem.data);
    }
    std::vector<unsigned char> host(out_bytes);
    check_cuda(cudaMemcpyAsync(host.data(), out_device, out_bytes, cudaMemcpyDeviceToHost, stream), "cudaMemcpyAsync resized");
    check_cuda(cudaStreamSynchronize(stream), "cudaStreamSynchronize resized");
    device_to_host_copies += 1;
    nvcvOperatorDestroy(op);
    nvcvTensorDecRef(output, nullptr);
    nvcvTensorDecRef(input, nullptr);
    cudaFree(out_device);
    return host;
}

// img_tool::resize's padded geometry (tools/mtmd/mtmd-image.cpp): under a
// pad style the source is scaled by the smaller axis ratio, rounded up
// (PAD_CEIL) or to nearest (PAD_NEAREST), resampled at that size, and
// composited onto a canvas of the pad color at a centered offset. The
// resample is the operation under comparison; the composite is a copy, so
// it is reproduced here on the host from the same arithmetic.
struct pad_geometry {
    int new_width, new_height, offset_x, offset_y;
    bool padded;
};

pad_geometry padded_geometry(int src_w, int src_h, int dst_w, int dst_h, pad_style padding) {
    pad_geometry g{dst_w, dst_h, 0, 0, false};
    if (padding == PAD_NONE) return g;
    float scale_w = static_cast<float>(dst_w) / src_w;
    float scale_h = static_cast<float>(dst_h) / src_h;
    float scale = std::min(scale_w, scale_h);
    if (padding == PAD_NEAREST) {
        g.new_width = std::min(static_cast<int>(std::round(src_w * scale)), dst_w);
        g.new_height = std::min(static_cast<int>(std::round(src_h * scale)), dst_h);
        g.offset_x = static_cast<int>(std::round((dst_w - g.new_width) / 2.0f));
        g.offset_y = static_cast<int>(std::round((dst_h - g.new_height) / 2.0f));
    } else {
        g.new_width = std::min(static_cast<int>(std::ceil(src_w * scale)), dst_w);
        g.new_height = std::min(static_cast<int>(std::ceil(src_h * scale)), dst_h);
        g.offset_x = (dst_w - g.new_width) / 2;
        g.offset_y = (dst_h - g.new_height) / 2;
    }
    g.padded = g.new_width != dst_w || g.new_height != dst_h;
    return g;
}

std::vector<unsigned char> composite_padded(const std::vector<unsigned char> & resized, const pad_geometry & g,
                                            int dst_w, int dst_h, const std::array<uint8_t, 3> & pad_color) {
    std::vector<unsigned char> canvas(static_cast<size_t>(dst_w) * dst_h * 3);
    for (size_t pixel = 0; pixel < canvas.size() / 3; ++pixel) {
        canvas[pixel * 3] = pad_color[0];
        canvas[pixel * 3 + 1] = pad_color[1];
        canvas[pixel * 3 + 2] = pad_color[2];
    }
    for (int y = 0; y < g.new_height; ++y) {
        const int dy = y + g.offset_y;
        if (dy < 0 || dy >= dst_h) continue;
        for (int x = 0; x < g.new_width; ++x) {
            const int dx = x + g.offset_x;
            if (dx < 0 || dx >= dst_w) continue;
            std::memcpy(&canvas[(static_cast<size_t>(dy) * dst_w + dx) * 3], &resized[(static_cast<size_t>(y) * g.new_width + x) * 3], 3);
        }
    }
    return canvas;
}

const char * pad_style_name(pad_style padding) {
    switch (padding) {
        case PAD_NONE: return "none";
        case PAD_CEIL: return "ceil";
        case PAD_NEAREST: return "nearest";
        default: return "other";
    }
}

// The same arithmetic clip_image_f32::from_u8 and normalize apply, in the
// same order, so an equal u8 input yields an equal F32 element.
std::vector<float> normalize_like_mtmd(const std::vector<unsigned char> & rgb, const float mean[3], const float std[3]) {
    std::vector<float> out(rgb.size());
    for (size_t index = 0; index < rgb.size(); ++index) {
        out[index] = static_cast<float>(rgb[index]) / 255.0f;
    }
    for (size_t pixel = 0; pixel < rgb.size() / 3; ++pixel) {
        for (int channel = 0; channel < 3; ++channel) {
            out[pixel * 3 + channel] = (out[pixel * 3 + channel] - mean[channel]) / std[channel];
        }
    }
    return out;
}

struct f32_diff {
    size_t compared = 0;
    size_t differing = 0;
    float max_abs = 0.0f;
    int max_abs_u8 = 0; // the reference inverted back to a byte against the candidate byte
};

f32_diff compare_f32(const std::vector<float> & candidate, const std::vector<float> & reference,
                     const std::vector<unsigned char> & candidate_u8, const float mean[3], const float std[3]) {
    f32_diff diff;
    diff.compared = reference.size();
    for (size_t index = 0; index < reference.size(); ++index) {
        const float delta = std::fabs(candidate[index] - reference[index]);
        if (delta != 0.0f) diff.differing += 1;
        if (delta > diff.max_abs) diff.max_abs = delta;
        const int channel = static_cast<int>(index % 3);
        const int reference_u8 = static_cast<int>(std::lround((reference[index] * std[channel] + mean[channel]) * 255.0f));
        const int delta_u8 = std::abs(reference_u8 - static_cast<int>(candidate_u8[index]));
        if (delta_u8 > diff.max_abs_u8) diff.max_abs_u8 = delta_u8;
    }
    return diff;
}

std::unique_ptr<mtmd_image_preprocessor> make_preprocessor(const clip_ctx * ctx, std::string & name) {
    switch (clip_get_projector_type(ctx)) {
        case PROJECTOR_TYPE_QWEN2VL:
        case PROJECTOR_TYPE_QWEN25VL:
        case PROJECTOR_TYPE_QWEN3VL:
            name = "dyn_size";
            return std::make_unique<mtmd_image_preprocessor_dyn_size>(ctx);
        case PROJECTOR_TYPE_LFM2:
            name = "lfm2";
            return std::make_unique<mtmd_image_preprocessor_lfm2>(ctx);
        default:
            name = "unsupported";
            return nullptr;
    }
}

const char * resize_algo_name(resize_algo algo) {
    switch (algo) {
        case RESIZE_ALGO_BILINEAR: return "bilinear";
        case RESIZE_ALGO_BICUBIC: return "bicubic";
        case RESIZE_ALGO_LANCZOS: return "lanczos";
        default: return "other";
    }
}

} // namespace

int main(int argc, char ** argv) {
    std::string mmproj, extensions, messages_path, only_policy;
    bool run_preproc = true;
    std::vector<std::string> images;
    for (int index = 1; index < argc; ++index) {
        const std::string arg = argv[index];
        if (arg == "--mmproj" && index + 1 < argc) mmproj = argv[++index];
        else if (arg == "--extensions" && index + 1 < argc) extensions = argv[++index];
        else if (arg == "--messages" && index + 1 < argc) messages_path = argv[++index];
        else if (arg == "--policy" && index + 1 < argc) only_policy = argv[++index];
        else if (arg == "--no-preproc") run_preproc = false;
        else if (!arg.empty() && arg[0] == '-') { std::fprintf(stderr, "unknown option %s\n", arg.c_str()); return 2; }
        else images.push_back(arg);
    }
    if (mmproj.empty() || extensions.empty() || images.empty()) {
        std::fprintf(stderr, "usage: media-placement --mmproj MMPROJ --extensions DIR [--messages FILE] [--policy NAME] [--no-preproc] IMAGE...\n");
        return 2;
    }

    int device_id = 0;
    check_cuda(cudaSetDevice(device_id), "cudaSetDevice");
    cudaDeviceProp properties{};
    check_cuda(cudaGetDeviceProperties(&properties, device_id), "cudaGetDeviceProperties");
    cudaStream_t stream;
    check_cuda(cudaStreamCreate(&stream), "cudaStreamCreate");

    nvimgcodecProperties_t codec_properties{};
    codec_properties.struct_type = NVIMGCODEC_STRUCTURE_TYPE_PROPERTIES;
    codec_properties.struct_size = sizeof(codec_properties);
    check_codec(nvimgcodecGetProperties(&codec_properties), "nvimgcodecGetProperties");

    messenger_sink sink;
    if (!messages_path.empty()) {
        sink.file = std::fopen(messages_path.c_str(), "w");
        if (sink.file == nullptr) fail("open_messages");
    }
    nvimgcodecDebugMessengerDesc_t messenger_desc{};
    messenger_desc.struct_type = NVIMGCODEC_STRUCTURE_TYPE_DEBUG_MESSENGER_DESC;
    messenger_desc.struct_size = sizeof(messenger_desc);
    messenger_desc.message_severity = NVIMGCODEC_DEBUG_MESSAGE_SEVERITY_ALL;
    messenger_desc.message_category = NVIMGCODEC_DEBUG_MESSAGE_CATEGORY_ALL;
    messenger_desc.user_callback = messenger_callback;
    messenger_desc.user_data = &sink;

    nvimgcodecInstanceCreateInfo_t instance_info{};
    instance_info.struct_type = NVIMGCODEC_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    instance_info.struct_size = sizeof(instance_info);
    instance_info.load_builtin_modules = 1;
    instance_info.load_extension_modules = 1;
    instance_info.extension_modules_path = extensions.c_str();
    instance_info.create_debug_messenger = 1;
    instance_info.debug_messenger_desc = &messenger_desc;
    instance_info.message_severity = NVIMGCODEC_DEBUG_MESSAGE_SEVERITY_ALL;
    instance_info.message_category = NVIMGCODEC_DEBUG_MESSAGE_CATEGORY_ALL;
    nvimgcodecInstance_t instance = nullptr;
    sink.arm = "instance";
    check_codec(nvimgcodecInstanceCreate(&instance, &instance_info), "nvimgcodecInstanceCreate");

    // The reference preprocessor: the projector's own, on the host, from the
    // mmproj the served row names. use_gpu=false keeps every projector weight
    // off the device, since nothing here encodes.
    clip_context_params clip_params{};
    clip_params.use_gpu = false;
    clip_params.device = nullptr;
    clip_params.flash_attn_type = CLIP_FLASH_ATTN_TYPE_DISABLED;
    clip_params.image_min_tokens = -1;
    clip_params.image_max_tokens = -1;
    clip_params.warmup = false;
    clip_params.no_alloc = false;
    clip_init_result clip = clip_init(mmproj.c_str(), clip_params);
    if (clip.ctx_v == nullptr) fail("clip_init");
    std::string preprocessor_name;
    std::unique_ptr<mtmd_image_preprocessor> preprocessor = make_preprocessor(clip.ctx_v, preprocessor_name);
    if (!preprocessor) fail("preprocessor_unsupported");
    const clip_hparams & hparams = *clip_get_hparams(clip.ctx_v);
    // dyn_size resizes under image_resize_pad; the LFM2 single tile is the
    // overview resize under image_pad_ov (mtmd-image.cpp, slice_image)
    const bool is_lfm2 = clip_get_projector_type(clip.ctx_v) == PROJECTOR_TYPE_LFM2;
    const pad_style entry_pad = is_lfm2 ? hparams.image_pad_ov : hparams.image_resize_pad;
    const std::array<uint8_t, 3> entry_pad_color = is_lfm2 ? hparams.image_pad_color_ov : hparams.image_pad_color;
    const resize_algo entry_algo = is_lfm2 ? hparams.image_resize_algo_ov : hparams.image_resize_algo;

    std::printf("probe\tdevice=%s\tnvimgcodec=%u.%u.%u\tcvcuda=%s\tprojector=%s\tpreprocessor=%s\tresize_algo=%s\tpad=%s\tpatch_size=%d\tn_merge=%d\timage_size=%d\tmin_pixels=%d\tmax_pixels=%d\tmean=%.6f,%.6f,%.6f\tstd=%.6f,%.6f,%.6f\n",
                properties.name, NVIMGCODEC_MAJOR_FROM_SEMVER(codec_properties.version),
                NVIMGCODEC_MINOR_FROM_SEMVER(codec_properties.version),
                NVIMGCODEC_PATCH_FROM_SEMVER(codec_properties.version), NVCV_VERSION_STRING,
                clip_get_projector_type(clip.ctx_v) == PROJECTOR_TYPE_LFM2 ? "lfm2" : "qwen3vl_merger",
                preprocessor_name.c_str(), resize_algo_name(entry_algo), pad_style_name(entry_pad), hparams.patch_size,
                hparams.n_merge, hparams.image_size, hparams.image_min_pixels, hparams.image_max_pixels,
                hparams.image_mean[0], hparams.image_mean[1], hparams.image_mean[2],
                hparams.image_std[0], hparams.image_std[1], hparams.image_std[2]);

    int host_to_device_copies = 0;
    int device_to_host_copies = 0;
    bool rejected = false;

    for (const std::string & path : images) {
        const std::string image_name = basename_of(path);
        std::ifstream file(path, std::ios::binary);
        if (!file) fail("read_image:" + image_name);
        std::vector<unsigned char> encoded((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
        if (encoded.empty()) fail("read_image:" + image_name);

        // The served decode: stb_image, three channels, on the host.
        int stb_w = 0, stb_h = 0, stb_c = 0;
        unsigned char * stb_pixels = stbi_load_from_memory(encoded.data(), static_cast<int>(encoded.size()), &stb_w, &stb_h, &stb_c, 3);
        if (stb_pixels == nullptr) fail("stbi_load:" + image_name);
        const size_t stb_bytes = static_cast<size_t>(stb_w) * stb_h * 3;
        std::vector<unsigned char> stb_rgb(stb_pixels, stb_pixels + stb_bytes);
        stbi_image_free(stb_pixels);
        std::printf("reference_decode\timage=%s\tencoded_bytes=%zu\tdecoder=stb_image\tbackend_kind=cpu_only\toutput_memory=host\twidth=%d\theight=%d\tsource_channels=%d\tdecoded_bytes=%zu\tdigest=%s\n",
                    image_name.c_str(), encoded.size(), stb_w, stb_h, stb_c, stb_bytes, hex16(fnv1a(stb_rgb.data(), stb_bytes)).c_str());

        decoded_plane any_plane;
        for (const backend_policy & policy : POLICIES) {
            if (!only_policy.empty() && only_policy != policy.name) continue;
            decoded_plane plane = decode_under_policy(instance, device_id, stream, encoded, policy, sink,
                                                      image_name + ":" + policy.name);
            std::string extensions_joined;
            for (const auto & ext : plane.extensions) {
                if (!extensions_joined.empty()) extensions_joined += ",";
                extensions_joined += ext;
            }
            if (extensions_joined.empty()) extensions_joined = "-";
            if (plane.ok) {
                device_to_host_copies += 1;
                pixel_diff diff = plane.width == static_cast<uint32_t>(stb_w) && plane.height == static_cast<uint32_t>(stb_h)
                                      ? compare_u8(plane.host.data(), stb_rgb.data(), stb_bytes)
                                      : pixel_diff{};
                std::printf("decode\timage=%s\tpolicy=%s\tstatus=%s\tcodec=%s\tdecoder=%s\textensions=%s\twidth=%u\theight=%u\tdecoded_bytes=%zu\toutput_memory=%s\tdigest=%s\tvs_stb_compared=%zu\tvs_stb_differing=%zu\tvs_stb_max_abs=%d\tvs_stb_identical=%s\n",
                            image_name.c_str(), policy.name, plane.status.c_str(), plane.codec.c_str(), plane.decoder.c_str(), extensions_joined.c_str(),
                            plane.width, plane.height, plane.bytes, memory_kind_name(plane.device),
                            hex16(fnv1a(plane.host.data(), plane.bytes)).c_str(), diff.compared, diff.differing, diff.max_abs,
                            diff.compared > 0 && diff.differing == 0 ? "yes" : "no");
            } else {
                std::printf("decode\timage=%s\tpolicy=%s\tstatus=%s\tcodec=%s\tdecoder=%s\textensions=%s\twidth=%u\theight=%u\tdecoded_bytes=%zu\toutput_memory=%s\tdigest=-\tvs_stb_compared=0\tvs_stb_differing=0\tvs_stb_max_abs=0\tvs_stb_identical=n/a\n",
                            image_name.c_str(), policy.name, plane.status.c_str(), plane.codec.c_str(), plane.decoder.c_str(), extensions_joined.c_str(),
                            plane.width, plane.height, plane.bytes, memory_kind_name(plane.device));
            }
            if (std::string(policy.name) == "any" && run_preproc) {
                any_plane = plane; // keeps the device buffer for the resize arms
            } else {
                cudaFree(plane.device);
            }
        }
        if (!run_preproc) continue;
        if (!any_plane.ok) {
            std::printf("preproc\timage=%s\tentries=0\tcvcuda=not_run\treason=decode_failed\n", image_name.c_str());
            rejected = true;
            cudaFree(any_plane.device);
            continue;
        }

        // The reference: the projector's preprocessor over the stb pixels.
        clip_image_u8 img_u8;
        img_u8.set_size({stb_w, stb_h}, false);
        img_u8.cpy_buf(stb_rgb);
        mtmd_image_preproc_out reference = preprocessor->preprocess(img_u8);
        std::printf("preproc\timage=%s\tentries=%zu\tgrid_x=%d\tgrid_y=%d\thas_overview=%s\n", image_name.c_str(),
                    reference.entries.size(), reference.grid_x, reference.grid_y, reference.has_overview() ? "yes" : "no");
        for (size_t entry = 0; entry < reference.entries.size(); ++entry) {
            const clip_image_f32 & ref = reference.entries[entry];
            const std::vector<float> & ref_buf = ref.get_ro_buf();
            std::printf("preproc_entry\timage=%s\tentry=%zu\twidth=%d\theight=%d\telements=%zu\tdigest=%s\n", image_name.c_str(), entry,
                        ref.nx(), ref.ny(), ref_buf.size(), hex16(fnv1a(ref_buf.data(), ref_buf.size() * sizeof(float))).c_str());
        }

        // A whole-image resize is the contract under comparison; a tiled
        // layout crops after its resize and stays out of this probe.
        const bool tiled = reference.entries.size() != 1 || reference.has_overview();
        if (tiled) {
            std::printf("preproc_compare\timage=%s\tentry=0\top=-\tresult=not_run\treason=tiled_layout\n", image_name.c_str());
            cudaFree(any_plane.device);
            continue;
        }
        const clip_image_f32 & ref = reference.entries[0];
        const std::vector<float> & ref_buf = ref.get_ro_buf();

        // Where the device decode differs from stb, the resize arms read the
        // stb pixels uploaded once, so the comparison isolates the resize.
        void * resize_source = any_plane.device;
        bool source_is_stb = false;
        void * uploaded = nullptr;
        if (any_plane.host != stb_rgb) {
            check_cuda(cudaMalloc(&uploaded, stb_bytes), "cudaMalloc stb upload");
            check_cuda(cudaMemcpy(uploaded, stb_rgb.data(), stb_bytes, cudaMemcpyHostToDevice), "cudaMemcpy stb upload");
            host_to_device_copies += 1;
            resize_source = uploaded;
            source_is_stb = true;
        }
        if (ref.nx() == stb_w && ref.ny() == stb_h) {
            // img_tool::resize copies where the target equals the source, so
            // there is no resample to compare
            std::printf("preproc_compare\timage=%s\tentry=0\top=-\tresult=not_run\treason=target_equals_source\n", image_name.c_str());
            if (uploaded != nullptr) cudaFree(uploaded);
            cudaFree(any_plane.device);
            continue;
        }
        const pad_geometry geometry = padded_geometry(stb_w, stb_h, ref.nx(), ref.ny(), entry_pad);
        for (const resize_arm & arm : RESIZE_ARMS) {
            std::vector<unsigned char> resized = cvcuda_resize(stream, resize_source, static_cast<uint32_t>(stb_w),
                                                               static_cast<uint32_t>(stb_h), geometry.new_width,
                                                               geometry.new_height, arm, device_to_host_copies);
            if (geometry.padded) resized = composite_padded(resized, geometry, ref.nx(), ref.ny(), entry_pad_color);
            std::vector<float> normalized = normalize_like_mtmd(resized, hparams.image_mean, hparams.image_std);
            f32_diff diff = compare_f32(normalized, ref_buf, resized, hparams.image_mean, hparams.image_std);
            std::printf("preproc_compare\timage=%s\tentry=0\top=%s\tsource=%s\ttarget=%dx%d\tresample=%dx%d\tpad=%s\toffset=%d,%d\tresult=%s\tcompared=%zu\tdiffering=%zu\tdiffering_fraction=%.6f\tmax_abs_f32=%.6g\tmax_abs_u8=%d\tdigest=%s\n",
                        image_name.c_str(), arm.name, source_is_stb ? "stb_upload" : "device_decode", ref.nx(), ref.ny(),
                        geometry.new_width, geometry.new_height, pad_style_name(entry_pad), geometry.offset_x, geometry.offset_y,
                        diff.differing == 0 ? "identical" : "differs", diff.compared, diff.differing,
                        diff.compared > 0 ? static_cast<double>(diff.differing) / diff.compared : 0.0, diff.max_abs, diff.max_abs_u8,
                        hex16(fnv1a(normalized.data(), normalized.size() * sizeof(float))).c_str());
        }
        if (uploaded != nullptr) cudaFree(uploaded);
        cudaFree(any_plane.device);
    }

    std::printf("transfers\tprogram_host_to_device=%d\tprogram_device_to_host=%d\tlibrary_transfers=read_from_nsys_capture\n",
                host_to_device_copies, device_to_host_copies);
    std::printf("media_placement=%s\n", rejected ? "rejected" : "completed");

    preprocessor.reset();
    clip_free(clip.ctx_v);
    nvimgcodecInstanceDestroy(instance);
    if (sink.file != nullptr) std::fclose(sink.file);
    check_cuda(cudaStreamDestroy(stream), "cudaStreamDestroy");
    return rejected ? 1 : 0;
}
