#!/bin/sh
# Name what ends a llama-server shutdown that a request is still inside.
#
# evidence/lease-coverage/served-admission/ refused candidate closure
# 15bc632adf7f because a terminating signal delivered while a decode pass waited
# on a held compute lease left the server alive past a 30 s bound. Two paths in
# the pinned tree can hold that shutdown and the log separates neither, because
# clean_up() calls llama_backend_free() ahead of the ctx_http.thread join:
# server-queue.cpp:550-575 polls a completion's result at HTTP_POLLING_SECONDS
# and returns when the client disconnects, so an unanswerable request holds its
# HTTP worker and the listener joins its workers before the thread returns; and
# a CUDA teardown under lease contention would end when the holder releases.
# Each arm launches its own server and applies at most one intervention, so the
# pair of interventions is a 2x2 whose filled cell names the path.
#
# evidence/lease-coverage/shutdown-stall/README.md carries the preregistration.
set -eu

usage() {
    cat >&2 <<'USAGE'
usage: probe-lease-shutdown-stall.sh OUTPUT_DIRECTORY [ARM_ID...]

Arms: no_intervention client_disconnect holder_release promoted_in_flight
      candidate_in_flight stack

Environment:
  QWEN_STALL_CANDIDATE_SERVER   llama-server carrying the lease patch
  QWEN_STALL_PROMOTED_SERVER    the promoted llama-server, which reads no lease
  QWEN_STALL_MODEL              the GGUF every arm serves
  QWEN_STALL_PORT               listener port (default 18099)
USAGE
    exit 2
}

[ "$#" -ge 1 ] || usage
case $1 in -h|--help) usage ;; esac

output_directory=$1
shift

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

llama_source_root=${QWEN_LLAMA_SOURCE_ROOT:-$HOME/src/llama.cpp-qwen-nvidia}
candidate_server=${QWEN_STALL_CANDIDATE_SERVER:-$llama_source_root/build-qwen-cuda-15bc632adf7f/bin/llama-server}
promoted_server=${QWEN_STALL_PROMOTED_SERVER:-$llama_source_root/build-qwen-cuda-88681bf4d161/bin/llama-server}
stall_model=${QWEN_STALL_MODEL:-$HOME/models/Qwen3.5-2B-GGUF/Qwen3.5-2B-Q4_K_M.gguf}
stall_port=${QWEN_STALL_PORT:-18099}

for required in "$candidate_server" "$promoted_server" "$stall_model"; do
    if [ ! -r "$required" ]; then
        printf 'probe refused: %s is unreadable\n' "$required" >&2
        exit 1
    fi
done

mkdir -p "$output_directory"
output_directory=$(CDPATH='' cd -- "$output_directory" && pwd)
# A run writes one table for the arms it was asked for and leaves every other
# artifact where it lies, so a second invocation into the same directory would
# put fresh readings beside a previous run's logs and stack under one apparently
# whole record. The readings table is the marker, since the window's own
# preconditions and open log are written into this directory before the probe
# starts.
if [ -e "$output_directory/readings.tsv" ]; then
    printf 'probe refused: %s already carries a probe run
' "$output_directory" >&2
    exit 1
fi
temporary_directory=$(mktemp -d)

# Every retained byte passes this, because a server log names the model path and
# the run directory and the ledger gate refuses a local absolute path. A
# compute client's full argv is elided down to its executable: the desktop
# browsers carry a crash-reporter GUID, a field-trial handle, and a
# pseudonymization salt in theirs, and what this record needs of a client is
# which program it is, what it holds, and how the authority classified it.
sanitize_text() {
    sed -e "s#$temporary_directory#\$STALL_TMPDIR#g" \
        -e "s#$HOME#\$HOME#g" \
        -e "s#$(hostname 2>/dev/null || printf 'qwen-laptop')#qwen-laptop#g" \
        -e 's#[0-9a-fA-F]\{2\}\(:[0-9a-fA-F]\{2\}\)\{5\}#<mac>#g' \
        -e 's#\(cuda_client pid=[0-9]* name=[^ ]*\) .* \(used=\)#\1 argv=<elided> \2#' \
        -e 's#cgroup=[^ ]*#cgroup=<elided>#g'
}

# /proc/uptime carries centiseconds, so this reads to 10 ms. The exit latency
# after a disconnect is compared against a 1 s polling interval, which that
# resolution separates.
monotonic_ms() {
    awk '{ printf "%d\n", $1 * 1000 }' /proc/uptime
}

