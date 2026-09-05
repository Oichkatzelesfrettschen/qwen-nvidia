// One bounded OptiX ray query on the GPU, with the proof that it ran there
// and a host reference for every ray printed ahead of its result.
//
// The program takes a scene name, a query-set name, a ray count, and a
// device index, all from argv as the service hands them out of
// scripts/geometry-profiles.tsv, and builds the scene from a table in this
// file: a caller chooses a fixture and supplies no geometry. It creates the
// CUDA context and the OptiX device context, builds a geometry acceleration
// structure over the fixture's triangles, creates the pipeline from the
// device programs compiled into this binary, launches one ray per index, and
// reads every hit back. Every ray is then intersected on the host against
// the same triangles, so the reply carries the agreement count between the
// device and the reference beside the hit summary: a device answer the
// reference contradicts is a result under the wrong claim. The proof block,
// the summary, the per-primitive hit counts, and a digest of the packed
// per-ray results go to stdout as one JSON object on one line; diagnostics go
// to stderr.
//
// Build: scripts/build-geometry-runtime.sh, against /usr/include/optix and
// the driver's libnvoptix.

#include <optix.h>
#include <optix_function_table_definition.h>
#include <optix_stubs.h>

#include <cuda.h>
#include <cuda_runtime.h>

#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "optix-ray-shared.h"
#include "optix-ray-programs-ptx.h"

