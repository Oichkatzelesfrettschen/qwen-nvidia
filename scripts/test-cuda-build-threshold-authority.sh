#!/bin/sh
set -eu

# The promoted row of scripts/serving-closures.tsv is the production dispatch
# policy, and build-llama-cuda.sh resolves every MMVQ threshold the caller
# leaves unset from it. This test holds four claims against fixture ledgers:
# a bare dry run configures the promoted pair; an override of one axis
# inherits the promoted value on the other, so a one-variable subject differs
# from production by one integer; the shipped ledger's promoted row states the
# pair the promoted closure's own evidence records; and a ledger with no
# promoted row, two promoted rows, missing columns, or a value outside the
# kernel ceiling refuses the build rather than falling back to a literal. It
# copies the builder, the ledger, and the patch series into a fixture scripts
# directory, because the builder reads the ledger beside itself, and drives the
# dry-run path, which creates no build tree and reaches no device.

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
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
check() {
    description=$1
    shift
    if "$@"; then
        report 0 "$description"
    else
        report 1 "$description"
    fi
}

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

source_tree=$temporary_directory/source
mkdir -p "$source_tree/ggml/src/ggml-cuda"
printf 'static const int tiles_efficiency_threshold_percent = 90;\n' \
    >"$source_tree/ggml/src/ggml-cuda/mmq.cuh"
git -C "$source_tree" init --quiet
git -C "$source_tree" -c user.email=test@invalid -c user.name=test add -A
git -C "$source_tree" -c user.email=test@invalid -c user.name=test \
    commit --quiet -m fixture

