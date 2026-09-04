#!/bin/sh
set -eu

# Every ceiling this tree has measured on decode was taken at one sequence.
# llama-bench decodes a single stream, `--parallel 1` is in every served argv
# here, and the three levers refuted against the 5.1% floor -- the projection
# fan-out merge, graph prewarming, and the bounded graph loop -- each named a
# concurrent served workload as the regime that recomputes its own bound. This
# harness is that regime: one llama-server at `--parallel N` answering N
# identical requests at once, swept over the column counts where this closure's
# own dispatch thresholds sit.
#
# The measurement rests on one mechanism. `update_slots` builds one batch across
# every slot with a token to decode, so N decoding slots make one ubatch of N
# columns and `ne11` equals the slot count; `ggml_cuda_should_use_mmvq` reads
# `ne11` and picks the mat-mul family from it. On the promoted closure Q4_K
# leaves MMVQ above seven columns at the upstream constant, Q6_K above ten and
# Q8_0 above sixteen through the AD104 crossover patch's cmake entries, so a 2B
# sweep crosses twice and a Q8_0 0.8B sweep crosses not at all. The 0.8B is
# therefore the control that separates a dispatch effect from a roofline or host
# effect: a kink both checkpoints share belongs to neither dispatch nor the
# quantization type.
#
# `llama_context` sets `cparams.n_ctx_seq = cparams.n_ctx / cparams.n_seq_max`
# (src/llama-context.cpp:293), so a fixed `--ctx-size` across the sweep shrinks
# each slot's depth as 1/N and lets KV traffic per sequence fall exactly as
# concurrency rises. Each arm therefore asks for `N * QWEN_CONCURRENCY_SLOT_DEPTH`
# and reads the per-slot depth back out of the server's own load line rather
# than assuming the division. Weight traffic is amortized across the ubatch and
# is constant in N while KV traffic is per-sequence and linear in it, which is
# the mechanism any scaling curve here decomposes into, so depth is an axis
# rather than a nuisance.
#
# Every request in a burst carries the same prompt, the same `n_predict`, and
# `ignore_eos`, because a request that stops early drops the batch to N-1 and
# decodes its tail at a column count the arm did not ask for. The window the
# aggregate rate divides by is the wall time from the first request leaving to
# the last returning, and the per-request rate comes from the server's own
# `predicted_ms`; they answer different questions and the summary carries both.

usage() {
    printf 'usage: %s SERVER MODEL_ID OUTPUT_DIRECTORY\n' "$0" >&2
    printf 'environment: QWEN_CONCURRENCY_LEVELS       slot counts, default "1 2 4 7 8 10 11"\n' >&2
    printf '             QWEN_CONCURRENCY_SLOT_DEPTH   per-slot context, default 4096\n' >&2
    printf '             QWEN_CONCURRENCY_PREDICT      tokens per request, default 128\n' >&2
    printf '             QWEN_CONCURRENCY_REPEATS      measured bursts per level, default 4\n' >&2
    printf '             QWEN_CONCURRENCY_PROMPT_CHARS prompt cut length, default 2048\n' >&2
    printf '             QWEN_CONCURRENCY_PASSAGE      prose file the prompt is cut from, default CLAUDE.md\n' >&2
    printf '             QWEN_CONCURRENCY_NSYS_LEVELS  levels to capture the dispatch of, default empty\n' >&2
    printf '             QWEN_CONCURRENCY_NSYS_PREDICT tokens per captured request, default 24\n' >&2
    printf '             QWEN_CONCURRENCY_NSYS         nsys, default the one on PATH\n' >&2
    printf '             QWEN_CONCURRENCY_PORT         default 18160\n' >&2
    printf '             QWEN_CONCURRENCY_LOCK_CLOCKS  SM MHz to pin through sudo -n nvidia-smi, default unset\n' >&2
    printf '             QWEN_MODEL_ROOT               default $HOME/models\n' >&2
    exit 2
}
[ "$#" -eq 3 ] || usage
server_binary=$1
model_id=$2
output_directory=$3
[ -x "$server_binary" ] || usage

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
levels=${QWEN_CONCURRENCY_LEVELS:-"1 2 4 7 8 10 11"}
slot_depth=${QWEN_CONCURRENCY_SLOT_DEPTH:-4096}
predict=${QWEN_CONCURRENCY_PREDICT:-128}
repeats=${QWEN_CONCURRENCY_REPEATS:-4}
prompt_chars=${QWEN_CONCURRENCY_PROMPT_CHARS:-2048}
passage=${QWEN_CONCURRENCY_PASSAGE:-"$script_directory/../CLAUDE.md"}
nsys_levels=${QWEN_CONCURRENCY_NSYS_LEVELS:-}
nsys_predict=${QWEN_CONCURRENCY_NSYS_PREDICT:-24}
nsys_binary=${QWEN_CONCURRENCY_NSYS:-$(command -v nsys 2>/dev/null || echo /usr/bin/nsys)}
port=${QWEN_CONCURRENCY_PORT:-18160}
lock_clocks=${QWEN_CONCURRENCY_LOCK_CLOCKS:-}
model_root=${QWEN_MODEL_ROOT:-"${HOME:?}/models"}
wrapper=$script_directory/cuda-runtime-env.sh
kernel_reader=$script_directory/read-nsys-mat-mul-kernels.py

