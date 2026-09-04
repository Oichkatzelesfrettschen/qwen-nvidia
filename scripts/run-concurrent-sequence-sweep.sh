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
# `ne11` and picks the mat-mul family from it. That holds only in a pass every
# member of the burst decodes in. A prompt enters the batch its request reaches,
# and `n_batch` bounds how many prompts one pass carries, so a burst whose
# prompts exceed it decodes its first members beside the others' prefill and
# every earlier pass runs below the level's width. The harness therefore
# admits each burst in one of two shapes and reads the shape back from the
# server's own log with read-server-decode-iterations.py rather than assuming
# it: `primed` fills every slot's cache with the prompt ahead of the burst,
# each slot prefilling alone, so the burst evaluates the last four prompt tokens per slot and
# every member reaches its first decode pass together; `cold` sends the prompt
# uncached, which is the shape a served appliance sees. A `primed` burst whose
# log shows a pass below full width, or more than one prefill pass, fails the
# level rather than being averaged in.
#
# `llama_context` sets `cparams.n_ctx_seq = cparams.n_ctx / cparams.n_seq_max`
# (src/llama-context.cpp:293), so a fixed `--ctx-size` across the sweep shrinks
# each slot's depth as 1/N. Each arm asks for `N * QWEN_CONCURRENCY_SLOT_DEPTH`
# and reads the per-slot depth back out of the server's load line. That depth
# is an allocation: the depth attention reads is the prompt plus the reply, so
# the summary carries `filled_depth` beside `slot_depth` and the prompt is cut
# to a token count rather than to a character count, through the server's own
# tokenizer, so a run can fill the slot it allocated by asking for it.
#
# Three rates answer three questions and the summary names each. The
# full-width decode rate divides the tokens of the passes every member decoded
# in by the span of those passes, read from the log, which is the iteration
# cost at exactly N columns. The delivered rate divides every generated token by
# the wall time from the burst's release to its last reply, which is what a
# client population receives. The per-request wait is the server's own
# `prompt_ms` plus `predicted_ms`, which is what one client waits through.

usage() {
    printf 'usage: %s SERVER MODEL_ID OUTPUT_DIRECTORY\n' "$0" >&2
    printf 'environment: QWEN_CONCURRENCY_LEVELS        slot counts, unique, holding 1, default "1 2 4 7 8 10 11"\n' >&2
    printf '             QWEN_CONCURRENCY_SLOT_DEPTH    per-slot allocation, default 4096\n' >&2
    printf '             QWEN_CONCURRENCY_PROMPT_TOKENS prompt length in tokens, default 448\n' >&2
    printf '             QWEN_CONCURRENCY_PREDICT       tokens per request, default 128\n' >&2
    printf '             QWEN_CONCURRENCY_REPEATS       measured bursts per level, default 4\n' >&2
    printf '             QWEN_CONCURRENCY_ADMISSION     primed (default) or cold\n' >&2
    printf '             QWEN_CONCURRENCY_SLOT_OFFSET   first slot id of every burst, default 0; the server serves level + offset slots\n' >&2
    printf '             QWEN_CONCURRENCY_PASSAGE       prose file the prompt is cut from, default CLAUDE.md\n' >&2
    printf '             QWEN_CONCURRENCY_SUBJECT       second closure, paired against SERVER per level\n' >&2
    printf '             QWEN_CONCURRENCY_FLOOR         paired-gain floor, default 0.051\n' >&2
    printf '             QWEN_CONCURRENCY_NSYS_LEVELS   levels to capture the dispatch of, default empty\n' >&2
    printf '             QWEN_CONCURRENCY_NSYS_PREDICT  tokens per captured request, default 24\n' >&2
    printf '             QWEN_CONCURRENCY_NSYS          nsys, default the one on PATH\n' >&2
    printf '             QWEN_CONCURRENCY_PORT          default 18160\n' >&2
    printf '             QWEN_CONCURRENCY_LOCK_CLOCKS   SM MHz to pin through sudo -n nvidia-smi, default unset\n' >&2
    printf '             QWEN_MODEL_ROOT                default $HOME/models\n' >&2
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
prompt_tokens=${QWEN_CONCURRENCY_PROMPT_TOKENS:-448}
predict=${QWEN_CONCURRENCY_PREDICT:-128}
repeats=${QWEN_CONCURRENCY_REPEATS:-4}
admission=${QWEN_CONCURRENCY_ADMISSION:-primed}
slot_offset=${QWEN_CONCURRENCY_SLOT_OFFSET:-0}
# Qwen3.5's linear-attention layers hold a recurrent state the server cannot
# roll back, and server-context.cpp creates a context checkpoint at the prompt
# end only where n_ctx_checkpoints is positive. A primed slot reuses its cache
# by restoring that checkpoint and re-evaluating the last token; with the
# count at zero the same request reprocesses the whole prompt and reads as
# cold. Cold admission keeps the count at zero so no checkpoint copy sits
# inside a measured prefill.
case $admission in
    primed) context_checkpoints=8 ;;
    cold) context_checkpoints=0 ;;
    *) context_checkpoints="" ;;
