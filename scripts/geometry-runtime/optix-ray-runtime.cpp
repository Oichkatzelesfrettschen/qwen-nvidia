// Bounded OptiX ray queries on the GPU, with the proof that each ran there
// and a host reference for every ray printed ahead of its result.
//
// The program runs in one of two modes against one Session. One-shot mode
// takes a ray count, builds the device state, serves that one query, releases
// everything and prints one JSON object; it is what geometry-service.py
// spawns per request and it is the control the resident mode is measured
// against. Resident mode takes the bounds a bounded-resident profile row
// declares -- the requests and wall seconds a session serves, the idle
// interval that ends it early, and the device memory it may hold -- builds
// the state once, prints a ready line, and then serves one request per line
// read from stdin until a bound or a shutdown arrives, whereupon it releases
// every device resource and prints a retired line. It runs one request at a
// time and holds no compute lease of its own: the supervisor takes the lease
// around each request and holds none while the worker waits for the next.
//
// The stages partition the same table in both modes. A one-shot run names all
// thirteen; a resident session names six at startup, six per request and
// teardown at retirement, which is what makes a session's total comparable
// against the one-shot run it is measured against.
//
// The program takes a scene name, a query-set name, and a device index, all
// from argv as the service or the supervisor hands them out of
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

#include <cerrno>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <poll.h>
#include <unistd.h>

#include "optix-ray-shared.h"
#include "optix-ray-programs-ptx.h"

namespace {

using Clock = std::chrono::steady_clock;

double elapsed_ms(Clock::time_point from, Clock::time_point to) {
    return std::chrono::duration<double, std::milli>(to - from).count();
}

// One number per stage rather than one wall figure, because the stages answer
// different questions: what a first launch costs, what a resident worker could
// keep, and what every query pays whatever is cached. optixModuleCreate is the
// stage the disk cache governs, so it is separated from the pipeline link it
// used to sit beside.
struct Stages {
    double scene_ms = 0.0;
    double cuda_context_ms = 0.0;
    double optix_context_ms = 0.0;
    double accel_ms = 0.0;
    double module_ms = 0.0;
    double pipeline_ms = 0.0;
    double sbt_ms = 0.0;
    double upload_ms = 0.0;
    double launch_ms = 0.0;
    double download_ms = 0.0;
    double reference_ms = 0.0;
    double compare_ms = 0.0;
    double teardown_ms = 0.0;
};

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

// The version of scripts/geometry_protocol.py this binary was built against.
// build-geometry-runtime.sh reads it out of that module and defines it here,
// so the Python module stays the one authority and a binary compiled against
// an older protocol reports the version it speaks rather than a key set that
// happens to differ. A protocol change moves the binary's digest with it.
#ifndef GEOMETRY_PROTOCOL_VERSION
#error "GEOMETRY_PROTOCOL_VERSION is defined by build-geometry-runtime.sh from geometry_protocol.py"
#endif
// The interval a worker that announced its retirement waits for the
// supervisor's shutdown line before destroying unauthorized. Both ends read
// geometry_protocol.RETIREMENT_AUTHORIZATION_S, so a supervisor cannot be
// slower to authorize than the worker is willing to wait.
#ifndef GEOMETRY_RETIREMENT_AUTHORIZATION_S
#error "GEOMETRY_RETIREMENT_AUTHORIZATION_S is defined by build-geometry-runtime.sh from geometry_protocol.py"
#endif

namespace {

// A supervisor asking the resident worker to stop ends the session the way
// the worker's own bounds do. sig_atomic_t is what a handler may write, and
// poll() returns EINTR at the same moment, so the wait ends without a second
// mechanism.
volatile sig_atomic_t stop_requested = 0;

void on_stop(int) { stop_requested = 1; }

// The request line's own parser. geometry_protocol.py bounds an identifier to
// [A-Za-z0-9_-] and a count to an integer, so no value can carry a quote and
// no key can appear inside one; the search for a key is exact rather than
// approximate. A line holding anything else is refused whole, because a
// long-lived process reading lines is where a permissive parser would widen
// what a caller reaches.
bool json_key_offset(const std::string & line, const char * key, size_t & offset) {
    const std::string quoted = std::string("\"") + key + "\"";
    const size_t found = line.find(quoted);
    if (found == std::string::npos) return false;
    size_t index = found + quoted.size();
    while (index < line.size() && (line[index] == ' ' || line[index] == '\t')) ++index;
    if (index >= line.size() || line[index] != ':') return false;
    ++index;
    while (index < line.size() && (line[index] == ' ' || line[index] == '\t')) ++index;
    offset = index;
    return true;
}

bool json_string_field(const std::string & line, const char * key, std::string & out) {
    size_t index = 0;
    if (!json_key_offset(line, key, index)) return false;
    if (index >= line.size() || line[index] != '"') return false;
    ++index;
    out.clear();
    while (index < line.size() && line[index] != '"') {
        const char c = line[index];
        const bool allowed = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                             (c >= '0' && c <= '9') || c == '-' || c == '_';
        if (!allowed || out.size() >= 64) return false;
        out.push_back(c);
        ++index;
    }
    return index < line.size() && !out.empty();
}

bool json_uint_field(const std::string & line, const char * key, unsigned long & out) {
    size_t index = 0;
    if (!json_key_offset(line, key, index)) return false;
    if (index >= line.size() || line[index] < '0' || line[index] > '9') return false;
    out = 0;
    while (index < line.size() && line[index] >= '0' && line[index] <= '9') {
        if (out > (4294967295UL - 9) / 10) return false;
        out = out * 10 + (unsigned long) (line[index] - '0');
        ++index;
    }
    return true;
}

// One line from the supervisor, or the reason none arrived. The caller passes
// the moment the wait ends rather than its length: a byte read restarts the
// loop, so a relative timeout would be renewed per byte and a sender dripping
// an unfinished line would hold the session open past the wall bound the loop
// checks only between requests. poll() takes an int of milliseconds, so a
// remaining interval longer than a day waits in day-length steps.
enum class LineOutcome { line, closed, timeout, interrupted, overlong };

const int POLL_WAIT_CEILING_MS = 86400000;

LineOutcome read_line(std::string & line, Clock::time_point deadline) {
    line.clear();
    for (;;) {
        const double remaining_ms = elapsed_ms(Clock::now(), deadline);
        if (remaining_ms <= 0.0) return LineOutcome::timeout;
        const int timeout_ms = remaining_ms > (double) POLL_WAIT_CEILING_MS
                               ? POLL_WAIT_CEILING_MS : (int) remaining_ms;
        struct pollfd waiting = {0, POLLIN, 0};
        const int ready = poll(&waiting, 1, timeout_ms);
        if (ready < 0) return errno == EINTR ? LineOutcome::interrupted : LineOutcome::closed;
        if (ready == 0) return LineOutcome::timeout;
        char byte = 0;
        const ssize_t got = read(0, &byte, 1);
        if (got == 0) return LineOutcome::closed;
        if (got < 0) return errno == EINTR ? LineOutcome::interrupted : LineOutcome::closed;
        if (byte == '\n') return LineOutcome::line;
        if (line.size() >= 65536) return LineOutcome::overlong;
        line.push_back(byte);
    }
}

// What one request found, apart from the timings that found it.
struct Summary {
    std::vector<uint64_t> primitive_hits;
    uint64_t hits = 0, misses = 0, agree = 0, disagree = 0;
    double t_sum = 0.0;
    float t_min = 0.0f, t_hi = 0.0f;
    uint64_t results_digest = 0;
};

#define SESSION_CHECK(call) do { const int rc = (call); if (rc != 0) return rc; } while (0)

// The device state a query runs against. One-shot mode builds it, serves one
// request and releases it; resident mode builds it once and serves the
// requests of one declared session against it. Both call setup(), serve() and
// teardown(), so the control arm and the experiment differ in how many times
// each runs and in nothing else the stages measure.
struct Session {
    std::string scene_name, query_name, module_cache;
    int device_index = 0;
    int cache_requested = 1;
    float t_max = 100.0f;
    // What this process may ask cudaMalloc for. Zero leaves the ceiling to the
    // caller, which is what a one-shot run has: its allocations end with the
    // process that held the compute lease.
    size_t budget_bytes = 0;
    // The supervisor's ceiling over the driver's reading for the whole
    // process, which counts the CUDA context and the OptiX module and pipeline
    // that no cudaMalloc here passes through. The worker echoes it so the
    // supervisor can detect the two holding different sessions, and enforces
    // budget_bytes, which is the only figure it can account for.
    size_t residency_budget_mib = 0;

