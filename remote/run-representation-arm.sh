#!/bin/sh
set -eu

# Measure one value representation against another on the same weights, in the
# order control, subject, subject, control. A representation changes the bytes
# streamed per token and nothing else about the model, so the question is a
# ratio; this tree has measured the same checkpoint under identical flags
# spanning 30.6% between sweeps, and an absolute band built across sweeps
# measured the sweep. The ABBA order puts both rungs inside one sweep and pairs
# each subject arm with a control arm minutes away, so a monotonic drift in
# machine state cancels in the paired mean instead of ordering the result.
#
# The first argument names the measured control rung. The runner
# requires matching architecture dimensions, tokenizer identity, and tensor
# layout before the value format may vary. Numeric tensor-value equality remains
# a provenance claim outside the header-only check.

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    printf 'usage: %s LABEL CONTROL_MODEL SUBJECT_MODEL [OUTPUT_DIRECTORY]\n' "$0" >&2
    printf 'environment: QWEN_LLAMA_BENCH QWEN_CLOCK_SAMPLER QWEN_ARM_REPEATS\n' >&2
    printf '             QWEN_BENCH_PROMPT QWEN_BENCH_GENERATE QWEN_COOLDOWN_SECONDS\n' >&2
    printf '             QWEN_SAMPLE_INTERVAL_SECONDS QWEN_TENSOR_CENSUS\n' >&2
    printf '             QWEN_REPRESENTATION_PAIR_CHECK\n' >&2
    exit 2
fi

label=$1
control_model=$2
subject_model=$3
output_directory=${4:-"${HOME:?}/qwen-representation-arm"}/$label
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
bench=${QWEN_LLAMA_BENCH:-"${HOME:?}/src/llama.cpp-qwen-nvidia/build-qwen-cuda-sm89/bin/llama-bench"}
cli=${QWEN_LLAMA_CLI:-"${HOME:?}/src/llama.cpp-qwen-nvidia/build-qwen-cuda-sm89/bin/llama-cli"}
clock_sampler=${QWEN_CLOCK_SAMPLER:-$script_directory/sample-gpu-clocks.sh}
census=${QWEN_TENSOR_CENSUS:-$script_directory/gguf-tensor-census.py}
pair_check=${QWEN_REPRESENTATION_PAIR_CHECK:-$script_directory/verify-representation-pair.py}
arm_repeats=${QWEN_ARM_REPEATS:-3}
prompt_tokens=${QWEN_BENCH_PROMPT:-512}
generate_tokens=${QWEN_BENCH_GENERATE:-64}
cooldown_seconds=${QWEN_COOLDOWN_SECONDS:-90}
sample_interval_seconds=${QWEN_SAMPLE_INTERVAL_SECONDS:-2}

for required_file in "$bench" "$cli" "$census" "$pair_check"; do
    if [ ! -x "$required_file" ]; then
        printf 'required executable is absent: %s\n' "$required_file" >&2
        exit 1
    fi
done

"$pair_check" "$control_model" "$subject_model"
for required_model in "$control_model" "$subject_model"; do
    if [ ! -f "$required_model" ]; then
        printf 'model does not exist: %s\n' "$required_model" >&2
        exit 2
    fi
done

# llama-bench and the server both take the whole device, so a second holder
# makes every rate below a measurement of contention.
if pgrep -x llama-server >/dev/null 2>&1 || pgrep -x llama-bench >/dev/null 2>&1; then
    printf 'another llama process holds the device\n' >&2
    exit 2
fi

mkdir -p "$output_directory"
summary=$output_directory/representation-summary.tsv
printf 'position\trole\tmodel\tstreamed_bytes\tprefill_tok_s\tdecode_tok_s\twall_seconds\tmclk_mhz_modal\tsclk_mhz_max\ttemp_c_max\tvram_bytes_max\tgtt_bytes_max\n' \
    >"$summary"

sampler_pid=''
stop_sampler() {
    [ -n "$sampler_pid" ] || return 0
    kill "$sampler_pid" 2>/dev/null || true
    wait "$sampler_pid" 2>/dev/null || true
    sampler_pid=''
}
trap 'stop_sampler' EXIT INT TERM

