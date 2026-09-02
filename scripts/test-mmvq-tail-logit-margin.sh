#!/bin/sh
set -eu

# probe-mmvq-tail-logit-margin.sh drives two real llama-server processes on the
# device, so its reply contract is decided here against
# scripts/test-fixtures/fake-llama-server.sh, which serves the sampled id array
# only under return_tokens and the candidate vectors only under n_probs, and
# which carries the three defects a margin reader has to refuse. Eight cases
# cover the contract: three that report divergence and five that refuse.

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
fixture=$script_directory/test-fixtures/fake-llama-server.sh
probe=$script_directory/probe-mmvq-tail-logit-margin.sh
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

# The control build carries the alias marker and the subject build does not,
# which is the separation the fixture reads to answer with its alternate id
# array; the CUDA wrapper's scrub guarantees the optimizer variable is absent.
control_build=$temporary_directory/build-control
subject_build=$temporary_directory/build-subject
for build_directory in "$control_build" "$subject_build"; do
    mkdir -p "$build_directory/bin"
    cp "$fixture" "$build_directory/bin/llama-server"
    chmod +x "$build_directory/bin/llama-server"
done
: >"$control_build/alias-marker"

# The device-owning guards read their fakes: a driver that reports no client
# and a clear latch directory, so the probe reaches its request loop here.
cat >"$temporary_directory/nvidia-smi" <<'SMI'
#!/bin/sh
:
SMI
chmod +x "$temporary_directory/nvidia-smi"
mkdir -p "$temporary_directory/proc" "$temporary_directory/state"

port=${QWEN_MARGIN_TEST_PORT:-18160}
run_probe() {
    # run_probe PROBE_SCRIPT PROBES OUTPUT_DIRECTORY [ENV=VALUE...]
    probe_script=$1
    probe_specification=$2
    probe_output_directory=$3
    shift 3
    env "$@" \
        QWEN_MODEL_ROOT="$model_root" \
        QWEN_TAIL_PASSAGE="$script_directory/../CLAUDE.md" \
        QWEN_GPU_OWNERSHIP_NVIDIA_SMI="$temporary_directory/nvidia-smi" \
        QWEN_GPU_OWNERSHIP_PROCFS="$temporary_directory/proc" \
        QWEN_GPU_OWNERSHIP_LOCK="$temporary_directory/ownership.lock" \
        QWEN_WEBUI_STATE_DIRECTORY="$temporary_directory/state" \
        QWEN_FAKE_SERVER_PLACEMENT=cuda QWEN_FAKE_SERVER_PORT_FROM_ARGV=1 \
        QWEN_FAKE_SERVER_STATE_DIRECTORY="$probe_output_directory/argv" \
        QWEN_MARGIN_PROBES="$probe_specification" QWEN_TAIL_PORT="$port" \
        "$probe_script" "$control_build/bin/llama-server" "$subject_build/bin/llama-server" \
        "$model_id" "$probe_output_directory"
}

margin_field() {
    # margin_field TABLE COLUMN
    awk -F '\t' -v column="$2" '
        NR == 1 { for (i = 1; i <= NF; i++) if ($i == column) want = i }
        NR == 2 { print $want }' "$1"
}

accepting_case() {
    # accepting_case NAME PROBES EXPECTED_DIVERGENT_AT [ENV=VALUE...]
    case_name=$1
    case_probes=$2
    case_expected=$3
    shift 3
    case_output=$temporary_directory/$case_name
    case_status=0
    run_probe "$probe" "$case_probes" "$case_output" "$@" \
        >"$temporary_directory/$case_name.log" 2>&1 || case_status=$?
    observed=$(margin_field "$case_output/logit-margins.tsv" divergent_at 2>/dev/null || printf 'absent')
    if [ "$case_status" -eq 0 ] && [ "$observed" = "$case_expected" ]; then
        report 0 "$case_name reports divergent_at=$case_expected"
    else
        report 1 "$case_name reports divergent_at=$case_expected (status $case_status, read $observed)"
        tail -5 "$temporary_directory/$case_name.log"
    fi
}

refusing_case() {
    # refusing_case NAME PROBES EXPECTED_MESSAGE [ENV=VALUE...]
    case_name=$1
    case_probes=$2
    case_message=$3
    shift 3
    case_output=$temporary_directory/$case_name
    case_status=0
    run_probe "$probe" "$case_probes" "$case_output" "$@" \
        >"$temporary_directory/$case_name.log" 2>&1 || case_status=$?
    if [ "$case_status" -ne 0 ] && grep -q "$case_message" "$temporary_directory/$case_name.log" &&
        [ ! -e "$case_output/logit-margins.tsv" ]; then
        report 0 "$case_name refuses and writes no table"
    else
        report 1 "$case_name refuses and writes no table (status $case_status)"
        tail -5 "$temporary_directory/$case_name.log"
    fi
}

