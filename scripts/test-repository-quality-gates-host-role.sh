#!/bin/sh
set -eu

# Prove the host-role dispatch in repository-quality-gates.sh: an
# undeclared value is a usage error, and the runner role reports both
# coding-principal tests not_run. Each arm aborts the gate ahead of the
# suite -- the invalid role at the case statement, the runner arm at the
# required-command loop under an emptied PATH -- so this test runs inside
# the gate that invokes it without recursing into it.

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
gate_script="$script_directory/repository-quality-gates.sh"

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

invalid_status=0
QWEN_GATE_HOST_ROLE=bogus "$gate_script" >/dev/null 2>&1 || invalid_status=$?
[ "$invalid_status" -eq 2 ] && check invalid_role_exits_2 pass ||
    check invalid_role_exits_2 fail "$invalid_status"

# An emptied PATH ends the runner arm at the required-command loop, after
# the dispatch has written both lines to stdout.
runner_output=$(PATH=/nonexistent QWEN_GATE_HOST_ROLE=runner \
    "$gate_script" 2>/dev/null || :)
case $runner_output in
    *"coding_principal=not_run reason=runner_host"*)
        check runner_principal_not_run pass ;;
    *) check runner_principal_not_run fail "$runner_output" ;;
esac
case $runner_output in
    *"coding_principal_path=not_run reason=runner_host"*)
        check runner_principal_path_not_run pass ;;
    *) check runner_principal_path_not_run fail "$runner_output" ;;
esac

if [ "$checks_failed" -eq 0 ]; then
    printf 'repository_quality_gates_host_role=accepted checks=%s\n' \
        "$checks_total"
    exit 0
fi
printf 'repository_quality_gates_host_role=rejected failed=%s of=%s\n' \
    "$checks_failed" "$checks_total" >&2
exit 1
