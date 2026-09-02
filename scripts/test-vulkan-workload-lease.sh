#!/bin/sh
# Prove the two writers of the Vulkan workload lease name one file and exclude
# each other. The path check and the patch replay run everywhere; the served
# half needs a patched llama-server and a model it can decode with, and reports
# itself not run where either is absent.
set -eu

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    printf '  QWEN_LEASE_TEST_SERVER names a patched llama-server\n' >&2
    printf '  QWEN_LEASE_TEST_MODEL names a GGUF it can decode with\n' >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repository_directory=$(CDPATH='' cd -- "$script_directory/.." && pwd)
temporary_directory=$(mktemp -d)
server_pid=''
holder_pid=''

cleanup() {
    if [ -n "$server_pid" ] && kill -0 "$server_pid" 2>/dev/null; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    if [ -n "$holder_pid" ] && kill -0 "$holder_pid" 2>/dev/null; then
        kill "$holder_pid" 2>/dev/null || true
    fi
    rm -rf "$temporary_directory"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'FAIL %s\n' "$1" >&2
    exit 1
}

pass() {
    printf 'ok %s\n' "$1"
}

# One file or two locks. The launch chain hands qwen-webui-session.sh's state
# directory to image-service.py as --state-dir and to qwen-capacity-policy.sh as
# QWEN_WEBUI_STATE_DIRECTORY, so the two sides agree exactly when the policy's
# basename equals image-service.py's LEASE_FILE_NAME.
policy_lock_expression=$(sed -n \
    's/^export QWEN_GPU_COMPUTE_LEASE="\$workload_lease_state_directory\/\(.*\)"$/\1/p' \
    "$script_directory/qwen-capacity-policy.sh")
service_lock_name=$(sed -n 's/^LEASE_FILE_NAME = "\(.*\)"$/\1/p' \
    "$script_directory/image-service.py")
if [ -z "$policy_lock_expression" ]; then
    fail 'qwen-capacity-policy.sh exports no workload lock path'
fi
if [ "$policy_lock_expression" != "$service_lock_name" ]; then
    fail "lock basenames differ: policy=$policy_lock_expression service=$service_lock_name"
fi
pass "lock_basename=$service_lock_name shared by the policy and the service"

if ! grep -q 'QWEN_WEBUI_STATE_DIRECTORY=\$state_directory' \
    "$script_directory/qwen-webui-session.sh"; then
    fail 'qwen-webui-session.sh forwards no state directory to the capacity server'
fi
if ! grep -q -- '--state-dir "\$state_directory"' \
    "$script_directory/qwen-webui-session.sh"; then
    fail 'qwen-webui-session.sh hands image-service.py another state directory'
fi
pass 'both writers resolve the lock under the session state directory'

# vulkan-runtime-env.sh scrubs the ambient environment before the exec, so a
# name it unsets would never reach the server.
for lease_variable in QWEN_GPU_COMPUTE_LEASE QWEN_VULKAN_WORKLOAD_LOCK; do
    if grep -q "^unset $lease_variable\$" \
        "$script_directory/vulkan-runtime-env.sh"; then
        fail "vulkan-runtime-env.sh scrubs $lease_variable"
    fi
done
pass 'both lease variable names survive the environment scrub'

# QWEN_GPU_COMPUTE_LEASE is the name and QWEN_VULKAN_WORKLOAD_LOCK is the one the
# candidate patch still reads, so the policy exports both over one file for this
# transition release. Two names resolving to two inodes is the split the rename
# exists to prevent, and gpu_ownership_lease_path refuses it by name.
if ! grep -q '^export QWEN_VULKAN_WORKLOAD_LOCK="\$QWEN_GPU_COMPUTE_LEASE"$' \
    "$script_directory/qwen-capacity-policy.sh"; then
    fail 'the policy exports the two lease names over two values'
fi
pass 'the legacy lease name aliases the new one over one file'

