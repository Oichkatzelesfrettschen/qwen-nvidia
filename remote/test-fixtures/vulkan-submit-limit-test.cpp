#include <cstdint>
#include <exception>
#include <iostream>
#include <limits>

#include "ggml-vulkan-submit-limit.h"

static bool rejects(const char * value)
{
    try {
        (void)ggml_vk_parse_max_nodes_per_submit(value, 100);
        return false;
    } catch (const std::exception &) {
        return true;
    }
}

int main()
{
    if (ggml_vk_parse_max_nodes_per_submit(nullptr, 100) != 100 ||
        ggml_vk_parse_max_nodes_per_submit("1", 100) != 1 ||
        ggml_vk_parse_max_nodes_per_submit("32", 100) != 32 ||
        ggml_vk_parse_max_nodes_per_submit("4294967295", 100) !=
            std::numeric_limits<uint32_t>::max() ||
        !rejects("") || !rejects("0") || !rejects("-1") ||
        !rejects("1x") || !rejects("4294967296")) {
        std::cerr << "Vulkan submit-limit parser test failed\n";
        return 1;
    }
    std::cout << "vulkan_submit_limit_parser=accepted\n";
    return 0;
}