for value in $levels; do
    case $value in
        '' | *[!0-9]* | 0) printf 'refused: a concurrency level is a positive integer: %s\n' "$value" >&2; exit 2 ;;
    esac
done
case $slot_depth in '' | *[!0-9]* | 0) usage ;; esac
case $predict in '' | *[!0-9]* | 0) usage ;; esac
case $repeats in '' | *[!0-9]* | 0) usage ;; esac
# Three bursts is the floor a median over repeats needs to be a median rather
# than a midpoint between two observations.
[ "$repeats" -ge 3 ] || { printf 'refused: a per-level median needs at least three bursts\n' >&2; exit 2; }
[ -r "$passage" ] || { printf 'passage file is not readable: %s\n' "$passage" >&2; exit 2; }
if [ -n "$nsys_levels" ]; then
    [ -x "$nsys_binary" ] || { printf 'nsys is unusable: %s\n' "$nsys_binary" >&2; exit 2; }
    [ -x "$kernel_reader" ] || { printf 'kernel reader is unusable: %s\n' "$kernel_reader" >&2; exit 2; }
fi

row=$("$script_directory/model-registry.sh" id "$model_id")
field() { printf '%s\n' "$row" | sed -n "s/^$1=//p"; }
model_path=$model_root/$(field model_file)
cache_type_k=$(field cache_type_k)
cache_type_v=$(field cache_type_v)
flash_attention=$(field flash_attention)
batch=$(field batch)
ubatch=$(field ubatch)
context_ceiling=$(field context_ceiling)
[ -r "$model_path" ] || { printf 'model file is not readable: %s\n' "$model_path" >&2; exit 2; }

# The deepest arm asks for level * slot_depth, and a depth above the registry
# ceiling is a tuple no row admits. The refusal is here rather than at the load,
# because the load would succeed and serve a depth the registry rejects.
deepest=0
for value in $levels; do
    [ "$value" -gt "$deepest" ] && deepest=$value
done
requested_ceiling=$((deepest * slot_depth))
if [ "$requested_ceiling" -gt "$context_ceiling" ]; then
    printf 'refused: %s slots at depth %s asks for %s, above the %s ceiling %s admits\n' \
        "$deepest" "$slot_depth" "$requested_ceiling" "$model_id" "$context_ceiling" >&2
    exit 2
fi

mkdir -p "$output_directory"
scrub_home() { sed "s|${HOME:?}|\$HOME|g"; }
. "$script_directory/gpu-workload-ownership.sh"
gpu_ownership_require >"$output_directory/ownership.txt.raw"
scrub_home <"$output_directory/ownership.txt.raw" >"$output_directory/ownership.txt"
rm -f "$output_directory/ownership.txt.raw"
"$script_directory/gpu-state-latch.sh" require-clear >"$output_directory/gpu-state-latch.txt"
"$script_directory/device-environment-identity.sh" "$output_directory/device-environment.tsv"

# One prompt, cut once, shared by every request of every arm: two arms differing
# in prompt differ in prefill, and prefill is not what a concurrency sweep asks
# about.
prompt_text=$(head -c "$prompt_chars" "$passage" | tr '\n\t"\\' '    ' | sed 's/  */ /g')
printf '%s' "$prompt_text" >"$output_directory/prompt.txt"

