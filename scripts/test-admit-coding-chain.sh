#!/bin/sh
set -eu

# Run the coding-chain admission harness on the workstation against its
# fixtures: the fake router stands in for llama-server, the fake coding
# agent for the pinned Qwen Code runtime, and the broker, the coding MCP
# child, the coding-agent service, the grant chain, the worktree
# lifecycle, and the teardown are the tree's own. The page arm runs where
# chromium is installed and reports not-run otherwise.

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
work_directory=$(mktemp -d "${TMPDIR:-/tmp}/admit-coding-chain.XXXXXX")
trap 'rm -rf "$work_directory"' EXIT INT TERM

page_arm=1
command -v chromium >/dev/null 2>&1 || page_arm=0

QWEN_CODING_PAGE_ARM=$page_arm \
QWEN_CODING_SERVER_PORT=${QWEN_CODING_SERVER_PORT:-8131} \
QWEN_CODING_BROKER_PORT=${QWEN_CODING_BROKER_PORT:-8631} \
    sh "$script_directory/admit-coding-chain.sh" "$work_directory/run"
