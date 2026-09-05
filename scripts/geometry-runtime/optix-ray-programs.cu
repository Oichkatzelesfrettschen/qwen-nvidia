// The device side of the geometry runtime: one ray per launch index traced
// against the fixture's acceleration structure, with the closest hit's
// distance and primitive index returned in two payload registers and a miss
// returned as a negative distance. The programs read nothing but the launch
// parameters, so the host owns every ray and every result.

#include <optix.h>

#include "optix-ray-shared.h"

extern "C" {
__constant__ LaunchParams params;
}

static __forceinline__ __device__ float uint_as_float_bits(unsigned int value) {
    return __uint_as_float(value);
}

extern "C" __global__ void __raygen__orbit() {
    const unsigned int index = optixGetLaunchIndex().x;
    if (index >= params.ray_count) {
        return;
    }
    const Ray ray = params.rays[index];
    unsigned int p0 = __float_as_uint(-1.0f);
    unsigned int p1 = 0xffffffffu;
    optixTrace(params.handle,
               make_float3(ray.origin[0], ray.origin[1], ray.origin[2]),
               make_float3(ray.direction[0], ray.direction[1], ray.direction[2]),
               0.0f, params.t_max, 0.0f,
               OptixVisibilityMask(255), OPTIX_RAY_FLAG_NONE,
               0, 1, 0,
               p0, p1);
    params.results[index].t = uint_as_float_bits(p0);
    params.results[index].primitive = (int) p1;
}

extern "C" __global__ void __miss__orbit() {
    optixSetPayload_0(__float_as_uint(-1.0f));
    optixSetPayload_1(0xffffffffu);
}

extern "C" __global__ void __closesthit__orbit() {
    optixSetPayload_0(__float_as_uint(optixGetRayTmax()));
    optixSetPayload_1(optixGetPrimitiveIndex());
}