    std::vector<Triangle> triangles;
    cudaDeviceProp prop = {};
    CUcontext cu_context = nullptr;
    OptixDeviceContext context = nullptr;
    OptixModule module = nullptr;
    OptixProgramGroup groups[3] = {};
    OptixPipeline pipeline = nullptr;
    OptixShaderBindingTable sbt = {};
    OptixTraversableHandle handle = 0;
    size_t gas_output_bytes = 0;
    int cache_enabled = -1;
    char cache_location[512] = {};
    bool context_created = false, gas_built = false, pipeline_created = false;

    CUdeviceptr d_vertices = 0, d_gas = 0, d_raygen = 0, d_miss = 0, d_hit = 0;
    CUdeviceptr d_rays = 0, d_results = 0, d_params = 0;
    size_t vertices_bytes = 0, gas_bytes = 0, raygen_bytes = 0, miss_bytes = 0, hit_bytes = 0;
    size_t rays_bytes = 0, results_bytes = 0, params_bytes = 0;
    size_t allocated_bytes = 0;

    std::vector<Ray> rays;
    std::vector<RayResult> results, references;

    // Every device allocation passes through here, so allocated_bytes is what
    // this process asked the driver for rather than an estimate of it. It is
    // one of the two readings the residency budget is held to; the supervisor
    // reads the driver's residency for the process, which counts the context
    // this number does not.
    int allocate(CUdeviceptr & pointer, size_t & tracked, size_t bytes) {
        CUDA_CHECK(cudaMalloc((void **) &pointer, bytes), "cuda_alloc_failed");
        tracked = bytes;
        allocated_bytes += bytes;
        return 0;
    }

