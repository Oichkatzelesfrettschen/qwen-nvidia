#!/bin/sh
set -eu

# build-llama-cuda.sh names a closure by a digest over its configuration, so
# the Ada MMQ tiling threshold has to reach that digest or three campaign arms
# would share one directory and the second build would be skipped as current.
# This test drives the script's own dry-run path against a fixture llama.cpp
# checkout, which resolves the digest and the configure argv while creating no
# build tree, compiling nothing, and reaching no device.

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
builder=$script_directory/build-llama-cuda.sh
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

failures=0
report() {
    if [ "$1" = 0 ]; then
        printf 'ok %s\n' "$2"
    else
        printf 'FAIL %s\n' "$2"
        failures=$((failures + 1))
    fi
}

# The fixture toolchain answers the version queries the digest records, so the
# assertions read relations between runs rather than a literal digest that a
# compiler or CUDA update would rot.
toolchain_directory=$temporary_directory/toolchain
mkdir -p "$toolchain_directory"
for tool in gcc-15 g++-15; do
    printf '#!/bin/sh\nprintf %%s\\\\n 15.2.1\n' >"$toolchain_directory/$tool"
done
printf '#!/bin/sh\nprintf %%s\\\\n "release 13.3, V13.3.0"\n' \
    >"$toolchain_directory/nvcc"
printf '#!/bin/sh\nprintf %%s\\\\n "cmake version 4.1.0"\n' \
    >"$toolchain_directory/cmake"
