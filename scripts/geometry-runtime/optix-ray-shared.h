// Shared between the host runtime and the device programs: the launch
// parameter block and the per-ray records it points at.

#pragma once

#include <optix.h>

struct Ray {
    float origin[3];
    float direction[3];
};

struct RayResult {
    float t;        // closest-hit distance, or a negative value for a miss
    int   primitive; // primitive index of the hit, or -1
};

struct LaunchParams {
    OptixTraversableHandle handle;
    const Ray * rays;
    RayResult * results;
    unsigned int ray_count;
    float t_max;
};
