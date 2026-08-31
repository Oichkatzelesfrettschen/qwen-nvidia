#!/bin/sh
set -eu

# End the coding-agent service and prove absence: no service process, no
# socket, no job worktree under the principal's worktree root, and no
# hand-off bundle. Residue exits non-zero and names what survived, the way
# qwen-teardown.sh treats the appliance.

usage() {
    printf 'usage: %s\n' "$0" >&2
    exit 2
}
[ "$#" -eq 0 ] || usage

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
state_directory=${QWEN_CODING_STATE_DIRECTORY:-"${HOME:?}/qwen-coding-state"}
principal_home=${QWEN_CODING_PRINCIPAL_HOME:-/var/lib/qwen-coder}
bundle_directory=${QWEN_CODING_BUNDLE_DIRECTORY:-/tmp/qwen-coding-bundles}

"$script_directory/coding-agent-control.sh" stop || :

# A child that left its process group through a second setsid survives the
# group kill, so teardown ends every process of the principal by uid; the
# account exists for the coding lane alone, which is what makes a uid-wide
# kill exact rather than broad.
principal=${QWEN_CODING_PRINCIPAL:-qwen-coder}
if [ "$principal" != current ] && id "$principal" >/dev/null 2>&1; then
    sudo -n pkill -KILL -u "$principal" 2>/dev/null || :
fi

residue=''
recorded_pid=$(sed -n 's/.*pid=\([0-9]*\).*/\1/p' \
    "$state_directory/session.status" 2>/dev/null || :)
if [ -n "$recorded_pid" ] && kill -0 "$recorded_pid" 2>/dev/null; then
    residue="$residue process=$recorded_pid"
fi
[ ! -e "$state_directory/agent.sock" ] || residue="$residue socket"
worktrees=$(sudo -n ls "$principal_home/worktrees" 2>/dev/null || \
    ls "$principal_home/worktrees" 2>/dev/null || :)
[ -z "$worktrees" ] || residue="$residue worktrees=$worktrees"
bundles=$(ls "$bundle_directory" 2>/dev/null || :)
[ -z "$bundles" ] || residue="$residue bundles=$bundles"

if [ -z "$residue" ]; then
    printf 'coding_teardown=clean\n'
    exit 0
fi
printf 'coding_teardown=residue%s\n' "$residue" >&2
exit 1
