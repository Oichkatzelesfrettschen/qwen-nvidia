#!/bin/sh
set -eu

# Calibrate each candidate vision reviewer on the device against declared
# fixtures, through the review path the served page uses: the artifact
# listener of scripts/image-service.py answering GET /artifacts/<sha256>.png
# with the Web UI credential, llama-server standalone at the reviewer's
# registry tuple with its own projector, and scripts/image-review.py posting
# one tool-free request per arm. The fixtures are two drawings whose content
# scripts/generate-quality-images.py declares: bars.png meets every
# constraint below by construction and shapes.png meets none of them, so
# run-vision-review-calibration.sh reads pass, fail, uncertain, and the
# refusal of an absent digest against a declaration rather than against a
# judgment.
#
# Residency is sampled at one row per second through the reviewer's load,
# the arms, and its unload, so the device memory a reviewer holds and the
# time it takes to leave are read from the sampler rather than assumed; the
# serialized generate-then-review sequence is designed against those rows.
#
# Every arm is bound to the reviewer it ran on: projector digest, model
# digest, tuple, and the promoted closure's server digest travel as
# --binding fields onto each verdict record and audit line.

usage() {
    printf 'usage: %s OUTPUT_DIRECTORY [REVIEWER_MODEL_ID...]\n' "$0" >&2
    printf '  reviewers default to lfm25-vl-450m qwen35-2b; each needs a projector beside its file\n' >&2
    printf '  QWEN_CALIBRATION_REPEATS sets the repeats per reviewer (default 3)\n' >&2
    printf '  QWEN_LLAMA_BUILD names the closure build directory (default: the promoted row)\n' >&2
    exit 2
}
[ "$#" -ge 1 ] || usage
output_directory=$1
shift
reviewers=${*:-"lfm25-vl-450m qwen35-2b"}
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
source_directory=${QWEN_LLAMA_SOURCE:-"${HOME:?}/src/llama.cpp-qwen-nvidia"}
models_directory=${QWEN_MODELS_DIR:-"${HOME:?}/models"}
repeats=${QWEN_CALIBRATION_REPEATS:-3}
server_port=${QWEN_CALIBRATION_PORT:-18291}
readiness_seconds=${QWEN_CALIBRATION_READINESS_SECONDS:-240}
thread_count=${QWEN_CALIBRATION_THREADS:-1}
registry_script=$script_directory/model-registry.sh

if [ -e "$output_directory" ] && [ -n "$(ls -A "$output_directory" 2>/dev/null)" ]; then
    printf 'refused: output directory exists and is not empty: %s\n' "$output_directory" >&2
    exit 2
fi
mkdir -p "$output_directory"
output_directory=$(CDPATH='' cd -- "$output_directory" && pwd)
# The listener's control socket is an AF_UNIX path under the state directory,
# and an evidence path exceeds the 107-byte bound, so the state lives under the
# runtime directory for the run and leaves with it; both names are scrubbed.
state_directory=${XDG_RUNTIME_DIR:-/tmp}/qwen-review-cal-$$
scrub_home() { sed -e "s|$output_directory|OUT|g" -e "s|$state_directory|STATE|g" -e "s|${HOME:?}|\$HOME|g"; }
listener_pid=
server_pid=
sampler_pid=
listener_started=0
stop_pid() {
    pid=$1
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || :
        wait_iteration=0
        while kill -0 "$pid" 2>/dev/null && [ "$wait_iteration" -lt 90 ]; do
            sleep 1
            wait_iteration=$((wait_iteration + 1))
        done
        kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || :
        wait "$pid" 2>/dev/null || :
    fi
}
# Every exit, a refusal ahead of the first arm and a signal in the middle of
# one alike, stops the children, proves the listener left nothing behind,
# scrubs every retained text, and removes the runtime state with the
# credential in it; the retained directory carries no local path whichever
# way the run ended.
finalize() {
    stop_pid "$server_pid"; server_pid=
    stop_pid "$sampler_pid"; sampler_pid=
    stop_pid "$listener_pid"; listener_pid=
    if [ "$listener_started" -eq 1 ] && [ ! -f "$output_directory/teardown.txt" ]; then
        "$script_directory/image-teardown-check.sh" "$state_directory" >"$output_directory/teardown.txt" 2>&1 || :
    fi
    rm -rf "$state_directory"
    if [ -f "$output_directory/ownership.txt.raw" ]; then
        sed -E -e 's|^(cuda_client) pid=[0-9]+ name=([^ ]+).* used=([0-9]+ MiB) .* verdict=(.*)$|\1 name=\2 used=\3 verdict=\4|' \
            -e 's|name=[^ ]*/([^ /]+)|name=\1|' -e 's|^(named_llama_server_pids)=.*$|\1=redacted|' \
            <"$output_directory/ownership.txt.raw" | scrub_home >"$output_directory/ownership.txt"
        rm -f "$output_directory/ownership.txt.raw"
    fi
    find "$output_directory" -type f \( -name '*.log' -o -name '*.txt' -o -name '*.stdout' -o -name '*.stderr' -o -name 'argv.txt' \) \
        -exec sh -c 'out=$1; state=$2; home=$3; shift 3; for f; do sed -e "s|$out|OUT|g" -e "s|$state|STATE|g" -e "s|$home|\$HOME|g" <"$f" >"$f.scrubbed" && mv "$f.scrubbed" "$f"; done' \
        scrub "$output_directory" "$state_directory" "${HOME:?}" {} +
}
trap 'finalize' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
summary=$output_directory/summary.tsv
record() { printf '%s\t%s\n' "$1" "$2" >>"$summary"; }
: >"$summary"