server_pid=''
clocks_locked=0
cleanup() {
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
        server_pid=''
    fi
    for raw in "$output_directory"/*.server.log.raw; do
        [ -f "$raw" ] || continue
        scrub_home <"$raw" >"${raw%.raw}"
        rm -f "$raw"
    done
    if [ "$clocks_locked" -eq 1 ]; then
        sudo -n nvidia-smi --reset-gpu-clocks >/dev/null 2>&1 || :
        clocks_locked=0
        printf 'gpu_clocks=released\n'
    fi
}
trap cleanup EXIT HUP INT TERM

if [ -n "$lock_clocks" ]; then
    { sudo -n nvidia-smi --lock-gpu-clocks="$lock_clocks,$lock_clocks"; } \
        >"$output_directory/clock-lock.txt" 2>&1 || {
        printf 'clock lock refused: %s\n' "$(cat "$output_directory/clock-lock.txt")" >&2
        exit 75
    }
    clocks_locked=1
    sleep 2
    printf 'gpu_clocks=locked sm_mhz=%s observed=%s\n' "$lock_clocks" \
        "$(nvidia-smi --query-gpu=clocks.sm --format=csv,noheader,nounits | head -1)" \
        | tee -a "$output_directory/clock-lock.txt"
fi

summary=$output_directory/summary.tsv
: >"$summary"
printf 'model_id\t%s\n' "$model_id" >>"$summary"
printf 'server_sha256\t%s\n' "$(sha256sum "$server_binary" | cut -d' ' -f1)" >>"$summary"
printf 'slot_depth\t%s\n' "$slot_depth" >>"$summary"
printf 'predict\t%s\n' "$predict" >>"$summary"
printf 'repeats\t%s\n' "$repeats" >>"$summary"
printf 'levels\t%s\n' "$levels" >>"$summary"

observations=$output_directory/observations.tsv
printf 'level\trepeat\trequest\tprompt_n\tpredicted_n\tprompt_ms\tpredicted_ms\twindow_s\n' \
    >"$observations"

# The server is started in this shell rather than in a command substitution, so
# its pid is this shell's child and `wait` in the teardown blocks until it has
# left; a pid read back from a subshell is nobody's child here.
serve() {
    # serve LEVEL LOG [PROFILE_PREFIX]; sets server_pid.
    serve_level=$1
    serve_log=$2
    serve_profile=${3:-}
    serve_ctx=$((serve_level * slot_depth))
    if [ -n "$serve_profile" ]; then
        # Node granularity is what puts graph nodes in CUPTI_ACTIVITY_KIND_KERNEL,
        # which is where the mat-mul symbol and its column count are readable at
        # all; graph granularity records the replay as one row and names no
        # kernel inside it.
        "$wrapper" "$nsys_binary" profile \
            --trace=cuda --cuda-graph-trace=node --sample=none --cpuctxsw=none \
            --output "$serve_profile" --force-overwrite true \
            -- "$server_binary" \
            --model "$model_path" --alias "$model_id" --host 127.0.0.1 --port "$port" --no-ui \
            --device CUDA0 --split-mode none --n-gpu-layers all --override-tensor '.*=CUDA0' \
            --fit off --parallel "$serve_level" --threads 6 --threads-batch 6 \
            --ctx-size "$serve_ctx" --batch-size "$batch" --ubatch-size "$ubatch" \
            --cache-type-k "$cache_type_k" --cache-type-v "$cache_type_v" \
            --flash-attn "$flash_attention" \
            --cache-ram 0 --ctx-checkpoints 0 --no-context-shift --no-warmup -lv 10 \
            >"$serve_log" 2>&1 9>&- &
    else
        QWEN_CUDA_PROFILE=default "$wrapper" "$server_binary" \
            --model "$model_path" --alias "$model_id" --host 127.0.0.1 --port "$port" --no-ui \
            --device CUDA0 --split-mode none --n-gpu-layers all --override-tensor '.*=CUDA0' \
            --fit off --parallel "$serve_level" --threads 6 --threads-batch 6 \
            --ctx-size "$serve_ctx" --batch-size "$batch" --ubatch-size "$ubatch" \
            --cache-type-k "$cache_type_k" --cache-type-v "$cache_type_v" \
            --flash-attn "$flash_attention" \
            --cache-ram 0 --ctx-checkpoints 0 --no-context-shift --no-warmup -lv 10 \
            >"$serve_log" 2>&1 9>&- &
    fi
    server_pid=$!
}

# /health answers ahead of the load banner in this build and the model-buffer
# line is an INFO line the default verbosity hides, so the argv sets -lv 10 and
# readiness is the banner itself, bounded.
ready() {
    ready_log=$1
    attempt=0
    while [ "$attempt" -lt 3000 ]; do
        if grep -q 'CUDA0 model buffer size' "$ready_log" && grep -q 'listening on' "$ready_log" &&
            curl --silent --fail "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
            return 0
        fi
        kill -0 "$server_pid" 2>/dev/null || break
        attempt=$((attempt + 1))
        sleep 0.1
    done
    printf 'the server did not become ready with a CUDA0 model buffer\n' >&2
    return 1
}

# The per-slot depth is read out of the server's own load line rather than
# derived from the argv, because `n_ctx / n_seq_max` is the division the claim
# rests on and an argv the server rounded is not what its slots hold.
assert_slot_depth() {
    assert_log=$1
    observed=$(sed -n 's/.*new slot, n_ctx = \([0-9][0-9]*\).*/\1/p' "$assert_log" | head -1)
    [ -n "$observed" ] || { printf 'the server named no slot depth\n' >&2; return 1; }
    [ "$observed" -eq "$slot_depth" ] || {
        printf 'slot depth is %s where the arm asked for %s\n' "$observed" "$slot_depth" >&2
        return 1
    }
    return 0
}

