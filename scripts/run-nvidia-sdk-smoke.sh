#!/bin/sh
set -eu

# Compile scripts/nvidia-sdk-smoke/decode-resize.cpp against the prefixes
# scripts/nvidia-sdk-artifacts.tsv names, draw the JPEG fixture, and run one
# decode-then-resize on the device under the GPU ownership lock. The binary
# prints whether the decoded plane and the resized tensor both sit in device
# memory and how many transfers it made, and the record keeps that line beside
# the ledger verification, the compiler line, and the ownership record.

usage() {
    printf 'usage: %s OUTPUT_DIRECTORY\n' "$0" >&2
    exit 2
}
[ "$#" -eq 1 ] || usage
output_directory=$1
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
host_cxx=${QWEN_HOST_COMPILER:-/usr/bin/g++-15}
cuda_prefix=${QWEN_CUDA_PREFIX:-/opt/cuda}

if [ -e "$output_directory" ] && [ -n "$(ls -A "$output_directory" 2>/dev/null)" ]; then
    printf 'refused: output directory exists and is not empty: %s\n' "$output_directory" >&2
    exit 2
fi
mkdir -p "$output_directory"
scrub_home() { sed "s|${HOME:?}|\$HOME|g"; }

"$script_directory/verify-nvidia-sdk.sh" | tee "$output_directory/sdk-verify.txt"
prefix_of() {
    awk -F '\t' -v id="$1" '!/^#/ && $1 == id { print $10 }' "$script_directory/nvidia-sdk-artifacts.tsv"
}
cvcuda_prefix=$(prefix_of cvcuda-lib)
nvimgcodec_prefix=$(prefix_of nvimgcodec)

"$host_cxx" -std=c++17 -O2 -o "$output_directory/decode-resize" \
    "$script_directory/nvidia-sdk-smoke/decode-resize.cpp" \
    -I"$cuda_prefix/include" -I"$nvimgcodec_prefix/include" -I"$cvcuda_prefix/include" \
    -L"$cuda_prefix/lib64" -L"$nvimgcodec_prefix/lib" -L"$cvcuda_prefix/lib" \
    -lnvimgcodec -lcvcuda -lnvcv_types -lcudart 2>&1 | scrub_home | tee "$output_directory/compile.txt"
[ -x "$output_directory/decode-resize" ] || { printf 'the smoke did not compile\n' >&2; exit 1; }
printf 'compiler\t%s\n' "$("$host_cxx" -dumpfullversion)" >"$output_directory/summary.tsv"
python3 "$script_directory/nvidia-sdk-smoke/make-fixture.py" "$output_directory/fixture.jpg"
printf 'fixture_sha256\t%s\n' "$(sha256sum "$output_directory/fixture.jpg" | cut -d ' ' -f 1)" >>"$output_directory/summary.tsv"

. "$script_directory/gpu-workload-ownership.sh"
gpu_ownership_require >"$output_directory/ownership.txt.raw"
sed -E -e 's|^(cuda_client) pid=[0-9]+ name=([^ ]+).* used=([0-9]+ MiB) .* verdict=(.*)$|\1 name=\2 used=\3 verdict=\4|' \
    -e 's|name=[^ ]*/([^ /]+)|name=\1|' -e 's|^(named_llama_server_pids)=.*$|\1=redacted|' \
    <"$output_directory/ownership.txt.raw" | scrub_home >"$output_directory/ownership.txt"
rm -f "$output_directory/ownership.txt.raw"
"$script_directory/device-environment-identity.sh" "$output_directory/device-environment.tsv"

status=0
QWEN_NVIMGCODEC_EXTENSIONS="$nvimgcodec_prefix/extensions" \
    "$output_directory/decode-resize" "$output_directory/fixture.jpg" 224 224 \
    >"$output_directory/smoke.txt" 2>&1 9>&- || status=$?
rm -f "$output_directory/decode-resize"
cat "$output_directory/smoke.txt"
printf 'smoke_exit\t%s\n' "$status" >>"$output_directory/summary.tsv"
[ "$status" -eq 0 ] || exit 1
grep -q '^nvidia_sdk_smoke=accepted' "$output_directory/smoke.txt"