if [ -z "${QWEN_LLAMA_BUILD:-}" ]; then
    promoted_digest=$(awk -F '\t' '!/^#/ && $1 == "promoted" { print $2 }' "$script_directory/serving-closures.tsv")
    [ -n "$promoted_digest" ] || { printf 'serving-closures.tsv names no promoted closure\n' >&2; exit 1; }
    build_directory=$source_directory/build-qwen-cuda-$promoted_digest
else
    build_directory=$QWEN_LLAMA_BUILD
fi
server_binary=$build_directory/bin/llama-server
[ -x "$server_binary" ] || { printf 'refused: no llama-server under %s\n' "$build_directory/bin" >&2; exit 1; }
record build_directory "$(printf '%s' "$build_directory" | scrub_home)"
record server_sha256 "$(sha256sum "$server_binary" | cut -d ' ' -f 1)"
record repeats "$repeats"

# The fixtures and the constraints they are declared against. bars.png holds
# four bars, the tallest JUN at 150; shapes.png holds a circle, a square, and
# a triangle and no bar chart, so every constraint reads fail there.
artifact_a_source=$script_directory/quality-images/bars.png
artifact_b_source=$script_directory/quality-images/shapes.png
artifact_a=$(sha256sum "$artifact_a_source" | cut -d ' ' -f 1)
artifact_b=$(sha256sum "$artifact_b_source" | cut -d ' ' -f 1)
artifact_absent=$(printf 'no such artifact %s' "$artifact_a" | sha256sum | cut -d ' ' -f 1)
prompt_hash=$(printf 'calibration: a bar chart of four monthly bars whose tallest is JUN at 150' | sha256sum | cut -d ' ' -f 1)
record artifact_a "bars.png $artifact_a"
record artifact_b "shapes.png $artifact_b"
record artifact_absent "$artifact_absent"
record prompt_hash "$prompt_hash"

# The image listener: the service itself, with an empty profile file so no
# job can run, an artifact directory holding the two fixtures under their
# digests, and a credential this harness alone knows.
mkdir -p "$state_directory/images/artifacts"
chmod 700 "$state_directory" "$state_directory/images"
cp "$artifact_a_source" "$state_directory/images/artifacts/$artifact_a.png"
cp "$artifact_b_source" "$state_directory/images/artifacts/$artifact_b.png"
printf '{}\n' >"$state_directory/profiles.json"
api_key_file=$state_directory/api.key
umask 077
head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$api_key_file"
printf '\n' >>"$api_key_file"
chmod 600 "$api_key_file"
umask 022

. "$script_directory/gpu-workload-ownership.sh"
gpu_ownership_require >"$output_directory/ownership.txt.raw" || {
    ownership_status=$?
    cat "$output_directory/ownership.txt.raw" >&2
    exit "$ownership_status"
}
"$script_directory/device-environment-identity.sh" "$output_directory/device-environment.tsv" >/dev/null 2>&1 || :

QWEN_WEBUI_STATE_DIRECTORY=$state_directory python3 "$script_directory/image-service.py" \
    --state-dir "$state_directory" --profiles-json "$state_directory/profiles.json" \
    --api-key-file "$api_key_file" --http-port 0 \
    >"$output_directory/image-service.log" 2>&1 9>&- &
listener_pid=$!
listener_started=1
listener_wait=0
artifact_origin=""
while [ "$listener_wait" -lt 30 ]; do
    listener_port=$(sed -n 's/^listening 127\.0\.0\.1 \([0-9]*\)$/\1/p' "$output_directory/image-service.log" | head -1)
    if [ -n "$listener_port" ]; then
        artifact_origin=http://127.0.0.1:$listener_port
        break
    fi
    kill -0 "$listener_pid" 2>/dev/null || break
    sleep 1
    listener_wait=$((listener_wait + 1))