# The fixture checkout holds the builder and the patch series verbatim and a
# ledger this test writes, so each arm changes the ledger alone.
fixture_root=$temporary_directory/fixture
mkdir -p "$fixture_root/scripts" "$fixture_root/patches"
cp "$script_directory/build-llama-cuda.sh" "$fixture_root/scripts/"
cp "$script_directory"/../patches/*.patch "$fixture_root/patches/"
fixture_ledger=$fixture_root/scripts/serving-closures.tsv

write_ledger() {
    {
        printf '# role\tconfiguration_id\tevidence_path\tbackend_set\tarchitecture\tcubin_images\tptx_images\tstatus\tmmvq_q6k_max\tmmvq_q8_0_max\n'
        printf '%s\n' "$@"
    } >"$fixture_ledger"
}
promoted_row() {
    printf 'promoted\t000000000000\tevidence/none\tcuda\t89-real\t187\t0\tpromoted\t%s\t%s' "$1" "$2"
}
rollback_row='rollback	111111111111	evidence/none	cuda	89-real	187	0	superseded	10	12'

run_dry() {
    output_file=$1
    shift
    status=0
    PATH=$toolchain_directory:$PATH \
    QWEN_BUILD_DRY_RUN=1 \
    QWEN_ALLOW_ANY_COMMIT=1 \
    QWEN_HOST_COMPILER=$toolchain_directory/g++-15 \
    QWEN_HOST_C_COMPILER=$toolchain_directory/gcc-15 \
    env "$@" "$fixture_root/scripts/build-llama-cuda.sh" "$source_tree" \
        >"$output_file" 2>&1 || status=$?
    return "$status"
}

write_ledger "$(promoted_row 10 16)" "$rollback_row"

run_dry "$temporary_directory/bare.out"
check "a bare build resolves the Q6_K ceiling from the promoted row" \
    grep -qx 'cmake_argument=-DGGML_CUDA_ADA_MMVQ_Q6_K_MAX_BATCH_SIZE=10' \
        "$temporary_directory/bare.out"
check "a bare build resolves the Q8_0 ceiling from the promoted row" \
    grep -qx 'cmake_argument=-DGGML_CUDA_ADA_MMVQ_Q8_0_MAX_BATCH_SIZE=16' \
        "$temporary_directory/bare.out"
check "the dry run names the promoted closure as each source" \
    grep -qx 'mmvq_q6k_max=10 source=promoted-closure promoted=10' \
        "$temporary_directory/bare.out"
check "the bare build ignores the rollback row" \
    grep -qx 'mmvq_q8_0_max=16 source=promoted-closure promoted=16' \
        "$temporary_directory/bare.out"

run_dry "$temporary_directory/one-axis.out" QWEN_CUDA_MMVQ_Q6K_MAX=7
check "a one-axis override moves the axis it names" \
    grep -qx 'mmvq_q6k_max=7 source=override promoted=10' \
        "$temporary_directory/one-axis.out"
check "a one-axis override inherits production on the other axis" \
    grep -qx 'mmvq_q8_0_max=16 source=promoted-closure promoted=16' \
        "$temporary_directory/one-axis.out"

# A one-axis subject and the bare build differ in the configuration record by
# that one field alone, which is what makes the pair a one-variable comparison.
record_of() {
    grep '^[a-z_0-9]*	' "$1" | grep -v '^builder_sha256\|^patch_series_sha256'
}
record_of "$temporary_directory/bare.out" >"$temporary_directory/bare.record"
record_of "$temporary_directory/one-axis.out" >"$temporary_directory/one-axis.record"
differing_fields=$(diff "$temporary_directory/bare.record" \
    "$temporary_directory/one-axis.record" | grep -c '^<' || :)
check "the two configuration records differ in one field" \
    test "$differing_fields" = 1

# The shipped builder against the shipped ledger resolves the pair the
# promoted row states, so the two files in the tree agree with each other the
# way the fixture pair does. check-authority-consistency.py holds the same
# row against README's threshold clauses, which is where the promoted
# closure's evidence states the pair in prose.
shipped_ledger=$script_directory/serving-closures.tsv
shipped_pair=$(awk -F '\t' '$1 == "promoted" { print $9 " " $10 }' "$shipped_ledger")
check "the shipped promoted row carries both thresholds" \
    test "$(printf '%s' "$shipped_pair" | wc -w)" = 2
shipped_q6k=${shipped_pair% *}
shipped_q8_0=${shipped_pair#* }
shipped_status=0
PATH=$toolchain_directory:$PATH \
QWEN_BUILD_DRY_RUN=1 \
QWEN_ALLOW_ANY_COMMIT=1 \
QWEN_HOST_COMPILER=$toolchain_directory/g++-15 \
QWEN_HOST_C_COMPILER=$toolchain_directory/gcc-15 \
    "$script_directory/build-llama-cuda.sh" "$source_tree" \
    >"$temporary_directory/shipped.out" 2>&1 || shipped_status=$?
check "the shipped builder resolves the shipped ledger" test "$shipped_status" = 0
check "the shipped bare build carries the promoted Q6_K ceiling" \
    grep -qx "mmvq_q6k_max=$shipped_q6k source=promoted-closure promoted=$shipped_q6k" \
        "$temporary_directory/shipped.out"
check "the shipped bare build carries the promoted Q8_0 ceiling" \
    grep -qx "mmvq_q8_0_max=$shipped_q8_0 source=promoted-closure promoted=$shipped_q8_0" \
        "$temporary_directory/shipped.out"

refuse() {
    description=$1
    shift
    refusal_status=0
    run_dry "$temporary_directory/refuse.out" || refusal_status=$?
    check "$description" test "$refusal_status" = 1
}

write_ledger "$rollback_row"
refuse "a ledger with no promoted row refuses the build"
write_ledger "$(promoted_row 10 16)" "$(promoted_row 10 12)"
refuse "a ledger with two promoted rows refuses the build"
printf '# role\tconfiguration_id\tevidence_path\tstatus\npromoted\t000000000000\tevidence/none\tpromoted\n' \
    >"$fixture_ledger"
refuse "a ledger without the threshold columns refuses the build"
write_ledger "$(promoted_row 17 16)"
refusal_status=0
run_dry "$temporary_directory/refuse.out" || refusal_status=$?
check "a promoted value above the kernel ceiling is refused by the range check" \
    test "$refusal_status" = 2
rm -f "$fixture_ledger"
refuse "a missing ledger refuses the build"

if [ "$failures" -ne 0 ]; then
    printf 'cuda_build_threshold_authority=rejected failures=%s\n' "$failures" >&2
    exit 1
fi
printf 'cuda_build_threshold_authority=accepted\n'