# The census reports what an ordinary load streams per token, which excludes the
# multi-token-prediction block the loader skips. File size counts that block, so
# a ratio built from file sizes overstates what the device moves.
streamed_bytes_of() {
    census_output=$(GGUF_PY_PATH=${GGUF_PY_PATH:-"${HOME:?}/src/llama.cpp-qwen-nvidia/gguf-py"} \
        "$census" --skip-hash "$1") || {
            printf 'tensor census failed: %s\n' "$1" >&2
            return 1
        }
    streamed_bytes=$(printf '%s\n' "$census_output" |
        awk -F'\t' '$1 == "streamed_bytes_per_token" { print $2; found = 1; exit }
                     END { if (!found) exit 1 }') || {
            printf 'tensor census reported no streamed byte count: %s\n' "$1" >&2
            return 1
        }
    case $streamed_bytes in
        ''|*[!0-9]*|0) printf 'tensor census reported invalid streamed bytes: %s\n' \
            "$streamed_bytes" >&2; return 1 ;;
    esac
    printf '%s\n' "$streamed_bytes"
}

# One token with every tensor forced onto the device, so an arm that silently
# placed weights elsewhere is named here rather than read as a slow
# representation. The discriminating line is the owner of the model buffer
# rather than the word CPU: llama-cli at -ngl 0 reports `Vulkan_Host model
# buffer size` and reserves its output, KV, and recurrent buffers on CPU, so a
# grep for `CPU buffer size` matches those three and misses where the weights
# went. The loader prints none of it at the default verbosity, which is why -v
# is passed; without it the check reads an empty log and can never fail.
weights_off_device() {
    awk '/load_tensors:.*model buffer size/ {
            size = $(NF - 1) + 0
            if (size <= 0) { next }
            owner = ""
            for (field = 1; field <= NF; field++) {
                if ($field == "model") { owner = $(field - 1) }
            }
            if (owner != "Vulkan0") { printf "%s holds %s MiB of weights\n", owner, size }
        }' "$1"
}

check_strict_placement() {
    placement_model=$1
    placement_log=$2
    nice -n 19 "$cli" --model "$placement_model" --device Vulkan0 \
        --n-gpu-layers all --override-tensor '.*=Vulkan0' --no-warmup \
        --ctx-size 256 --n-predict 1 --temp 0 --prompt 'ok' \
        --single-turn -v >"$placement_log" 2>&1 || return 1
    # An empty result from an empty log would pass, so the log must carry at
    # least one model buffer line before its owners mean anything.
    if ! grep -q 'load_tensors:.*model buffer size' "$placement_log"; then
        return 3
    fi
    if [ -n "$(weights_off_device "$placement_log")" ]; then
        return 2
    fi
    return 0
}