esac
passage=${QWEN_CONCURRENCY_PASSAGE:-"$script_directory/../CLAUDE.md"}
subject_server=${QWEN_CONCURRENCY_SUBJECT:-}
# NAME=VALUE words exported to the subject arm's server alone, so one closure
# can answer for a switch the library reads from its environment; with a word
# set the subject may name the control's own binary, since the environment is
# then what varies.
subject_environment=${QWEN_CONCURRENCY_SUBJECT_ENV:-}
floor=${QWEN_CONCURRENCY_FLOOR:-0.051}
nsys_levels=${QWEN_CONCURRENCY_NSYS_LEVELS:-}
nsys_predict=${QWEN_CONCURRENCY_NSYS_PREDICT:-24}
nsys_binary=${QWEN_CONCURRENCY_NSYS:-$(command -v nsys 2>/dev/null || echo /usr/bin/nsys)}
port=${QWEN_CONCURRENCY_PORT:-18160}
lock_clocks=${QWEN_CONCURRENCY_LOCK_CLOCKS:-}
model_root=${QWEN_MODEL_ROOT:-"${HOME:?}/models"}
wrapper=$script_directory/cuda-runtime-env.sh
profiler_wrapper=$script_directory/exec-profiler-clean-env.sh
kernel_reader=$script_directory/read-nsys-mat-mul-kernels.py
iteration_reader=$script_directory/read-server-decode-iterations.py
burst_client=$script_directory/concurrent-burst-client.py
telemetry_sampler=$script_directory/sample-nvidia-clocks.sh

refuse() { printf 'refused: %s\n' "$1" >&2; exit 2; }

for value in $levels $nsys_levels; do
    case $value in
        '' | *[!0-9]* | 0) refuse "a concurrency level is a positive integer: $value" ;;
    esac
done
# Every level names one arm and level 1 is the arm every ratio divides by: a
# repeated level would enter the reducer twice under one key, and a sweep
# without 1 would report its smallest level as a 1.0000 that names nothing.
level_count=$(printf '%s\n' $levels | wc -l)
unique_count=$(printf '%s\n' $levels | sort -n | uniq | wc -l)
[ "$level_count" -eq "$unique_count" ] || refuse "QWEN_CONCURRENCY_LEVELS repeats a level: $levels"
printf '%s\n' $levels | grep -qx 1 || refuse "QWEN_CONCURRENCY_LEVELS holds no level 1, the arm every ratio divides by"
levels=$(printf '%s\n' $levels | sort -n | tr '\n' ' ' | sed 's/ $//')
case $slot_depth in '' | *[!0-9]* | 0) usage ;; esac
case $slot_offset in '' | *[!0-9]*) usage ;; esac
case $prompt_tokens in '' | *[!0-9]* | 0) usage ;; esac
case $predict in '' | *[!0-9]* | 0) usage ;; esac
case $repeats in '' | *[!0-9]* | 0) usage ;; esac
case $admission in primed | cold) ;; *) refuse "QWEN_CONCURRENCY_ADMISSION takes primed or cold: $admission" ;; esac
[ "$repeats" -ge 3 ] || refuse "a per-level median needs at least three bursts"
[ -r "$passage" ] || refuse "passage file is not readable: $passage"
# A prompt at or above the slot's depth evicts rather than decodes, and the
# reply has to fit after it.
[ $((prompt_tokens + predict)) -lt "$slot_depth" ] ||
    refuse "prompt $prompt_tokens plus reply $predict does not fit a slot of $slot_depth"
