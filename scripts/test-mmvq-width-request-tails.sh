#!/bin/sh
set -eu

# run-mmvq-width-request-tails.sh drives two real llama-server processes on
# the device, so its reply contract is checked against
# scripts/test-fixtures/fake-llama-server.sh, which returns the sampled id
# array only under return_tokens the way the server does. Three runs cover the
# contract: identical closures yield an identical token and content digest at
# every length, a subject returning a different id array is reported as
# divergent, and a harness copy with the return_tokens flag removed is refused
# at the first reply rather than digesting an absent array.

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
fixture=$script_directory/test-fixtures/fake-llama-server.sh
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

model_id=qwen35-08b
model_file=$("$script_directory/model-registry.sh" id "$model_id" model_file)
model_root=$temporary_directory/models
mkdir -p "$model_root/$(dirname -- "$model_file")"
printf 'not a real gguf\n' >"$model_root/$model_file"

control_build=$temporary_directory/build-control
subject_build=$temporary_directory/build-subject
for build_directory in "$control_build" "$subject_build"; do
    mkdir -p "$build_directory/bin"
    cp "$fixture" "$build_directory/bin/llama-server"
    chmod +x "$build_directory/bin/llama-server"
done

# The device-owning guards read their fakes: a driver that reports no client
# and a clear latch directory, so the harness reaches its request loop here.
cat >"$temporary_directory/nvidia-smi" <<'SMI'
#!/bin/sh
:
SMI
chmod +x "$temporary_directory/nvidia-smi"
mkdir -p "$temporary_directory/proc" "$temporary_directory/state"

port=${QWEN_TAIL_TEST_PORT:-18140}
run_harness() {
    # run_harness HARNESS OUTPUT_DIRECTORY [ENV=VALUE...]
    harness=$1
    harness_output_directory=$2
    shift 2
    env "$@" \
        QWEN_MODEL_ROOT="$model_root" \
        QWEN_TAIL_PASSAGE="$script_directory/../CLAUDE.md" \
        QWEN_GPU_OWNERSHIP_NVIDIA_SMI="$temporary_directory/nvidia-smi" \
        QWEN_GPU_OWNERSHIP_PROCFS="$temporary_directory/proc" \
        QWEN_GPU_OWNERSHIP_LOCK="$temporary_directory/ownership.lock" \
        QWEN_WEBUI_STATE_DIRECTORY="$temporary_directory/state" \
        QWEN_FAKE_SERVER_PLACEMENT=cuda QWEN_FAKE_SERVER_PORT_FROM_ARGV=1 \
        QWEN_FAKE_SERVER_STATE_DIRECTORY="$harness_output_directory/argv" \
        QWEN_TAIL_WIDTHS='19 20' QWEN_TAIL_BASES=512 QWEN_TAIL_PAIRS=2 \
        QWEN_TAIL_PREDICT=8 QWEN_TAIL_PORT="$port" \
        "$harness" "$control_build/bin/llama-server" "$subject_build/bin/llama-server" \
        "$model_id" "$harness_output_directory"
}

summary_field() {
    # summary_field SUMMARY WIDTH COLUMN
    awk -F '\t' -v width="$2" -v column="$3" '
        NR == 1 { for (i = 1; i <= NF; i++) if ($i == column) want = i }
        NR > 1 && $2 == width { print $want }' "$1"
}

# Identical closures: every reply carries eight ids, the token and content
# digests agree at both lengths, and the observation table carries both.
identical=$temporary_directory/identical
status=0
run_harness "$script_directory/run-mmvq-width-request-tails.sh" "$identical" \
    >"$temporary_directory/identical.log" 2>&1 || status=$?
if [ "$status" -eq 0 ] &&
    [ "$(summary_field "$identical/tails-summary.tsv" 19 tokens_identical)" = yes ] &&
    [ "$(summary_field "$identical/tails-summary.tsv" 20 tokens_identical)" = yes ] &&
    [ "$(summary_field "$identical/tails-summary.tsv" 19 content_identical)" = yes ] &&
    [ "$(summary_field "$identical/tails-summary.tsv" 20 content_identical)" = yes ]; then
    report 0 'identical closures report identical token and content digests'
else
    report 1 "identical closures report identical token and content digests (status $status)"
    tail -5 "$temporary_directory/identical.log"
