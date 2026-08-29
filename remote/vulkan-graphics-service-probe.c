#define _POSIX_C_SOURCE 200809L

#include <vulkan/vulkan.h>

#include <errno.h>
#include <inttypes.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t stop_requested;

static void handle_signal(int signal_number)
{
    (void)signal_number;
    stop_requested = 1;
}

static uint64_t monotonic_nanoseconds(void)
{
    struct timespec timestamp = {0};

    if (clock_gettime(CLOCK_MONOTONIC, &timestamp) != 0) {
        perror("clock_gettime(CLOCK_MONOTONIC)");
        exit(EXIT_FAILURE);
    }
    return (uint64_t)timestamp.tv_sec * UINT64_C(1000000000) +
           (uint64_t)timestamp.tv_nsec;
}

static uint64_t realtime_nanoseconds(void)
{
    struct timespec timestamp = {0};

    if (clock_gettime(CLOCK_REALTIME, &timestamp) != 0) {
        perror("clock_gettime(CLOCK_REALTIME)");
        exit(EXIT_FAILURE);
    }
    return (uint64_t)timestamp.tv_sec * UINT64_C(1000000000) +
           (uint64_t)timestamp.tv_nsec;
}

static uint64_t parse_unsigned(const char *name, const char *value,
                               uint64_t minimum, uint64_t maximum)
{
    char *end = NULL;
    unsigned long long parsed_value;

    if (value == NULL || *value == '\0' || *value == '-') {
        fprintf(stderr, "%s must be an integer from %" PRIu64 " through %" PRIu64 "\n",
                name, minimum, maximum);
        exit(2);
    }
    errno = 0;
    parsed_value = strtoull(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0' ||
        parsed_value < minimum || parsed_value > maximum) {
        fprintf(stderr, "%s must be an integer from %" PRIu64 " through %" PRIu64 "\n",
                name, minimum, maximum);
        exit(2);
    }
    return (uint64_t)parsed_value;
}

static bool priority_supported(
    const VkQueueFamilyGlobalPriorityPropertiesKHR *priority_properties,
    VkQueueGlobalPriorityKHR requested_priority)
{
    uint32_t priority_index;

    for (priority_index = 0; priority_index < priority_properties->priorityCount;
         ++priority_index) {
        if (priority_properties->priorities[priority_index] == requested_priority) {
            return true;
        }
    }
    return false;
}

static bool extension_supported(VkPhysicalDevice physical_device,
                                const char *requested_extension)
{
    VkExtensionProperties *extensions = NULL;
    uint32_t extension_count = 0;
    uint32_t extension_index;
    VkResult result;
    bool found = false;

    result = vkEnumerateDeviceExtensionProperties(physical_device, NULL,
                                                   &extension_count, NULL);
    if (result != VK_SUCCESS || extension_count == 0) {
        return false;
    }
    extensions = calloc(extension_count, sizeof(*extensions));
    if (extensions == NULL) {
        return false;
    }
    result = vkEnumerateDeviceExtensionProperties(physical_device, NULL,
                                                   &extension_count, extensions);
    if (result == VK_SUCCESS) {
        for (extension_index = 0; extension_index < extension_count;
             ++extension_index) {
            if (strcmp(extensions[extension_index].extensionName,
                       requested_extension) == 0) {
                found = true;
                break;
            }
        }
    }
    free(extensions);
    return found;
}

static void sleep_milliseconds(uint64_t interval_milliseconds)
{
    struct timespec remaining = {
        .tv_sec = (time_t)(interval_milliseconds / UINT64_C(1000)),
        .tv_nsec = (long)((interval_milliseconds % UINT64_C(1000)) * UINT64_C(1000000)),
    };

    while (!stop_requested && nanosleep(&remaining, &remaining) != 0) {
        if (errno != EINTR) {
            perror("nanosleep");
            exit(EXIT_FAILURE);
        }
    }
}

static void print_usage(const char *program_name)
{
    fprintf(stderr,
            "usage: %s --log PATH [--watch-pid PID] [--samples COUNT] "
            "[--interval-ms N] [--deadline-us N] [--observe]\n",
            program_name);
}