run_arm() {
    arm_position=$1
    arm_role=$2
    arm_model=$3
    arm_stem=$output_directory/$(printf '%02d' "$arm_position")-$arm_role
    arm_clocks=$arm_stem-clocks.tsv
    arm_log=$arm_stem-bench.csv
    arm_diagnostics=$arm_stem-bench.log

    # The sampler's second argument is the interval between rows, so a large
    # value writes one row and sleeps rather than running for that long.
    #
    # A background job that exits at once leaves the shell running and the wait
    # status discarded, so the arm would record dashes for every device
    # covariate and still report completion. The covariates are what separate a
    # representation effect from machine-state drift, so a sampler that fails to
    # start ends the arm rather than emptying it.
    "$clock_sampler" "$arm_clocks" "$sample_interval_seconds" >/dev/null 2>&1 &
    sampler_pid=$!
    sampler_started=0
    sampler_attempt=0
    while [ "$sampler_attempt" -lt 40 ]; do
        if [ -s "$arm_clocks" ]; then
            sampler_started=1
            break
        fi
        kill -0 "$sampler_pid" 2>/dev/null || break
        sleep 0.25
        sampler_attempt=$((sampler_attempt + 1))
    done
    if [ "$sampler_started" -eq 0 ]; then
        printf 'clock sampler wrote no rows: %s\n' "$clock_sampler" >&2
        stop_sampler
        exit 1
    fi

    arm_started=$(date +%s)
    # The CSV goes to its own file. llama-bench writes the loader's key-value
    # dump to stderr, and a merged stream puts comma-bearing log lines ahead of
    # the header, which a reader that takes the first comma-bearing line adopts
    # as the header instead.
    nice -n 19 "$bench" --model "$arm_model" -ngl 99 -t 2 \
        -ot '.*=Vulkan0' -r "$arm_repeats" -p "$prompt_tokens" \
        -n "$generate_tokens" -b 128 -ub 32 -fa on -ctk q8_0 -ctv q4_0 \
        -o csv -v >"$arm_log" 2>"$arm_diagnostics" || {
            printf 'bench arm failed: position %s role %s\n' \
                "$arm_position" "$arm_role" >&2
            tail -20 "$arm_diagnostics" >&2
            stop_sampler
            return 1
        }
    arm_wall=$(( $(date +%s) - arm_started ))
    stop_sampler

    # The pre-check proves strict placement is reachable; this proves the arm
    # that produced the rate took it. A weight tensor left on the CPU backend
    # makes the ratio a placement measurement rather than a format one, and the
    # 0.8B keeps 34% of its streamed bytes in one tied embedding tensor.
    arm_misplaced=$(weights_off_device "$arm_diagnostics")
    if [ -n "$arm_misplaced" ]; then
        printf 'arm placed weights off the device: position %s role %s\n' \
            "$arm_position" "$arm_role" >&2
        printf '%s\n' "$arm_misplaced" >&2
        return 1
    fi
    if ! grep -q 'load_tensors:.*model buffer size' "$arm_diagnostics"; then
        printf 'arm log carries no model buffer line, so placement is unproven: %s\n' \
            "$arm_diagnostics" >&2
        return 1
    fi

    # The header is found by the column it must contain rather than by being the
    # first line with a comma, so a diagnostic line cannot stand in for it.
    arm_rates=$(python3 - "$arm_log" <<'PYTHON'
import csv
import sys

with open(sys.argv[1]) as handle:
    lines = handle.read().splitlines()
start = next((i for i, line in enumerate(lines) if "avg_ts" in line), None)
if start is None:
    print("llama-bench emitted no avg_ts column", file=sys.stderr)
    raise SystemExit(1)

prefill = decode = "-"
for row in csv.DictReader(lines[start:]):
    rate = row.get("avg_ts") or ""
    n_prompt = (row.get("n_prompt") or "0").strip()
    n_gen = (row.get("n_gen") or "0").strip()
    if not rate:
        continue
    if n_prompt != "0" and n_gen == "0":
        prefill = f"{float(rate):.2f}"
    elif n_gen != "0":
        decode = f"{float(rate):.2f}"
# Both rates are the arm. A pair with one side missing supports no ratio, and
# recording it as a dash would carry a failed measurement into the paired means.
missing = [name for name, value in (("prefill", prefill), ("decode", decode))
           if value == "-"]
if missing:
    print(f"llama-bench reported no {' and no '.join(missing)} rate",
          file=sys.stderr)
    raise SystemExit(1)
print(f"{prefill}\t{decode}")
PYTHON
) || {
        printf 'bench arm produced no usable rates: position %s role %s\n' \
            "$arm_position" "$arm_role" >&2
        tail -20 "$arm_diagnostics" >&2
        stop_sampler
        exit 1
    }

    # sample-gpu-clocks.sh writes no header and six columns: memory clock,
    # shader clock, temperature in millidegrees, load average, VRAM bytes, and
    # GTT bytes. Rows carrying `unavailable` are skipped per column rather than
    # per row, because one absent sysfs node leaves the others readable.
    arm_device_summary=$(awk -F'\t' '
        $1 ~ /^[0-9]+$/ { mclk[$1]++ }
        $2 ~ /^[0-9]+$/ { if ($2 + 0 > sclk) { sclk = $2 + 0 } }
        $3 ~ /^[0-9]+$/ { if ($3 + 0 > temp) { temp = $3 + 0 } }
        $5 ~ /^[0-9]+$/ { if ($5 + 0 > vram) { vram = $5 + 0 } }
        $6 ~ /^[0-9]+$/ { if ($6 + 0 > gtt) { gtt = $6 + 0 } }
        END {
            modal = "-"; best = 0
            for (value in mclk) { if (mclk[value] > best) { best = mclk[value]; modal = value } }
            printf "%s\t%s\t%s\t%s\t%s", modal, (sclk ? sclk : "-"),
                (temp ? temp / 1000 : "-"), (vram ? vram : "-"), (gtt ? gtt : "-")
        }' "$arm_clocks" 2>/dev/null || printf -- '-\t-\t-\t-\t-')

    arm_streamed_bytes=$(streamed_bytes_of "$arm_model") || {
        stop_sampler
        return 1
    }
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$arm_position" "$arm_role" "$(basename "$arm_model")" \
        "$arm_streamed_bytes" "$arm_rates" "$arm_wall" \
        "$arm_device_summary" >>"$summary"
    printf 'position=%s role=%s prefill=%s decode=%s wall=%ss\n' \
        "$arm_position" "$arm_role" \
        "$(printf '%s' "$arm_rates" | cut -f1)" \
        "$(printf '%s' "$arm_rates" | cut -f2)" "$arm_wall"
}

for placement_role in control subject; do
    case $placement_role in
        control) placement_target=$control_model ;;
        subject) placement_target=$subject_model ;;
    esac
    set +e
    check_strict_placement "$placement_target" \
        "$output_directory/placement-$placement_role.txt"
    placement_status=$?
    set -e
    case $placement_status in
        0) printf 'placement=%s strict_vulkan=passed\n' "$placement_role" ;;
        2) printf 'placement=%s strict_vulkan=weights-off-device\n' "$placement_role" >&2
           weights_off_device "$output_directory/placement-$placement_role.txt" >&2
           exit 1 ;;
        3) printf 'placement=%s strict_vulkan=unproven reason=no-model-buffer-line\n' \
               "$placement_role" >&2
           exit 1 ;;
        *) printf 'placement=%s strict_vulkan=failed\n' "$placement_role" >&2
           tail -20 "$output_directory/placement-$placement_role.txt" >&2
           exit 1 ;;
    esac
