#!/bin/sh
set -eu

# A projector fetched for one checkpoint can load beside another checkpoint and
# silently corrupt image embeddings. This fixture runs the real launch script
# against two fake downloaders and proves the registry-selected downloader is
# the only one invoked and the resulting projector reaches the control layer.

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
temporary_directory=$(mktemp -d)
cleanup() {
    rm -rf -- "$temporary_directory"
}
trap cleanup EXIT HUP INT TERM

fixture_scripts=$temporary_directory/remote
fixture_bin=$temporary_directory/bin
model_directory=$temporary_directory/models/matched
state_directory=$temporary_directory/state
mkdir -p "$fixture_scripts" "$fixture_bin" "$model_directory" "$state_directory"
cp "$script_directory/qwen-launch.sh" "$fixture_scripts/qwen-launch.sh"
chmod +x "$fixture_scripts/qwen-launch.sh"
# qwen-launch.sh runs gpu-state-latch.sh require-clear from its own directory
# before anything else, so the fixture carries the latch beside it; a fresh
# state directory holds no recorded failure, so the check admits the launch.
cp "$script_directory/gpu-state-latch.sh" "$fixture_scripts/gpu-state-latch.sh"

model_path=$model_directory/model.gguf
: >"$model_path"

cat >"$fixture_scripts/model-registry.sh" <<'SCRIPT'
#!/bin/sh
set -eu
if [ "$#" -eq 3 ] && [ "$1" = path ] &&
   [ "$3" = projector_fetch_script ]; then
    printf 'download-matched-mmproj.sh\n'
    exit 0
fi
exit 1
SCRIPT

cat >"$fixture_scripts/select-projector.sh" <<'SCRIPT'
#!/bin/sh
set -eu
model_directory=$(dirname -- "$1")
[ -f "$model_directory/mmproj-matched.gguf" ] &&
    printf '%s\n' "$model_directory/mmproj-matched.gguf"
SCRIPT

cat >"$fixture_scripts/download-matched-mmproj.sh" <<'SCRIPT'
#!/bin/sh
set -eu
: >"$1/mmproj-matched.gguf"
: >"${QWEN_TEST_MATCHED_DOWNLOADER:?}"
SCRIPT

cat >"$fixture_scripts/download-qwen35-4b-mmproj.sh" <<'SCRIPT'
#!/bin/sh
set -eu
: >"${QWEN_TEST_WRONG_DOWNLOADER:?}"
SCRIPT

cat >"$fixture_scripts/qwen-webui-control.sh" <<'SCRIPT'
#!/bin/sh
set -eu
mkdir -p "${QWEN_WEBUI_STATE_DIRECTORY:?}"
printf 'state=running model=%s projector=%s\n' \
    "${QWEN_MODEL_PATH:?}" "${QWEN_MMPROJ:?}" \
    >"$QWEN_WEBUI_STATE_DIRECTORY/session.status"
SCRIPT

cat >"$fixture_scripts/qwen-teardown.sh" <<'SCRIPT'
#!/bin/sh
exit 0
SCRIPT

cat >"$fixture_bin/pgrep" <<'SCRIPT'
#!/bin/sh
exit 1
SCRIPT

cat >"$fixture_bin/curl" <<'SCRIPT'
#!/bin/sh
exit 0
SCRIPT

chmod +x "$fixture_scripts"/*.sh "$fixture_bin"/*

matched_downloader_marker=$temporary_directory/matched-downloader
wrong_downloader_marker=$temporary_directory/wrong-downloader
QWEN_MODEL_PATH=$model_path QWEN_FETCH_MMPROJ=1 \
QWEN_WEBUI_STATE_DIRECTORY=$state_directory QWEN_READY_ATTEMPTS=1 \
QWEN_TEST_MATCHED_DOWNLOADER=$matched_downloader_marker \
QWEN_TEST_WRONG_DOWNLOADER=$wrong_downloader_marker \
PATH="$fixture_bin:$PATH" \
    "$fixture_scripts/qwen-launch.sh" >"$temporary_directory/launch.stdout"

test -f "$matched_downloader_marker"
if [ -e "$wrong_downloader_marker" ]; then
    printf 'launch invoked the unrelated 4B projector downloader\n' >&2
    exit 1
fi
grep -F "projector=$model_directory/mmproj-matched.gguf" \
    "$state_directory/session.status" >/dev/null

printf 'projector_fetch_dispatch=accepted\n'