if [ -n "$subject_server" ]; then
    [ -x "$subject_server" ] || refuse "subject closure is unusable: $subject_server"
    [ "$subject_server" != "$server_binary" ] || [ -n "$subject_environment" ] ||
        refuse "the two arms name one closure and no subject environment, so nothing varies"
    for environment_word in $subject_environment; do
        case $environment_word in
        [A-Za-z_]*=*) ;;
        *) refuse "subject environment word is not NAME=VALUE: $environment_word" ;;
        esac
    done
    [ "$repeats" -ge 4 ] || refuse "a paired closure comparison requires at least four repeats"
fi
if [ -n "$nsys_levels" ]; then
    [ -x "$nsys_binary" ] || refuse "nsys is unusable: $nsys_binary"
    [ -x "$kernel_reader" ] || refuse "kernel reader is unusable: $kernel_reader"
    [ -x "$profiler_wrapper" ] || refuse "profiler wrapper is unusable: $profiler_wrapper"
fi
for helper in "$iteration_reader" "$burst_client" "$telemetry_sampler" "$wrapper"; do
    [ -x "$helper" ] || refuse "helper is unusable: $helper"
done
# A run writes into a directory of its own. An existing directory can hold
# another run's paired ratios, subject logs, or dispatch captures that this
# run never rewrites, and a reader could not tell the two apart.
if [ -e "$output_directory" ] && [ -n "$(ls -A "$output_directory" 2>/dev/null)" ]; then
    refuse "output directory exists and is not empty: $output_directory"
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
[ -r "$model_path" ] || refuse "model file is not readable: $model_path"

# The deepest arm asks for level * slot_depth, and a depth above the registry
# ceiling is a tuple no row admits. Both level sets are bounded here, because
# the profiler loop starts a server of its own.
deepest=0
for value in $levels $nsys_levels; do
    [ "$value" -gt "$deepest" ] && deepest=$value
done
requested_ceiling=$(((deepest + slot_offset) * slot_depth))
[ "$requested_ceiling" -le "$context_ceiling" ] ||
    refuse "$deepest slots at depth $slot_depth asks for $requested_ceiling, above the $model_id ceiling $context_ceiling"

# A paired campaign holds both closures resident so the arms can alternate
# inside a repeat, which is what cancels drift between them; two copies of the
# weights beside the desktop's own allocation have to fit the carve-out.
if [ -n "$subject_server" ]; then
    model_bytes=$(stat -c %s "$model_path")
    device_mib=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
    case $device_mib in '' | *[!0-9]*) refuse "device memory is unreadable through nvidia-smi" ;; esac
    if [ $((2 * model_bytes / 1048576)) -gt $((device_mib * 6 / 10)) ]; then
        refuse "two resident copies of $model_id exceed six tenths of the $device_mib MiB device; run the arms as two campaigns"
    fi
fi

mkdir -p "$output_directory"
scrub_home() { sed "s|${HOME:?}|\$HOME|g"; }
# The ownership record keeps what a comparison between runs reads -- the lock
# state, each client's command basename, its device memory, and its verdict --
# and drops the pid, the executable path, the start time, the cgroup, and the
# command line, which name this machine's session rather than a covariate.
scrub_ownership() {
    sed -E \
        -e 's|^(cuda_client) pid=[0-9]+ name=([^ ]+).* used=([0-9]+ MiB) .* verdict=(.*)$|\1 name=\2 used=\3 verdict=\4|' \
        -e 's|name=[^ ]*/([^ /]+)|name=\1|' \
        -e 's|^(named_llama_server_pids)=.*$|\1=redacted|' |
        scrub_home
}
. "$script_directory/gpu-workload-ownership.sh"
gpu_ownership_require >"$output_directory/ownership.txt.raw"
scrub_ownership <"$output_directory/ownership.txt.raw" >"$output_directory/ownership.txt"
rm -f "$output_directory/ownership.txt.raw"
"$script_directory/gpu-state-latch.sh" require-clear >"$output_directory/gpu-state-latch.txt"
"$script_directory/device-environment-identity.sh" "$output_directory/device-environment.tsv"