printf '#!/bin/sh\nprintf %%s\\\\n 1.13.1\n' >"$toolchain_directory/ninja"
chmod +x "$toolchain_directory"/*

# Two fixture checkouts differ by the macro alone: one carries the #ifndef
# guard patches/llama-cuda-mmq-stream-k-grid.patch adds, the other holds the
# upstream header text the guard replaces.
make_source_tree() {
    tree_directory=$1
    macro_state=$2
    mkdir -p "$tree_directory/ggml/src/ggml-cuda"
    if [ "$macro_state" = present ]; then
        cat >"$tree_directory/ggml/src/ggml-cuda/mmq.cuh" <<'HEADER'
#ifndef GGML_CUDA_ADA_MMQ_TILING_EFFICIENCY_PERCENT
#define GGML_CUDA_ADA_MMQ_TILING_EFFICIENCY_PERCENT 90
#endif
HEADER
    else
        printf 'static const int tiles_efficiency_threshold_percent = 90;\n' \
            >"$tree_directory/ggml/src/ggml-cuda/mmq.cuh"
    fi
    git -C "$tree_directory" init --quiet
    git -C "$tree_directory" -c user.email=test@invalid -c user.name=test \
        add -A
    git -C "$tree_directory" -c user.email=test@invalid -c user.name=test \
        commit --quiet -m fixture
}

patched_tree=$temporary_directory/patched
unpatched_tree=$temporary_directory/unpatched
make_source_tree "$patched_tree" present
make_source_tree "$unpatched_tree" absent

run_dry() {
    tree_directory=$1
    output_file=$2
    shift 2
    PATH=$toolchain_directory:$PATH \
    QWEN_BUILD_DRY_RUN=1 \
    QWEN_ALLOW_ANY_COMMIT=1 \
    QWEN_HOST_COMPILER=$toolchain_directory/g++-15 \
    QWEN_HOST_C_COMPILER=$toolchain_directory/gcc-15 \
    env "$@" "$builder" "$tree_directory" >"$output_file" 2>&1
}

configuration_id_of() {
    awk '$1 == "cuda_build=dry_run" { print $2 }' "$1"
}

run_dry "$patched_tree" "$temporary_directory/default.out"
run_dry "$patched_tree" "$temporary_directory/explicit-90.out" \
    QWEN_CUDA_MMQ_TILING_PERCENT=90
run_dry "$patched_tree" "$temporary_directory/at-80.out" \
    QWEN_CUDA_MMQ_TILING_PERCENT=80
run_dry "$patched_tree" "$temporary_directory/at-1.out" \
    QWEN_CUDA_MMQ_TILING_PERCENT=1
run_dry "$unpatched_tree" "$temporary_directory/unpatched.out"

default_id=$(configuration_id_of "$temporary_directory/default.out")
explicit_id=$(configuration_id_of "$temporary_directory/explicit-90.out")
id_80=$(configuration_id_of "$temporary_directory/at-80.out")
id_1=$(configuration_id_of "$temporary_directory/at-1.out")

check() {
    description=$1
    shift
    if "$@"; then
        report 0 "$description"
    else
        report 1 "$description"
    fi
}

if [ -n "$default_id" ] && [ "$default_id" = "$explicit_id" ]; then
    report 0 "the unset threshold reproduces the identity of an explicit 90"
else
    report 1 "the unset threshold reproduces the identity of an explicit 90"
fi

if [ "$id_80" != "$default_id" ] && [ "$id_1" != "$default_id" ] &&
    [ "$id_1" != "$id_80" ]
then
    report 0 "each threshold names its own closure identity"
else
    report 1 "each threshold names its own closure identity"
fi

check "the configuration record states the threshold the digest hashes" \
    grep -q '^mmq_tiling_percent	80$' "$temporary_directory/at-80.out"

check "a patched tree carries the threshold on CMAKE_CUDA_FLAGS" \
    grep -qx 'cmake_argument=-DCMAKE_CUDA_FLAGS=-DGGML_CUDA_ADA_MMQ_TILING_EFFICIENCY_PERCENT=80' \
        "$temporary_directory/at-80.out"

check "the default value reaches the compile line as itself" \
    grep -qx 'cmake_argument=-DCMAKE_CUDA_FLAGS=-DGGML_CUDA_ADA_MMQ_TILING_EFFICIENCY_PERCENT=90' \
        "$temporary_directory/explicit-90.out"

# The MMVQ ceilings ride cache entries their own patch bridges into defines,
# so the two mechanisms are asserted apart.
check "the MMVQ ceiling stays a cache entry beside the compiler flag" \
    grep -qx 'cmake_argument=-DGGML_CUDA_ADA_MMVQ_Q6_K_MAX_BATCH_SIZE=8' \
        "$temporary_directory/default.out"

if grep -q 'CMAKE_CUDA_FLAGS' "$temporary_directory/unpatched.out"; then
    report 1 "an unpatched tree keeps the configure argv it already carries"
else
    report 0 "an unpatched tree keeps the configure argv it already carries"
fi

# Everything other than the one flag and the digest-named build tree is equal
# across two thresholds, which is what makes a difference between the arms
# readable as the threshold.
normalized_argv() {
    sed -n 's/^cmake_argument=//p' "$1" |
        grep -v CMAKE_CUDA_FLAGS |
        sed "s/build-qwen-cuda-[0-9a-f]*/build-qwen-cuda-ID/"
}
normalized_argv "$temporary_directory/explicit-90.out" \
    >"$temporary_directory/argv-90"
normalized_argv "$temporary_directory/at-80.out" >"$temporary_directory/argv-80"
check "two thresholds change one configure argument" \
    cmp -s "$temporary_directory/argv-90" "$temporary_directory/argv-80"

refusal_status=0
run_dry "$unpatched_tree" "$temporary_directory/refused.out" \
    QWEN_CUDA_MMQ_TILING_PERCENT=80 || refusal_status=$?
check "an unpatched tree refuses a threshold beside 90 by name" \
    test "$refusal_status" = 1
check "the refusal names the patch that supplies the macro" \
    grep -q 'needs the stream-K grid patch' "$temporary_directory/refused.out"

for rejected_value in 0 101 08 90.0 ninety; do
    argument_status=0
    run_dry "$patched_tree" "$temporary_directory/rejected.out" \
        "QWEN_CUDA_MMQ_TILING_PERCENT=$rejected_value" || argument_status=$?
    check "the threshold refuses the value $rejected_value" \
        test "$argument_status" = 2
done

if [ "$failures" -ne 0 ]; then
    printf 'cuda_build_tiling_threshold=rejected failures=%s\n' "$failures" >&2
    exit 1
fi
printf 'cuda_build_tiling_threshold=accepted\n'
