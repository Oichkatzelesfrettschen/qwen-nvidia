#!/bin/sh
set -eu

if [ "$#" -gt 2 ]; then
    printf 'usage: %s [BINARY_DIRECTORY] [MODEL_PATH]\n' "$0" >&2
    exit 2
fi

renice -n 19 -p $$ >/dev/null
taskset -pc 0 $$ >/dev/null
ionice -c 3 -p $$

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repository_directory=$(CDPATH='' cd -- "$script_directory/.." && pwd)
binary_directory=${1:-"$repository_directory/artifacts/bin"}
model_path=${2:-"${HOME:?}/models/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf"}

verify_artifact() {
    artifact_path=$1
    expected_bytes=$2
    expected_sha256=$3
    if [ ! -f "$artifact_path" ]; then
        printf 'artifact is missing: %s\n' "$artifact_path" >&2
        exit 1
    fi
    actual_bytes=$(stat -c %s "$artifact_path")
    actual_sha256=$(sha256sum "$artifact_path" | cut -d ' ' -f 1)
    if [ "$actual_bytes" -ne "$expected_bytes" ] || \
       [ "$actual_sha256" != "$expected_sha256" ]; then
        printf 'artifact mismatch: %s expected %s/%s found %s/%s\n' \
            "$artifact_path" "$expected_bytes" "$expected_sha256" \
            "$actual_bytes" "$actual_sha256" >&2
        exit 1
    fi
    printf 'artifact=accepted path=%s bytes=%s sha256=%s\n' \
        "$artifact_path" "$actual_bytes" "$actual_sha256"
}

# The raven2-vulkan-production closure: llama.cpp f280b269 under the five-patch
# production series, promoted to build-appliance-current. The prior five-file closure
# (llama-server 3d5b1581...) is retained in ARTIFACTS.md as rollback identity.
verify_artifact "$binary_directory/llama-server" 57696808 \
    4117a9c4d58e530c3c5ef6934596ae6d257ca61ef80c5f0f8a5ee71d1d63ca79
verify_artifact "$binary_directory/llama-cli" 57865008 \
    59b8154a83cb3da1555e07330a7ca7bf5cefd3de2603791302f2c29388e9c21c
verify_artifact "$binary_directory/llama-mtmd-cli" 55806024 \
    dd094cfbddf4bc971c003a3612b8a83a34c6f39e05b6cac871ed78cdd98e54af
verify_artifact "$binary_directory/llama-bench" 54160040 \
    557d6690d338bc79b81ea690762a0d8987c0ca66f3c122a5fcc0f2a8420df092
verify_artifact "$model_path" 2740937888 \
    00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4
