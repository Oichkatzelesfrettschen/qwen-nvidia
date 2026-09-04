#!/bin/sh
set -eu

# Prove the physics lane left nothing behind: no physics-service.py process,
# no physx-rigid-runtime process, no socket, and a free compute lease under the
# state directory. Exit 1 on residue and name it.

usage() {
    printf 'usage: %s [STATE_DIRECTORY]\n' "$0" >&2
    exit 2
}
[ "$#" -le 1 ] || usage
state_directory=${1:-"${HOME:?}/qwen-webui-state"}
residue=0
# The process names are matched on the comm field alone, so this script's own
# command line is never a match.
for name in physics-service.py physx-rigid-runtime; do
    if pgrep -x "$(printf '%s' "$name" | cut -c1-15)" >/dev/null 2>&1; then
        printf 'physics_teardown=residue process=%s\n' "$name" >&2
        residue=1
    fi
done
if [ -S "$state_directory/physics-service.sock" ]; then
    printf 'physics_teardown=residue socket=%s\n' "$state_directory/physics-service.sock" >&2
    residue=1
fi
lease=$state_directory/vulkan-workload.lock
if [ -e "$lease" ]; then
    if ! flock -n "$lease" true 2>/dev/null; then
        printf 'physics_teardown=residue lease=held\n' >&2
        residue=1
    fi
fi
[ "$residue" -eq 0 ] || exit 1
printf 'physics_teardown=clean state_directory=%s\n' "$state_directory"
