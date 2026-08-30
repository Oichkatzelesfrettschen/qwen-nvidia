#!/bin/sh
set -eu

if [ "$#" -gt 1 ]; then
    printf 'usage: %s [LLAMA_SOURCE]\n' "$0" >&2
    exit 2
fi

source_directory=${1:-"${HOME:?}/src/llama.cpp-qwen-nvidia"}
header=$source_directory/ggml/src/ggml-vulkan/ggml-vulkan-pacing.h
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

if [ ! -r "$header" ]; then
    printf 'Vulkan pacing header is missing: %s\n' "$header" >&2
    exit 1
fi

test_source=$temporary_directory/test-vulkan-pacing.cpp
printf '%s\n' \
    '#include "ggml-vulkan-pacing.h"' \
    '#include <cstdint>' \
    '#include <stdexcept>' \
    '' \
    'static void require(bool condition) {' \
    '    if (!condition) {' \
    '        throw std::runtime_error("Vulkan pacing test failed");' \
    '    }' \
    '}' \
    '' \
    'static void require_parse_failure(const char * value) {' \
    '    try {' \
    '        (void) ggml_vk_parse_duty_cycle_percent(value);' \
    '    } catch (const std::runtime_error &) {' \
    '        return;' \
    '    }' \
    '    throw std::runtime_error("invalid percentage was accepted");' \
    '}' \
    '' \
    'int main() {' \
    '    require(ggml_vk_parse_duty_cycle_percent(nullptr) == 100);' \
    '    require(ggml_vk_parse_duty_cycle_percent("1") == 1);' \
    '    require(ggml_vk_parse_duty_cycle_percent("60") == 60);' \
    '    require(ggml_vk_parse_duty_cycle_percent("100") == 100);' \
    '    require_parse_failure("");' \
    '    require_parse_failure("0");' \
    '    require_parse_failure("101");' \
    '    require_parse_failure(" 60");' \
    '    require_parse_failure("60x");' \
    '    require(ggml_vk_pacing_idle_us(0, 60) == 0);' \
    '    require(ggml_vk_pacing_idle_us(1000, 100) == 0);' \
    '    require(ggml_vk_pacing_idle_us(1000, 75) == 334);' \
    '    require(ggml_vk_pacing_idle_us(1000, 60) == 667);' \
    '    require(ggml_vk_pacing_idle_us(1, 1) == 99);' \
    '    return 0;' \
    '}' >"$test_source"

${CXX:-c++} -std=c++11 -Wall -Wextra -Werror -pedantic \
    -I"$(dirname -- "$header")" "$test_source" \
    -o "$temporary_directory/test-vulkan-pacing"
"$temporary_directory/test-vulkan-pacing"

printf 'vulkan_pacing_math=accepted\n'