# 1. Both closures answer with the same ids, so the position carries one
# chosen id and the table reports no divergence.
accepting_case identical 512+19:3 - \
    QWEN_FAKE_SERVER_TOKENS='10 11 12 13 14 15 16 17'

# 2. The subject's first id differs. The compared prefix is empty at position
# zero, so the comparison stands and the table names position 0.
accepting_case first-token 512+19:0 0 \
    QWEN_FAKE_SERVER_TOKENS='10 11 12 13 14 15 16 17' \
    QWEN_FAKE_SERVER_TOKENS_OPTIMIZE='90 11 12 13 14 15 16 17'

# 3. The arms agree through index two and part at index three, which is the
# position asked for, so the prefix is identical and the table names 3.
accepting_case later-divergence 512+19:3 3 \
    QWEN_FAKE_SERVER_TOKENS='10 11 12 13 14 15 16 17' \
    QWEN_FAKE_SERVER_TOKENS_OPTIMIZE='10 11 12 99 14 15 16 17'

# 4. The mutation the contract exists to catch: the same probe with the
# return_tokens flag removed. The fixture then omits the array and the probe
# refuses at the first reply rather than comparing an absent history.
mutated_scripts=$temporary_directory/scripts
mkdir -p "$mutated_scripts"
for entry in "$script_directory"/*; do
    ln -s "$entry" "$mutated_scripts/$(basename -- "$entry")"
done
rm "$mutated_scripts/probe-mmvq-tail-logit-margin.sh"
sed 's/"return_tokens": True, //' "$probe" >"$mutated_scripts/probe-mmvq-tail-logit-margin.sh"
chmod +x "$mutated_scripts/probe-mmvq-tail-logit-margin.sh"
if ! grep -q '"return_tokens": True' "$mutated_scripts/probe-mmvq-tail-logit-margin.sh" &&
    ! cmp -s "$probe" "$mutated_scripts/probe-mmvq-tail-logit-margin.sh"; then
    report 0 'the mutated probe no longer requests return_tokens'
else
    report 1 'the mutated probe no longer requests return_tokens'
fi
missing_tokens=$temporary_directory/missing-tokens
status=0
run_probe "$mutated_scripts/probe-mmvq-tail-logit-margin.sh" 512+19:3 "$missing_tokens" \
    QWEN_FAKE_SERVER_TOKENS='10 11 12 13 14 15 16 17' \
    >"$temporary_directory/missing-tokens.log" 2>&1 || status=$?
if [ "$status" -ne 0 ] &&
    grep -q 'omitted the requested raw token list' "$temporary_directory/missing-tokens.log" &&
    [ ! -e "$missing_tokens/logit-margins.tsv" ]; then
    report 0 'an absent token array refuses and writes no table'
else
    report 1 "an absent token array refuses and writes no table (status $status)"
    tail -5 "$temporary_directory/missing-tokens.log"
fi

# 5. The reply carries three ids beside a predicted_n of four, which is a
# reader reading one array against another reply's length.
refusing_case count-mismatch 512+19:3 'token-count mismatch' \
    QWEN_FAKE_SERVER_TOKENS='10 11 12 13 14 15 16 17' \
    QWEN_FAKE_SERVER_TOKEN_COUNT_SKEW=-1

# 6. The position carries no candidate list, so no distance between two
# candidates exists to report.
refusing_case no-top-logprobs 512+19:3 'carries no top-candidate pair' \
    QWEN_FAKE_SERVER_TOKENS='10 11 12 13 14 15 16 17' \
    QWEN_FAKE_SERVER_TOP_LOGPROBS=absent

# 7. The sampled id is outside the candidate set the margin is measured over,
# so the two readings describe different vectors.
refusing_case chosen-absent 512+19:3 'is absent from the candidates' \
    QWEN_FAKE_SERVER_TOKENS='10 11 12 13 14 15 16 17' \
    QWEN_FAKE_SERVER_CHOSEN_IN_TOP=0

# 8. The arms part at index one and the probe asks for position five, so the
# two logit vectors are conditioned on different prefixes and the comparison
# stops isolating kernel arithmetic.
refusing_case parted-history 512+19:5 'the histories parted at index 1' \
    QWEN_FAKE_SERVER_TOKENS='10 11 12 13 14 15 16 17' \
    QWEN_FAKE_SERVER_TOKENS_OPTIMIZE='10 99 12 13 14 15 16 17'

if [ "$failures" -ne 0 ]; then
    printf '%s failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'mmvq_tail_logit_margin=accepted cases=9\n'
