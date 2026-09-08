#!/bin/sh
set -eu

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

run_mutation() {
    mutation_name=$1
    expected_failure=$2
    expected_message=$3
    mutation_scripts=$temporary_directory/$mutation_name
    cp -a "$script_directory" "$mutation_scripts"
    shift 3
    "$@" "$mutation_scripts"
    set +e
    QWEN_SKIP_STALE_RETIREMENT_FIXTURE=1 TMPDIR=${TMPDIR:-/tmp} \
        "$mutation_scripts/$expected_failure" \
        >"$temporary_directory/$mutation_name.stdout" \
        2>"$temporary_directory/$mutation_name.stderr"
    mutation_status=$?
    set -e
    if [ "$mutation_status" -eq 0 ]; then
        printf 'mutation survived: %s\n' "$mutation_name" >&2
        exit 1
    fi
    if ! grep -F "$expected_message" "$temporary_directory/$mutation_name.stderr" >/dev/null; then
        printf 'mutation failed outside intended branch: %s\n' "$mutation_name" >&2
        tail -n 20 "$temporary_directory/$mutation_name.stderr" >&2
        exit 1
    fi
    printf 'mutation_discriminated=%s status=%s\n' "$mutation_name" "$mutation_status"
}

mutate_bypass_drain() {
    mutation_scripts=$1
    sed -i 's|qwen-drain-controller.sh" retire|qwen-drain-controller-bypass.sh" retire|' \
        "$mutation_scripts/qwen-webui-session.sh"
    printf '%s\n' '#!/bin/sh' 'set -eu' \
        'while [ "$#" -gt 0 ]; do [ "$1" = -- ] && { shift; break; }; shift; done' \
        'exec "$@"' >"$mutation_scripts/qwen-drain-controller-bypass.sh"
    chmod +x "$mutation_scripts/qwen-drain-controller-bypass.sh"
}

mutate_accept_missing_proof() {
    mutation_scripts=$1
    sed -i 's/\[ "$teardown_yes" -eq 1 \]/[ "$teardown_yes" -le 1 ]/' \
        "$mutation_scripts/qwen-retire-server-child.sh"
}

run_mutation bypass_session_drain test-qwen-session-signals.sh \
    'session retirement did not wait for active work' mutate_bypass_drain
run_mutation accept_missing_child_proof test-qwen-retire-server-child.sh \
    'missing teardown proof was accepted' mutate_accept_missing_proof

printf 'drain_integration_mutations=accepted\n'
