#!/bin/sh
set -eu

# Exercise every branch of remote/select-projector.sh against a temporary tree.
# The cases that matter are the two that changed behaviour: a publisher-named
# projector must be found where an exact filename search missed it, and two
# candidates must leave the choice unmade rather than resolved by sort order.

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
selector=$script_directory/select-projector.sh
work_directory=$(mktemp -d)
trap 'rm -rf "$work_directory"' EXIT INT TERM

failures=0

expect() {
    case_name=$1
    model_path=$2
    expected=$3
    actual=$("$selector" "$model_path" 2>/dev/null || printf '<exit-%s>' "$?")
    if [ "$actual" != "$expected" ]; then
        printf 'FAIL\t%s: expected %s, got %s\n' \
            "$case_name" "${expected:-<empty>}" "${actual:-<empty>}" >&2
        failures=$((failures + 1))
    else
        printf 'ok\t%s -> %s\n' "$case_name" "${actual:-<text-only>}"
    fi
}

for name in exact publisher both two none; do
    mkdir -p "$work_directory/$name"
    : > "$work_directory/$name/model.gguf"
done
: > "$work_directory/exact/mmproj-F16.gguf"
: > "$work_directory/publisher/mmproj-Ornith-1.5-9B-BF16.gguf"
: > "$work_directory/both/mmproj-F16.gguf"
: > "$work_directory/both/mmproj-Ornith-1.5-9B-BF16.gguf"
: > "$work_directory/two/mmproj-alpha-BF16.gguf"
: > "$work_directory/two/mmproj-beta-BF16.gguf"

expect 'exact name present' \
    "$work_directory/exact/model.gguf" "$work_directory/exact/mmproj-F16.gguf"
expect 'publisher name alone' \
    "$work_directory/publisher/model.gguf" \
    "$work_directory/publisher/mmproj-Ornith-1.5-9B-BF16.gguf"
expect 'exact wins over publisher name' \
    "$work_directory/both/model.gguf" "$work_directory/both/mmproj-F16.gguf"
expect 'two candidates leave it unmade' "$work_directory/two/model.gguf" ''
expect 'no projector runs text-only' "$work_directory/none/model.gguf" ''
expect 'absent directory runs text-only' \
    "$work_directory/absent/model.gguf" ''

# $? inside `if ! cmd` reports the negated status, so the call is made plainly
# with errexit suspended around it.
set +e
"$selector" >/dev/null 2>&1
argument_status=$?
set -e
if [ "$argument_status" -ne 2 ]; then
    printf 'FAIL\tmissing argument must exit 2, got %s\n' "$argument_status" >&2
    failures=$((failures + 1))
else
    printf 'ok\tmissing argument exits 2\n'
fi

if [ "$failures" -ne 0 ]; then
    printf 'projector_pairing=failed cases=%s\n' "$failures" >&2
    exit 1
fi
printf 'projector_pairing=passed\n'
