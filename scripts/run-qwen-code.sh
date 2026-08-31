#!/bin/sh
set -eu

# Launch the pinned Qwen Code runtime against the local llama-server. The
# wrapper owns the provider environment: it reads the credential from a
# mode-0600 key file, exports QWEN_NVIDIA_LOCAL_API_KEY only into the child,
# removes the ambient provider variables the runtime would otherwise read,
# names the model and the loopback base URL explicitly, and gives the child
# an isolated home directory holding the repository's generated settings, so
# the primary user's own configuration, credentials, and chat state stay
# outside the process. The key travels through the environment alone and
# stays out of argv, status files, and retained logs.
#
# execution_policy in scripts/coding-runtimes.tsv reads `refused`, so this
# wrapper runs only under QWEN_CODE_ALLOW_DIRECT=1 for interactive local use
# against the loopback listener; the coding-agent service is the path a
# browser-approved job takes.

usage() {
    printf 'usage: %s MODEL_ID [ARGUMENT...]\n' "$0" >&2
    printf '  QWEN_CODE_INSTALL_ROOT  default ~/tools/qwen-code\n' >&2
    printf '  QWEN_CODE_STATE_DIR     default ~/qwen-code-state\n' >&2
    printf '  QWEN_CODE_KEY_FILE      mode-0600 credential file, required\n' >&2
    printf '  QWEN_CODE_BASE_URL      default http://127.0.0.1:8080/v1\n' >&2
    exit 2
}

[ "$#" -ge 1 ] || usage
model_id=$1
shift

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
registry=$script_directory/coding-runtimes.tsv
settings_template=$script_directory/qwen-code-settings.json

execution_policy=$(awk -F'\t' '!/^#/ && $1 == "qwen-code" { print $10 }' \
    "$registry")
if [ "$execution_policy" = refused ] &&
    [ "${QWEN_CODE_ALLOW_DIRECT:-0}" != 1 ]; then
    printf 'coding-runtimes.tsv holds qwen-code at execution_policy=refused; ' >&2
    printf 'QWEN_CODE_ALLOW_DIRECT=1 admits an interactive loopback run\n' >&2
    exit 1
fi

install_root=${QWEN_CODE_INSTALL_ROOT:-"${HOME:?}/tools/qwen-code"}
executable_relative=$(awk -F'\t' '!/^#/ && $1 == "qwen-code" { print $9 }' \
    "$registry")
qwen_executable=$install_root/candidate/$executable_relative
[ -x "$qwen_executable" ] || {
    printf 'no executable at %s; run download-qwen-code-v0223.sh first\n' \
        "$qwen_executable" >&2
    exit 1
}

# The model must be one the generated settings define, so a typo fails here
# rather than reaching the runtime's own default provider.
python3 - "$settings_template" "$model_id" <<'EOF' || exit 1
import json, sys
settings = json.load(open(sys.argv[1]))
ids = [entry["id"]
       for provider in settings.get("modelProviders", {}).values()
       for entry in provider]
if sys.argv[2] not in ids:
    print("model %s is not defined in qwen-code-settings.json; defined: %s"
          % (sys.argv[2], ", ".join(ids)), file=sys.stderr)
    raise SystemExit(1)
EOF

base_url=${QWEN_CODE_BASE_URL:-http://127.0.0.1:8080/v1}
case $base_url in
    http://127.0.0.1:*/v1 | http://127.0.0.1/v1 | \
    http://localhost:*/v1 | http://localhost/v1 | \
    'http://[::1]:'*/v1 | 'http://[::1]/v1') : ;;
    *)
        printf 'base URL %s is not a loopback /v1 endpoint\n' "$base_url" >&2
        exit 1
        ;;
esac

key_file=${QWEN_CODE_KEY_FILE:-}
[ -n "$key_file" ] || {
    printf 'QWEN_CODE_KEY_FILE is required\n' >&2
    exit 1
}
[ -f "$key_file" ] || {
    printf 'key file %s is not a regular file\n' "$key_file" >&2
    exit 1
}
key_mode=$(stat -c %a "$key_file")
[ "$key_mode" = 600 ] || {
    printf 'key file %s carries mode %s, required 0600\n' \
        "$key_file" "$key_mode" >&2
    exit 1
}
local_api_key=$(cat "$key_file")
[ -n "$local_api_key" ] || {
    printf 'key file %s is empty\n' "$key_file" >&2
    exit 1
}

# The child's home is a private state directory carrying exactly the
# generated settings, so the runtime reads this repository's configuration
# and writes its own state beside it rather than into the primary home.
state_directory=${QWEN_CODE_STATE_DIR:-"${HOME:?}/qwen-code-state"}
mkdir -p "$state_directory/.qwen"
chmod 700 "$state_directory"
settings_next=$(mktemp "$state_directory/.qwen/settings.json.XXXXXX")
cp "$settings_template" "$settings_next"
mv "$settings_next" "$state_directory/.qwen/settings.json"

# Ambient provider credentials and endpoints stay out of the child; the one
# variable the settings name is exported with the key-file content.
exec env \
    -u OPENAI_API_KEY -u OPENAI_BASE_URL -u OPENAI_MODEL \
    -u DASHSCOPE_API_KEY -u GEMINI_API_KEY -u GOOGLE_API_KEY \
    -u ANTHROPIC_API_KEY -u QWEN_OAUTH_TOKEN \
    HOME="$state_directory" \
    QWEN_NVIDIA_LOCAL_API_KEY="$local_api_key" \
    "$qwen_executable" --model "$model_id" "$@"
