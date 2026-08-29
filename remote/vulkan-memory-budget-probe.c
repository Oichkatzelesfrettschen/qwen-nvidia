#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <vulkan/vulkan.h>

int main(void) {
    const VkApplicationInfo application_info = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "vulkan-memory-budget-probe",
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
        fprintf(stderr, "vkCreateInstance failed: %d\n", result);
        return EXIT_FAILURE;
    }

    uint32_t physical_device_count = 0;
    result = vkEnumeratePhysicalDevices(instance, &physical_device_count, NULL);
    if (result != VK_SUCCESS || physical_device_count == 0) {
        fprintf(stderr, "no Vulkan physical devices: result=%d count=%u\n", result, physical_device_count);
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
        fprintf(stderr, "physical-device enumeration failed: %d\n", result);
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
        fprintf(stderr, "device extension count failed: %d\n", result);
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
        fprintf(stderr, "device extension enumeration failed: %d\n", result);
        free(extensions);
        vkDestroyInstance(instance, NULL);
        return EXIT_FAILURE;
    }

    bool has_memory_budget = false;
    for (uint32_t extension_index = 0; extension_index < extension_count; ++extension_index) {
        if (strcmp(extensions[extension_index].extensionName, VK_EXT_MEMORY_BUDGET_EXTENSION_NAME) == 0) {
            has_memory_budget = true;
            break;
        }
    }
    free(extensions);

    if (!has_memory_budget) {
        fprintf(stderr, "%s is not advertised\n", VK_EXT_MEMORY_BUDGET_EXTENSION_NAME);
        vkDestroyInstance(instance, NULL);
        return EXIT_FAILURE;
    }

    VkPhysicalDeviceMemoryBudgetPropertiesEXT budget_properties = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MEMORY_BUDGET_PROPERTIES_EXT,
    };
    VkPhysicalDeviceMemoryProperties2 memory_properties = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MEMORY_PROPERTIES_2,
        .pNext = &budget_properties,
    };
    vkGetPhysicalDeviceMemoryProperties2(physical_device, &memory_properties);

    uint64_t aggregate_budget = 0;
    uint64_t aggregate_usage = 0;
    uint64_t aggregate_available = 0;
    printf("device_name=%s\n", device_properties.deviceName);
    printf("device_vendor=0x%04x\n", device_properties.vendorID);
    printf("device_id=0x%04x\n", device_properties.deviceID);

    for (uint32_t heap_index = 0; heap_index < memory_properties.memoryProperties.memoryHeapCount; ++heap_index) {
        const uint64_t heap_size = memory_properties.memoryProperties.memoryHeaps[heap_index].size;
        const uint64_t heap_budget = budget_properties.heapBudget[heap_index];
        const uint64_t heap_usage = budget_properties.heapUsage[heap_index];
        const uint64_t heap_available = heap_budget > heap_usage ? heap_budget - heap_usage : 0;
        const uint32_t heap_flags = memory_properties.memoryProperties.memoryHeaps[heap_index].flags;

        printf("heap_%u_size_bytes=%llu\n", heap_index, (unsigned long long) heap_size);
        printf("heap_%u_budget_bytes=%llu\n", heap_index, (unsigned long long) heap_budget);
        printf("heap_%u_usage_bytes=%llu\n", heap_index, (unsigned long long) heap_usage);
        printf("heap_%u_available_bytes=%llu\n", heap_index, (unsigned long long) heap_available);
        printf("heap_%u_flags=0x%x\n", heap_index, heap_flags);

        aggregate_budget += heap_budget;
        aggregate_usage += heap_usage;
        aggregate_available += heap_available;
    }

    printf("aggregate_budget_bytes=%llu\n", (unsigned long long) aggregate_budget);
    printf("aggregate_usage_bytes=%llu\n", (unsigned long long) aggregate_usage);
    printf("aggregate_available_bytes=%llu\n", (unsigned long long) aggregate_available);

    vkDestroyInstance(instance, NULL);
    return EXIT_SUCCESS;
}