lease_split_stderr=$temporary_directory/lease-split.stderr
: >"$temporary_directory/lease-a"
: >"$temporary_directory/lease-b"
if (
    . "$script_directory/gpu-workload-ownership.sh"
    QWEN_GPU_COMPUTE_LEASE=$temporary_directory/lease-a \
    QWEN_VULKAN_WORKLOAD_LOCK=$temporary_directory/lease-b \
        gpu_ownership_lease_path
) >/dev/null 2>"$lease_split_stderr"; then
    fail 'two lease files resolved without a refusal'
fi
grep -q 'name two files' "$lease_split_stderr" ||
    fail 'the two-lease refusal names no reason'
pass 'two distinct lease paths are refused'

# The lease is bidirectional and bounded in both directions. A holder makes the
# other lane wait for its deadline and then refuse, rather than blocking without
# end. Both arms run against flock(2) on one file with no device, which is the
# same kernel object image-service.py and the patched update_slots take.
contended_lease=$temporary_directory/contended.lease
: >"$contended_lease"
lease_wait_seconds=${QWEN_LEASE_TEST_WAIT_SECONDS:-2}
lease_contention_arm() {
    arm_name=$1
    flock --close "$contended_lease" sleep 6 &
    lease_holder=$!
    arm_attempts=0
    while [ "$arm_attempts" -lt 50 ]; do
        if ! flock -n -x "$contended_lease" true 2>/dev/null; then break; fi
        arm_attempts=$((arm_attempts + 1))
        sleep 0.1
    done
    arm_started=$(date +%s)
    arm_status=0
    flock -x -w "$lease_wait_seconds" "$contended_lease" true || arm_status=$?
    arm_elapsed=$(( $(date +%s) - arm_started ))
    kill "$lease_holder" 2>/dev/null || true
    wait "$lease_holder" 2>/dev/null || true
    if [ "$arm_status" -ne 0 ] && [ "$arm_elapsed" -ge "$lease_wait_seconds" ] &&
        [ "$arm_elapsed" -lt 6 ]; then
        pass "$arm_name waits its deadline and then refuses"
    else
        fail "$arm_name status=$arm_status elapsed=${arm_elapsed}s"
    fi
}
lease_contention_arm 'an llama workload against a held image lease'
lease_contention_arm 'an image generation against a held llama lease'

# The lease releases with its holder, so the other lane proceeds at once.
flock --close "$contended_lease" sleep 1 &
release_holder=$!
wait "$release_holder" 2>/dev/null || true
flock -n -x "$contended_lease" true ||
    fail 'the lease stayed held after its holder exited'
pass 'a released lease admits the other lane'


candidate_report=$temporary_directory/candidate-patches.log
if ! QWEN_LLAMA_CANDIDATE_PATCHES=1 \
    "$script_directory/verify-llama-patch-series.sh" \
    >"$candidate_report" 2>&1; then
    cat "$candidate_report" >&2
    fail 'the candidate patch series failed to replay'
fi
if ! grep -q '^candidate_patch=llama-server-vulkan-workload-lease.patch applies=yes$' \
    "$candidate_report"; then
    fail 'the workload lease patch is absent from the candidate stage'
fi
patch_digest=$(sha256sum \
    "$repository_directory/patches/llama-server-vulkan-workload-lease.patch" |
    cut -d ' ' -f 1)
pass "patch_applies=yes sha256=$patch_digest"

llama_server=${QWEN_LEASE_TEST_SERVER:-}
model_path=${QWEN_LEASE_TEST_MODEL:-}
if [ -z "$llama_server" ] || [ ! -x "$llama_server" ]; then
    printf 'served_lease=not_run reason=QWEN_LEASE_TEST_SERVER_unset_or_not_executable\n'
    exit 0
fi
if [ -z "$model_path" ] || [ ! -r "$model_path" ]; then
    printf 'served_lease=not_run reason=QWEN_LEASE_TEST_MODEL_unset_or_unreadable\n'
    exit 0
fi

state_directory=$temporary_directory/state
mkdir -p "$state_directory"
lock_path=$state_directory/$service_lock_name
server_log=$temporary_directory/server.log
server_port=${QWEN_LEASE_TEST_PORT:-18471}
hold_seconds=${QWEN_LEASE_TEST_HOLD_SECONDS:-6}