namespace {

struct Triangle {
    float a[3];
    float b[3];
    float c[3];
};

// The fixtures. cube-and-plane is a unit cube centered at the origin over a
// ground square at y = -0.5 spanning [-4, 4] on x and z.
std::vector<Triangle> build_scene(const std::string & name) {
    std::vector<Triangle> triangles;
    if (name != "cube-and-plane") {
        return triangles;
    }
    const float h = 0.5f;
    const float v[8][3] = {
        {-h, -h, -h}, {h, -h, -h}, {h, h, -h}, {-h, h, -h},
        {-h, -h,  h}, {h, -h,  h}, {h, h,  h}, {-h, h,  h},
    };
    const int faces[12][3] = {
        {0, 2, 1}, {0, 3, 2}, {4, 5, 6}, {4, 6, 7},
        {0, 1, 5}, {0, 5, 4}, {3, 7, 6}, {3, 6, 2},
        {0, 4, 7}, {0, 7, 3}, {1, 2, 6}, {1, 6, 5},
    };
    for (const auto & face : faces) {
        Triangle t;
        std::memcpy(t.a, v[face[0]], sizeof t.a);
        std::memcpy(t.b, v[face[1]], sizeof t.b);
        std::memcpy(t.c, v[face[2]], sizeof t.c);
        triangles.push_back(t);
    }
    const float g = 4.0f;
    const float y = -0.5f;
    Triangle p0 = {{-g, y, -g}, {g, y, g}, {g, y, -g}};
    Triangle p1 = {{-g, y, -g}, {-g, y, g}, {g, y, g}};
    triangles.push_back(p0);
    triangles.push_back(p1);
    return triangles;
}

// The query sets. orbit places ray i on a circle of radius 3 at height 0.25
// at angle 2*pi*i/n, aimed at a point that sweeps the cube's height as i
// advances, so a set of any count covers hits on every cube face, hits on the
// ground behind the cube, and misses above it.
bool build_rays(const std::string & name, unsigned int count, std::vector<Ray> & rays) {
    if (name != "orbit") {
        return false;
    }
    rays.resize(count);
    const float radius = 3.0f;
    for (unsigned int i = 0; i < count; ++i) {
        const double angle = 2.0 * M_PI * (double) i / (double) count;
        const float ox = (float) (radius * std::cos(angle));
        const float oz = (float) (radius * std::sin(angle));
        const float oy = 0.25f;
        // the aim point sweeps from y = -1.2 to y = 1.4: a ray from height
        // 0.25 three units out reaches the cube's near face at
        // y = 0.25 + (ty - 0.25) * 2.5 / 3, so aims under -0.65 cross the
        // ground ahead of the cube, aims up to about 0.55 strike a face, and
        // aims above pass over the cube and miss
        const float ty = -1.2f + 2.6f * (float) ((i * 7919u) % 1000u) / 999.0f;
        float dx = -ox, dy = ty - oy, dz = -oz;
        const float len = std::sqrt(dx*dx + dy*dy + dz*dz);
        dx /= len; dy /= len; dz /= len;
        rays[i] = {{ox, oy, oz}, {dx, dy, dz}};
    }
    return true;
}

// Moller-Trumbore on the host, the reference every device hit is held to.
bool intersect(const Ray & ray, const Triangle & tri, float & t_out) {
    const float e1[3] = {tri.b[0]-tri.a[0], tri.b[1]-tri.a[1], tri.b[2]-tri.a[2]};
    const float e2[3] = {tri.c[0]-tri.a[0], tri.c[1]-tri.a[1], tri.c[2]-tri.a[2]};
    const float d[3] = {ray.direction[0], ray.direction[1], ray.direction[2]};
    const float p[3] = {d[1]*e2[2]-d[2]*e2[1], d[2]*e2[0]-d[0]*e2[2], d[0]*e2[1]-d[1]*e2[0]};
    const float det = e1[0]*p[0] + e1[1]*p[1] + e1[2]*p[2];
    if (std::fabs(det) < 1e-9f) return false;
    const float inv = 1.0f / det;
    const float s[3] = {ray.origin[0]-tri.a[0], ray.origin[1]-tri.a[1], ray.origin[2]-tri.a[2]};
    const float u = (s[0]*p[0] + s[1]*p[1] + s[2]*p[2]) * inv;
    if (u < 0.0f || u > 1.0f) return false;
    const float q[3] = {s[1]*e1[2]-s[2]*e1[1], s[2]*e1[0]-s[0]*e1[2], s[0]*e1[1]-s[1]*e1[0]};
    const float v = (d[0]*q[0] + d[1]*q[1] + d[2]*q[2]) * inv;
    if (v < 0.0f || u + v > 1.0f) return false;
    const float t = (e2[0]*q[0] + e2[1]*q[1] + e2[2]*q[2]) * inv;
    if (t <= 0.0f) return false;
    t_out = t;
    return true;
}

RayResult reference(const Ray & ray, const std::vector<Triangle> & triangles, float t_max) {
    RayResult best = {-1.0f, -1};
    for (size_t i = 0; i < triangles.size(); ++i) {
        float t;
        if (intersect(ray, triangles[i], t) && t <= t_max && (best.primitive < 0 || t < best.t)) {
            best.t = t;
            best.primitive = (int) i;
        }
    }
    return best;
}

// FNV-1a 64 over the packed results, the identity of one launch's answer.
uint64_t digest(const std::vector<RayResult> & results) {
    uint64_t h = 1469598103934665603ULL;
    for (const auto & r : results) {
        unsigned char bytes[8];
        std::memcpy(bytes, &r.t, 4);
        std::memcpy(bytes + 4, &r.primitive, 4);
        for (unsigned char b : bytes) {
            h ^= b;
            h *= 1099511628211ULL;
        }
    }
    return h;
}

int fail(const char * reason) {
    std::fprintf(stderr, "optix_runtime=rejected reason=%s\n", reason);
    return 1;
}

#define CUDA_CHECK(call, reason) do { cudaError_t e = (call); if (e != cudaSuccess) { std::fprintf(stderr, "cuda: %s\n", cudaGetErrorString(e)); return fail(reason); } } while (0)
#define OPTIX_CHECK(call, reason) do { OptixResult r = (call); if (r != OPTIX_SUCCESS) { std::fprintf(stderr, "optix: %s\n", optixGetErrorName(r)); return fail(reason); } } while (0)

void log_callback(unsigned int level, const char * tag, const char * message, void *) {
    if (level <= 2) {
        std::fprintf(stderr, "optix[%u][%s]: %s\n", level, tag, message);
    }
}

template <typename T>
struct SbtRecord {
    alignas(OPTIX_SBT_RECORD_ALIGNMENT) char header[OPTIX_SBT_RECORD_HEADER_SIZE];
    T data;
};

struct Empty { int unused; };

} // namespace

