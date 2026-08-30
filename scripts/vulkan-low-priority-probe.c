#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <vulkan/vulkan.h>

#ifndef VK_KHR_global_priority
#error "Vulkan headers do not provide VK_KHR_global_priority"
#endif

static const char * result_name(VkResult result) {
    switch (result) {
        case VK_SUCCESS:
            return "VK_SUCCESS";
        case VK_ERROR_EXTENSION_NOT_PRESENT:
            return "VK_ERROR_EXTENSION_NOT_PRESENT";
        case VK_ERROR_FEATURE_NOT_PRESENT:
            return "VK_ERROR_FEATURE_NOT_PRESENT";
        case VK_ERROR_INITIALIZATION_FAILED:
            return "VK_ERROR_INITIALIZATION_FAILED";
        case VK_ERROR_NOT_PERMITTED_KHR:
            return "VK_ERROR_NOT_PERMITTED_KHR";
        default:
            return "other VkResult";
    }
}

static bool supports_low_priority(const VkQueueFamilyGlobalPriorityPropertiesKHR * priority_properties) {
    for (uint32_t priority_index = 0; priority_index < priority_properties->priorityCount; ++priority_index) {
        if (priority_properties->priorities[priority_index] == VK_QUEUE_GLOBAL_PRIORITY_LOW_KHR) {
            return true;
        }
    }

    return false;
}