# A burst is N concurrent requests carrying one prompt, one reply length, and
# ignore_eos, so every slot decodes for the whole window and the column count
# the arm names is the column count every pass sees.
burst() {
    burst_level=$1
    burst_predict=$2
    burst_directory=$3
    mkdir -p "$burst_directory"
    burst_index=0
    # Each request pid is collected and waited on by name. A bare `wait` waits
    # for every background child of this shell, and the server is one of them,
    # so it blocks until the server exits rather than until the burst ends.
    burst_pids=''
    burst_start=$(date +%s.%N)
    while [ "$burst_index" -lt "$burst_level" ]; do
        curl --silent --show-error --max-time 600 \
            --header 'Content-Type: application/json' \
            --data "{\"prompt\":\"$prompt_text\",\"n_predict\":$burst_predict,\"temperature\":0,\"ignore_eos\":true,\"stream\":false,\"cache_prompt\":false}" \
            "http://127.0.0.1:$port/completion" \
            >"$burst_directory/request-$burst_index.json" \
            2>"$burst_directory/request-$burst_index.err" &
        burst_pids="$burst_pids $!"
        burst_index=$((burst_index + 1))
    done
    for burst_pid in $burst_pids; do
        wait "$burst_pid" || :
    done
    burst_end=$(date +%s.%N)
    printf '%s\n' "$burst_start $burst_end" >"$burst_directory/window.txt"
}

for level in $levels; do
    level_directory=$output_directory/level-$level
    mkdir -p "$level_directory"
    log=$output_directory/level-$level.server.log.raw
    serve "$level" "$log"
    ready "$log"
    if grep -q 'CPU fallback rejected\|CPU_Mapped model buffer' "$log"; then
        printf 'level %s left a tensor on the host\n' "$level" >&2
        exit 1
    fi
    assert_slot_depth "$log"

    # The warm-up burst is uncounted: a kernel instantiation this process has
    # never launched pays its module load on first use, and every column count
    # in this sweep is a distinct instantiation.
    burst "$level" "$predict" "$level_directory/warmup"

    repeat=1
    while [ "$repeat" -le "$repeats" ]; do
        burst "$level" "$predict" "$level_directory/repeat-$repeat"
        repeat=$((repeat + 1))
    done

    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=''
    # The log is scrubbed here rather than only in the teardown trap. A trap
    # covers every signal that runs it and SIGKILL runs none, so a campaign
    # killed hard leaves whatever logs it had written naming the home directory;
    # scrubbing per level bounds that to the one level still open.
    scrub_home <"$log" >"${log%.raw}"
    rm -f "$log"

    python3 - "$level" "$level_directory" "$repeats" >>"$observations" <<'PY'
import json
import pathlib
import sys

