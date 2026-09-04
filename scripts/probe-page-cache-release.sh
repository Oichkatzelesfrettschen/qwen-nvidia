#!/bin/sh
set -eu

# Measure what releasing a checkpoint's page cache after its load buys and
# costs. llama-server reads a GGUF through mmap and copies every tensor to
# CUDA0, and after the load the file's pages stay in the host page cache with
# nothing mapping them: fincore reports the whole 9B resident while the server
# serves from device memory. This probe loads model A, reads the file's
# residency, drops it with posix_fadvise(POSIX_FADV_DONTNEED) on the file
# alone, loads model B, and loads A again, recording around each step the
# resident pages of both files, the Cached and MemAvailable figures, the
# sectors read from the model volume, the major fault count, the time to a
# healthy listener, and the latency of one request. A control arm runs the
# same three loads with the advice step left out, and a second control closes
# the sequence so drift is bounded. /proc/sys/vm/drop_caches is never written:
# the advice names one file and leaves every other page where it is.

usage() {
    printf 'usage: %s SERVER_BINARY OUTPUT_DIRECTORY [MODEL_A_ID] [MODEL_B_ID]\n' "$0" >&2
    printf 'environment: QWEN_MODEL_ROOT default $HOME/models; QWEN_PAGE_CACHE_PORT default 18190\n' >&2
    exit 2
}
[ "$#" -ge 2 ] && [ "$#" -le 4 ] || usage
server_binary=$1
output_directory=$2
model_a=${3:-qwen38-9b-distill}
model_b=${4:-qwen38-2b-distill}
[ -x "$server_binary" ] || usage
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
model_root=${QWEN_MODEL_ROOT:-"${HOME:?}/models"}
port=${QWEN_PAGE_CACHE_PORT:-18190}
wrapper=$script_directory/cuda-runtime-env.sh

if [ -e "$output_directory" ] && [ -n "$(ls -A "$output_directory" 2>/dev/null)" ]; then
    printf 'refused: output directory exists and is not empty: %s\n' "$output_directory" >&2
    exit 2
fi
mkdir -p "$output_directory"
output_directory=$(CDPATH='' cd -- "$output_directory" && pwd)
scrub_home() { sed "s|${HOME:?}|\$HOME|g"; }
for tool in fincore curl python3 nvidia-smi; do
    command -v "$tool" >/dev/null 2>&1 || { printf '%s is absent\n' "$tool" >&2; exit 1; }
done

registry() { "$script_directory/model-registry.sh" id "$1" "$2"; }
path_a=$model_root/$(registry "$model_a" model_file)
path_b=$model_root/$(registry "$model_b" model_file)
[ -r "$path_a" ] && [ -r "$path_b" ] || { printf 'a model file is unreadable\n' >&2; exit 1; }
volume=$(df --output=source "$model_root" | tail -1 | sed 's|^/dev/||')
grep -q " $volume " /proc/diskstats || { printf 'volume %s is absent from /proc/diskstats\n' "$volume" >&2; exit 1; }

summary=$output_directory/summary.tsv
steps=$output_directory/steps.tsv
printf 'server_sha256\t%s\n' "$(sha256sum "$server_binary" | cut -d ' ' -f 1)" >"$summary"
printf 'model_a\t%s\nmodel_b\t%s\n' "$model_a" "$model_b" >>"$summary"
printf 'model_a_bytes\t%s\nmodel_b_bytes\t%s\n' "$(stat -c %s "$path_a")" "$(stat -c %s "$path_b")" >>"$summary"
printf 'volume\t%s\n' "$volume" >>"$summary"
printf 'page_size\t%s\n' "$(getconf PAGE_SIZE)" >>"$summary"
printf 'arm\tstep\tready_s\trequest_s\tprompt_ms\tpredicted_ms\tmaps_while_serving\tresident_a_pages\tresident_b_pages\tcached_kb\tavailable_kb\tsectors_read\tmajor_faults\tadvise_s\n' >"$steps"