done
[ -n "$artifact_origin" ] || {
    printf 'refused: the artifact listener did not announce a port\n' >&2
    scrub_home <"$output_directory/image-service.log" >&2
    record verdict "refused listener_absent"
    exit 1
}
record artifact_origin "$artifact_origin"
listener_check=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
    --header "Authorization: Bearer $(sed -n 1p "$api_key_file")" "$artifact_origin/artifacts/$artifact_a.png" || :)
[ "$listener_check" = 200 ] || {
    printf 'refused: the listener answered %s for artifact A\n' "$listener_check" >&2
    record verdict "refused listener_read_$listener_check"
    exit 1
}
record listener_read_a "$listener_check"

wait_ready() {
    ready_iteration=0
    while [ "$ready_iteration" -lt "$readiness_seconds" ]; do
        if ! kill -0 "$2" 2>/dev/null; then
            printf 'refused: the server exited before readiness; see %s\n' "$1/server.log" >&2
            return 1
        fi
        if curl --silent --fail --max-time 2 "http://127.0.0.1:$server_port/health" >/dev/null 2>&1; then
            for placement_line in 'CUDA0 model buffer size' 'CUDA0 KV buffer size' 'CUDA0 compute buffer size'; do
                grep -qF "$placement_line" "$1/server.log" || {
                    printf 'refused: placement missing %s in %s\n' "$placement_line" "$1/server.log" >&2
                    return 1
                }
            done
            return 0
        fi
        ready_iteration=$((ready_iteration + 1))
        sleep 1
    done
    printf 'refused: the server stayed unready for %s seconds\n' "$readiness_seconds" >&2
    return 1
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
memory_stat() {
    # memory_stat CLOCKS_TSV FROM_UTC TO_UTC: max and min memory_used_mib over
    # the rows whose utc column lies strictly between the two boundaries. The
    # sampler and the boundaries share a whole-second spelling, so a row on a
    # boundary second may belong to either state and is left out; a window
    # shorter than three seconds therefore reads zero rows rather than a
    # mixed one.
    awk -F '\t' -v from="$2" -v to="$3" 'NR == 1 { for (i = 1; i <= NF; i++) { if ($i == "memory_used_mib") m = i; if ($i == "utc") e = i } next }
        m && e && $e > from && $e < to { if (max == "" || $m + 0 > max + 0) max = $m; if (min == "" || $m + 0 < min + 0) min = $m; n++ }
        END { printf "max_mib=%s min_mib=%s rows=%d", max, min, n }' "$1"
}

status=0
for reviewer in $reviewers; do
    reviewer_directory=$output_directory/$reviewer
    mkdir -p "$reviewer_directory"
    model_file=$("$registry_script" id "$reviewer" model_file)
    model_path=$models_directory/$model_file
    projector_path=$("$script_directory/select-projector.sh" "$model_path" || :)
    [ -n "$projector_path" ] && [ -f "$projector_path" ] || {
        printf 'refused: no projector beside %s\n' "$model_path" >&2
        record "verdict:$reviewer" "refused projector_absent"
        status=1
        continue
    }
    model_context=$("$registry_script" id "$reviewer" context_default)
    model_batch=$("$registry_script" id "$reviewer" batch)
    model_ubatch=$("$registry_script" id "$reviewer" ubatch)
    model_cache_k=$("$registry_script" id "$reviewer" cache_type_k)
    model_cache_v=$("$registry_script" id "$reviewer" cache_type_v)
    model_flash_attention=$("$registry_script" id "$reviewer" flash_attention)
    tuple_id="$reviewer-cuda-d$model_context-b$model_batch-ub$model_ubatch"
    model_sha256=$(sha256sum "$model_path" | cut -d ' ' -f 1)
    projector_sha256=$(sha256sum "$projector_path" | cut -d ' ' -f 1)
    record "tuple:$reviewer" "$tuple_id cache_k=$model_cache_k cache_v=$model_cache_v flash_attn=$model_flash_attention"
    record "model_sha256:$reviewer" "$model_sha256"
    record "projector_sha256:$reviewer" "$projector_sha256"

    "$script_directory/sample-nvidia-clocks.sh" "$reviewer_directory/clocks.tsv" 1 >/dev/null 2>&1 9>&- &
    sampler_pid=$!
    load_started=$(now_utc)
    load_started_epoch=$(date +%s)
    printf '%s\n' --model "$model_path" --mmproj "$projector_path" --host 127.0.0.1 --port "$server_port" \
        --ctx-size "$model_context" --batch-size "$model_batch" --ubatch-size "$model_ubatch" \
        --cache-type-k "$model_cache_k" --cache-type-v "$model_cache_v" --flash-attn "$model_flash_attention" \
        --device CUDA0 --split-mode none --override-tensor '.*=CUDA0' --fit off --n-gpu-layers all \
        --parallel 1 --threads "$thread_count" --threads-batch "$thread_count" \
        --no-context-shift --offline --log-verbosity 4 >"$reviewer_directory/argv.txt"
    set --
    while IFS= read -r argument; do set -- "$@" "$argument"; done <"$reviewer_directory/argv.txt"
    scrub_home <"$reviewer_directory/argv.txt" >"$reviewer_directory/argv.scrubbed" && mv "$reviewer_directory/argv.scrubbed" "$reviewer_directory/argv.txt"
    env LLAMA_NO_CPU_FALLBACK=1 "LLAMA_MEDIA_MARKER=<__media__>" \
        "$server_binary" "$@" >"$reviewer_directory/server.log" 2>&1 9>&- &
    server_pid=$!
    if ! wait_ready "$reviewer_directory" "$server_pid"; then
        record "verdict:$reviewer" "refused server_unready"
        status=1
        stop_pid "$server_pid"; server_pid=
        stop_pid "$sampler_pid"; sampler_pid=
        continue
    fi
    load_ready=$(now_utc)
    load_ready_epoch=$(date +%s)
    record "load_seconds:$reviewer" "$((load_ready_epoch - load_started_epoch))"
    resident_line=$(grep -o 'CUDA0 model buffer size = *[0-9.]* MiB' "$reviewer_directory/server.log" | head -1)
    record "model_buffer:$reviewer" "${resident_line:-unread}"

    calibration_status=0
    QWEN_API_KEY=$(sed -n 1p "$api_key_file") \
        sh "$script_directory/run-vision-review-calibration.sh" \
        "http://127.0.0.1:$server_port" "$artifact_origin" "$reviewer" \
        "$artifact_a" "$artifact_b" "$artifact_absent" "$prompt_hash" \
        "$reviewer_directory/calibration" --repeat "$repeats" \
        --binding "reviewer=$reviewer" --binding "tuple_id=$tuple_id" \
        --binding "model_sha256=$model_sha256" --binding "projector_sha256=$projector_sha256" \
        --binding "server_sha256=$(sha256sum "$server_binary" | cut -d ' ' -f 1)" \
        --constraint 'four_bars=the image is a bar chart holding exactly four bars' \
        --constraint 'tallest_jun=the tallest bar is the one labeled JUN' \
        --constraint 'axis_150=the vertical axis or the tallest bar is marked 150' \
        >"$reviewer_directory/calibration.log" 2>&1 || calibration_status=$?
    arms_finished=$(now_utc)
    arms_finished_epoch=$(date +%s)
    record "calibration_exit:$reviewer" "$calibration_status"
    [ "$calibration_status" -eq 0 ] || status=1
    tail -n 1 "$reviewer_directory/calibration.log" | scrub_home >"$reviewer_directory/calibration-summary.txt"
    record "calibration:$reviewer" "$(cat "$reviewer_directory/calibration-summary.txt")"

    stop_pid "$server_pid"; server_pid=
    unload_done=$(now_utc)
    unload_done_epoch=$(date +%s)
    # the sampler runs on past the unload so the device's return to its idle
    # occupancy is inside the rows
    sleep 5
    stop_pid "$sampler_pid"; sampler_pid=
    record "residency_load:$reviewer" "$(memory_stat "$reviewer_directory/clocks.tsv" "$load_started" "$load_ready")"
    record "residency_arms:$reviewer" "$(memory_stat "$reviewer_directory/clocks.tsv" "$load_ready" "$arms_finished")"
    record "residency_after_unload:$reviewer" "$(memory_stat "$reviewer_directory/clocks.tsv" "$unload_done" "$(now_utc)")"
    record "unload_seconds:$reviewer" "$((unload_done_epoch - arms_finished_epoch))"
done

stop_pid "$listener_pid"; listener_pid=
teardown_status=0
"$script_directory/image-teardown-check.sh" "$state_directory" >"$output_directory/teardown.txt" 2>&1 || teardown_status=$?
record teardown_exit "$teardown_status"
[ "$teardown_status" -eq 0 ] || status=1
record exit "$status"
grep -v '^fixture:' "$summary" | scrub_home
exit "$status"
