#!/bin/sh
set -eu

# Launch the pinned Qwen Code runtime inside a coding job's containment.
# The coding-agent service executes this script as the qwen-coder
# principal, inside the job worktree, under prlimit and the job deadline;
# the script owns the provider environment the runtime starts with. It
# reads the appliance-local credential from the runtime key file, exports
# QWEN_NVIDIA_LOCAL_API_KEY only into the child, removes the ambient
# provider variables the runtime would otherwise read, forces the loopback
# base URL and the approved model, installs the service-owned settings into
# the worktree-scoped home, and selects the read-only plan approval mode
# for a plan run against the fully automatic mode for an apply run. The
# outer containment -- the principal, the worktree, the resource limits,
# and the uid-scoped egress rule -- remains the security authority; the
# approval mode shapes the runtime's own behavior inside it. The key
# travels through the environment alone and stays out of argv and logs.
#
#   QWEN_CODING_KEY_FILE       mode-0400 or 0600 credential, required
#   QWEN_CODING_SETTINGS       service-owned settings.json, required
#   QWEN_CODING_BASE_URL       loopback /v1 endpoint, required
#   QWEN_CODING_RUNTIME_ROOT   install root holding candidate/, required
#   QWEN_CODING_RUNTIME_EXECUTABLE  overrides the resolved executable

usage() {
    printf 'usage: %s plan|apply MODEL_ID INSTRUCTION\n' "$0" >&2
    exit 2
}
[ "$#" -eq 3 ] || usage
mode=$1
model_id=$2
instruction=$3

case $mode in
plan) approval_mode=plan ;;
apply) approval_mode=yolo ;;
*) usage ;;
esac

key_file=${QWEN_CODING_KEY_FILE:?QWEN_CODING_KEY_FILE is required}
[ -f "$key_file" ] || {
    printf 'runtime key %s is not a regular file\n' "$key_file" >&2
    exit 1
}
key_mode=$(stat -c %a "$key_file")
case $key_mode in
400 | 600) : ;;
*)
    printf 'runtime key %s carries mode %s, required 0400 or 0600\n' \
        "$key_file" "$key_mode" >&2
    exit 1
    ;;
esac
local_api_key=$(cat "$key_file")
[ -n "$local_api_key" ] || {
    printf 'runtime key %s is empty\n' "$key_file" >&2
    exit 1
}

base_url=${QWEN_CODING_BASE_URL:?QWEN_CODING_BASE_URL is required}
case $base_url in
http://127.0.0.1:*/v1 | http://127.0.0.1/v1 | \
    http://localhost:*/v1 | http://localhost/v1 | \
    'http://[::1]:'*/v1 | 'http://[::1]/v1') : ;;
*)
    printf 'base URL %s is not a loopback /v1 endpoint\n' "$base_url" >&2
    exit 1
    ;;
esac

settings=${QWEN_CODING_SETTINGS:?QWEN_CODING_SETTINGS is required}
[ -f "$settings" ] || {
    printf 'settings file %s is absent\n' "$settings" >&2
    exit 1
}

runtime_root=${QWEN_CODING_RUNTIME_ROOT:?QWEN_CODING_RUNTIME_ROOT is required}
qwen_executable=${QWEN_CODING_RUNTIME_EXECUTABLE:-"$runtime_root/candidate/qwen-code/bin/qwen"}
[ -x "$qwen_executable" ] || {
    printf 'no executable at %s\n' "$qwen_executable" >&2
    exit 1
}

# HOME is the job worktree; the runtime's own state lives under its .qwen
# directory there, which the worktree's exclude file keeps out of the
# exported diff. The settings copy lands whole through a rename.
mkdir -p "$HOME/.qwen"
settings_next=$(mktemp "$HOME/.qwen/settings.json.XXXXXX")
cp "$settings" "$settings_next"
mv "$settings_next" "$HOME/.qwen/settings.json"

exec env \
    -u OPENAI_API_KEY -u OPENAI_BASE_URL -u OPENAI_MODEL \
    -u DASHSCOPE_API_KEY -u GEMINI_API_KEY -u GOOGLE_API_KEY \
    -u ANTHROPIC_API_KEY -u QWEN_OAUTH_TOKEN \
    QWEN_NVIDIA_LOCAL_API_KEY="$local_api_key" \
    "$qwen_executable" \
    --model "$model_id" \
    --output-format stream-json \
    --approval-mode "$approval_mode" \
    --prompt "$instruction"