server_pid=''
cleanup() {
    status=$?
    if [ -n "$server_pid" ] && kill -0 "$server_pid" 2>/dev/null; then
        kill "$server_pid" 2>/dev/null || :
        wait "$server_pid" 2>/dev/null || :
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

. "$script_directory/gpu-workload-ownership.sh"
gpu_ownership_require >"$output_directory/ownership.txt.raw"
sed -E -e 's|^(cuda_client) pid=[0-9]+ name=([^ ]+).* used=([0-9]+ MiB) .* verdict=(.*)$|\1 name=\2 used=\3 verdict=\4|' \
    -e 's|name=[^ ]*/([^ /]+)|name=\1|' -e 's|^(named_llama_server_pids)=.*$|\1=redacted|' \
    <"$output_directory/ownership.txt.raw" | scrub_home >"$output_directory/ownership.txt"
rm -f "$output_directory/ownership.txt.raw"
"$script_directory/device-environment-identity.sh" "$output_directory/device-environment.tsv"

resident_pages() { fincore --noheadings --raw --output PAGES "$1"; }
meminfo_kb() { awk -v key="$1:" '$1 == key { print $2 }' /proc/meminfo; }
sectors_read() { awk -v dev="$volume" '$3 == dev { print $6 }' /proc/diskstats; }
major_faults() { awk '$1 == "pgmajfault" { print $2 }' /proc/vmstat; }
maps_of() {
    # How many mappings of the file the serving process holds, read from its
    # own maps table; a zero here is what makes the advice reach the pages.
    grep -c -F "$1" "/proc/$2/maps" 2>/dev/null || :
}
now() { date +%s.%N; }
elapsed() { printf '%s %s' "$1" "$2" | awk '{ printf "%.3f", $2 - $1 }'; }

serve() {
    # serve MODEL_ID MODEL_PATH LOG -> sets ready_s request_s prompt_ms predicted_ms maps_while_serving
    serve_id=$1; serve_path=$2; serve_log=$3
    serve_cache_type_k=$(registry "$serve_id" cache_type_k)
    serve_cache_type_v=$(registry "$serve_id" cache_type_v)
    serve_flash_attention=$(registry "$serve_id" flash_attention)
    serve_batch=$(registry "$serve_id" batch)
    serve_ubatch=$(registry "$serve_id" ubatch)
    started=$(now)
    QWEN_CUDA_PROFILE=default "$wrapper" "$server_binary" \
        --model "$serve_path" --alias "$serve_id" --host 127.0.0.1 --port "$port" --no-ui \
        --device CUDA0 --split-mode none --n-gpu-layers all --override-tensor '.*=CUDA0' \
        --fit off --parallel 1 --threads 6 --threads-batch 6 --ctx-size 4096 \
        --batch-size "$serve_batch" --ubatch-size "$serve_ubatch" \
        --cache-type-k "$serve_cache_type_k" --cache-type-v "$serve_cache_type_v" \
        --flash-attn "$serve_flash_attention" \
        --cache-ram 0 --ctx-checkpoints 0 --no-context-shift --no-warmup -lv 10 \
        >"$serve_log" 2>&1 9>&- &
    server_pid=$!
    attempt=0
    until curl --silent --fail "http://127.0.0.1:$port/health" >/dev/null 2>&1; do
        kill -0 "$server_pid" 2>/dev/null || { printf 'server for %s exited during load\n' "$serve_id" >&2; return 1; }
        attempt=$((attempt + 1))
        [ "$attempt" -lt 6000 ] || { printf 'server for %s never became healthy\n' "$serve_id" >&2; return 1; }
        sleep 0.05
    done
    ready_s=$(elapsed "$started" "$(now)")
    grep -q 'CUDA0 model buffer size' "$serve_log" || { printf '%s placed no buffer on CUDA0\n' "$serve_id" >&2; return 1; }
    maps_while_serving=$(maps_of "$serve_path" "$server_pid")
    request_started=$(now)
    reply=$(curl --silent --fail "http://127.0.0.1:$port/completion" -H 'Content-Type: application/json' \
        -d '{"prompt":"The page cache holds","n_predict":16,"temperature":0,"cache_prompt":false}')
    request_s=$(elapsed "$request_started" "$(now)")
    prompt_ms=$(printf '%s' "$reply" | python3 -c 'import json,sys; t=json.load(sys.stdin)["timings"]; print("%.3f" % t["prompt_ms"])')
    predicted_ms=$(printf '%s' "$reply" | python3 -c 'import json,sys; t=json.load(sys.stdin)["timings"]; print("%.3f" % t["predicted_ms"])')
    kill "$server_pid"
    wait "$server_pid" || :
    server_pid=''
    sed -i "s|${HOME:?}|\$HOME|g" "$serve_log"
    return 0
}

advise() {
    # POSIX_FADV_DONTNEED over the whole file; the kernel drops the clean
    # unmapped pages it names and leaves every other page alone.
    python3 - "$1" <<'PY'
import os, sys, time
fd = os.open(sys.argv[1], os.O_RDONLY)
started = time.monotonic()
os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
print("%.3f" % (time.monotonic() - started))
os.close(fd)
PY
}

record() {
    # record ARM STEP ADVISE_S
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$1" "$2" "${ready_s:--}" "${request_s:--}" "${prompt_ms:--}" "${predicted_ms:--}" "${maps_while_serving:--}" \
        "$(resident_pages "$path_a")" "$(resident_pages "$path_b")" "$(meminfo_kb Cached)" "$(meminfo_kb MemAvailable)" \
        "$(sectors_read)" "$(major_faults)" "$3" >>"$steps"
    ready_s=''; request_s=''; prompt_ms=''; predicted_ms=''; maps_while_serving=''
}

for arm in control-1 advise control-2; do
    record "$arm" start -
    serve "$model_a" "$path_a" "$output_directory/$arm-load-a.log"
    record "$arm" load-a -
    case $arm in
        advise)
            advise_s=$(advise "$path_a")
            record "$arm" advise-a "$advise_s"
            ;;
    esac
    serve "$model_b" "$path_b" "$output_directory/$arm-load-b.log"
    record "$arm" load-b -
    serve "$model_a" "$path_a" "$output_directory/$arm-reload-a.log"
    record "$arm" reload-a -
