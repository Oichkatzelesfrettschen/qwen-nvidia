#!/bin/sh
set -eu

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/qwen-admission-restore.XXXXXX")
harness=$temporary_directory/remote
fixture_bin=$temporary_directory/bin
output_directory=$temporary_directory/output
process_state_file=$temporary_directory/llama-server.pid
initial_server_pid=''

cleanup() {
    if [ -s "$process_state_file" ]; then
        restored_server_pid=$(sed -n '1p' "$process_state_file")
        kill "$restored_server_pid" 2>/dev/null || true
    fi
    if [ -n "$initial_server_pid" ]; then
        kill "$initial_server_pid" 2>/dev/null || true
        wait "$initial_server_pid" 2>/dev/null || true
    fi
    rm -rf "$temporary_directory"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$harness" "$fixture_bin" "$output_directory"
cp "$script_directory/admit-web-router-fake.sh" \
    "$harness/admit-web-router-fake.sh"
cp /usr/bin/sleep "$temporary_directory/llama-server"
"$temporary_directory/llama-server" 300 &
initial_server_pid=$!
printf '%s\n' "$initial_server_pid" >"$process_state_file"

cat >"$fixture_bin/pgrep" <<'EOF'
#!/bin/sh
set -eu
case " $* " in
    *' -x llama-server '*)
        [ -s "$QWEN_TEST_PROCESS_STATE" ] || exit 1
        sed -n '1p' "$QWEN_TEST_PROCESS_STATE"
        ;;
    *) exit 1 ;;
esac
EOF
cat >"$fixture_bin/curl" <<'EOF'
#!/bin/sh
set -eu
response_file=''
headers_file=''
while [ "$#" -gt 0 ]; do
    case $1 in
        -o) response_file=$2; shift ;;
        -D) headers_file=$2; shift ;;
        --max-time | -X | -H | --data-binary) shift ;;
    esac
    shift
done
printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n' \
    >"$headers_file"
printf '{"data":[{"id":"fixture-model"}]}\n' >"$response_file"
EOF
cat >"$harness/qwen-teardown.sh" <<'EOF'
#!/bin/sh
set -eu
if [ -s "$QWEN_TEST_PROCESS_STATE" ]; then
    process_pid=$(sed -n '1p' "$QWEN_TEST_PROCESS_STATE")
    kill "$process_pid" 2>/dev/null || true
    : >"$QWEN_TEST_PROCESS_STATE"
fi
EOF
cat >"$harness/qwen-launch.sh" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$QWEN_LLAMA_SERVER" >"$QWEN_TEST_RESTORE_SERVER_RECORD"
"$QWEN_LLAMA_SERVER" 300 &
printf '%s\n' "$!" >"$QWEN_TEST_PROCESS_STATE"
EOF
chmod 0755 "$fixture_bin/pgrep" "$fixture_bin/curl" \
    "$harness/admit-web-router-fake.sh" "$harness/qwen-teardown.sh" \
    "$harness/qwen-launch.sh"

registry=$temporary_directory/models.tsv
printf '# model_id\n' >"$registry"
set +e
PATH="$fixture_bin:$PATH" \
QWEN_WEBUI_STATE_DIRECTORY=$temporary_directory/state \
QWEN_TEST_PROCESS_STATE=$process_state_file \
QWEN_TEST_RESTORE_SERVER_RECORD=$temporary_directory/restored-server.path \
QWEN_MODEL_REGISTRY=$registry \
QWEN_LLAMA_SERVER=$temporary_directory/llama-server \
QWEN_ADMISSION_MODEL_ID=absent-model \
    "$harness/admit-web-router-fake.sh" "$output_directory" \
    >"$temporary_directory/admission.stdout" \
    2>"$temporary_directory/admission.stderr"
admission_status=$?
set -e

if [ "$admission_status" -eq 0 ]; then
    printf 'admission fixture accepted an absent model\n' >&2
    exit 1
fi
if ! grep -Fqx "$temporary_directory/llama-server" \
    "$temporary_directory/restored-server.path"; then
    printf 'restoration did not receive the captured server binary\n' >&2
    exit 1
fi
if ! grep -q '^ordinary_restore[[:space:]]*pass' "$output_directory/summary.tsv"; then
    printf 'exit trap did not restore the ordinary router\n' >&2
    cat "$output_directory/summary.tsv" >&2
    exit 1
fi
if [ "$(stat -c %a "$output_directory/http")" != 700 ]; then
    printf 'HTTP capture directory is not private\n' >&2
    exit 1
fi
for capture_file in "$output_directory"/http/*; do
    if [ "$(stat -c %a "$capture_file")" != 600 ]; then
        printf 'HTTP capture is not private: %s\n' "$capture_file" >&2
        exit 1
    fi
done

# A second run against the same state directory refuses while another
# process holds the flock, and runs once the holder has gone; the kernel
# releases the lock with the holder, so no stale claim can remain.
lock_file=$temporary_directory/state/web-admission.lock
flock --close "$lock_file" sleep 300 &
holder_pid=$!
sleep 0.5
set +e
PATH="$fixture_bin:$PATH" \
QWEN_WEBUI_STATE_DIRECTORY=$temporary_directory/state \
QWEN_TEST_PROCESS_STATE=$process_state_file \
QWEN_TEST_RESTORE_SERVER_RECORD=$temporary_directory/restored-server.path \
QWEN_MODEL_REGISTRY=$registry \
QWEN_LLAMA_SERVER=$temporary_directory/llama-server \
QWEN_ADMISSION_MODEL_ID=absent-model \
    "$harness/admit-web-router-fake.sh" "$temporary_directory/locked-output" \
    >"$temporary_directory/locked.stdout" \
    2>"$temporary_directory/locked.stderr"
locked_status=$?
set -e
# flock(1) forks the command, so the sleep is its child and outlives a
# signal to the parent unless it is signalled too.
pkill -P "$holder_pid" 2>/dev/null || true
kill "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true
if [ "$locked_status" -eq 0 ] || \
   ! grep -q 'another admission run holds' "$temporary_directory/locked.stderr"; then
    printf 'a live lock holder did not refuse the second run\n' >&2
    cat "$temporary_directory/locked.stderr" >&2
    exit 1
fi
set +e
PATH="$fixture_bin:$PATH" \
QWEN_WEBUI_STATE_DIRECTORY=$temporary_directory/state \
QWEN_TEST_PROCESS_STATE=$process_state_file \
QWEN_TEST_RESTORE_SERVER_RECORD=$temporary_directory/restored-server.path \
QWEN_MODEL_REGISTRY=$registry \
QWEN_LLAMA_SERVER=$temporary_directory/llama-server \
QWEN_ADMISSION_MODEL_ID=absent-model \
    "$harness/admit-web-router-fake.sh" "$temporary_directory/released-output" \
    >"$temporary_directory/released.stdout" \
    2>"$temporary_directory/released.stderr"
set -e
if grep -q 'another admission run holds' "$temporary_directory/released.stderr"; then
    printf 'the lock outlived its holder\n' >&2
    exit 1
fi

printf 'admit_web_router_fake=accepted restoration=exit-trap,captured-server private_http=accepted lock=flock-live-refused,released-with-holder\n'
