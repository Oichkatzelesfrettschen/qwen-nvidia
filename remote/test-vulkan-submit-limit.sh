#!/bin/sh
set -eu

if [ "$#" -gt 1 ]; then
    printf 'usage: %s [LLAMA_SOURCE]\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
source_directory=${1:-"${HOME:?}/src/llama.cpp-qwen-nvidia"}
header=$source_directory/ggml/src/ggml-vulkan/ggml-vulkan-submit-limit.h
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

if [ ! -r "$header" ]; then
    printf 'Vulkan submit-limit header is unavailable: %s\n' "$header" >&2
    exit 1
fi

test_source=$temporary_directory/test-vulkan-submit-limit.cpp
test_binary=$temporary_directory/test-vulkan-submit-limit
test_fixture=$script_directory/test-fixtures/vulkan-submit-limit-test.cpp

if [ ! -r "$test_fixture" ]; then
    printf 'Vulkan submit-limit test fixture is unavailable: %s\n' \
        "$test_fixture" >&2
    exit 1
fi
cp "$test_fixture" "$test_source"

c++ -std=c++17 -Wall -Wextra -Wpedantic -Werror \
    -I"$(dirname -- "$header")" "$test_source" -o "$test_binary"
"$test_binary"