done

# The claim rows: what the advice dropped, and what the reload paid for it.
python3 - "$steps" >>"$summary" <<'PY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1]), delimiter="\t"))
def row(arm, step):
    return next(r for r in rows if r["arm"] == arm and r["step"] == step)
adv = row("advise", "advise-a"); before = row("advise", "load-a")
print("advise_dropped_pages\t%d" % (int(before["resident_a_pages"]) - int(adv["resident_a_pages"])))
print("advise_resident_after\t%s" % adv["resident_a_pages"])
print("advise_cached_delta_kb\t%d" % (int(adv["cached_kb"]) - int(before["cached_kb"])))
print("advise_s\t%s" % adv["advise_s"])
for arm in ("control-1", "advise", "control-2"):
    lb = row(arm, "load-b"); ra = row(arm, "reload-a"); la = row(arm, "load-a")
    print("%s_reload_a_ready_s\t%s" % (arm, ra["ready_s"]))
    print("%s_reload_a_sectors_read\t%d" % (arm, int(ra["sectors_read"]) - int(lb["sectors_read"])))
    print("%s_reload_a_major_faults\t%d" % (arm, int(ra["major_faults"]) - int(lb["major_faults"])))
    print("%s_load_b_ready_s\t%s" % (arm, lb["ready_s"]))
    print("%s_load_b_request_s\t%s" % (arm, lb["request_s"]))
    print("%s_load_a_maps_while_serving\t%s" % (arm, la["maps_while_serving"]))
PY
printf 'page_cache_release=complete output=%s\n' "$(printf '%s' "$output_directory" | scrub_home)"
