#!/bin/sh
set -eu

if [ "$#" -gt 1 ]; then
    printf 'usage: %s [OUTPUT_PATH]\n' "$0" >&2
    exit 2
fi

ionice -c 3 -p $$

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
output_path=${1:-"$script_directory/../build/vulkan-graphics-service-probe"}

if ! command -v cc >/dev/null 2>&1; then
    printf 'C compiler is unavailable\n' >&2
    exit 1
fi
if [ ! -r /usr/include/vulkan/vulkan.h ]; then
    printf 'Vulkan development headers are unavailable\n' >&2
    exit 1
fi

mkdir -p "$(dirname -- "$output_path")"
cc -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror \
    "$script_directory/vulkan-graphics-service-probe.c" \
    -lvulkan -o "$output_path"
printf 'graphics_service_probe=%s sha256=%s\n' "$output_path" \
    "$(sha256sum "$output_path" | awk '{ print $1 }')"
