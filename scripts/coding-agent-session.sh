#!/bin/sh
set -eu

# Run the coding-agent service in the foreground with the checked-in
# authorities. The session owns the environment the service starts under:
# the state directory, the socket path, and the grant key file, each
# overridable for a harness and defaulted for the appliance. The control
# script backgrounds this session and records its identity; the service
# itself validates every authority before it listens.

usage() {
    printf 'usage: %s\n' "$0" >&2
    printf '  QWEN_CODING_STATE_DIRECTORY  default ~/qwen-coding-state\n' >&2
    printf '  QWEN_CODING_GRANT_KEY_FILE   mode-0600 key file, required\n' >&2
    printf '  QWEN_CODING_PRINCIPAL        default qwen-coder\n' >&2
    exit 2
}
[ "$#" -eq 0 ] || usage

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
state_directory=${QWEN_CODING_STATE_DIRECTORY:-"${HOME:?}/qwen-coding-state"}
grant_key_file=${QWEN_CODING_GRANT_KEY_FILE:-}
[ -n "$grant_key_file" ] || {
    printf 'QWEN_CODING_GRANT_KEY_FILE is required\n' >&2
    exit 1
}

mkdir -p "$state_directory"
chmod 700 "$state_directory"

exec python3 "$script_directory/coding-agent-service.py" \
    --state-dir "$state_directory" \
    --socket "$state_directory/agent.sock" \
    --profiles "$script_directory/coding-profiles.tsv" \
    --workspaces "$script_directory/coding-workspaces.tsv" \
    --models "$script_directory/coding-models.tsv" \
    --quarantine "$script_directory/coding-quarantine.tsv" \
    --registry "$script_directory/models.tsv" \
    --runtimes "$script_directory/coding-runtimes.tsv" \
    --grant-key-file "$grant_key_file" \
    --principal "${QWEN_CODING_PRINCIPAL:-qwen-coder}"