level = int(sys.argv[1])
directory = pathlib.Path(sys.argv[2])
repeats = int(sys.argv[3])
for repeat in range(1, repeats + 1):
    burst = directory / ("repeat-%d" % repeat)
    start, end = (float(value) for value in (burst / "window.txt").read_text().split())
    window = end - start
    for index in range(level):
        record = json.loads((burst / ("request-%d.json" % index)).read_text())
        timings = record["timings"]
        print("\t".join(str(value) for value in (
            level, repeat, index,
            timings["prompt_n"], timings["predicted_n"],
            "%.3f" % timings["prompt_ms"], "%.3f" % timings["predicted_ms"],
            "%.6f" % window)))
PY
    printf 'level=%s served n=%s bursts\n' "$level" "$repeats"
done

# The dispatch read is a second launch per captured level rather than a profiler
# over the throughput arms, because the rates above are what the sweep reports
# and nsys node granularity stretches device time on this device by 2.25% on the
# 2B and 2.10 times on the 0.8B.
for level in $nsys_levels; do
    capture_directory=$output_directory/dispatch-$level
    mkdir -p "$capture_directory"
    log=$output_directory/dispatch-$level.server.log.raw
    serve "$level" "$log" "$capture_directory/capture"
    ready "$log"
    assert_slot_depth "$log"
    burst "$level" "$nsys_predict" "$capture_directory/burst"
    # The server is signalled by pid rather than through the nsys wrapper: the
    # wrapper forwards nothing, so a signal to it leaves the server resident and
    # the report unfinalized.
    served=$(pgrep -P "$server_pid" -x "$(basename "$server_binary")" 2>/dev/null | head -1)
    [ -n "$served" ] && kill -TERM "$served" 2>/dev/null || true
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=''

    "$nsys_binary" export --type sqlite --force-overwrite true \
        --output "$capture_directory/capture.sqlite" \
        "$capture_directory/capture.nsys-rep" \
        >"$capture_directory/export.stdout" 2>"$capture_directory/export.stderr" 9>&- || {
        printf 'dispatch capture at level %s failed to export\n' "$level" >&2
        exit 1
    }
    "$kernel_reader" "$capture_directory/capture.sqlite" \
        >"$capture_directory/mat-mul-kernels.tsv" \
        2>"$capture_directory/mat-mul-kernels.stderr"
    # The raw report and its database are the largest artifacts a run writes and
    # neither is checked in; the symbol table above is what the evidence keeps.
    sha256sum "$capture_directory/capture.nsys-rep" \
        >"$capture_directory/capture.nsys-rep.sha256"
    rm -f "$capture_directory/capture.nsys-rep" "$capture_directory/capture.sqlite"
    printf 'level=%s dispatch captured\n' "$level"
done

python3 - "$observations" "$output_directory/rates.tsv" <<'PY'
import collections
import statistics
import sys

observations, destination = sys.argv[1], sys.argv[2]
bursts = collections.defaultdict(list)
windows = {}
with open(observations) as handle:
    header = next(handle)
    for line in handle:
        (level, repeat, _request, _prompt_n, predicted_n,
         _prompt_ms, predicted_ms, window) = line.rstrip("\n").split("\t")
        key = (int(level), int(repeat))
        bursts[key].append((int(predicted_n), float(predicted_ms)))
        windows[key] = float(window)

# Two rates answer two questions. The aggregate divides every token the burst
# generated by the wall time the burst occupied, which is what a served
# appliance delivers. The per-request rate divides one reply by the server's own
# predicted_ms, which is what one client waits through.
rows = collections.defaultdict(lambda: {"aggregate": [], "per_request": []})
for (level, repeat), requests in bursts.items():
    tokens = sum(count for count, _ in requests)
    rows[level]["aggregate"].append(tokens / windows[(level, repeat)])
    for count, milliseconds in requests:
        rows[level]["per_request"].append(count * 1000.0 / milliseconds)

with open(destination, "w") as handle:
    handle.write("level\taggregate_tok_s_median\tper_request_tok_s_median\t"
                 "aggregate_speedup\tper_request_share\tbursts\n")
    baseline = None
    for level in sorted(rows):
        aggregate = statistics.median(rows[level]["aggregate"])
        per_request = statistics.median(rows[level]["per_request"])
        if baseline is None:
            baseline = (aggregate, per_request)
        handle.write("%d\t%.2f\t%.2f\t%.4f\t%.4f\t%d\n" % (
            level, aggregate, per_request,
            aggregate / baseline[0], per_request / baseline[1],
            len(rows[level]["aggregate"])))
PY

printf 'concurrent_sequence_sweep=complete output=%s\n' "$output_directory"
cat "$output_directory/rates.tsv"