int main(int argument_count, char **argument_values)
{
    const char *log_path = NULL;
    pid_t watched_pid = 0;
    uint64_t sample_limit = 0;
    uint64_t interval_milliseconds = 16;
    uint64_t deadline_microseconds = 20000;
    bool observe_only = false;
    uint64_t deadline_breach_count = 0;
    int argument_index;
    FILE *log_file = NULL;
    VkInstance instance = VK_NULL_HANDLE;
    VkPhysicalDevice physical_device = VK_NULL_HANDLE;
    VkPhysicalDeviceProperties physical_device_properties = {0};
    VkDevice device = VK_NULL_HANDLE;
    VkQueue queue = VK_NULL_HANDLE;
    VkCommandPool command_pool = VK_NULL_HANDLE;
    VkCommandBuffer command_buffer = VK_NULL_HANDLE;
    VkFence fence = VK_NULL_HANDLE;
    uint32_t queue_family_index = UINT32_MAX;
    uint64_t sample_index = 0;
    uint64_t total_elapsed_microseconds = 0;
    uint64_t maximum_elapsed_microseconds = 0;
    bool abandon_device_cleanup = false;
    int exit_status = EXIT_SUCCESS;
    VkResult result;

    for (argument_index = 1; argument_index < argument_count; ++argument_index) {
        const char *argument = argument_values[argument_index];

        if (strcmp(argument, "--log") == 0 && argument_index + 1 < argument_count) {
            log_path = argument_values[++argument_index];
        } else if (strcmp(argument, "--watch-pid") == 0 &&
                   argument_index + 1 < argument_count) {
            watched_pid = (pid_t)parse_unsigned("watch PID",
                                                argument_values[++argument_index],
                                                1, INT32_MAX);
        } else if (strcmp(argument, "--samples") == 0 &&
                   argument_index + 1 < argument_count) {
            sample_limit = parse_unsigned("sample count",
                                          argument_values[++argument_index],
                                          1, UINT32_MAX);
        } else if (strcmp(argument, "--interval-ms") == 0 &&
                   argument_index + 1 < argument_count) {
            interval_milliseconds = parse_unsigned(
                "interval milliseconds", argument_values[++argument_index], 1, 60000);
        } else if (strcmp(argument, "--deadline-us") == 0 &&
                   argument_index + 1 < argument_count) {
            deadline_microseconds = parse_unsigned(
                "deadline microseconds", argument_values[++argument_index], 1, 60000000);
        } else if (strcmp(argument, "--observe") == 0) {
            observe_only = true;
        } else {
            print_usage(argument_values[0]);
            return 2;
        }
    }

    if (log_path == NULL || (watched_pid == 0 && sample_limit == 0)) {
        print_usage(argument_values[0]);
        return 2;
    }

    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);

    log_file = fopen(log_path, "a");
    if (log_file == NULL) {
        perror("fopen latency log");
        return EXIT_FAILURE;
    }
    if (setvbuf(log_file, NULL, _IOLBF, 0) != 0) {
        perror("setvbuf latency log");
        fclose(log_file);
        return EXIT_FAILURE;
    }

    {
        const VkApplicationInfo application_info = {
            .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pApplicationName = "qwen-apu-graphics-service-probe",
            .applicationVersion = VK_MAKE_API_VERSION(0, 1, 0, 0),
            .pEngineName = "none",
            .engineVersion = VK_MAKE_API_VERSION(0, 1, 0, 0),
            .apiVersion = VK_API_VERSION_1_1,
        };
        const VkInstanceCreateInfo instance_create_info = {
            .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pApplicationInfo = &application_info,
        };

        result = vkCreateInstance(&instance_create_info, NULL, &instance);
    }
    if (result != VK_SUCCESS) {
        fprintf(stderr, "vkCreateInstance failed: %d\n", result);
        exit_status = EXIT_FAILURE;
        goto cleanup;
    }

    {
        VkPhysicalDevice *physical_devices = NULL;
        uint32_t physical_device_count = 0;
        uint32_t physical_device_index;

        result = vkEnumeratePhysicalDevices(instance, &physical_device_count, NULL);
        if (result != VK_SUCCESS || physical_device_count == 0) {
            fprintf(stderr, "vkEnumeratePhysicalDevices failed: %d count=%u\n",
                    result, physical_device_count);
            exit_status = EXIT_FAILURE;
            goto cleanup;
        }
        physical_devices = calloc(physical_device_count, sizeof(*physical_devices));
        if (physical_devices == NULL) {
            exit_status = EXIT_FAILURE;
            goto cleanup;
        }
        result = vkEnumeratePhysicalDevices(instance, &physical_device_count,
                                             physical_devices);
        if (result == VK_SUCCESS) {
            for (physical_device_index = 0;
                 physical_device_index < physical_device_count;
                 ++physical_device_index) {
                VkPhysicalDeviceProperties candidate_properties = {0};

                vkGetPhysicalDeviceProperties(physical_devices[physical_device_index],
                                              &candidate_properties);
                if (candidate_properties.vendorID == 0x1002) {
                    physical_device = physical_devices[physical_device_index];
                    physical_device_properties = candidate_properties;
                    break;
                }
            }
        }
        free(physical_devices);
        if (result != VK_SUCCESS || physical_device == VK_NULL_HANDLE) {
            fprintf(stderr, "RADV AMD physical device is unavailable\n");
            exit_status = EXIT_FAILURE;
            goto cleanup;
        }
    }

    if (!extension_supported(physical_device,
                             VK_KHR_GLOBAL_PRIORITY_EXTENSION_NAME)) {
        fprintf(stderr, "%s is unavailable\n",
                VK_KHR_GLOBAL_PRIORITY_EXTENSION_NAME);
        exit_status = EXIT_FAILURE;
        goto cleanup;
    }

    {
        VkPhysicalDeviceGlobalPriorityQueryFeaturesKHR priority_query_features = {
            .sType =
                VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_GLOBAL_PRIORITY_QUERY_FEATURES_KHR,
        };
        VkPhysicalDeviceFeatures2 physical_device_features = {
            .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
            .pNext = &priority_query_features,
        };
        VkQueueFamilyProperties2 *queue_properties = NULL;
        VkQueueFamilyGlobalPriorityPropertiesKHR *priority_properties = NULL;
        uint32_t queue_family_count = 0;
        uint32_t candidate_family_index;

        vkGetPhysicalDeviceFeatures2(physical_device, &physical_device_features);
        if (priority_query_features.globalPriorityQuery != VK_TRUE) {
            fprintf(stderr, "globalPriorityQuery is unavailable\n");
            exit_status = EXIT_FAILURE;
            goto cleanup;
        }

        vkGetPhysicalDeviceQueueFamilyProperties2(physical_device,
                                                   &queue_family_count, NULL);
        queue_properties = calloc(queue_family_count, sizeof(*queue_properties));
        priority_properties = calloc(queue_family_count,
                                     sizeof(*priority_properties));
        if (queue_properties == NULL || priority_properties == NULL) {
            free(priority_properties);
            free(queue_properties);
            exit_status = EXIT_FAILURE;
            goto cleanup;
        }
        for (candidate_family_index = 0;
             candidate_family_index < queue_family_count;
             ++candidate_family_index) {
            queue_properties[candidate_family_index].sType =
                VK_STRUCTURE_TYPE_QUEUE_FAMILY_PROPERTIES_2;
            queue_properties[candidate_family_index].pNext =
                &priority_properties[candidate_family_index];
            priority_properties[candidate_family_index].sType =
                VK_STRUCTURE_TYPE_QUEUE_FAMILY_GLOBAL_PRIORITY_PROPERTIES_KHR;
        }
        vkGetPhysicalDeviceQueueFamilyProperties2(physical_device,
                                                   &queue_family_count,
                                                   queue_properties);
        for (candidate_family_index = 0;
             candidate_family_index < queue_family_count;
             ++candidate_family_index) {
            const VkQueueFlags queue_flags =
                queue_properties[candidate_family_index]
                    .queueFamilyProperties.queueFlags;

            if ((queue_flags & VK_QUEUE_GRAPHICS_BIT) != 0 &&
                priority_supported(&priority_properties[candidate_family_index],
                                   VK_QUEUE_GLOBAL_PRIORITY_MEDIUM_KHR)) {
                queue_family_index = candidate_family_index;
                break;
            }
        }
        free(priority_properties);
        free(queue_properties);
    }
    if (queue_family_index == UINT32_MAX) {
        fprintf(stderr,
                "no graphics queue family supports MEDIUM global priority\n");
        exit_status = EXIT_FAILURE;
        goto cleanup;
    }

    {
        const float queue_priority = 1.0f;
        const VkDeviceQueueGlobalPriorityCreateInfoKHR global_priority_info = {
            .sType =
                VK_STRUCTURE_TYPE_DEVICE_QUEUE_GLOBAL_PRIORITY_CREATE_INFO_KHR,
            .globalPriority = VK_QUEUE_GLOBAL_PRIORITY_MEDIUM_KHR,
        };
        const VkDeviceQueueCreateInfo queue_create_info = {
            .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .pNext = &global_priority_info,
            .queueFamilyIndex = queue_family_index,
            .queueCount = 1,
            .pQueuePriorities = &queue_priority,
        };
        VkPhysicalDeviceGlobalPriorityQueryFeaturesKHR priority_query_features = {
            .sType =
                VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_GLOBAL_PRIORITY_QUERY_FEATURES_KHR,
            .globalPriorityQuery = VK_TRUE,
        };
        const char *device_extensions[] = {
            VK_KHR_GLOBAL_PRIORITY_EXTENSION_NAME,
        };
        const VkDeviceCreateInfo device_create_info = {
            .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = &priority_query_features,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &queue_create_info,
            .enabledExtensionCount = 1,
            .ppEnabledExtensionNames = device_extensions,
        };

        result = vkCreateDevice(physical_device, &device_create_info, NULL, &device);
    }
    if (result != VK_SUCCESS) {
        fprintf(stderr, "MEDIUM-priority vkCreateDevice failed: %d\n", result);
        exit_status = EXIT_FAILURE;
        goto cleanup;
    }
    vkGetDeviceQueue(device, queue_family_index, 0, &queue);
    if (queue == VK_NULL_HANDLE) {
        fprintf(stderr, "vkGetDeviceQueue returned a null queue\n");
        exit_status = EXIT_FAILURE;
        goto cleanup;
    }

    {
        const VkCommandPoolCreateInfo command_pool_create_info = {
            .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .flags = VK_COMMAND_POOL_CREATE_TRANSIENT_BIT,
            .queueFamilyIndex = queue_family_index,
        };
        const VkCommandBufferAllocateInfo command_buffer_allocate_info = {
            .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = VK_NULL_HANDLE,
            .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        VkCommandBufferAllocateInfo allocation_info = command_buffer_allocate_info;
        const VkFenceCreateInfo fence_create_info = {
            .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        };
        const VkCommandBufferBeginInfo command_buffer_begin_info = {
            .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = VK_COMMAND_BUFFER_USAGE_SIMULTANEOUS_USE_BIT,
        };
        const VkMemoryBarrier memory_barrier = {
            .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
            .srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT,
            .dstAccessMask = VK_ACCESS_MEMORY_READ_BIT,
        };

        result = vkCreateCommandPool(device, &command_pool_create_info, NULL,
                                     &command_pool);
        if (result != VK_SUCCESS) {
            fprintf(stderr, "vkCreateCommandPool failed: %d\n", result);
            exit_status = EXIT_FAILURE;
            goto cleanup;
        }
        allocation_info.commandPool = command_pool;
        result = vkAllocateCommandBuffers(device, &allocation_info,
                                          &command_buffer);
        if (result != VK_SUCCESS) {
            fprintf(stderr, "vkAllocateCommandBuffers failed: %d\n", result);
            exit_status = EXIT_FAILURE;
            goto cleanup;
        }
        result = vkBeginCommandBuffer(command_buffer, &command_buffer_begin_info);
        if (result != VK_SUCCESS) {
            fprintf(stderr, "vkBeginCommandBuffer failed: %d\n", result);
            exit_status = EXIT_FAILURE;
            goto cleanup;
        }
        vkCmdPipelineBarrier(command_buffer, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
                             VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 1,
                             &memory_barrier, 0, NULL, 0, NULL);
        result = vkEndCommandBuffer(command_buffer);
        if (result != VK_SUCCESS) {
            fprintf(stderr, "vkEndCommandBuffer failed: %d\n", result);
            exit_status = EXIT_FAILURE;
            goto cleanup;
        }
        result = vkCreateFence(device, &fence_create_info, NULL, &fence);
        if (result != VK_SUCCESS) {
            fprintf(stderr, "vkCreateFence failed: %d\n", result);
            exit_status = EXIT_FAILURE;
            goto cleanup;
        }
    }

    fprintf(log_file,
            "probe_start realtime_ns=%" PRIu64 " device=%s vendor=0x%04x "
            "device_id=0x%04x queue_family=%u global_priority=MEDIUM "
            "deadline_us=%" PRIu64 " interval_ms=%" PRIu64
            " watched_pid=%ld mode=%s\n",
            realtime_nanoseconds(), physical_device_properties.deviceName,
            physical_device_properties.vendorID,
            physical_device_properties.deviceID, queue_family_index,
            deadline_microseconds, interval_milliseconds, (long)watched_pid,
            observe_only ? "observe" : "terminate");

    while (!stop_requested &&
           (sample_limit == 0 || sample_index < sample_limit)) {
        const VkSubmitInfo submit_info = {
            .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .commandBufferCount = 1,
            .pCommandBuffers = &command_buffer,
        };
        uint64_t start_nanoseconds;
        uint64_t elapsed_microseconds;

        if (watched_pid != 0 && kill(watched_pid, 0) != 0) {
            if (errno == ESRCH) {
                break;
            }
            perror("kill watched PID probe");
            exit_status = EXIT_FAILURE;
            break;
        }

        result = vkResetFences(device, 1, &fence);
        if (result != VK_SUCCESS) {
            fprintf(stderr, "vkResetFences failed: %d\n", result);
            exit_status = EXIT_FAILURE;
            break;
        }
        start_nanoseconds = monotonic_nanoseconds();
        result = vkQueueSubmit(queue, 1, &submit_info, fence);
        if (result == VK_SUCCESS) {
            result = vkWaitForFences(device, 1, &fence, VK_TRUE,
                                     deadline_microseconds * UINT64_C(1000));
        }
        elapsed_microseconds =
            (monotonic_nanoseconds() - start_nanoseconds + UINT64_C(999)) /
            UINT64_C(1000);
        ++sample_index;
        total_elapsed_microseconds += elapsed_microseconds;
        if (elapsed_microseconds > maximum_elapsed_microseconds) {
            maximum_elapsed_microseconds = elapsed_microseconds;
        }
        fprintf(log_file,
                "sample realtime_ns=%" PRIu64 " index=%" PRIu64
                " elapsed_us=%" PRIu64 " result=%d\n",
                realtime_nanoseconds(), sample_index, elapsed_microseconds,
                result);

        if (result != VK_SUCCESS ||
            elapsed_microseconds > deadline_microseconds) {
            /* The deadline is also the vkWaitForFences timeout, so a frame
             * that runs long returns VK_TIMEOUT rather than VK_SUCCESS with a
             * large elapsed time. VK_TIMEOUT and an over-deadline success are
             * therefore the two forms of a late frame; every other result is a
             * device-level fault that ends the run whatever the mode. */
            const bool late_frame =
                result == VK_TIMEOUT ||
                (result == VK_SUCCESS &&
                 elapsed_microseconds > deadline_microseconds);
            const bool tolerated = observe_only && late_frame;

            if (tolerated) {
                ++deadline_breach_count;
            }
            fprintf(log_file,
                    "probe_breach realtime_ns=%" PRIu64 " index=%" PRIu64
                    " elapsed_us=%" PRIu64 " deadline_us=%" PRIu64
                    " result=%d action=%s\n",
                    realtime_nanoseconds(), sample_index,
                    elapsed_microseconds, deadline_microseconds, result,
                    tolerated ? "observe" : "SIGTERM");
            if (!tolerated) {
                if (watched_pid != 0) {
                    (void)kill(watched_pid, SIGTERM);
                }
                if (result == VK_TIMEOUT) {
                    abandon_device_cleanup = true;
                }
                exit_status = 3;
                break;
            }
            if (result == VK_TIMEOUT) {
                /* The submission is still in flight, so the next iteration
                 * cannot reset this fence until it signals. Drain it under a
                 * bound far above any scheduling delay; exceeding that bound
                 * is a stalled queue rather than a late frame. */
                result = vkWaitForFences(device, 1, &fence, VK_TRUE,
                                         UINT64_C(5000000000));
                if (result != VK_SUCCESS) {
                    fprintf(log_file,
                            "probe_stall realtime_ns=%" PRIu64 " index=%"
                            PRIu64 " result=%d action=SIGTERM\n",
                            realtime_nanoseconds(), sample_index, result);
                    if (watched_pid != 0) {
                        (void)kill(watched_pid, SIGTERM);
                    }
                    abandon_device_cleanup = true;
                    exit_status = 3;
                    break;
                }
            }
        }

        if (sample_limit == 0 || sample_index < sample_limit) {
            sleep_milliseconds(interval_milliseconds);
        }
    }

    fprintf(log_file,
            "probe_stop realtime_ns=%" PRIu64 " samples=%" PRIu64
            " mean_elapsed_us=%" PRIu64 " maximum_elapsed_us=%" PRIu64
            " deadline_breaches=%" PRIu64 " status=%d\n",
            realtime_nanoseconds(), sample_index,
            sample_index == 0 ? 0 : total_elapsed_microseconds / sample_index,
            maximum_elapsed_microseconds, deadline_breach_count, exit_status);

cleanup:
    if (!abandon_device_cleanup && device != VK_NULL_HANDLE) {
        (void)vkDeviceWaitIdle(device);
        if (fence != VK_NULL_HANDLE) {
            vkDestroyFence(device, fence, NULL);
        }
        if (command_pool != VK_NULL_HANDLE) {
            vkDestroyCommandPool(device, command_pool, NULL);
        }
        vkDestroyDevice(device, NULL);
    }
    if (!abandon_device_cleanup && instance != VK_NULL_HANDLE) {
        vkDestroyInstance(instance, NULL);
    }
    if (log_file != NULL) {
        fclose(log_file);
    }
    return exit_status;
}
