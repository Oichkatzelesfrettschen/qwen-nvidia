#!/bin/sh
set -eu

# Exercise the representation runner's header gate, census status propagation,
# skip-hash contract, and fractional sampler interval without a GPU.

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
temporary_directory=$(mktemp -d)
cleanup() {
    cleanup_status=$?
    rm -rf -- "$temporary_directory"
    exit "$cleanup_status"
}
trap cleanup EXIT HUP INT TERM

fake_bin=$temporary_directory/bin
mkdir -p "$fake_bin"
printf '%s\n' '#!/bin/sh' 'exit 1' >"$fake_bin/pgrep"
chmod +x "$fake_bin/pgrep"

fake_cli=$temporary_directory/llama-cli
printf '%s\n' '#!/bin/sh' \
    'printf "load_tensors: Vulkan0 model buffer size = 1.00 MiB\n" >&2' \
    'exit 0' >"$fake_cli"
chmod +x "$fake_cli"

fake_bench=$temporary_directory/llama-bench
printf '%s\n' '#!/bin/sh' \
    'printf "load_tensors: Vulkan0 model buffer size = 1.00 MiB\n" >&2' \
    'printf "avg_ts,n_prompt,n_gen\n100,512,0\n10,0,64\n"' \
    >"$fake_bench"
chmod +x "$fake_bench"

fake_sampler=$temporary_directory/sample-clocks.sh
printf '%s\n' '#!/bin/sh' 'set -eu' \
    'printf "933\t1100\t80000\t1.0\t1024\t2048\n" >"$1"' \
    'trap "exit 0" HUP INT TERM' \
    'while :; do sleep "${2:-1}"; done' >"$fake_sampler"
chmod +x "$fake_sampler"

census_calls=$temporary_directory/census-calls
fake_census=$temporary_directory/gguf-tensor-census.py
printf '%s\n' '#!/bin/sh' 'set -eu' \
    'printf "%s\n" "$*" >>"${QWEN_TEST_CENSUS_CALLS:?}"' \
    '[ "${QWEN_TEST_CENSUS_FAIL:-no}" = no ] || exit 7' \
    '[ "$1" = --skip-hash ] || exit 8' \
    'printf "streamed_bytes_per_token\t1000\n"' >"$fake_census"
chmod +x "$fake_census"

pair_calls=$temporary_directory/pair-calls
fake_pair_check=$temporary_directory/verify-pair.py
printf '%s\n' '#!/bin/sh' 'set -eu' \
    'printf "%s\t%s\n" "$1" "$2" >>"${QWEN_TEST_PAIR_CALLS:?}"' \
    '[ "${QWEN_TEST_PAIR_FAIL:-no}" = no ] || exit 9' \
    'printf "representation_pair=compatible\n"' >"$fake_pair_check"
chmod +x "$fake_pair_check"

control_model=$temporary_directory/control.gguf
subject_model=$temporary_directory/subject.gguf
: >"$control_model"
: >"$subject_model"

common_environment="PATH=$fake_bin:$PATH"
output_root=$temporary_directory/output
env $common_environment HOME=$temporary_directory \
    QWEN_LLAMA_BENCH=$fake_bench QWEN_LLAMA_CLI=$fake_cli \
    QWEN_CLOCK_SAMPLER=$fake_sampler QWEN_TENSOR_CENSUS=$fake_census \
    QWEN_REPRESENTATION_PAIR_CHECK=$fake_pair_check \
    QWEN_TEST_CENSUS_CALLS=$census_calls QWEN_TEST_PAIR_CALLS=$pair_calls \
    QWEN_ARM_REPEATS=1 QWEN_COOLDOWN_SECONDS=0 \
    QWEN_SAMPLE_INTERVAL_SECONDS=0.05 \
    "$script_directory/run-representation-arm.sh" pair "$control_model" \
    "$subject_model" "$output_root" >"$temporary_directory/success.stdout" \
    2>"$temporary_directory/success.stderr"

grep -F 'representation_arm=completed' "$temporary_directory/success.stdout" \
    >/dev/null
if [ "$(wc -l <"$census_calls")" -ne 4 ] || \
   grep -Ev '^--skip-hash ' "$census_calls" >/dev/null; then
    printf 'representation runner omitted the bounded census contract\n' >&2
    exit 1
fi
if [ "$(wc -l <"$pair_calls")" -ne 1 ]; then
    printf 'representation runner did not check the pair exactly once\n' >&2
    exit 1
fi

if env $common_environment HOME=$temporary_directory \
    QWEN_LLAMA_BENCH=$fake_bench QWEN_LLAMA_CLI=$fake_cli \
    QWEN_CLOCK_SAMPLER=$fake_sampler QWEN_TENSOR_CENSUS=$fake_census \
    QWEN_REPRESENTATION_PAIR_CHECK=$fake_pair_check \
    QWEN_TEST_CENSUS_CALLS=$census_calls QWEN_TEST_PAIR_CALLS=$pair_calls \
    QWEN_TEST_CENSUS_FAIL=yes QWEN_COOLDOWN_SECONDS=0 \
    QWEN_SAMPLE_INTERVAL_SECONDS=0.05 \
    "$script_directory/run-representation-arm.sh" census-failure \
    "$control_model" "$subject_model" "$output_root" \
    >"$temporary_directory/census-failure.stdout" \
    2>"$temporary_directory/census-failure.stderr"; then
    printf 'representation runner masked a failed census\n' >&2
    exit 1
fi
grep -F 'tensor census failed:' "$temporary_directory/census-failure.stderr" \
    >/dev/null

if env $common_environment HOME=$temporary_directory \
    QWEN_LLAMA_BENCH=$fake_bench QWEN_LLAMA_CLI=$fake_cli \
    QWEN_CLOCK_SAMPLER=$fake_sampler QWEN_TENSOR_CENSUS=$fake_census \
    QWEN_REPRESENTATION_PAIR_CHECK=$fake_pair_check \
    QWEN_TEST_CENSUS_CALLS=$census_calls QWEN_TEST_PAIR_CALLS=$pair_calls \
    QWEN_TEST_PAIR_FAIL=yes QWEN_COOLDOWN_SECONDS=0 \
    "$script_directory/run-representation-arm.sh" pair-failure \
    "$control_model" "$subject_model" "$output_root" \
    >"$temporary_directory/pair-failure.stdout" \
    2>"$temporary_directory/pair-failure.stderr"; then
    printf 'representation runner admitted a failed pair check\n' >&2
    exit 1
fi

printf 'representation_arm_driver=accepted\n'