    void release(CUdeviceptr & pointer, size_t & tracked) {
        if (pointer == 0) return;
        cudaFree((void *) pointer);
        allocated_bytes -= tracked;
        pointer = 0;
        tracked = 0;
    }

    int setup(Stages & stages);
    int serve(unsigned int ray_count, Stages & stages, Summary & summary);
    double teardown();
};

int Session::setup(Stages & stages) {
    auto mark = Clock::now();
    CUDA_CHECK(cudaSetDevice(device_index), "cuda_device_unavailable");
    CUDA_CHECK(cudaGetDeviceProperties(&prop, device_index), "cuda_device_unavailable");
    CUDA_CHECK(cudaFree(nullptr), "cuda_context_invalid");
    if (cuCtxGetCurrent(&cu_context) != CUDA_SUCCESS || cu_context == nullptr) return fail("cuda_context_invalid");
    stages.cuda_context_ms = elapsed_ms(mark, Clock::now());
    mark = Clock::now();

    OPTIX_CHECK(optixInit(), "optix_init_failed");
    OptixDeviceContextOptions options = {};
    options.logCallbackFunction = &log_callback;
    options.logCallbackLevel = 2;
    OPTIX_CHECK(optixDeviceContextCreate(cu_context, &options, &context), "optix_context_failed");
    context_created = true;

    // The disk cache is what decides whether optixModuleCreate compiles the
    // PTX or reads a compiled module back, and optix_host.h states there is no
    // in-memory cache, so a module timing taken without pinning it measures
    // run history. OPTIX_CACHE_MAXSIZE=0 in the environment takes precedence
    // over this call and can disable the cache but not enable it, so the state
    // is read back off the context rather than assumed from the request.
    OPTIX_CHECK(optixDeviceContextSetCacheEnabled(context, cache_requested), "optix_cache_failed");
    OPTIX_CHECK(optixDeviceContextGetCacheEnabled(context, &cache_enabled), "optix_cache_failed");
    if (cache_requested == 0 && cache_enabled != 0) return fail("module_cache_not_disabled");
    if (cache_enabled) {
        OPTIX_CHECK(optixDeviceContextGetCacheLocation(context, cache_location, sizeof cache_location),
                    "optix_cache_failed");
    }
    stages.optix_context_ms = elapsed_ms(mark, Clock::now());
    mark = Clock::now();

    // geometry acceleration structure over the fixture's triangles
    std::vector<float> vertices;
    vertices.reserve(triangles.size() * 9);
    for (const auto & t : triangles) {
        vertices.insert(vertices.end(), t.a, t.a + 3);
        vertices.insert(vertices.end(), t.b, t.b + 3);
        vertices.insert(vertices.end(), t.c, t.c + 3);
    }
    SESSION_CHECK(allocate(d_vertices, vertices_bytes, vertices.size() * sizeof(float)));
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
    CUdeviceptr d_temp = 0;
    size_t temp_bytes = 0;
    SESSION_CHECK(allocate(d_temp, temp_bytes, sizes.tempSizeInBytes));
    SESSION_CHECK(allocate(d_gas, gas_bytes, sizes.outputSizeInBytes));
    gas_output_bytes = sizes.outputSizeInBytes;
    OPTIX_CHECK(optixAccelBuild(context, nullptr, &accel_options, &build_input, 1, d_temp, sizes.tempSizeInBytes,
                                d_gas, sizes.outputSizeInBytes, &handle, nullptr, 0), "optix_gas_build_failed");
    CUDA_CHECK(cudaDeviceSynchronize(), "optix_gas_build_failed");
    gas_built = true;
    // The build's scratch is dead the moment the structure is built, so it is
    // released here rather than at teardown: a session holding it would carry
    // it against the residency budget for every request that never uses it.
    release(d_temp, temp_bytes);

    stages.accel_ms = elapsed_ms(mark, Clock::now());
    mark = Clock::now();

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
    OPTIX_CHECK(optixModuleCreate(context, &module_options, &pipeline_options, optix_ray_programs_ptx,
                                  sizeof(optix_ray_programs_ptx) - 1, log, &log_size, &module), "optix_module_failed");
    stages.module_ms = elapsed_ms(mark, Clock::now());
    mark = Clock::now();
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
    log_size = sizeof log;
    OPTIX_CHECK(optixProgramGroupCreate(context, descs, 3, &group_options, log, &log_size, groups), "optix_program_group_failed");
    OptixPipelineLinkOptions link_options = {};
    link_options.maxTraceDepth = 1;
    log_size = sizeof log;
    OPTIX_CHECK(optixPipelineCreate(context, &pipeline_options, &link_options, groups, 3, log, &log_size, &pipeline), "optix_pipeline_failed");
    OPTIX_CHECK(optixPipelineSetStackSize(pipeline, 0, 0, 2048, 1), "optix_pipeline_failed");
    pipeline_created = true;
    stages.pipeline_ms = elapsed_ms(mark, Clock::now());
    mark = Clock::now();

    // The shader binding table and the launch parameter block are fixed for
    // the session, so they are built once here and a request's upload writes
    // the block's contents rather than its allocation.
    SbtRecord<Empty> raygen_record = {}, miss_record = {}, hit_record = {};
    OPTIX_CHECK(optixSbtRecordPackHeader(groups[0], &raygen_record), "optix_sbt_failed");
    OPTIX_CHECK(optixSbtRecordPackHeader(groups[1], &miss_record), "optix_sbt_failed");
    OPTIX_CHECK(optixSbtRecordPackHeader(groups[2], &hit_record), "optix_sbt_failed");
    SESSION_CHECK(allocate(d_raygen, raygen_bytes, sizeof raygen_record));
    SESSION_CHECK(allocate(d_miss, miss_bytes, sizeof miss_record));
    SESSION_CHECK(allocate(d_hit, hit_bytes, sizeof hit_record));
    SESSION_CHECK(allocate(d_params, params_bytes, sizeof(LaunchParams)));
    CUDA_CHECK(cudaMemcpy((void *) d_raygen, &raygen_record, sizeof raygen_record, cudaMemcpyHostToDevice), "cuda_copy_failed");
    CUDA_CHECK(cudaMemcpy((void *) d_miss, &miss_record, sizeof miss_record, cudaMemcpyHostToDevice), "cuda_copy_failed");
    CUDA_CHECK(cudaMemcpy((void *) d_hit, &hit_record, sizeof hit_record, cudaMemcpyHostToDevice), "cuda_copy_failed");
    sbt.raygenRecord = d_raygen;
    sbt.missRecordBase = d_miss;
    sbt.missRecordStrideInBytes = sizeof miss_record;
    sbt.missRecordCount = 1;
    sbt.hitgroupRecordBase = d_hit;
    sbt.hitgroupRecordStrideInBytes = sizeof hit_record;
    sbt.hitgroupRecordCount = 1;
    stages.sbt_ms = elapsed_ms(mark, Clock::now());
    return 0;
}

// Serve one request against the session's device state. Returns 0 for a
// served request, 2 where the ray count would take the session's own
// allocations past its residency ceiling, and 1 where the device refused.
int Session::serve(unsigned int ray_count, Stages & stages, Summary & summary) {
    auto mark = Clock::now();
    if (!build_rays(query_name, ray_count, rays)) return fail("unknown_query_set");
    stages.scene_ms = elapsed_ms(mark, Clock::now());
    mark = Clock::now();

    // The ray and result buffers are the only allocations a request's size
    // changes. A larger request grows them and a smaller one runs inside what
    // is already there. The check is against the growth rather than the held
    // total so a request that fits in existing buffers never fails, and it
    // runs before cudaMalloc so a refusal costs no device memory.
    const size_t need_rays = (size_t) ray_count * sizeof(Ray);
    const size_t need_results = (size_t) ray_count * sizeof(RayResult);
    if (budget_bytes) {
        const size_t growth = (need_rays > rays_bytes ? need_rays - rays_bytes : 0) +
                              (need_results > results_bytes ? need_results - results_bytes : 0);
        if (allocated_bytes + growth > budget_bytes) {
            std::fprintf(stderr, "optix_runtime=refused reason=budget_exceeded held=%zu growth=%zu application_budget=%zu\n",
                         allocated_bytes, growth, budget_bytes);
            return 2;
        }
    }
    if (need_rays > rays_bytes) {
        release(d_rays, rays_bytes);
        SESSION_CHECK(allocate(d_rays, rays_bytes, need_rays));
    }
    if (need_results > results_bytes) {
        release(d_results, results_bytes);
        SESSION_CHECK(allocate(d_results, results_bytes, need_results));
    }
    CUDA_CHECK(cudaMemcpy((void *) d_rays, rays.data(), need_rays, cudaMemcpyHostToDevice), "cuda_copy_failed");
    LaunchParams params = {};
    params.handle = handle;
    params.rays = (const Ray *) d_rays;
    params.results = (RayResult *) d_results;
    params.ray_count = ray_count;
    params.t_max = t_max;
    CUDA_CHECK(cudaMemcpy((void *) d_params, &params, sizeof params, cudaMemcpyHostToDevice), "cuda_copy_failed");
    stages.upload_ms = elapsed_ms(mark, Clock::now());

    const auto launch_start = Clock::now();
    OPTIX_CHECK(optixLaunch(pipeline, nullptr, d_params, sizeof(LaunchParams), &sbt, ray_count, 1, 1), "optix_launch_failed");
    CUDA_CHECK(cudaDeviceSynchronize(), "optix_launch_failed");
    stages.launch_ms = elapsed_ms(launch_start, Clock::now());
    mark = Clock::now();

    results.resize(ray_count);
    CUDA_CHECK(cudaMemcpy(results.data(), (void *) d_results, need_results, cudaMemcpyDeviceToHost), "cuda_copy_failed");
    stages.download_ms = elapsed_ms(mark, Clock::now());
    mark = Clock::now();

    // The reference answer is a function of the rays, the triangles and t_max
    // and of nothing the device produced, so it is computed into its own
    // vector and timed apart from the comparison that consumes it. Unchanged
    // inputs give the same reference every run; the comparison is what has to
    // run against every fresh device result, and separating them is what makes
    // the first reusable without weakening the second.
    references.resize(ray_count);
    for (unsigned int i = 0; i < ray_count; ++i) {
        references[i] = reference(rays[i], triangles, t_max);
    }
    stages.reference_ms = elapsed_ms(mark, Clock::now());
    mark = Clock::now();

    // summary and reference agreement
    summary = Summary();
    summary.primitive_hits.assign(triangles.size(), 0);
    summary.t_min = t_max;
    for (unsigned int i = 0; i < ray_count; ++i) {
        const RayResult & r = results[i];
        const RayResult & ref = references[i];
        const bool device_hit = r.t >= 0.0f && r.primitive >= 0 && (size_t) r.primitive < triangles.size();
        const bool reference_hit = ref.primitive >= 0;
        bool same = device_hit == reference_hit;
        if (same && device_hit) {
            // the same face at the same distance within the float error of
            // two intersectors; two coplanar triangles of one face are the
            // same surface, so an edge hit on the neighbor is not a disagreement
            same = std::fabs(r.t - ref.t) <= 1e-3f * std::fmax(1.0f, ref.t);
        }
        if (same) ++summary.agree; else ++summary.disagree;
        if (device_hit) {
            ++summary.hits;
            ++summary.primitive_hits[(size_t) r.primitive];
            summary.t_sum += r.t;
            if (r.t < summary.t_min) summary.t_min = r.t;
            if (r.t > summary.t_hi) summary.t_hi = r.t;
        } else {
            ++summary.misses;
        }
    }
    summary.results_digest = digest(results);
    stages.compare_ms = elapsed_ms(mark, Clock::now());
    return 0;
}

double Session::teardown() {
    const auto mark = Clock::now();
    if (pipeline) { optixPipelineDestroy(pipeline); pipeline = nullptr; }
    for (auto & g : groups) { if (g) { optixProgramGroupDestroy(g); g = nullptr; } }
    if (module) { optixModuleDestroy(module); module = nullptr; }
    if (context) { optixDeviceContextDestroy(context); context = nullptr; }
    release(d_rays, rays_bytes);
    release(d_results, results_bytes);
    release(d_params, params_bytes);
    release(d_raygen, raygen_bytes);
    release(d_miss, miss_bytes);
    release(d_hit, hit_bytes);
    release(d_gas, gas_bytes);
    release(d_vertices, vertices_bytes);
    return elapsed_ms(mark, Clock::now());
}

struct StageField { const char * name; double value; };

// The summary a reply carries, over whichever stages the caller paid. A
// one-shot run names all thirteen; a resident request names the six it paid,
// and the session's ready and retired lines name the other seven, so the
// three sets partition one table rather than zeroing what a run did not do.
std::string result_object(const Session & session, unsigned int ray_count, const Summary & summary,
                          double wall_ms, double launch_ms, const StageField * timed, size_t timed_count) {
    char buffer[128];
    std::string out = "{";
    out += "\"scene\":\"" + session.scene_name + "\",\"query_set\":\"" + session.query_name + "\"";
    out += ",\"rays\":" + std::to_string(ray_count);
    out += ",\"hits\":" + std::to_string(summary.hits) + ",\"misses\":" + std::to_string(summary.misses);
    std::snprintf(buffer, sizeof buffer, ",\"t_min\":%.6g,\"t_max\":%.6g,\"t_mean\":%.6g",
                  summary.hits ? summary.t_min : 0.0f, summary.t_hi,
                  summary.hits ? summary.t_sum / (double) summary.hits : 0.0);
    out += buffer;
    out += ",\"primitive_hits\":[";
    for (size_t i = 0; i < summary.primitive_hits.size(); ++i) {
        out += (i ? "," : "") + std::to_string(summary.primitive_hits[i]);
    }
    out += "]";
    out += ",\"reference_agreement\":" + std::to_string(summary.agree) +
           ",\"reference_disagreement\":" + std::to_string(summary.disagree);
    std::snprintf(buffer, sizeof buffer, ",\"results_fnv1a64\":\"%016llx\"",
                  (unsigned long long) summary.results_digest);
    out += buffer;
    std::snprintf(buffer, sizeof buffer, ",\"wall_ms\":%.3f,\"launch_ms\":%.3f", wall_ms, launch_ms);
    out += buffer;
    out += ",\"timings\":{";
    for (size_t i = 0; i < timed_count; ++i) {
        std::snprintf(buffer, sizeof buffer, "%s\"%s_ms\":%.3f", i ? "," : "", timed[i].name, timed[i].value);
        out += buffer;
    }
    out += "}";
    // The request and the readback both travel: OPTIX_CACHE_MAXSIZE=0 in the
    // environment can disable a cache this asked for, and a module timing read
    // without that distinction is not reproducible.
    out += ",\"module_cache\":{\"requested\":\"" + session.module_cache + "\"";
    out += ",\"enabled\":" + std::string(session.cache_enabled ? "true" : "false");
    out += ",\"location\":\"" + std::string(session.cache_location) + "\"}";
    out += ",\"gpu\":{";
    out += std::string("\"context_created\":") + (session.context_created ? "true" : "false");
    out += std::string(",\"gas_built\":") + (session.gas_built ? "true" : "false");
    out += std::string(",\"pipeline_created\":") + (session.pipeline_created ? "true" : "false");
    // The launch this reply reports is the one that filled the results it
    // summarizes, so the flag is true wherever a result object is built at
    // all: serve() returns before this point on a launch the device refused.
    out += ",\"launch_completed\":true";
    out += ",\"optix_version\":" + std::to_string(OPTIX_VERSION);
    out += ",\"gas_bytes\":" + std::to_string(session.gas_output_bytes);
    out += ",\"device_name\":\"" + std::string(session.prop.name) + "\",\"device_index\":" +
           std::to_string(session.device_index) + "}";
    out += "}";
    return out;
}

void emit(const std::string & line) {
    std::printf("%s\n", line.c_str());
    std::fflush(stdout);
}

int one_shot(Session & session, unsigned int ray_count) {
    Stages stages;
    const auto wall_start = Clock::now();
    SESSION_CHECK(session.setup(stages));
    Summary summary;
    const int served = session.serve(ray_count, stages, summary);
    if (served == 2) return fail("budget_exceeded");
    if (served != 0) return served;
    // Teardown is timed, so it runs before the reply is assembled rather than
    // after it is printed: a stage nobody measures is a stage a resident
    // worker cannot be shown to save.
    stages.teardown_ms = session.teardown();
    const double wall_ms = elapsed_ms(wall_start, Clock::now());
    const StageField timed[] = {
        {"scene", stages.scene_ms},
        {"cuda_context", stages.cuda_context_ms},
        {"optix_context", stages.optix_context_ms},
        {"accel", stages.accel_ms},
        {"module", stages.module_ms},
        {"pipeline", stages.pipeline_ms},
        {"sbt", stages.sbt_ms},
        {"upload", stages.upload_ms},
        {"launch", stages.launch_ms},
        {"download", stages.download_ms},
        {"reference", stages.reference_ms},
        {"compare", stages.compare_ms},
        {"teardown", stages.teardown_ms},
    };
    emit(result_object(session, ray_count, summary, wall_ms, stages.launch_ms, timed,
                       sizeof timed / sizeof timed[0]));
    return 0;
}

std::string ready_line(const Session & session, const Stages & startup, double startup_ms,
                       unsigned long requests, unsigned long seconds, unsigned long idle) {
    char buffer[1024];
    std::string ready;
    std::snprintf(buffer, sizeof buffer, "{\"protocol\":%d,\"event\":\"ready\"", GEOMETRY_PROTOCOL_VERSION);
    ready += buffer;
    ready += ",\"scene\":\"" + session.scene_name + "\",\"query_set\":\"" + session.query_name + "\"";
    ready += ",\"module_cache\":{\"requested\":\"" + session.module_cache + "\"";
    ready += ",\"enabled\":" + std::string(session.cache_enabled ? "true" : "false");
    ready += ",\"location\":\"" + std::string(session.cache_location) + "\"}";
    ready += ",\"gpu\":{";
    ready += std::string("\"context_created\":") + (session.context_created ? "true" : "false");
    ready += std::string(",\"gas_built\":") + (session.gas_built ? "true" : "false");
    ready += std::string(",\"pipeline_created\":") + (session.pipeline_created ? "true" : "false");
    ready += ",\"optix_version\":" + std::to_string(OPTIX_VERSION);
    ready += ",\"gas_bytes\":" + std::to_string(session.gas_output_bytes);
    ready += ",\"device_name\":\"" + std::string(session.prop.name) + "\",\"device_index\":" +
             std::to_string(session.device_index) + "}";
    std::snprintf(buffer, sizeof buffer,
                  ",\"timings\":{\"cuda_context_ms\":%.3f,\"optix_context_ms\":%.3f,\"accel_ms\":%.3f,"
                  "\"module_ms\":%.3f,\"pipeline_ms\":%.3f,\"sbt_ms\":%.3f}"
                  ",\"startup_ms\":%.3f,\"device_allocated_bytes\":%zu"
                  ",\"session_requests\":%lu,\"session_seconds\":%lu,\"idle_timeout_s\":%lu"
                  ",\"residency_budget_mib\":%zu,\"application_budget_mib\":%zu}",
                  startup.cuda_context_ms, startup.optix_context_ms, startup.accel_ms,
                  startup.module_ms, startup.pipeline_ms, startup.sbt_ms, startup_ms,
                  session.allocated_bytes, requests, seconds, idle,
                  session.residency_budget_mib, session.budget_bytes / (1024 * 1024));
    ready += buffer;
    return ready;
}

int resident(Session & session, unsigned long session_requests, unsigned long session_seconds,
             unsigned long idle_seconds) {
    struct sigaction action = {};
    action.sa_handler = on_stop;
    sigaction(SIGTERM, &action, nullptr);
    sigaction(SIGINT, &action, nullptr);

    Stages startup;
    const auto session_start = Clock::now();
    SESSION_CHECK(session.setup(startup));
    emit(ready_line(session, startup, elapsed_ms(session_start, Clock::now()),
                    session_requests, session_seconds, idle_seconds));

    char buffer[512];
    unsigned long served = 0;
    const char * retirement = "shutdown";
    // Whether the supervisor named this retirement, and whether the worker
    // reached it on a bound of its own. The first decides whether destruction
    // runs under an owner; the second decides whether there is anybody left
    // to ask, because a closed pipe, a signal and a malformed line are each
    // the supervisor already gone or already distrusted.
    bool authorized = false;
    bool reached_own_bound = false;
    for (;;) {
        if (stop_requested) break;
        const double age_s = elapsed_ms(session_start, Clock::now()) / 1000.0;
        if (served >= session_requests) { retirement = "request_limit"; reached_own_bound = true; break; }
        if (age_s >= (double) session_seconds) { retirement = "session_limit"; reached_own_bound = true; break; }
        // Whichever bound is nearer decides how long this waits: the idle
        // interval with no request in hand, or what the session has left.
        const double remaining_s = (double) session_seconds - age_s;
        const bool idle_is_nearer = (double) idle_seconds < remaining_s;
        const double wait_s = idle_is_nearer ? (double) idle_seconds : remaining_s;
        std::string line;
        const LineOutcome outcome = read_line(
            line, Clock::now() + std::chrono::microseconds((long long) (wait_s * 1000000.0)));
        if (outcome == LineOutcome::timeout) {
            retirement = idle_is_nearer ? "idle_timeout" : "session_limit";
            reached_own_bound = true;
            break;
        }
        if (outcome != LineOutcome::line) {
            // A closed pipe is the supervisor gone and an interrupted wait is
            // its signal; an overlong line is neither, and its sender is told
            // on stderr rather than answered.
            if (outcome == LineOutcome::overlong) {
                std::fprintf(stderr, "optix_runtime=rejected reason=line_over_65536_bytes\n");
            }
            break;
        }
        unsigned long line_protocol = 0;
        std::string request_id, action_name;
        if (!json_uint_field(line, "protocol", line_protocol) ||
            line_protocol != (unsigned long) GEOMETRY_PROTOCOL_VERSION ||
            !json_string_field(line, "action", action_name) ||
            !json_string_field(line, "request_id", request_id)) {
            std::fprintf(stderr, "optix_runtime=rejected reason=malformed_request\n");
            break;
        }
        if (action_name == "shutdown") { authorized = true; break; }
        unsigned long rays_requested = 0;
        if (action_name != "query" || !json_uint_field(line, "rays", rays_requested) ||
            rays_requested < 1 || rays_requested > 1048576) {
            std::snprintf(buffer, sizeof buffer,
                          "{\"protocol\":%d,\"event\":\"refused\",\"request_id\":\"%s\","
                          "\"reason\":\"invalid_argument\","
                          "\"detail\":\"the line names no query of 1 to 1048576 rays\"}",
                          GEOMETRY_PROTOCOL_VERSION, request_id.c_str());
            emit(buffer);
            continue;
        }
        Stages stages;
        Summary summary;
        const auto request_start = Clock::now();
        const int outcome_code = session.serve((unsigned int) rays_requested, stages, summary);
        if (outcome_code == 2) {
            std::snprintf(buffer, sizeof buffer,
                          "{\"protocol\":%d,\"event\":\"refused\",\"request_id\":\"%s\","
                          "\"reason\":\"budget_exceeded\","
                          "\"detail\":\"%lu rays would take the session past its application allocation ceiling\"}",
                          GEOMETRY_PROTOCOL_VERSION, request_id.c_str(), rays_requested);
            emit(buffer);
            // The ceiling is the configuration's, so passing it ends the
            // session rather than shrinking the request: a worker that served
            // the next request would hold memory nothing admitted.
            retirement = "budget_exceeded";
            reached_own_bound = true;
            break;
        }
        if (outcome_code != 0) return outcome_code;
        const double wall_ms = elapsed_ms(request_start, Clock::now());
        ++served;
        const StageField timed[] = {
            {"scene", stages.scene_ms},
            {"upload", stages.upload_ms},
            {"launch", stages.launch_ms},
            {"download", stages.download_ms},
            {"reference", stages.reference_ms},
            {"compare", stages.compare_ms},
        };
        std::string reply;
        std::snprintf(buffer, sizeof buffer, "{\"protocol\":%d,\"event\":\"result\",\"request_id\":\"%s\"",
                      GEOMETRY_PROTOCOL_VERSION, request_id.c_str());
        reply += buffer;
        std::snprintf(buffer, sizeof buffer,
                      ",\"residency\":{\"request_index\":%lu,\"session_age_s\":%.3f,"
                      "\"device_allocated_bytes\":%zu,\"requests_remaining\":%lu}",
                      served, elapsed_ms(session_start, Clock::now()) / 1000.0,
                      session.allocated_bytes, session_requests - served);
        reply += buffer;
        reply += ",\"result\":" + result_object(session, (unsigned int) rays_requested, summary, wall_ms,
                                                stages.launch_ms, timed, sizeof timed / sizeof timed[0]);
        reply += "}";
        emit(reply);
    }
    // Destruction is compute: it frees device allocations, tears down an
    // acceleration structure, a pipeline and a context, and it runs under the
    // same compute lease a request runs under. A session ending on a bound of
    // its own reaches that moment while the supervisor holds no lease, so it
    // announces the retirement it wants and waits for the shutdown line the
    // supervisor sends holding the lease. The worker acquires no lease itself,
    // so a supervisor holding one never waits on a child that wants one.
    if (reached_own_bound && !stop_requested) {
        std::snprintf(buffer, sizeof buffer,
                      "{\"protocol\":%d,\"event\":\"retiring\",\"reason\":\"%s\","
                      "\"requests_served\":%lu,\"session_age_s\":%.3f}",
                      GEOMETRY_PROTOCOL_VERSION, retirement, served,
                      elapsed_ms(session_start, Clock::now()) / 1000.0);
        emit(buffer);
        // A supervisor that answers nothing would otherwise leave this process
        // holding its device memory for as long as it lives, so the wait ends
        // and the retired line reports destruction the supervisor never named.
        // A request the supervisor sent before it read the notice is already
        // on the wire, so lines are read until the shutdown arrives or the
        // deadline does. A query read here goes unanswered by construction:
        // the session is over, and its reply would be a request served after
        // the bound that ended it.
        std::string line;
        const auto authorize_by = Clock::now() +
            std::chrono::seconds(GEOMETRY_RETIREMENT_AUTHORIZATION_S);
        while (!authorized && read_line(line, authorize_by) == LineOutcome::line) {
            unsigned long line_protocol = 0;
            std::string request_id, action_name;
            authorized = json_uint_field(line, "protocol", line_protocol) &&
                         line_protocol == (unsigned long) GEOMETRY_PROTOCOL_VERSION &&
                         json_string_field(line, "action", action_name) &&
                         json_string_field(line, "request_id", request_id) &&
                         action_name == "shutdown";
        }
        if (!authorized) {
            std::fprintf(stderr, "optix_runtime=emergency reason=retirement_unauthorized bound=%s\n",
                         retirement);
        }
    }
    const double teardown_ms = session.teardown();
    std::snprintf(buffer, sizeof buffer,
                  "{\"protocol\":%d,\"event\":\"retired\",\"reason\":\"%s\",\"requests_served\":%lu,"
                  "\"session_age_s\":%.3f,\"timings\":{\"teardown_ms\":%.3f},"
                  "\"device_allocated_bytes\":%zu,\"authorized\":%s}",
                  GEOMETRY_PROTOCOL_VERSION, retirement, served,
                  elapsed_ms(session_start, Clock::now()) / 1000.0, teardown_ms,
                  session.allocated_bytes, authorized ? "true" : "false");
    emit(buffer);
    return 0;
}

} // namespace

int main(int argc, char ** argv) {
    // One-shot: the ray count stands where resident mode names its bounds, so
    // the two forms cannot be confused for one another by a miscounted argv.
    const bool resident_mode = argc >= 4 && std::string(argv[3]) == "resident";
    if (!((resident_mode && argc == 11) || (!resident_mode && argc == 6))) {
        std::fprintf(stderr,
                     "usage: optix-ray-runtime SCENE QUERY_SET RAY_COUNT DEVICE_INDEX MODULE_CACHE\n"
                     "       optix-ray-runtime SCENE QUERY_SET resident DEVICE_INDEX MODULE_CACHE"
                     " SESSION_REQUESTS SESSION_SECONDS IDLE_SECONDS"
                     " RESIDENCY_BUDGET_MIB APPLICATION_BUDGET_MIB\n");
        return 2;
    }
    Session session;
    session.scene_name = argv[1];
    session.query_name = argv[2];
    session.device_index = std::atoi(argv[4]);
    session.module_cache = argv[5];
    if (session.device_index < 0) return 2;
    if (session.module_cache != "enabled" && session.module_cache != "disabled") return fail("unknown_module_cache");
    session.cache_requested = session.module_cache == "enabled" ? 1 : 0;
    session.triangles = build_scene(session.scene_name);
    if (session.triangles.empty()) return fail("unknown_scene");

    if (!resident_mode) {
        const long ray_count = std::strtol(argv[3], nullptr, 10);
        if (ray_count < 1 || ray_count > 1048576) return 2;
        return one_shot(session, (unsigned int) ray_count);
    }
    const long requests = std::strtol(argv[6], nullptr, 10);
    const long seconds = std::strtol(argv[7], nullptr, 10);
    const long idle = std::strtol(argv[8], nullptr, 10);
    const long residency_mib = std::strtol(argv[9], nullptr, 10);
    const long application_mib = std::strtol(argv[10], nullptr, 10);
    // The bounds are the profile row's, revalidated here: a supervisor is what
    // hands them over, and a session that took them on trust would run under
    // whatever the launch line happened to say.
    if (requests < 1 || requests > 64 || seconds < 1 || seconds > 3600 ||
        idle < 1 || idle >= seconds || residency_mib < 1 || residency_mib > 4096 ||
        application_mib < 1 || application_mib > 4096) {
        return 2;
    }
    session.residency_budget_mib = (size_t) residency_mib;
    session.budget_bytes = (size_t) application_mib * 1024 * 1024;
    return resident(session, (unsigned long) requests, (unsigned long) seconds, (unsigned long) idle);
}