QWEN_GPU_COMPUTE_LEASE=$lock_path QWEN_VULKAN_WORKLOAD_LOCK=$lock_path \
    "$llama_server" \
    --model "$model_path" \
    --host 127.0.0.1 \
    --port "$server_port" \
    --ctx-size 256 \
    --threads 2 \
    --no-webui \
    >"$server_log" 2>&1 &
server_pid=$!

attempt=0
while [ "$attempt" -lt 120 ]; do
    if curl -s -m 2 "http://127.0.0.1:$server_port/health" |
        grep -q '"status":"ok"'; then
        break
    fi
    attempt=$((attempt + 1))
    sleep 1
done
if [ "$attempt" -ge 120 ]; then
    cat "$server_log" >&2
    fail 'the server never reported health'
fi

if ! grep -q "vulkan workload lease armed: path=$lock_path" "$server_log"; then
    cat "$server_log" >&2
    fail 'the server armed no lease for the named path'
fi
pass 'the server arms the lease at startup'

# A loaded server that decodes nothing holds nothing, which is the residency
# exception the invariant states.
if ! flock -n -x "$lock_path" true; then
    fail 'an idle loaded server holds the lease'
fi
pass 'an idle loaded server leaves the lease free'

holder_started=$temporary_directory/holder.started
(
    flock -x 9
    : >"$holder_started"
    sleep "$hold_seconds"
) 9>"$lock_path" &
holder_pid=$!

attempt=0
while [ ! -f "$holder_started" ] && [ "$attempt" -lt 100 ]; do
    attempt=$((attempt + 1))
    sleep 0.1
done
if [ ! -f "$holder_started" ]; then
    fail 'the competing holder never took the lease'
fi

completion_body=$temporary_directory/completion.json
request_started=$(date +%s)
curl -s -m 300 -o "$completion_body" \
    -H 'Content-Type: application/json' \
    -d '{"prompt":"lease","n_predict":4,"temperature":0}' \
    "http://127.0.0.1:$server_port/completion" ||
    fail 'the completion request failed'
request_finished=$(date +%s)
elapsed_seconds=$((request_finished - request_started))

wait "$holder_pid" 2>/dev/null || true
holder_pid=''

if [ "$elapsed_seconds" -lt "$hold_seconds" ]; then
    fail "the reply arrived in ${elapsed_seconds}s while the holder kept the lease for ${hold_seconds}s"
fi
pass "the reply waits for the holder: elapsed=${elapsed_seconds}s hold=${hold_seconds}s"

if ! grep -q "vulkan workload lease waiting: path=$lock_path" "$server_log"; then
    cat "$server_log" >&2
    fail 'the server logged no wait while it was blocked'
fi
# The path carries slashes, so the substitution takes another delimiter.
waited_ms=$(sed -n \
    "s|.*vulkan workload lease acquired: path=$lock_path waited_ms=\([0-9]*\).*|\1|p" \
    "$server_log" | sed -n '1p')
if [ -z "$waited_ms" ]; then
    cat "$server_log" >&2
    fail 'the server logged no acquire line'
fi
minimum_waited_ms=$(((hold_seconds - 1) * 1000))
if [ "$waited_ms" -lt "$minimum_waited_ms" ]; then
    fail "the acquire reports waited_ms=$waited_ms below $minimum_waited_ms"
fi
pass "the acquire names the wait: waited_ms=$waited_ms"

if ! grep -q '"content"' "$completion_body"; then
    cat "$completion_body" >&2
    fail 'the completion carries no content'
fi
pass 'the completion answers after the lease is taken'

attempt=0
while [ "$attempt" -lt 100 ]; do
    if grep -q "vulkan workload lease released: path=$lock_path" "$server_log" &&
        flock -n -x "$lock_path" true; then
        break
    fi
    attempt=$((attempt + 1))
    sleep 0.2
done
if [ "$attempt" -ge 100 ]; then
    cat "$server_log" >&2
    fail 'the lease stayed held after the last slot went idle'
fi
pass 'the lease returns once every slot is idle'

printf 'served_lease=admitted waited_ms=%s elapsed_s=%s\n' \
    "$waited_ms" "$elapsed_seconds"