fi
observed_rows=$(awk -F '\t' 'NR > 1 && $11 == 8 && length($13) == 64 && length($14) == 64' "$identical/observations.tsv" | wc -l)
expected_rows=$((2 * 2 + 2 * 2 * 2))
if [ "$observed_rows" -eq "$expected_rows" ]; then
    report 0 "every observation carries predicted_n 8 and two digests ($observed_rows rows)"
else
    report 1 "every observation carries predicted_n 8 and two digests ($observed_rows of $expected_rows rows)"
fi
empty_digest=$(printf '[]' | sha256sum | cut -d ' ' -f 1)
if grep -q "$empty_digest" "$identical/observations.tsv"; then
    report 1 'no observation digests the empty array'
else
    report 0 'no observation digests the empty array'
fi
if grep -q '"return_tokens": true' "$identical/observations.tsv"; then
    report 1 'the observation table holds digests rather than request bodies'
else
    report 0 'the observation table holds digests rather than request bodies'
fi

# A divergent subject: the fixture returns its alternate array from a build
# carrying no alias marker while the optimizer variable is absent, which the
# CUDA wrapper's scrub guarantees, so the control build carries the marker
# and the subject build answers with the other array.
: >"$control_build/alias-marker"
divergent=$temporary_directory/divergent
status=0
run_harness "$script_directory/run-mmvq-width-request-tails.sh" "$divergent" \
    QWEN_FAKE_SERVER_TOKENS_OPTIMIZE='10 11 12 99 14 15 16 17' \
    >"$temporary_directory/divergent.log" 2>&1 || status=$?
if [ "$status" -eq 0 ] &&
    [ "$(summary_field "$divergent/tails-summary.tsv" 19 tokens_identical)" = no ] &&
    [ "$(summary_field "$divergent/tails-summary.tsv" 20 tokens_identical)" = no ]; then
    report 0 'a subject returning different ids is reported as divergent'
    if [ "$(summary_field "$divergent/tails-summary.tsv" 19 first_divergent_index)" = 3 ]; then
        report 0 'the summary names the first differing id position'
    else
        report 1 "the summary names the first differing id position ($(summary_field "$divergent/tails-summary.tsv" 19 first_divergent_index))"
    fi
else
    report 1 "a subject returning different ids is reported as divergent (status $status)"
    tail -5 "$temporary_directory/divergent.log"
fi
rm -f "$control_build/alias-marker"

# The mutation the contract exists to catch: the same harness with the
# return_tokens flag removed. The fixture then omits the array, and the
# harness has to refuse at the first reply rather than hash an absent list.
mutated_scripts=$temporary_directory/scripts
mkdir -p "$mutated_scripts"
for entry in "$script_directory"/*; do
    ln -s "$entry" "$mutated_scripts/$(basename -- "$entry")"
done
rm "$mutated_scripts/run-mmvq-width-request-tails.sh"
sed 's/"return_tokens": True/"cache_prompt": False/' "$script_directory/run-mmvq-width-request-tails.sh" \
    >"$mutated_scripts/run-mmvq-width-request-tails.sh"
chmod +x "$mutated_scripts/run-mmvq-width-request-tails.sh"
if grep -q return_tokens "$mutated_scripts/run-mmvq-width-request-tails.sh" &&
    ! grep -q '"return_tokens": True' "$mutated_scripts/run-mmvq-width-request-tails.sh"; then
    report 0 'the mutated harness no longer requests return_tokens'
else
    report 1 'the mutated harness no longer requests return_tokens'
fi
mutated=$temporary_directory/mutated
status=0
run_harness "$mutated_scripts/run-mmvq-width-request-tails.sh" "$mutated" \
    >"$temporary_directory/mutated.log" 2>&1 || status=$?
if [ "$status" -ne 0 ] && grep -q 'omitted the requested raw token list' "$temporary_directory/mutated.log"; then
    report 0 'a harness that leaves return_tokens unset is refused at the first reply'
else
    report 1 "a harness that leaves return_tokens unset is refused at the first reply (status $status)"
    tail -5 "$temporary_directory/mutated.log"
fi
if [ ! -e "$mutated/tails-summary.tsv" ]; then
    report 0 'the refused run writes no summary'
else
    report 1 'the refused run writes no summary'
fi

if [ "$failures" -ne 0 ]; then
    printf '%s failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'mmvq_width_request_tails=accepted\n'
