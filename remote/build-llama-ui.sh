#!/bin/sh
set -eu

# Build the llama.cpp SvelteKit front end and deploy it as static files.
#
# The build needs Node, npm, and roughly a thousand packages; the laptop has
# none of them and should not. This runs on a workstation, pulls the UI sources
# out of the pinned checkout so the front end matches the server that serves it,
# and copies only the built output across. The laptop gains no toolchain and
# starts no second process: llama-server serves the directory through --path.

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    printf 'usage: %s SSH_TARGET [REMOTE_STATIC_DIRECTORY]\n' "$0" >&2
    exit 2
fi

ssh_target=$1
remote_static_directory=${2:-qwen-laptop-setup/webui-llama-ui}
source_directory=${QWEN_UI_SOURCE:-src/llama.cpp-qwen-nvidia/tools/ui}
work_directory=$(mktemp -d)

cleanup() {
    rm -rf "$work_directory"
}
trap cleanup EXIT HUP INT TERM

for required in node npm rsync; do
    command -v "$required" >/dev/null 2>&1 || {
        printf 'this machine needs %s to build the front end\n' "$required" >&2
        exit 1
    }
done

printf 'fetching UI sources from %s:%s\n' "$ssh_target" "$source_directory"
rsync -a -e 'ssh -o BatchMode=yes' \
    "$ssh_target:$source_directory/" "$work_directory/"

printf 'installing dependencies\n'
( cd "$work_directory" && npm ci --no-audit --no-fund >/dev/null )

printf 'building\n'
( cd "$work_directory" && npm run build >/dev/null )

if [ ! -f "$work_directory/dist/index.html" ]; then
    printf 'build produced no dist/index.html\n' >&2
    exit 1
fi

printf 'deploying to %s:%s\n' "$ssh_target" "$remote_static_directory"
rsync -a --delete -e 'ssh -o BatchMode=yes' \
    "$work_directory/dist/" "$ssh_target:$remote_static_directory/"

printf 'deployed; restart the session to serve it\n'