int main(int argc, char ** argv) {
    if (argc != 5) {
        std::fprintf(stderr, "usage: optix-ray-runtime SCENE QUERY_SET RAY_COUNT DEVICE_INDEX\n");
        return 2;
    }
    const std::string scene_name = argv[1];
    const std::string query_name = argv[2];
    const long ray_count_long = std::strtol(argv[3], nullptr, 10);
    const int device_index = std::atoi(argv[4]);
    if (ray_count_long < 1 || ray_count_long > 1048576 || device_index < 0) {
        return 2;
    }
    const unsigned int ray_count = (unsigned int) ray_count_long;
    const float t_max = 100.0f;

    const auto wall_start = std::chrono::steady_clock::now();
    std::vector<Triangle> triangles = build_scene(scene_name);
    if (triangles.empty()) return fail("unknown_scene");
    std::vector<Ray> rays;
    if (!build_rays(query_name, ray_count, rays)) return fail("unknown_query_set");

    bool context_created = false, gas_built = false, pipeline_created = false, launch_completed = false;

    CUDA_CHECK(cudaSetDevice(device_index), "cuda_device_unavailable");
    cudaDeviceProp prop;
    CUDA_CHECK(cudaGetDeviceProperties(&prop, device_index), "cuda_device_unavailable");
    CUDA_CHECK(cudaFree(nullptr), "cuda_context_invalid");
    CUcontext cu_context = nullptr;
    if (cuCtxGetCurrent(&cu_context) != CUDA_SUCCESS || cu_context == nullptr) return fail("cuda_context_invalid");

    OPTIX_CHECK(optixInit(), "optix_init_failed");
    OptixDeviceContextOptions options = {};
    options.logCallbackFunction = &log_callback;
    options.logCallbackLevel = 2;
    OptixDeviceContext context = nullptr;
    OPTIX_CHECK(optixDeviceContextCreate(cu_context, &options, &context), "optix_context_failed");
    context_created = true;

    // geometry acceleration structure over the fixture's triangles
    std::vector<float> vertices;
    vertices.reserve(triangles.size() * 9);
    for (const auto & t : triangles) {
        vertices.insert(vertices.end(), t.a, t.a + 3);
        vertices.insert(vertices.end(), t.b, t.b + 3);
        vertices.insert(vertices.end(), t.c, t.c + 3);
    }
    CUdeviceptr d_vertices = 0;
    CUDA_CHECK(cudaMalloc((void **) &d_vertices, vertices.size() * sizeof(float)), "cuda_alloc_failed");
    CUDA_CHECK(cudaMemcpy((void *) d_vertices, vertices.data(), vertices.size() * sizeof(float), cudaMemcpyHostToDevice), "cuda_copy_failed");
    OptixBuildInput build_input = {};
    build_input.type = OPTIX_BUILD_INPUT_TYPE_TRIANGLES;
    build_input.triangleArray.vertexFormat = OPTIX_VERTEX_FORMAT_FLOAT3;
    build_input.triangleArray.vertexStrideInBytes = sizeof(float) * 3;
    build_input.triangleArray.numVertices = (unsigned int) (triangles.size() * 3);
    build_input.triangleArray.vertexBuffers = &d_vertices;
    const unsigned int flags[1] = {OPTIX_GEOMETRY_FLAG_NONE};
    build_input.triangleArray.flags = flags;
    build_input.triangleArray.numSbtRecords = 1;
    OptixAccelBuildOptions accel_options = {};
    accel_options.buildFlags = OPTIX_BUILD_FLAG_NONE;
    accel_options.operation = OPTIX_BUILD_OPERATION_BUILD;
    OptixAccelBufferSizes sizes = {};
    OPTIX_CHECK(optixAccelComputeMemoryUsage(context, &accel_options, &build_input, 1, &sizes), "optix_gas_size_failed");
    CUdeviceptr d_temp = 0, d_gas = 0;
    CUDA_CHECK(cudaMalloc((void **) &d_temp, sizes.tempSizeInBytes), "cuda_alloc_failed");
    CUDA_CHECK(cudaMalloc((void **) &d_gas, sizes.outputSizeInBytes), "cuda_alloc_failed");
    OptixTraversableHandle handle = 0;
    OPTIX_CHECK(optixAccelBuild(context, nullptr, &accel_options, &build_input, 1, d_temp, sizes.tempSizeInBytes,
                                d_gas, sizes.outputSizeInBytes, &handle, nullptr, 0), "optix_gas_build_failed");
    CUDA_CHECK(cudaDeviceSynchronize(), "optix_gas_build_failed");
    gas_built = true;

    // module, program groups, pipeline from the compiled-in PTX
    OptixModuleCompileOptions module_options = {};
    module_options.optLevel = OPTIX_COMPILE_OPTIMIZATION_DEFAULT;
    module_options.debugLevel = OPTIX_COMPILE_DEBUG_LEVEL_NONE;
    OptixPipelineCompileOptions pipeline_options = {};
    pipeline_options.usesMotionBlur = 0;
    pipeline_options.traversableGraphFlags = OPTIX_TRAVERSABLE_GRAPH_FLAG_ALLOW_SINGLE_GAS;
    pipeline_options.numPayloadValues = 2;
    pipeline_options.numAttributeValues = 2;
    pipeline_options.exceptionFlags = OPTIX_EXCEPTION_FLAG_NONE;
    pipeline_options.pipelineLaunchParamsVariableName = "params";
    pipeline_options.usesPrimitiveTypeFlags = OPTIX_PRIMITIVE_TYPE_FLAGS_TRIANGLE;
    char log[4096];
    size_t log_size = sizeof log;
    OptixModule module = nullptr;
    OPTIX_CHECK(optixModuleCreate(context, &module_options, &pipeline_options, optix_ray_programs_ptx,
                                  sizeof(optix_ray_programs_ptx) - 1, log, &log_size, &module), "optix_module_failed");
    OptixProgramGroupOptions group_options = {};
    OptixProgramGroupDesc descs[3] = {};
    descs[0].kind = OPTIX_PROGRAM_GROUP_KIND_RAYGEN;
    descs[0].raygen.module = module;
    descs[0].raygen.entryFunctionName = "__raygen__orbit";
    descs[1].kind = OPTIX_PROGRAM_GROUP_KIND_MISS;
    descs[1].miss.module = module;
    descs[1].miss.entryFunctionName = "__miss__orbit";
    descs[2].kind = OPTIX_PROGRAM_GROUP_KIND_HITGROUP;
    descs[2].hitgroup.moduleCH = module;
    descs[2].hitgroup.entryFunctionNameCH = "__closesthit__orbit";
    OptixProgramGroup groups[3] = {};
    log_size = sizeof log;
    OPTIX_CHECK(optixProgramGroupCreate(context, descs, 3, &group_options, log, &log_size, groups), "optix_program_group_failed");
    OptixPipelineLinkOptions link_options = {};
    link_options.maxTraceDepth = 1;
    OptixPipeline pipeline = nullptr;
    log_size = sizeof log;
    OPTIX_CHECK(optixPipelineCreate(context, &pipeline_options, &link_options, groups, 3, log, &log_size, &pipeline), "optix_pipeline_failed");
    OPTIX_CHECK(optixPipelineSetStackSize(pipeline, 0, 0, 2048, 1), "optix_pipeline_failed");
    pipeline_created = true;

    // shader binding table
    SbtRecord<Empty> raygen_record = {}, miss_record = {}, hit_record = {};
    OPTIX_CHECK(optixSbtRecordPackHeader(groups[0], &raygen_record), "optix_sbt_failed");
    OPTIX_CHECK(optixSbtRecordPackHeader(groups[1], &miss_record), "optix_sbt_failed");
    OPTIX_CHECK(optixSbtRecordPackHeader(groups[2], &hit_record), "optix_sbt_failed");
    CUdeviceptr d_raygen = 0, d_miss = 0, d_hit = 0;
    CUDA_CHECK(cudaMalloc((void **) &d_raygen, sizeof raygen_record), "cuda_alloc_failed");
    CUDA_CHECK(cudaMalloc((void **) &d_miss, sizeof miss_record), "cuda_alloc_failed");
    CUDA_CHECK(cudaMalloc((void **) &d_hit, sizeof hit_record), "cuda_alloc_failed");
    CUDA_CHECK(cudaMemcpy((void *) d_raygen, &raygen_record, sizeof raygen_record, cudaMemcpyHostToDevice), "cuda_copy_failed");
    CUDA_CHECK(cudaMemcpy((void *) d_miss, &miss_record, sizeof miss_record, cudaMemcpyHostToDevice), "cuda_copy_failed");
    CUDA_CHECK(cudaMemcpy((void *) d_hit, &hit_record, sizeof hit_record, cudaMemcpyHostToDevice), "cuda_copy_failed");
    OptixShaderBindingTable sbt = {};
    sbt.raygenRecord = d_raygen;
    sbt.missRecordBase = d_miss;
    sbt.missRecordStrideInBytes = sizeof miss_record;
    sbt.missRecordCount = 1;
    sbt.hitgroupRecordBase = d_hit;
    sbt.hitgroupRecordStrideInBytes = sizeof hit_record;
    sbt.hitgroupRecordCount = 1;

    // rays in, results out, one launch
    CUdeviceptr d_rays = 0, d_results = 0, d_params = 0;
    CUDA_CHECK(cudaMalloc((void **) &d_rays, rays.size() * sizeof(Ray)), "cuda_alloc_failed");
    CUDA_CHECK(cudaMalloc((void **) &d_results, rays.size() * sizeof(RayResult)), "cuda_alloc_failed");
    CUDA_CHECK(cudaMalloc((void **) &d_params, sizeof(LaunchParams)), "cuda_alloc_failed");
    CUDA_CHECK(cudaMemcpy((void *) d_rays, rays.data(), rays.size() * sizeof(Ray), cudaMemcpyHostToDevice), "cuda_copy_failed");
    LaunchParams params = {};
    params.handle = handle;
    params.rays = (const Ray *) d_rays;
    params.results = (RayResult *) d_results;
    params.ray_count = ray_count;
    params.t_max = t_max;
    CUDA_CHECK(cudaMemcpy((void *) d_params, &params, sizeof params, cudaMemcpyHostToDevice), "cuda_copy_failed");
    const auto launch_start = std::chrono::steady_clock::now();
    OPTIX_CHECK(optixLaunch(pipeline, nullptr, d_params, sizeof(LaunchParams), &sbt, ray_count, 1, 1), "optix_launch_failed");
    CUDA_CHECK(cudaDeviceSynchronize(), "optix_launch_failed");
    const auto launch_end = std::chrono::steady_clock::now();
    launch_completed = true;
    std::vector<RayResult> results(ray_count);
    CUDA_CHECK(cudaMemcpy(results.data(), (void *) d_results, results.size() * sizeof(RayResult), cudaMemcpyDeviceToHost), "cuda_copy_failed");

    // summary and reference agreement
    std::vector<uint64_t> primitive_hits(triangles.size(), 0);
    uint64_t hits = 0, misses = 0, agree = 0, disagree = 0;
    double t_sum = 0.0;
    float t_min = t_max, t_hi = 0.0f;
    for (unsigned int i = 0; i < ray_count; ++i) {
        const RayResult & r = results[i];
        const RayResult ref = reference(rays[i], triangles, t_max);
        const bool device_hit = r.t >= 0.0f && r.primitive >= 0 && (size_t) r.primitive < triangles.size();
        const bool reference_hit = ref.primitive >= 0;
        bool same = device_hit == reference_hit;
        if (same && device_hit) {
            // the same face at the same distance within the float error of
            // two intersectors; two coplanar triangles of one face are the
            // same surface, so an edge hit on the neighbor is not a disagreement
            same = std::fabs(r.t - ref.t) <= 1e-3f * std::fmax(1.0f, ref.t);
        }
        if (same) ++agree; else ++disagree;
        if (device_hit) {
            ++hits;
            ++primitive_hits[(size_t) r.primitive];
            t_sum += r.t;
            if (r.t < t_min) t_min = r.t;
            if (r.t > t_hi) t_hi = r.t;
        } else {
            ++misses;
        }
    }
    const auto wall_end = std::chrono::steady_clock::now();
    const double launch_ms = std::chrono::duration<double, std::milli>(launch_end - launch_start).count();
    const double wall_ms = std::chrono::duration<double, std::milli>(wall_end - wall_start).count();

    char buffer[128];
    std::string out = "{";
    out += "\"scene\":\"" + scene_name + "\",\"query_set\":\"" + query_name + "\"";
    out += ",\"rays\":" + std::to_string(ray_count);
    out += ",\"hits\":" + std::to_string(hits) + ",\"misses\":" + std::to_string(misses);
    std::snprintf(buffer, sizeof buffer, ",\"t_min\":%.6g,\"t_max\":%.6g,\"t_mean\":%.6g",
                  hits ? t_min : 0.0f, t_hi, hits ? t_sum / (double) hits : 0.0);
    out += buffer;
    out += ",\"primitive_hits\":[";
    for (size_t i = 0; i < primitive_hits.size(); ++i) {
        out += (i ? "," : "") + std::to_string(primitive_hits[i]);
    }
    out += "]";
    out += ",\"reference_agreement\":" + std::to_string(agree) + ",\"reference_disagreement\":" + std::to_string(disagree);
    std::snprintf(buffer, sizeof buffer, ",\"results_fnv1a64\":\"%016llx\"", (unsigned long long) digest(results));
    out += buffer;
    std::snprintf(buffer, sizeof buffer, ",\"wall_ms\":%.3f,\"launch_ms\":%.3f", wall_ms, launch_ms);
    out += buffer;
    out += ",\"gpu\":{";
    out += std::string("\"context_created\":") + (context_created ? "true" : "false");
    out += std::string(",\"gas_built\":") + (gas_built ? "true" : "false");
    out += std::string(",\"pipeline_created\":") + (pipeline_created ? "true" : "false");
    out += std::string(",\"launch_completed\":") + (launch_completed ? "true" : "false");
    out += ",\"optix_version\":" + std::to_string(OPTIX_VERSION);
    out += ",\"gas_bytes\":" + std::to_string(sizes.outputSizeInBytes);
    out += ",\"device_name\":\"" + std::string(prop.name) + "\",\"device_index\":" + std::to_string(device_index) + "}";
    out += "}";
    std::printf("%s\n", out.c_str());

    optixPipelineDestroy(pipeline);
    for (auto & g : groups) optixProgramGroupDestroy(g);
    optixModuleDestroy(module);
    optixDeviceContextDestroy(context);
    cudaFree((void *) d_rays); cudaFree((void *) d_results); cudaFree((void *) d_params);
    cudaFree((void *) d_raygen); cudaFree((void *) d_miss); cudaFree((void *) d_hit);
    cudaFree((void *) d_temp); cudaFree((void *) d_gas); cudaFree((void *) d_vertices);
    return 0;
}