done

position=1
for arm_role in control subject subject control; do
    case $arm_role in
        control) arm_model=$control_model ;;
        subject) arm_model=$subject_model ;;
    esac
    run_arm "$position" "$arm_role" "$arm_model"
    position=$((position + 1))
    [ "$position" -le 4 ] && sleep "$cooldown_seconds"
done

printf '\n'
cat "$summary"

# The paired mean is what the ABBA order was run for: two subject arms against
# two control arms measured minutes apart in the same session.
python3 - "$summary" <<'PYTHON'
import sys

rows = []
with open(sys.argv[1]) as handle:
    header = handle.readline().rstrip("\n").split("\t")
    for line in handle:
        rows.append(dict(zip(header, line.rstrip("\n").split("\t"))))

def mean(role, column):
    values = [float(r[column]) for r in rows
              if r["role"] == role and r[column] not in ("-", "")]
    return sum(values) / len(values) if values else None

print()
for column in ("prefill_tok_s", "decode_tok_s"):
    control, subject = mean("control", column), mean("subject", column)
    if control and subject:
        print(f"{column}\tcontrol={control:.2f}\tsubject={subject:.2f}"
              f"\tratio={subject / control:.3f}")

streamed = {r["role"]: int(r["streamed_bytes"]) for r in rows
            if r["streamed_bytes"] not in ("-", "")}
if len(streamed) == 2:
    print(f"streamed_bytes\tcontrol={streamed['control']}"
          f"\tsubject={streamed['subject']}"
          f"\tratio={streamed['subject'] / streamed['control']:.3f}")
    for role in ("control", "subject"):
        decode = mean(role, "decode_tok_s")
        if decode:
            print(f"achieved_gib_tok_s\t{role}="
                  f"{decode * streamed[role] / 1073741824:.2f}")
PYTHON

printf 'representation_arm=completed label=%s output=%s\n' "$label" "$output_directory"