server_pid=''
subject_pid=''
served_pid=''
profiled_child=''
telemetry_pid=''
clocks_locked=0
cleanup() {
    for cleanup_pid in "$profiled_child" "$server_pid" "$subject_pid"; do
        [ -n "$cleanup_pid" ] || continue
        kill "$cleanup_pid" 2>/dev/null || true
    done
    for cleanup_pid in "$server_pid" "$subject_pid"; do
        [ -n "$cleanup_pid" ] || continue
        wait "$cleanup_pid" 2>/dev/null || true
    done
    profiled_child=''
    server_pid=''
    subject_pid=''
    if [ -n "$telemetry_pid" ]; then
        kill "$telemetry_pid" 2>/dev/null || true
        wait "$telemetry_pid" 2>/dev/null || true
        telemetry_pid=''
    fi
    for raw in "$output_directory"/*.log.raw; do
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
# A signal ends the campaign with a nonzero status rather than returning into
# the loop with the clocks released and the servers gone, so a run cut short
# never prints the completion line.
trap 'cleanup' EXIT
trap 'cleanup; trap - EXIT; exit 129' HUP
trap 'cleanup; trap - EXIT; exit 130' INT
trap 'cleanup; trap - EXIT; exit 143' TERM

# One-second operating-state rows span the whole campaign, and every burst's
# window is retained beside them, so a rate joins to the clock, temperature,
# power, and throttle state it ran under.
"$telemetry_sampler" "$output_directory/telemetry.tsv" 1 9>&- &
telemetry_pid=$!

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
printf 'control_sha256\t%s\n' "$(sha256sum "$server_binary" | cut -d' ' -f1)" >>"$summary"
printf 'control_path\t%s\n' "$(printf '%s' "$server_binary" | scrub_home)" >>"$summary"
if [ -n "$subject_server" ]; then
    printf 'subject_sha256\t%s\n' "$(sha256sum "$subject_server" | cut -d' ' -f1)" >>"$summary"
    printf 'subject_path\t%s\n' "$(printf '%s' "$subject_server" | scrub_home)" >>"$summary"
    printf 'subject_environment\t%s\n' "${subject_environment:--}" >>"$summary"
fi
printf 'slot_depth\t%s\n' "$slot_depth" >>"$summary"
printf 'slot_offset\t%s\n' "$slot_offset" >>"$summary"
printf 'context_checkpoints\t%s\n' "$context_checkpoints" >>"$summary"
printf 'prompt_tokens_requested\t%s\n' "$prompt_tokens" >>"$summary"
printf 'predict\t%s\n' "$predict" >>"$summary"
printf 'filled_depth\t%s\n' $((prompt_tokens + predict)) >>"$summary"
printf 'admission\t%s\n' "$admission" >>"$summary"
printf 'repeats\t%s\n' "$repeats" >>"$summary"
printf 'levels\t%s\n' "$levels" >>"$summary"
printf 'batch\t%s\nubatch\t%s\n' "$batch" "$ubatch" >>"$summary"

observations=$output_directory/observations.tsv
printf 'level\tarm\trepeat\tslot\tprompt_n\tpredicted_n\tprompt_ms\tpredicted_ms\twindow_s\n' \
    >"$observations"
bursts=$output_directory/bursts.tsv
printf 'level\tarm\tburst\twidth\tprefill_passes\tprefill_split\treply_tokens\tdistinct_replies\tfirst_divergence\tdivergence_pass_width\thistory_full_width\tdecode_passes\tfull_width_passes\tfull_width_span_s\n' \
    >"$bursts"

# The server is started in this shell rather than in a command substitution, so
# its pid is this shell's child and `wait` in the teardown blocks until it has
# left; a pid read back from a subshell is nobody's child here.
serve() {
    # serve LEVEL LOG BINARY PORT [PROFILE_PREFIX]; sets served_pid.
    serve_level=$1
    serve_log=$2
    serve_binary=$3
    serve_port=$4
    serve_profile=${5:-}
    serve_environment=${6:-}
    serve_level=$((serve_level + slot_offset))
    serve_ctx=$((serve_level * slot_depth))
    if [ -n "$serve_profile" ]; then
        # The clean-environment wrapper is outermost because Nsight records
        # the capturing process's environment into the report, and the
        # allowlist is what keeps a credential the calling shell exported
        # out of a file that outlives the run on any failure ahead of its
        # deletion. Node granularity is what puts graph nodes in
        # CUPTI_ACTIVITY_KIND_KERNEL, where the mat-mul symbol and its
        # column count are readable at all.
        "$profiler_wrapper" "$nsys_binary" profile \
            --trace=cuda --cuda-graph-trace=node --sample=none --cpuctxsw=none \
            --output "$serve_profile" --force-overwrite true \
            -- env $serve_environment "$wrapper" "$serve_binary" \
            --model "$model_path" --alias "$model_id" --host 127.0.0.1 --port "$serve_port" --no-ui \
            --device CUDA0 --split-mode none --n-gpu-layers all --override-tensor '.*=CUDA0' \
            --fit off --parallel "$serve_level" --threads 6 --threads-batch 6 \
            --ctx-size "$serve_ctx" --batch-size "$batch" --ubatch-size "$ubatch" \
            --cache-type-k "$cache_type_k" --cache-type-v "$cache_type_v" \
            --flash-attn "$flash_attention" \
            --cache-ram 0 --ctx-checkpoints "$context_checkpoints" --no-context-shift --no-warmup -lv 10 \
            >"$serve_log" 2>&1 9>&- &
    else
        # shellcheck disable=SC2086
        env $serve_environment QWEN_CUDA_PROFILE=default "$wrapper" "$serve_binary" \
            --model "$model_path" --alias "$model_id" --host 127.0.0.1 --port "$serve_port" --no-ui \
            --device CUDA0 --split-mode none --n-gpu-layers all --override-tensor '.*=CUDA0' \
            --fit off --parallel "$serve_level" --threads 6 --threads-batch 6 \
            --ctx-size "$serve_ctx" --batch-size "$batch" --ubatch-size "$ubatch" \
            --cache-type-k "$cache_type_k" --cache-type-v "$cache_type_v" \
            --flash-attn "$flash_attention" \
            --cache-ram 0 --ctx-checkpoints "$context_checkpoints" --no-context-shift --no-warmup -lv 10 \
            >"$serve_log" 2>&1 9>&- &
    fi
    served_pid=$!
}

# /health answers ahead of the load banner in this build and the model-buffer
# line is an INFO line the default verbosity hides, so the argv sets -lv 10 and
# readiness is the banner itself, bounded.
ready() {
    ready_log=$1
    ready_pid=$2
    ready_port=$3
    attempt=0
    while [ "$attempt" -lt 3000 ]; do
        if grep -q 'CUDA0 model buffer size' "$ready_log" && grep -q 'listening on' "$ready_log" &&
            curl --silent --fail "http://127.0.0.1:$ready_port/health" >/dev/null 2>&1; then
            return 0
        fi
        kill -0 "$ready_pid" 2>/dev/null || break
        attempt=$((attempt + 1))
        sleep 0.1
    done
    printf 'the server did not become ready with a CUDA0 model buffer\n' >&2
    return 1
}

# Placement is read after the work rather than after the load alone: the load
# line names where the weights sit, and a fallback line names a graph the
# backend refused at run time, which only a burst can provoke.
assert_placement() {
    if grep -q 'CPU fallback rejected\|CPU_Mapped model buffer' "$1"; then
        printf '%s left a tensor or a graph on the host\n' "$2" >&2
        return 1
    fi
    return 0
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

burst() {
    # burst LEVEL PREDICT DIRECTORY PORT
    "$burst_client" --port "$4" --level "$1" --predict "$2" \
        --prompt-tokens "$output_directory/prompt-tokens.json" \
        --output "$3" --admission "$admission" --slot-offset "$slot_offset" \
        >"$3.client.log" 2>&1 || {
        printf 'burst at level %s rejected:\n' "$1" >&2
        cat "$3.client.log" >&2
        return 1
    }
}

stop_server() {
    # stop_server PID_VARIABLE
    eval "stop_pid=\$$1"
    [ -n "${stop_pid:-}" ] || return 0
    kill "$stop_pid" 2>/dev/null || true
    wait "$stop_pid" 2>/dev/null || true
    eval "$1=''"
}

scrub_level_logs() {
    # The log is scrubbed here rather than only in the teardown trap. A trap
    # covers every signal that runs it and SIGKILL runs none, so a campaign
    # killed hard leaves whatever logs it had written naming the home
    # directory; scrubbing per level bounds that to the one level still open.
    for raw in "$@"; do
        [ -f "$raw" ] || continue
        scrub_home <"$raw" >"${raw%.raw}"
        rm -f "$raw"
    done
}

# The prompt is cut in tokens through the server's own tokenizer, once, on the
# level-1 control server, and every request of every arm carries the resulting
# id array. Two arms differing in prompt differ in prefill, and a token count
# is what a filled depth is stated in.
cut_prompt() {
    python3 - "$passage" "$prompt_tokens" "$1" "$output_directory/prompt-tokens.json" <<'PY'
import http.client
import json
import pathlib
import sys

passage, wanted, port, destination = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
text = pathlib.Path(passage).read_text(encoding="utf-8", errors="replace")
connection = http.client.HTTPConnection("127.0.0.1", port, timeout=120)
connection.request("POST", "/tokenize",
                   body=json.dumps({"content": text, "add_special": False}),
                   headers={"Content-Type": "application/json"})
response = connection.getresponse()
payload = json.loads(response.read())
if response.status != 200 or "tokens" not in payload:
    sys.exit("tokenize answered %s: %s" % (response.status, str(payload)[:200]))
ids = payload["tokens"]
if len(ids) < wanted:
    sys.exit("the passage tokenizes to %d tokens, short of the %d asked" % (len(ids), wanted))
pathlib.Path(destination).write_text(json.dumps(ids[:wanted]))
print("prompt_tokens=%d passage_tokens=%d" % (wanted, len(ids)))
PY
}

# One level's server log, read into per-burst composition rows. Under primed
# admission every measured burst has to show one prefill pass and a history
# every member decoded in, because that is the claim the level makes.
read_level_bursts() {
    # read_level_bursts LEVEL ARM LOG
    # The reader runs once into a file whose exit status is checked, since a
    # pipeline's status is awk's and a reader that failed would leave the
    # gate below reading an empty input as an absence of faults. The log has
    # to carry every burst the client sent, the warm-up and one per repeat,
    # so a reader that parsed fewer states that the witness is short rather
    # than that the bursts were clean.
    level_bursts=$output_directory/level-$1.$2.bursts.tsv
    if ! "$iteration_reader" --bursts "$3" >"$level_bursts"; then
        printf 'level %s %s: the iteration reader failed on %s\n' "$1" "$2" "$3" >&2
        return 1
    fi
    measured_bursts=$(awk -F '\t' '$1 == "burst" && $6 > 1 { n++ } END { print n + 0 }' "$level_bursts")
    if [ "$measured_bursts" -ne $((repeats + 1)) ]; then
        printf 'level %s %s: the log holds %s measured bursts where %s were expected\n' \
            "$1" "$2" "$measured_bursts" $((repeats + 1)) >&2
        return 1
    fi
    awk -F '\t' -v level="$1" -v arm="$2" -v OFS='\t' \
        '$1 == "burst" { $1 = ""; print level, arm, substr($0, 2) }' "$level_bursts" >>"$bursts"
    rm -f "$level_bursts"
    if [ "$admission" = primed ]; then
        # The priming requests form their own one-token rows ahead of each
        # burst and are not measured; the warm-up burst is the first measured
        # row and is not held to the claim.
        if "$iteration_reader" --bursts "$3" | awk -F '\t' '
            $1 == "burst" && $6 > 1 { n++; if (n > 1 && ($4 != 1 || $10 != "yes")) bad++ }
            END { exit !(bad > 0) }'
        then
            printf 'level %s %s: a primed burst ran below full width or prefilled in two passes\n' "$1" "$2" >&2
            return 1
        fi
    fi
    return 0
}

subject_port=$((port + 1))
prompt_cut=0
for level in $levels; do
    level_directory=$output_directory/level-$level
    mkdir -p "$level_directory"
    log=$output_directory/level-$level.server.log.raw
    subject_log=$output_directory/level-$level.subject.log.raw
    serve "$level" "$log" "$server_binary" "$port"
    server_pid=$served_pid
    ready "$log" "$server_pid" "$port"
    assert_placement "$log" "level $level control load"
    assert_slot_depth "$log"
    if [ "$prompt_cut" -eq 0 ]; then
        cut_prompt "$port" | tr ' ' '\n' | tr '=' '\t' >>"$summary"
        prompt_cut=1
    fi
    if [ -n "$subject_server" ]; then
        serve "$level" "$subject_log" "$subject_server" "$subject_port" '' "$subject_environment"
        subject_pid=$served_pid
        ready "$subject_log" "$subject_pid" "$subject_port"
        assert_placement "$subject_log" "level $level subject load"
        assert_slot_depth "$subject_log"
    fi

    # The warm-up burst is uncounted: a kernel instantiation this process has
    # never launched pays its module load on first use, and every column count
    # in this sweep is a distinct instantiation.
    burst "$level" "$predict" "$level_directory/warmup" "$port"
    [ -z "$subject_server" ] ||
        burst "$level" "$predict" "$level_directory/warmup-subject" "$subject_port"

    repeat=1
    while [ "$repeat" -le "$repeats" ]; do
        if [ -z "$subject_server" ]; then
            burst "$level" "$predict" "$level_directory/repeat-$repeat" "$port"
        elif [ $((repeat % 2)) -eq 1 ]; then
            # The two closures alternate which one answers first, so drift
            # inside the pair and order bias cancel across repeats the way the
            # MMVQ width campaigns already require of a paired comparison.
            burst "$level" "$predict" "$level_directory/repeat-$repeat" "$port"
            burst "$level" "$predict" "$level_directory/repeat-$repeat-subject" "$subject_port"
        else
            burst "$level" "$predict" "$level_directory/repeat-$repeat-subject" "$subject_port"
            burst "$level" "$predict" "$level_directory/repeat-$repeat" "$port"
        fi
        repeat=$((repeat + 1))
    done

    stop_server server_pid
    stop_server subject_pid
    assert_placement "$log" "level $level control"
    [ -z "$subject_server" ] || assert_placement "$subject_log" "level $level subject"
    scrub_level_logs "$log" "$subject_log"
    read_level_bursts "$level" control "${log%.raw}"
    [ -z "$subject_server" ] || read_level_bursts "$level" subject "${subject_log%.raw}"

    python3 - "$level" "$level_directory" "$repeats" "$([ -n "$subject_server" ] && echo yes || echo no)" >>"$observations" <<'PY'
import json
import pathlib
import sys

level = int(sys.argv[1])
directory = pathlib.Path(sys.argv[2])
repeats = int(sys.argv[3])
paired = sys.argv[4] == "yes"
arms = [("control", "repeat-%d")] + ([("subject", "repeat-%d-subject")] if paired else [])
for repeat in range(1, repeats + 1):
    for arm, pattern in arms:
        burst = directory / (pattern % repeat)
        start, end = (float(value) for value in (burst / "window.txt").read_text().split())
        window = end - start
        # The client files each reply under the slot id it occupied, which
        # starts at the slot offset rather than at zero.
        for path in sorted(burst.glob("request-*.json"), key=lambda p: int(p.stem.split("-")[1])):
            slot = int(path.stem.split("-")[1])
            record = json.loads(path.read_text())
            timings = record["timings"]
            print("\t".join(str(value) for value in (
                level, arm, repeat, slot,
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
    serve "$level" "$log" "$server_binary" "$port" "$capture_directory/capture"
    server_pid=$served_pid
    ready "$log" "$server_pid" "$port"
    # The served child is found now rather than at teardown, so a failure in
    # any step below still terminates the process holding the device and not
    # only the profiler wrapping it, which forwards no signal.
    profiled_child=$(pgrep -P "$server_pid" -x "$(basename "$server_binary")" 2>/dev/null | head -1)
    assert_placement "$log" "dispatch $level load"
    assert_slot_depth "$log"
    burst "$level" "$nsys_predict" "$capture_directory/burst" "$port"
    [ -n "$profiled_child" ] && kill -TERM "$profiled_child" 2>/dev/null || true
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=''
    profiled_child=''
    assert_placement "$log" "dispatch $level"
    scrub_level_logs "$log"
    read_level_bursts "$level" dispatch "${log%.raw}"

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

python3 - "$observations" "$bursts" "$output_directory/rates.tsv" <<'PY'
import collections
import statistics
import sys

observations, bursts_path, destination = sys.argv[1:4]
requests = collections.defaultdict(list)
windows = {}
with open(observations) as handle:
    next(handle)
    for line in handle:
        (level, arm, repeat, _slot, prompt_n, predicted_n,
         prompt_ms, predicted_ms, window) = line.rstrip("\n").split("\t")
        key = (int(level), arm, int(repeat))
        requests[key].append((int(predicted_n), float(prompt_ms), float(predicted_ms)))
        windows[key] = float(window)

# The full-width passes of each measured burst, in file order: the warm-up
# burst is the first row of each (level, arm) and is skipped.
full_width = collections.defaultdict(list)
seen = collections.Counter()
with open(bursts_path) as handle:
    next(handle)
    for line in handle:
        fields = line.rstrip("\n").split("\t")
        level, arm = int(fields[0]), fields[1]
        if arm == "dispatch":
            continue
        seen[(level, arm)] += 1
        if seen[(level, arm)] == 1:
            continue
        width, passes, span = int(fields[3]), int(fields[12]), float(fields[13])
        full_width[(level, arm)].append((width, passes, span))

rows = collections.defaultdict(lambda: collections.defaultdict(list))
for (level, arm, _repeat), members in requests.items():
    tokens = sum(count for count, _p, _d in members)
    rows[(level, arm)]["delivered"].append(tokens / windows[(level, arm, _repeat)])
    for count, prompt_ms, predicted_ms in members:
        rows[(level, arm)]["generation"].append(count * 1000.0 / predicted_ms)
        rows[(level, arm)]["wait"].append((prompt_ms + predicted_ms) / 1000.0)
for key, entries in full_width.items():
    for width, passes, span in entries:
        if passes > 1 and span > 0:
            rows[key]["decode"].append(width * (passes - 1) / span)
            rows[key]["iteration_ms"].append(1000.0 * span / (passes - 1))

with open(destination, "w") as handle:
    handle.write("level\tarm\tfull_width_decode_tok_s\tdecode_iteration_ms\t"
                 "delivered_tok_s\tper_request_generation_tok_s\tper_request_wait_s\t"
                 "decode_speedup\tdelivered_speedup\twait_growth\tbursts\tfull_width_bursts\n")
    baseline = {}
    for level, arm in sorted(rows):
        entry = rows[(level, arm)]
        decode = statistics.median(entry["decode"]) if entry["decode"] else float("nan")
        iteration = statistics.median(entry["iteration_ms"]) if entry["iteration_ms"] else float("nan")
        delivered = statistics.median(entry["delivered"])
        generation = statistics.median(entry["generation"])
        wait = statistics.median(entry["wait"])
        base = baseline.setdefault(arm, (decode, delivered, wait))
        handle.write("%d\t%s\t%.2f\t%.3f\t%.2f\t%.2f\t%.3f\t%.4f\t%.4f\t%.4f\t%d\t%d\n" % (
            level, arm, decode, iteration, delivered, generation, wait,
            decode / base[0], delivered / base[1], wait / base[2],
            len(entry["delivered"]), len(entry["decode"])))
PY

if [ -n "$subject_server" ]; then
    python3 - "$output_directory" "$levels" "$repeats" "$floor" \
        >"$output_directory/paired.tsv" <<'PAIRED'
import json
import pathlib
import statistics
import sys

directory = pathlib.Path(sys.argv[1])
levels = [int(value) for value in sys.argv[2].split()]
repeats = int(sys.argv[3])
floor = float(sys.argv[4])


# return_tokens has to be present and non-empty for the identity comparison to
# mean anything: an absent field reads as one empty list on both closures and
# would report an agreement it never checked. The client already refused a
# burst holding one, so the check here is the reader's own.
def read(burst, level):
    start, end = (float(v) for v in (burst / "window.txt").read_text().split())
    tokens, replies = 0, []
    paths = sorted(burst.glob("request-*.json"), key=lambda p: int(p.stem.split("-")[1]))
    if len(paths) != level:
        sys.exit("%s holds %d replies where the level is %d" % (burst, len(paths), level))
    for path in paths:
        record = json.loads(path.read_text())
        ids = record.get("tokens")
        if not isinstance(ids, list) or not ids:
            raise SystemExit("slot %s in %s returned no token ids" % (slot, burst))
        replies.append(ids)
        tokens += record["timings"]["predicted_n"]
    return tokens / (end - start), replies


# Reply identity is compared slot by slot, because a slot's reply under
# concurrent decoding is a function of its position and two closures are
# compared at the same position.
print("level\tdelivered_ratio_median\tclears_floor\treply_identity\tpairs")
for level in levels:
    level_directory = directory / ("level-%d" % level)
    ratios, identical = [], True
    for repeat in range(1, repeats + 1):
        control_rate, control_replies = read(level_directory / ("repeat-%d" % repeat), level)
        subject_rate, subject_replies = read(level_directory / ("repeat-%d-subject" % repeat), level)
        ratios.append(subject_rate / control_rate)
        if control_replies != subject_replies:
            identical = False
    median = statistics.median(ratios)
    print("%d\t%.4f\t%s\t%s\t%d" % (
        level, median, "yes" if median - 1.0 >= floor else "no",
        "identical" if identical else "diverged", len(ratios)))
PAIRED
    cat "$output_directory/paired.tsv"
fi

printf 'concurrent_sequence_sweep=complete output=%s\n' "$output_directory"
cat "$output_directory/rates.tsv"