int main(void) {
    const VkApplicationInfo application_info = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "vulkan-low-priority-probe",
        .applicationVersion = VK_MAKE_API_VERSION(0, 1, 0, 0),
        .pEngineName = "none",
        .engineVersion = VK_MAKE_API_VERSION(0, 1, 0, 0),
        .apiVersion = VK_API_VERSION_1_1,
    };
    const VkInstanceCreateInfo instance_create_info = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &application_info,
    };
    VkInstance instance = VK_NULL_HANDLE;
    VkResult result = vkCreateInstance(&instance_create_info, NULL, &instance);
    if (result != VK_SUCCESS) {
        fprintf(stderr, "vkCreateInstance failed: %s (%d)\n", result_name(result), result);
        return EXIT_FAILURE;
    }

    uint32_t physical_device_count = 0;
    result = vkEnumeratePhysicalDevices(instance, &physical_device_count, NULL);
    if (result != VK_SUCCESS || physical_device_count == 0) {
        fprintf(stderr, "vkEnumeratePhysicalDevices failed: %s (%d), count=%u\n",
                result_name(result), result, physical_device_count);
        vkDestroyInstance(instance, NULL);
        return EXIT_FAILURE;
    }

    VkPhysicalDevice * physical_devices = calloc(physical_device_count, sizeof(*physical_devices));
    if (physical_devices == NULL) {
        vkDestroyInstance(instance, NULL);
        return EXIT_FAILURE;
    }
    result = vkEnumeratePhysicalDevices(instance, &physical_device_count, physical_devices);
    if (result != VK_SUCCESS) {
        fprintf(stderr, "vkEnumeratePhysicalDevices list failed: %s (%d)\n", result_name(result), result);
        free(physical_devices);
        vkDestroyInstance(instance, NULL);
        return EXIT_FAILURE;
    }

    VkPhysicalDevice physical_device = VK_NULL_HANDLE;
    VkPhysicalDeviceProperties device_properties = {0};
    for (uint32_t device_index = 0; device_index < physical_device_count; ++device_index) {
        VkPhysicalDeviceProperties candidate_properties = {0};
        vkGetPhysicalDeviceProperties(physical_devices[device_index], &candidate_properties);
        if (candidate_properties.vendorID == 0x1002) {
            physical_device = physical_devices[device_index];
            device_properties = candidate_properties;
            break;
        }
    }
    free(physical_devices);

    if (physical_device == VK_NULL_HANDLE) {
        fprintf(stderr, "no AMD Vulkan physical device found\n");
        vkDestroyInstance(instance, NULL);
        return EXIT_FAILURE;
    }

    uint32_t extension_count = 0;
    result = vkEnumerateDeviceExtensionProperties(physical_device, NULL, &extension_count, NULL);
    if (result != VK_SUCCESS) {
        fprintf(stderr, "device extension count failed: %s (%d)\n", result_name(result), result);
        vkDestroyInstance(instance, NULL);
        return EXIT_FAILURE;
    }

    VkExtensionProperties * extensions = calloc(extension_count, sizeof(*extensions));
    if (extensions == NULL) {
        vkDestroyInstance(instance, NULL);
        return EXIT_FAILURE;
    }
    result = vkEnumerateDeviceExtensionProperties(physical_device, NULL, &extension_count, extensions);
    if (result != VK_SUCCESS) {
        fprintf(stderr, "device extension list failed: %s (%d)\n", result_name(result), result);
        free(extensions);
        vkDestroyInstance(instance, NULL);
        return EXIT_FAILURE;
    }

    bool has_global_priority_extension = false;
    for (uint32_t extension_index = 0; extension_index < extension_count; ++extension_index) {
        if (strcmp(extensions[extension_index].extensionName, VK_KHR_GLOBAL_PRIORITY_EXTENSION_NAME) == 0) {
            has_global_priority_extension = true;
            break;
        }
    }
    free(extensions);

    if (!has_global_priority_extension) {
        fprintf(stderr, "%s is not advertised\n", VK_KHR_GLOBAL_PRIORITY_EXTENSION_NAME);
        vkDestroyInstance(instance, NULL);
        return EXIT_FAILURE;
    }

    VkPhysicalDeviceGlobalPriorityQueryFeaturesKHR global_priority_features = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_GLOBAL_PRIORITY_QUERY_FEATURES_KHR,
    };
    VkPhysicalDeviceFeatures2 physical_device_features = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
        .pNext = &global_priority_features,
    };
    vkGetPhysicalDeviceFeatures2(physical_device, &physical_device_features);
    if (global_priority_features.globalPriorityQuery != VK_TRUE) {
        fprintf(stderr, "globalPriorityQuery is false\n");
        vkDestroyInstance(instance, NULL);
        return EXIT_FAILURE;
    }

    uint32_t queue_family_count = 0;
    vkGetPhysicalDeviceQueueFamilyProperties2(physical_device, &queue_family_count, NULL);
    VkQueueFamilyProperties2 * queue_properties = calloc(queue_family_count, sizeof(*queue_properties));
    VkQueueFamilyGlobalPriorityPropertiesKHR * priority_properties =
        calloc(queue_family_count, sizeof(*priority_properties));
    if (queue_properties == NULL || priority_properties == NULL) {
        free(priority_properties);
        free(queue_properties);
        vkDestroyInstance(instance, NULL);
        return EXIT_FAILURE;
    }

    for (uint32_t family_index = 0; family_index < queue_family_count; ++family_index) {
        queue_properties[family_index].sType = VK_STRUCTURE_TYPE_QUEUE_FAMILY_PROPERTIES_2;
        queue_properties[family_index].pNext = &priority_properties[family_index];
        priority_properties[family_index].sType =
            VK_STRUCTURE_TYPE_QUEUE_FAMILY_GLOBAL_PRIORITY_PROPERTIES_KHR;
    }
    vkGetPhysicalDeviceQueueFamilyProperties2(physical_device, &queue_family_count, queue_properties);

    uint32_t selected_family = UINT32_MAX;
    for (uint32_t family_index = 0; family_index < queue_family_count; ++family_index) {
        const VkQueueFlags flags = queue_properties[family_index].queueFamilyProperties.queueFlags;
        if ((flags & VK_QUEUE_COMPUTE_BIT) != 0 && (flags & VK_QUEUE_GRAPHICS_BIT) == 0 &&
            supports_low_priority(&priority_properties[family_index])) {
            selected_family = family_index;
            break;
        }
    }
    if (selected_family == UINT32_MAX) {
        for (uint32_t family_index = 0; family_index < queue_family_count; ++family_index) {
            const VkQueueFlags flags = queue_properties[family_index].queueFamilyProperties.queueFlags;
            if ((flags & VK_QUEUE_COMPUTE_BIT) != 0 && supports_low_priority(&priority_properties[family_index])) {
                selected_family = family_index;
                break;
            }
        }
    }

    free(priority_properties);
    free(queue_properties);

    if (selected_family == UINT32_MAX) {
        fprintf(stderr, "no compute queue family reports LOW global priority\n");
        vkDestroyInstance(instance, NULL);
        return EXIT_FAILURE;
    }

    const float queue_priority = 1.0f;
    const VkDeviceQueueGlobalPriorityCreateInfoKHR global_priority_create_info = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_GLOBAL_PRIORITY_CREATE_INFO_KHR,
        .globalPriority = VK_QUEUE_GLOBAL_PRIORITY_LOW_KHR,
    };
    const VkDeviceQueueCreateInfo queue_create_info = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .pNext = &global_priority_create_info,
        .queueFamilyIndex = selected_family,
        .queueCount = 1,
        .pQueuePriorities = &queue_priority,
    };
    const char * enabled_extensions[] = {VK_KHR_GLOBAL_PRIORITY_EXTENSION_NAME};
    global_priority_features.globalPriorityQuery = VK_TRUE;
    const VkDeviceCreateInfo device_create_info = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = &global_priority_features,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue_create_info,
        .enabledExtensionCount = 1,
        .ppEnabledExtensionNames = enabled_extensions,
    };

    VkDevice device = VK_NULL_HANDLE;
    result = vkCreateDevice(physical_device, &device_create_info, NULL, &device);
    if (result != VK_SUCCESS) {
        fprintf(stderr, "LOW-priority vkCreateDevice failed: %s (%d)\n", result_name(result), result);
        vkDestroyInstance(instance, NULL);
        return EXIT_FAILURE;
    }

    VkQueue queue = VK_NULL_HANDLE;
    vkGetDeviceQueue(device, selected_family, 0, &queue);
    if (queue == VK_NULL_HANDLE) {
        fprintf(stderr, "vkGetDeviceQueue returned a null queue\n");
        vkDestroyDevice(device, NULL);
        vkDestroyInstance(instance, NULL);
        return EXIT_FAILURE;
    }

    result = vkDeviceWaitIdle(device);
    if (result != VK_SUCCESS) {
        fprintf(stderr, "vkDeviceWaitIdle failed: %s (%d)\n", result_name(result), result);
        vkDestroyDevice(device, NULL);
        vkDestroyInstance(instance, NULL);
        return EXIT_FAILURE;
    }

    printf("device=%s vendor=0x%04x device=0x%04x queue_family=%u global_priority=LOW result=VK_SUCCESS\n",
           device_properties.deviceName, device_properties.vendorID, device_properties.deviceID, selected_family);

    vkDestroyDevice(device, NULL);
    vkDestroyInstance(instance, NULL);
    return EXIT_SUCCESS;
}
