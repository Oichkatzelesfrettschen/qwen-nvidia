#define _POSIX_C_SOURCE 200809L
// Reads the CUDA virtual memory management contract of one device without
// creating a context: cuInit, cuDeviceGet, the VMM support attribute, and
// cuMemGetAllocationGranularity at both CU_MEM_ALLOC_GRANULARITY_MINIMUM and
// CU_MEM_ALLOC_GRANULARITY_RECOMMENDED. The driver requires a mapped address,
// a mapping size, and a mapping offset to be multiples of the minimum
// (CUDA Driver API, cuMemMap); the recommended value is the one the pinned
// ggml VMM pool reads, and the two are distinct fields because they answer
// distinct questions. Every call here is a query: no cuCtxCreate, no
// cuMemCreate, no cuMemAddressReserve, no kernel. The probe proves that itself
// by reading cuCtxGetCurrent before it exits, and it holds for
// QWEN_PROBE_HOLD_MS milliseconds after the reads so a wrapper can sample the
// driver's client list while the process is alive.
#include <cuda.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static const char * error_name(CUresult result) {
    const char * name = NULL;
    if (cuGetErrorName(result, &name) != CUDA_SUCCESS || name == NULL) {
        return "unknown";
    }
    return name;
}

#define CU_TRY(call) \
    do { \
        CUresult result_ = (call); \
        if (result_ != CUDA_SUCCESS) { \
            printf("probe_status=failed call=%s result=%s\n", #call, error_name(result_)); \
            return 1; \
        } \
    } while (0)

int main(int argc, char ** argv) {
    int device_index = 0;
    if (argc > 2) {
        fprintf(stderr, "usage: %s [DEVICE_INDEX]\n", argv[0]);
        return 2;
    }
    if (argc == 2) {
        char * end = NULL;
        long parsed = strtol(argv[1], &end, 10);
        if (*argv[1] == '\0' || *end != '\0' || parsed < 0) {
            fprintf(stderr, "usage: %s [DEVICE_INDEX]\n", argv[0]);
            return 2;
        }
        device_index = (int) parsed;
    }

    int driver_version = 0;
    CU_TRY(cuInit(0));
    CU_TRY(cuDriverGetVersion(&driver_version));

    CUdevice device;
    CU_TRY(cuDeviceGet(&device, device_index));
    char name[256];
    memset(name, 0, sizeof(name));
    CU_TRY(cuDeviceGetName(name, (int) sizeof(name) - 1, device));

    int vmm_supported = 0;
    CU_TRY(cuDeviceGetAttribute(&vmm_supported, CU_DEVICE_ATTRIBUTE_VIRTUAL_MEMORY_MANAGEMENT_SUPPORTED, device));

    printf("probe_schema=1\n");
    printf("device_index=%d\n", device_index);
    printf("device_name=%s\n", name);
    printf("driver_api_version=%d\n", driver_version);
    printf("vmm_supported=%s\n", vmm_supported ? "yes" : "no");

    if (vmm_supported) {
        CUmemAllocationProp prop;
        memset(&prop, 0, sizeof(prop));
        prop.type = CU_MEM_ALLOCATION_TYPE_PINNED;
        prop.location.type = CU_MEM_LOCATION_TYPE_DEVICE;
        prop.location.id = device;

        size_t minimum = 0;
        size_t recommended = 0;
        CU_TRY(cuMemGetAllocationGranularity(&minimum, &prop, CU_MEM_ALLOC_GRANULARITY_MINIMUM));
        CU_TRY(cuMemGetAllocationGranularity(&recommended, &prop, CU_MEM_ALLOC_GRANULARITY_RECOMMENDED));
        printf("granularity_minimum=%zu\n", minimum);
        printf("granularity_recommended=%zu\n", recommended);
    } else {
        printf("granularity_minimum=unavailable\n");
        printf("granularity_recommended=unavailable\n");
    }

    const char * hold_text = getenv("QWEN_PROBE_HOLD_MS");
    long hold_ms = hold_text != NULL ? strtol(hold_text, NULL, 10) : 0;
    if (hold_ms > 0) {
        struct timespec pause;
        pause.tv_sec = hold_ms / 1000;
        pause.tv_nsec = (hold_ms % 1000) * 1000000L;
        fflush(stdout);
        nanosleep(&pause, NULL);
    }

    // A context would have to have been created by this process for the
    // current context to be non-null; the queries above create none.
    CUcontext current = NULL;
    CU_TRY(cuCtxGetCurrent(&current));
    printf("context_current=%s\n", current == NULL ? "none" : "present");
    printf("hold_ms=%ld\n", hold_ms);
    printf("probe_status=%s\n", current == NULL ? "completed" : "failed_context_present");
    return current == NULL ? 0 : 1;
}
