#!/bin/sh
set -eu

# The Ada MMQ tiling threshold is fixed at the upstream 90 because
# patches/llama-cuda-mmq-stream-k-grid.patch, which made it configurable, lost
# its promotion gate on exact greedy token identity
# (evidence/ada/mmq-stream-k-grid/phase-c-identity/). This test holds three
# claims: the configuration digest still records the threshold, so every
# closure identity the campaign retained keeps its name; the configure argv
# carries no tiling define on either a patched or an unpatched tree, so no
# build reaches the rejected mechanism; and a caller who still sets
# QWEN_CUDA_MMQ_TILING_PERCENT is refused at any value beside 90 rather than
# served the control under a subject request. It drives the script's own
# dry-run path against fixture checkouts, which resolves the digest and the
# argv while creating no build tree, compiling nothing, and reaching no
# device.

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
run_dry "$unpatched_tree" "$temporary_directory/unpatched.out"

default_id=$(configuration_id_of "$temporary_directory/default.out")
explicit_id=$(configuration_id_of "$temporary_directory/explicit-90.out")

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
    report 0 "a caller naming 90 asks for what the build already does"
else
    report 1 "a caller naming 90 asks for what the build already does"
fi

# The field stays in the configuration record at its fixed value, which is what
# holds the identity of every closure the campaign retained: removing it would
# rename the production closure and orphan the digests bound in
# scripts/ad104-stream-k-matrix.tsv.
check "the configuration record states the fixed threshold" \
    grep -q '^mmq_tiling_percent	90$' "$temporary_directory/default.out"

check "the dry run names the threshold as fixed rather than as an input" \
    grep -qx 'mmq_tiling_percent=90 source=fixed' "$temporary_directory/default.out"

for tree_output in default explicit-90 unpatched; do
    if grep -q 'GGML_CUDA_ADA_MMQ_TILING_EFFICIENCY_PERCENT' \
        "$temporary_directory/$tree_output.out"
    then
        report 1 "the $tree_output argv reaches no tiling define"
    else
        report 0 "the $tree_output argv reaches no tiling define"
    fi
done

# The MMVQ ceilings ride cache entries their own patch bridges into defines and
# are unaffected by the tiling retirement, so the two mechanisms are asserted
# apart. The value is the promoted row of serving-closures.tsv, which
# test-cuda-build-threshold-authority.sh holds; this assertion reads the same
# row so the two tests cannot disagree about it.
promoted_q6k_max=$(awk -F '\t' '$1 == "promoted" { print $9 }' \
    "$script_directory/serving-closures.tsv")
check "the MMVQ ceiling stays a cache entry" \
    grep -qx "cmake_argument=-DGGML_CUDA_ADA_MMVQ_Q6_K_MAX_BATCH_SIZE=$promoted_q6k_max" \
        "$temporary_directory/default.out"

# A tree carrying the rejected patch builds the same argv as one without it,
# because the patch's own #ifndef default is 90 and nothing defines the macro.
normalized_argv() {
    sed -n 's/^cmake_argument=//p' "$1" |
        sed "s/build-qwen-cuda-[0-9a-f]*/build-qwen-cuda-ID/" |
        sed "s#$temporary_directory/[a-z]*#TREE#g"
}
normalized_argv "$temporary_directory/default.out" >"$temporary_directory/argv-patched"
normalized_argv "$temporary_directory/unpatched.out" >"$temporary_directory/argv-unpatched"
check "a patched tree and an unpatched tree configure alike" \
    cmp -s "$temporary_directory/argv-patched" "$temporary_directory/argv-unpatched"

for rejected_value in 1 80 100 0 101 08 90.0 ninety; do
    argument_status=0
    run_dry "$patched_tree" "$temporary_directory/rejected.out" \
        "QWEN_CUDA_MMQ_TILING_PERCENT=$rejected_value" || argument_status=$?
    check "the threshold refuses the value $rejected_value" \
        test "$argument_status" = 2
    check "the refusal of $rejected_value names the rejected patch" \
        grep -q 'llama-cuda-mmq-stream-k-grid.patch is rejected' \
            "$temporary_directory/rejected.out"
done

# The patch itself stays in the tree as a rejected artifact, and the series
# authority is where that claim lives. Reading it here keeps the builder and
# the authority from drifting apart without a pinned llama.cpp checkout.
series_script=$script_directory/verify-llama-patch-series.sh
if grep -q '^candidate_patch_names=.*llama-cuda-mmq-stream-k-grid' \
    "$series_script"
then
    report 1 "the grid patch left the candidate list"
else
    report 0 "the grid patch left the candidate list"
fi

check "the grid patch joined the rejected list" \
    grep -q '^rejected_patch_names=.*llama-cuda-mmq-stream-k-grid' "$series_script"

# mmq.cuh belongs in the digest paths exactly while a candidate rewrites it.
# The grid patch was its sole writer and left with it; the fixup-pipeline patch
# is its writer now, so the path returns and two closures differing by the
# reduction loop carry different names.
if grep -q '^candidate_patch_names=.*llama-cuda-mmq-fixup-pipeline' \
    "$series_script"
then
    check "mmq.cuh is a candidate digest path while a candidate writes it" \
        grep -q '^candidate_digest_paths=.*mmq\.cuh' "$series_script"
elif grep -q '^candidate_digest_paths=.*mmq\.cuh' "$series_script"; then
    report 1 "mmq.cuh leaves the candidate digest paths with its last writer"
else
    report 0 "mmq.cuh leaves the candidate digest paths with its last writer"
fi

check "the rejected patch is retained rather than deleted" \
    test -f "$script_directory/../patches/llama-cuda-mmq-stream-k-grid.patch"

if [ "$failures" -ne 0 ]; then
    printf 'cuda_build_tiling_threshold=rejected failures=%s\n' "$failures" >&2
    exit 1
fi
printf 'cuda_build_tiling_threshold=accepted\n'