record() {
    printf '%s\t%s\t%s\n' "$(monotonic_ms)" "$1" "$2" |
        sanitize_text >>"$output_directory/timeline.tsv"
}

reading() {
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" |
        sanitize_text >>"$output_directory/readings.tsv"
}

server_pid=''
client_group=''
client_reaper=''
holder_group=''
holder_reaper=''
server_log=''
arm_id=''
residue_found=no

# One termination for every process this probe starts. Each signal names -s,
# because a bare `kill -1234` parses as a signal specification rather than as
# the process group 1234 and never reaches the kernel. A blocking wait is what
# an ignored signal turns into an unbounded stall, so absence is polled against
# a monotonic deadline and the reap follows the confirmed absence.
terminate_bounded() {
    terminate_target=$1
    terminate_deadline_ms=$2
    terminate_pid=${terminate_target#-}
    kill -s TERM "$terminate_target" 2>/dev/null || true
    terminate_end=$(( $(monotonic_ms) + terminate_deadline_ms ))
    while kill -s 0 "$terminate_target" 2>/dev/null &&
        [ "$(monotonic_ms)" -lt "$terminate_end" ]; do
        sleep 0.1
    done
    if ! kill -s 0 "$terminate_target" 2>/dev/null; then
        wait "$terminate_pid" 2>/dev/null || true
        printf 'terminated\n'
        return 0
    fi
    kill -s KILL "$terminate_target" 2>/dev/null || true
    terminate_end=$(( $(monotonic_ms) + 5000 ))
    while kill -s 0 "$terminate_target" 2>/dev/null &&
        [ "$(monotonic_ms)" -lt "$terminate_end" ]; do
        sleep 0.1
    done
    if ! kill -s 0 "$terminate_target" 2>/dev/null; then
        wait "$terminate_pid" 2>/dev/null || true
        printf 'killed\n'
        return 0
    fi
    printf 'residue\n'
    return 1
}

lease_path=$temporary_directory/compute.lock
: >"$lease_path"

# The holder names its own process group before it blocks, so a signal arriving
# inside the wait has the group to end. setsid makes it a session leader, so its
# pid is that group whether setsid exec'd into it or forked it. Descriptor 9
# carries the probe's own owner-lock claim, so the child closes it before
# reopening 9 for the lease.
start_holder() {
    holder_state=$temporary_directory/holder-state
    holder_ready=$temporary_directory/holder-ready
    : >"$holder_state"
    : >"$holder_ready"
    setsid sh -c 'printf "%s" "$$" >"$2"
        exec 9>"$1"
        flock -x 9
        printf "held" >"$4"
        sleep "$3"' \
        holder "$lease_path" "$holder_state" "$1" "$holder_ready" 9>&- &
    holder_reaper=$!
    holder_named=0
    while [ ! -s "$holder_state" ] && [ "$holder_named" -lt 100 ]; do
        holder_named=$((holder_named + 1))
        sleep 0.1
    done
    [ -s "$holder_state" ] || return 1
    holder_group=$(cat "$holder_state")
    holder_held=0
    while [ ! -s "$holder_ready" ] && [ "$holder_held" -lt 100 ]; do
        holder_held=$((holder_held + 1))
        sleep 0.1
    done
    [ -s "$holder_ready" ] || return 1
    record "$arm_id.holder" "group=$holder_group"
    return 0
}

# The group carries the flock and the launcher is what this shell has to reap,
# and setsid makes them one pid only where it exec'd rather than forked, so both
# are ended. A group that outlived its termination leaves the launcher unreaped
# rather than waited on, because a blocking wait on a live process is the
# unbounded stall every termination here exists to replace, and a signal that
# arrived before the group handshake leaves the launcher pid as the only handle
# there is.
stop_holder() {
    if [ -n "$holder_group" ]; then
        holder_outcome=$(terminate_bounded "-$holder_group" 5000 || true)
        record "$arm_id.holder_release" "$holder_outcome"
        [ "$holder_outcome" = residue ] && residue_found=yes
    else
        holder_outcome=none
    fi
    if [ -n "$holder_reaper" ]; then
        if [ "$holder_outcome" = none ]; then
            holder_launcher=$(terminate_bounded "$holder_reaper" 5000 || true)
            record "$arm_id.holder_launcher" "unnamed_group $holder_launcher"
            [ "$holder_launcher" = residue ] && residue_found=yes
        elif [ "$holder_outcome" != residue ]; then
            wait "$holder_reaper" 2>/dev/null || true
        else
            record "$arm_id.holder_launcher" "left_unreaped pid=$holder_reaper"
        fi
    fi
    holder_reaper=''
    holder_group=''
    return 0
}

# lease_mode: held and free both arm the lease; none names no lease at all,
# which is what the promoted closure reads anyway and what keeps its arm free of
# a variable it cannot honor.
start_server() {
    start_server_binary=$1
    start_server_lease=$2
    server_log=$temporary_directory/$arm_id.server.log
    : >"$server_log"
    if [ "$start_server_lease" = none ]; then
        LLAMA_NO_CPU_FALLBACK=1 \
            "$start_server_binary" --model "$stall_model" \
            --host 127.0.0.1 --port "$stall_port" \
            --device CUDA0 -ot '.*=CUDA0' -ngl 99 \
            >"$server_log" 2>&1 9>&- &
    else
        QWEN_GPU_COMPUTE_LEASE=$lease_path \
        QWEN_VULKAN_WORKLOAD_LOCK=$lease_path \
        QWEN_GPU_COMPUTE_LEASE_WAIT_S=600 \
        LLAMA_NO_CPU_FALLBACK=1 \
            "$start_server_binary" --model "$stall_model" \
            --host 127.0.0.1 --port "$stall_port" \
            --device CUDA0 -ot '.*=CUDA0' -ngl 99 \
            >"$server_log" 2>&1 9>&- &
    fi
    server_pid=$!
    record "$arm_id.server" "pid=$server_pid lease=$start_server_lease"
}

wait_health() {
    wait_health_end=$(( $(monotonic_ms) + $1 * 1000 ))
    while [ "$(monotonic_ms)" -lt "$wait_health_end" ]; do
        if [ -n "$server_pid" ] && ! kill -s 0 "$server_pid" 2>/dev/null; then
            printf 'exited\n'
            return 0
        fi
        if curl -fsS --max-time 2 \
            "http://127.0.0.1:$stall_port/health" >/dev/null 2>&1; then
            printf 'served\n'
            return 0
        fi
        sleep 0.2
    done
    printf 'absent\n'
}

# The client reports its own process group, so ending it signals the curl rather
# than the shell that forked it: the departure this probe measures is the
# connection closing, and a signal that missed curl would leave it open.
start_client() {
    client_timeout=$1
    client_body=$2
    client_state=$temporary_directory/$arm_id.client-state
    client_reply=$temporary_directory/$arm_id.client.json
    : >"$client_state"
    : >"$client_reply"
    setsid sh -c 'printf "%s" "$$" >"$4"
        curl -fsS --max-time "$5" -H "Content-Type: application/json" \
            -d "$3" "$2" >"$1" 2>/dev/null
        printf "%s" "$?" >"$1.status"' \
        client "$client_reply" \
        "http://127.0.0.1:$stall_port/completion" \
        "$client_body" "$client_state" "$client_timeout" 9>&- &
    client_reaper=$!
    client_named=0
    while [ ! -s "$client_state" ] && [ "$client_named" -lt 100 ]; do
        client_named=$((client_named + 1))
        sleep 0.1
    done
    [ -s "$client_state" ] || return 1
    client_group=$(cat "$client_state")
    record "$arm_id.client" "group=$client_group timeout_s=$client_timeout"
    return 0
}

stop_client() {
    if [ -n "$client_group" ]; then
        client_outcome=$(terminate_bounded "-$client_group" 5000 || true)
        record "$arm_id.client_release" "$client_outcome"
        [ "$client_outcome" = residue ] && residue_found=yes
    else
        client_outcome=none
    fi
    if [ -n "$client_reaper" ]; then
        if [ "$client_outcome" = none ]; then
            client_launcher=$(terminate_bounded "$client_reaper" 5000 || true)
            record "$arm_id.client_launcher" "unnamed_group $client_launcher"
            [ "$client_launcher" = residue ] && residue_found=yes
        elif [ "$client_outcome" != residue ]; then
            wait "$client_reaper" 2>/dev/null || true
        else
            record "$arm_id.client_launcher" "left_unreaped pid=$client_reaper"
        fi
    fi
    client_reaper=''
    client_group=''
    return 0
}

# Count rather than match: a log may already carry the pattern from an earlier
# transition of the same server, so the wait is for one more than it held.
wait_log_increase() {
    wait_pattern=$1
    wait_before=$2
    wait_end=$(( $(monotonic_ms) + $3 * 1000 ))
    while [ "$(monotonic_ms)" -lt "$wait_end" ]; do
        if [ "$(grep -c "$wait_pattern" "$server_log" || true)" -gt "$wait_before" ]; then
            printf 'reached\n'
            return 0
        fi
        sleep 0.2
    done
    printf 'absent\n'
}

# The exit latency this returns is measured from the caller's own mark rather
# than from the signal, because each arm marks the event it is timing against.
observe_exit() {
    observe_from=$1
    observe_end=$(( $(monotonic_ms) + $2 * 1000 ))
    while [ "$(monotonic_ms)" -lt "$observe_end" ]; do
        if ! kill -s 0 "$server_pid" 2>/dev/null; then
            printf '%s\n' "$(( $(monotonic_ms) - observe_from ))"
            return 0
        fi
        sleep 0.1
    done
    printf 'alive\n'
}

retain_server_log() {
    [ -f "$server_log" ] || return 0
    sanitize_text <"$server_log" >"$output_directory/$arm_id.server.log"
}

# A server that outlived its arm is ended here rather than left for the next
# arm's port bind, and the outcome is recorded because an escalation is a
# reading of its own. server.cpp's handler exits(1) on a second interrupt after
# printing one line, so a server this function signals a second time did not
# complete an orderly shutdown whatever terminate_bounded reports; the log is
# read for that line and the timeline says so.
end_server() {
    [ -n "$server_pid" ] || return 0
    end_signalled=no
    kill -s 0 "$server_pid" 2>/dev/null && end_signalled=yes
    end_outcome=$(terminate_bounded "$server_pid" 20000 || true)
    end_second=no
    if [ -f "$server_log" ] &&
        grep -q 'Received second interrupt' "$server_log"; then
        end_second=yes
    fi
    record "$arm_id.server_end" \
        "$end_outcome alive_at_cleanup=$end_signalled second_interrupt=$end_second"
    [ "$end_outcome" = residue ] && residue_found=yes
    server_pid=''
}

short_request='{"prompt":"Reply with the word ok.","n_predict":8,"temperature":0}'
long_request='{"prompt":"Count slowly from one to two hundred, one number per line.","n_predict":2048,"temperature":0}'

# Bring one server to the state the arm signals in: a contended arm waits for the
# decode pass to report the lease wait it is to be interrupted in, and an
# in-flight arm waits for the slot to take the task and then lets it decode.
#
# The fixture holder is taken after the load rather than before it, because the
# load path acquires the same lease and a holder present at launch refuses the
# server on its own deadline instead of putting a decode pass behind the lease.
# The served arm reached its holder the same way, on a server already idle.
stage_arm() {
    stage_binary=$1
    stage_lease=$2
    stage_timeout=$3
    start_server "$stage_binary" "$stage_lease"
    stage_health=$(wait_health 180)
    if [ "$stage_health" != served ]; then
        reading "$arm_id" refused "the server did not serve: $stage_health"
        return 1
    fi
    if [ "$stage_lease" = held ]; then
        if ! start_holder 300; then
            reading "$arm_id" refused 'the holder never took the lease'
            return 1
        fi
        stage_before=$(grep -c 'workload lease waiting' "$server_log" || true)
        start_client "$stage_timeout" "$short_request" || {
            reading "$arm_id" refused 'the client never reported its group'
            return 1
        }
        if [ "$(wait_log_increase 'workload lease waiting' "$stage_before" 30)" != reached ]; then
            reading "$arm_id" refused 'the decode pass never reported its lease wait'
            return 1
        fi
    else
        stage_before=$(grep -c 'processing task' "$server_log" || true)
        stage_released=$(grep -c 'slot      release' "$server_log" || true)
        start_client "$stage_timeout" "$long_request" || {
            reading "$arm_id" refused 'the client never reported its group'
            return 1
        }
        if [ "$(wait_log_increase 'processing task' "$stage_before" 30)" != reached ]; then
            reading "$arm_id" refused 'the slot never took the request'
            return 1
        fi
        # The slot has the task; three seconds of decoding puts the signal
        # inside generation rather than inside the launch.
        sleep 3
        # n_predict names a ceiling rather than a floor and the launch line is
        # historical, so the arm asserts the request is still open at the
        # moment it signals: the slot has released nothing since staging began
        # and the client has written no exit status. A request that answered
        # inside those three seconds is the state this arm exists to exclude,
        # and it refuses rather than signalling an idle server.
        if [ "$(grep -c 'slot      release' "$server_log" || true)" -gt "$stage_released" ]; then
            reading "$arm_id" refused 'the request completed before the signal, so nothing was in flight'
            return 1
        fi
        if [ -s "$client_reply.status" ]; then
            reading "$arm_id" refused "the client already ended, status=$(cat "$client_reply.status")"
            return 1
        fi
    fi
    return 0
}

arm_no_intervention() {
    arm_id=no_intervention
    printf 'arm=%s\n' "$arm_id"
    if stage_arm "$candidate_server" held 20; then
        signal_at=$(monotonic_ms)
        kill -s TERM "$server_pid" 2>/dev/null || true
        record "$arm_id.signal" "sent"
        exit_ms=$(observe_exit "$signal_at" 90)
        if [ "$exit_ms" = alive ]; then
            reading "$arm_id" alive_past_90s 'client_timeout_s=20 no intervention'
        else
            reading "$arm_id" "exit_ms_after_signal=$exit_ms" 'client_timeout_s=20 no intervention'
        fi
    fi
    end_server
    stop_client
    stop_holder
    retain_server_log
}

arm_client_disconnect() {
    arm_id=client_disconnect
    printf 'arm=%s\n' "$arm_id"
    if stage_arm "$candidate_server" held 600; then
        signal_at=$(monotonic_ms)
        kill -s TERM "$server_pid" 2>/dev/null || true
        record "$arm_id.signal" "sent"
        bound_state=$(observe_exit "$signal_at" 30)
        reading "$arm_id" "at_30s=$bound_state" 'the bound the served arm refused on'
        if [ "$bound_state" = alive ]; then
            disconnect_at=$(monotonic_ms)
            stop_client
            exit_ms=$(observe_exit "$disconnect_at" 20)
            reading "$arm_id" "exit_ms_after_disconnect=$exit_ms" 'holder still holds the lease'
        fi
    fi
    end_server
    stop_client
    stop_holder
    retain_server_log
}

arm_holder_release() {
    arm_id=holder_release
    printf 'arm=%s\n' "$arm_id"
    if stage_arm "$candidate_server" held 600; then
        signal_at=$(monotonic_ms)
        kill -s TERM "$server_pid" 2>/dev/null || true
        record "$arm_id.signal" "sent"
        bound_state=$(observe_exit "$signal_at" 30)
        reading "$arm_id" "at_30s=$bound_state" 'the bound the served arm refused on'
        if [ "$bound_state" = alive ]; then
            release_at=$(monotonic_ms)
            stop_holder
            exit_ms=$(observe_exit "$release_at" 20)
            reading "$arm_id" "exit_ms_after_holder_release=$exit_ms" 'the client is still connected'
            # The client leaves last, so a server the release did not end is
            # read against the other intervention in the same process rather
            # than escalated on.
            if [ "$exit_ms" = alive ]; then
                disconnect_at=$(monotonic_ms)
                stop_client
                exit_ms=$(observe_exit "$disconnect_at" 20)
                reading "$arm_id" "exit_ms_after_later_disconnect=$exit_ms" 'the lease was already free'
            fi
        fi
    fi
    end_server
    stop_client
    stop_holder
    retain_server_log
}

arm_in_flight() {
    arm_id=$1
    printf 'arm=%s\n' "$arm_id"
    if stage_arm "$2" "$3" 600; then
        signal_at=$(monotonic_ms)
        kill -s TERM "$server_pid" 2>/dev/null || true
        record "$arm_id.signal" "sent"
        bound_state=$(observe_exit "$signal_at" 30)
        reading "$arm_id" "at_30s=$bound_state" "closure=$4 lease=$3 generation in flight"
        if [ "$bound_state" = alive ]; then
            disconnect_at=$(monotonic_ms)
            stop_client
            exit_ms=$(observe_exit "$disconnect_at" 20)
            reading "$arm_id" "exit_ms_after_disconnect=$exit_ms" "closure=$4"
        fi
    fi
    end_server
    stop_client
    retain_server_log
}

# The stack is its own repetition because eu-stack stops the target, so a
# latency measured after it in the same process would carry the stop.
arm_stack() {
    arm_id=stack
    printf 'arm=%s\n' "$arm_id"
    if stage_arm "$candidate_server" held 600; then
        kill -s TERM "$server_pid" 2>/dev/null || true
        record "$arm_id.signal" "sent"
        sleep 10
        if kill -s 0 "$server_pid" 2>/dev/null; then
            stack_file=$output_directory/stack.txt
            # The redirect is this shell's own write into a directory it
            # owns, so sudo covers the debugger alone and the sample lands
            # unprivileged; yama ptrace_scope of 1 admits no sibling tracer,
            # which is why the debugger is the privileged part.
            # shellcheck disable=SC2024
            if sudo -n eu-stack -p "$server_pid" >"$temporary_directory/stack.raw" 2>&1; then
                sanitize_text <"$temporary_directory/stack.raw" >"$stack_file"
                reading "$arm_id" "sampled_at_10s=eu-stack" "frames=$(grep -c '^#' "$stack_file" || true)"
            elif sudo -n gdb -batch -p "$server_pid" -ex 'thread apply all bt' \
                >"$temporary_directory/stack.raw" 2>&1; then
                sanitize_text <"$temporary_directory/stack.raw" >"$stack_file"
                reading "$arm_id" "sampled_at_10s=gdb" "frames=$(grep -c '^#' "$stack_file" || true)"
            else
                sanitize_text <"$temporary_directory/stack.raw" >"$output_directory/stack-refused.txt"
                reading "$arm_id" not_run 'no debugger reached the target'
            fi
        else
            reading "$arm_id" not_run 'the server had already exited at ten seconds'
        fi
    fi
    end_server
    stop_client
    stop_holder
    retain_server_log
}

cleanup_ran=no
cleanup() {
    [ "$cleanup_ran" = no ] || return 0
    cleanup_ran=yes
    # The active arm's log is retained before anything is removed, because an
    # interruption is exactly when the log explains what the readings cannot.
    [ -z "$arm_id" ] || retain_server_log
    end_server
    stop_client
    stop_holder
    if [ "$residue_found" = yes ]; then
        printf 'probe residue: a process outlived its termination, lease %s left in place\n' \
            "$lease_path" >&2
    else
        rm -rf "$temporary_directory"
    fi
    {
        printf 'field\tvalue\n'
        printf 'candidate_server\t%s\n' "$candidate_server"
        printf 'promoted_server\t%s\n' "$promoted_server"
        printf 'model\t%s\n' "$stall_model"
        printf 'http_polling_seconds\t1\n'
        printf 'residue\t%s\n' "$residue_found"
    } | sanitize_text >"$output_directory/summary.tsv"
}
trap 'cleanup' EXIT
trap 'cleanup; exit 143' HUP INT TERM

. "$script_directory/gpu-workload-ownership.sh"
gpu_ownership_require >"$temporary_directory/ownership.raw" || {
    printf 'probe refused: the GPU ownership authority is held elsewhere\n' >&2
    exit 75
}
sanitize_text <"$temporary_directory/ownership.raw" >"$output_directory/ownership.txt"
cat "$output_directory/ownership.txt"

"$script_directory/device-environment-identity.sh" \
    >"$temporary_directory/device.raw" 2>/dev/null || true
sanitize_text <"$temporary_directory/device.raw" >"$output_directory/device-environment.txt"

printf 'arm\treading\tdetail\n' >"$output_directory/readings.tsv"
: >"$output_directory/timeline.tsv"

requested_arms=$*
[ -n "$requested_arms" ] || requested_arms='no_intervention client_disconnect holder_release promoted_in_flight candidate_in_flight stack'

for requested in $requested_arms; do
    case $requested in
        no_intervention)     arm_no_intervention ;;
        client_disconnect)   arm_client_disconnect ;;
        holder_release)      arm_holder_release ;;
        promoted_in_flight)  arm_in_flight promoted_in_flight "$promoted_server" none 88681bf4d161 ;;
        candidate_in_flight) arm_in_flight candidate_in_flight "$candidate_server" free 15bc632adf7f ;;
        stack)               arm_stack ;;
        *) printf 'probe refused: unknown arm %s\n' "$requested" >&2; exit 2 ;;
    esac
done

printf '\n'
cat "$output_directory/readings.tsv"
[ "$residue_found" = no ]
