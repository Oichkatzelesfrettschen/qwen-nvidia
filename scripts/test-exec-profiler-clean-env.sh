#!/bin/sh
set -eu

# Admit the profiler environment allowlist by planting secrets in the caller
# and reading what the child actually received. The child is `env` itself, so
# the check reads the environment the profiler would have absorbed rather than
# a profiler's opinion of it, and the arms run without the device.

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
wrapper=$script_directory/exec-profiler-clean-env.sh
work_directory=$(mktemp -d "${TMPDIR:-/tmp}/profiler-clean-env.XXXXXX")
trap 'rm -rf "$work_directory"' EXIT INT TERM

checks_total=0
checks_failed=0
check() {
    checks_total=$((checks_total + 1))
    if [ "$2" = pass ]; then
        printf 'check=%s outcome=pass\n' "$1"
    else
        checks_failed=$((checks_failed + 1))
        printf 'check=%s outcome=FAIL detail=%s\n' "$1" "${3:-}" >&2
    fi
}

# The planted values are what a real capture would absorb from an interactive
# shell: a key, a token, and a password, under names the wrapper never lists.
TEST_SECRET_KEY=plant-key-4f2a
TEST_SECRET_TOKEN=plant-token-9b7c
TEST_SECRET_PASSWORD=plant-password-1d3e
GREPTILE_API_KEY=plant-vendor-key-0a5f
export TEST_SECRET_KEY TEST_SECRET_TOKEN TEST_SECRET_PASSWORD GREPTILE_API_KEY

child_env=$work_directory/child.env
sh "$wrapper" env >"$child_env"

for planted in plant-key-4f2a plant-token-9b7c plant-password-1d3e \
    plant-vendor-key-0a5f; do
    if grep -qF "$planted" "$child_env"; then
        check "secret_value_withheld_$planted" fail 'value crossed into child'
    else
        check "secret_value_withheld_$planted" pass
    fi
done

for name in TEST_SECRET_KEY TEST_SECRET_TOKEN TEST_SECRET_PASSWORD \
    GREPTILE_API_KEY; do
    if grep -q "^$name=" "$child_env"; then
        check "secret_name_withheld_$name" fail 'name crossed into child'
    else
        check "secret_name_withheld_$name" pass
    fi
done

# The allowlist is exactly what the child holds, so a later edit that adds a
# passthrough fails here rather than silently widening every capture.
observed=$(sed 's/=.*//' "$child_env" | LC_ALL=C sort | tr '\n' ' ')
expected='CUDA_MODULE_LOADING CUDA_VISIBLE_DEVICES HOME LANG LC_ALL LOGNAME PATH SHELL TERM TMPDIR USER '
if [ "$observed" = "$expected" ]; then
    check environment_is_exactly_the_allowlist pass
else
    check environment_is_exactly_the_allowlist fail "$observed"
fi

# The command still runs and its arguments still arrive.
if [ "$(sh "$wrapper" printf '%s-%s' ready now)" = ready-now ]; then
    check command_and_arguments_reach_child pass
else
    check command_and_arguments_reach_child fail
fi

# A caller-varied CUDA device selection is passed through, since a measurement
# arm legitimately sets it.
if CUDA_VISIBLE_DEVICES=1 sh "$wrapper" env |
    grep -q '^CUDA_VISIBLE_DEVICES=1$'; then
    check cuda_device_selection_passes_through pass
else
    check cuda_device_selection_passes_through fail
fi

if sh "$wrapper" >/dev/null 2>&1; then
    check usage_error_exit_two fail 'empty argv accepted'
else
    [ "$?" = 2 ] || : # the wrapper exits 2; the status is read below
    sh "$wrapper" >/dev/null 2>&1 || status=$?
    [ "${status:-0}" = 2 ] &&
        check usage_error_exit_two pass ||
        check usage_error_exit_two fail "status=${status:-0}"
fi

if QWEN_PROFILER_EXTRA_PATH=/nonexistent-profiler-dir sh "$wrapper" env \
    >/dev/null 2>&1; then
    check absent_extra_path_refused fail 'accepted a missing directory'
else
    check absent_extra_path_refused pass
fi

if [ "$checks_failed" -eq 0 ]; then
    printf 'profiler_clean_env=accepted checks=%s\n' "$checks_total"
    exit 0
fi
printf 'profiler_clean_env=rejected failed=%s of=%s\n' \
    "$checks_failed" "$checks_total" >&2
exit 1
