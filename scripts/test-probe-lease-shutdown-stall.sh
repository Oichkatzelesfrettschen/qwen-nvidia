#!/bin/sh
# Prove that probe-lease-shutdown-stall.sh separates the two shutdown paths.
#
# The probe's arms are only worth device time if a client-bounded shutdown and a
# lease-bounded one read differently through them, so this drives
# scripts/test-fixtures/fake-lease-llama-server.py in both shapes and requires
# the readings to swap. QWEN_FAKE_LEASE_STALL=client holds each orphaned
# request until its own client disconnects, which is llama.cpp's own path;
# QWEN_FAKE_LEASE_STALL=lease holds it until the compute lease goes free. A
# probe hard-coded to report either fills the wrong cell under the other. A
# third run leaves the stall off, so a request that answers before the signal
# reaches the in-flight staging and has to refuse rather than signal an idle
# server. A passing run states that the probe reads what it claims to read and
# states nothing about any closure.
#
# gpu-ownership: runs no device command; the probe under test is copied beside a
# stub authority, so no owner lock is taken and no CUDA context opens.
set -eu

usage() {
    printf 'usage: test-probe-lease-shutdown-stall.sh\n' >&2
    exit 2
}
[ "$#" -eq 0 ] || usage

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT

failures=0
pass() { printf 'accepted %s\n' "$1"; }
fail() { printf 'REJECTED %s\n' "$1"; failures=$((failures + 1)); }

stub_scripts=$temporary_directory/scripts
mkdir -p "$stub_scripts"
cp "$script_directory/probe-lease-shutdown-stall.sh" "$stub_scripts/"
cp "$script_directory/test-fixtures/fake-lease-llama-server.py" "$stub_scripts/"

# The authority stub takes no lock: this test proves the probe's readings, and
# the ownership contract is what scripts/test-gpu-workload-ownership.sh grades.
cat >"$stub_scripts/gpu-workload-ownership.sh" <<'STUB'
gpu_ownership_require() {
    printf 'gpu_ownership_lock=stub\n'
}
STUB
cat >"$stub_scripts/device-environment-identity.sh" <<'STUB'
#!/bin/sh
printf 'device_name=stub\n'
STUB
chmod +x "$stub_scripts/device-environment-identity.sh"

: >"$temporary_directory/model.gguf"
output_directory=$temporary_directory/out

# The fixture answers a completion in about 0.2 s, so an arm whose staging waits
# for a decode still in flight needs the lease held against it; the in-flight
# arms therefore read the fixture's own reply rather than a stall, which is the
# one reading this fixture cannot supply and the device run does.
if QWEN_FAKE_LEASE_STALL=client \
    QWEN_STALL_CANDIDATE_SERVER="$stub_scripts/fake-lease-llama-server.py" \
    QWEN_STALL_PROMOTED_SERVER="$stub_scripts/fake-lease-llama-server.py" \
    QWEN_STALL_MODEL="$temporary_directory/model.gguf" \
    QWEN_STALL_PORT=18197 \
    "$stub_scripts/probe-lease-shutdown-stall.sh" "$output_directory" \
    no_intervention client_disconnect holder_release \
    >"$temporary_directory/run.log" 2>&1; then
    pass 'probe=exit_zero'
else
    fail "probe=exit_nonzero $(tail -3 "$temporary_directory/run.log" | tr '\n' ' ')"
fi

readings=$output_directory/readings.tsv
if [ ! -s "$readings" ]; then
    fail 'readings=absent'
    printf 'test_probe_lease_shutdown_stall=rejected failures=%s\n' "$((failures + 1))"
    exit 1
fi

# The readings file is named at call time rather than captured, because the
# later shapes read their own runs through the same accessor.
read_field() {
    awk -F'\t' -v arm="$1" -v key="$2" \
        '$1 == arm && index($2, key) == 1 { sub(key, "", $2); print $2 }' "$readings"
}

# The fixture's client-bounded shutdown puts the no-intervention exit just past
# the client's own 20 s timeout, and a probe that reported an exit on the signal
# would be reading something other than the departure.
no_intervention_ms=$(read_field no_intervention exit_ms_after_signal=)
case $no_intervention_ms in
    ''|alive) fail "no_intervention=$(read_field no_intervention alive_past_90s)${no_intervention_ms:+ $no_intervention_ms} expected an exit past the client timeout" ;;
    *)
        if [ "$no_intervention_ms" -ge 19000 ] && [ "$no_intervention_ms" -le 30000 ]; then
            pass "no_intervention=exit_at_client_timeout ms=$no_intervention_ms"
        else
            fail "no_intervention=exit_ms=$no_intervention_ms outside the client's own 20 s timeout"
        fi
        ;;
esac

# The bound the served arm refused on has to reproduce, or the probe is reading
# a server that shut down and the interventions decide nothing.
for bounded_arm in client_disconnect holder_release; do
    case $(read_field "$bounded_arm" at_30s=) in
        alive) pass "$bounded_arm=alive_at_30s" ;;
        *)     fail "$bounded_arm=exited_before_the_bound, so its intervention reads nothing" ;;
    esac
done

# A reading of `alive` is a claim about elapsed time, so the timeline is read
# for the time that elapsed: a probe that reported the bound without waiting for
# it would leave under 30 s between its signal and the intervention that
# follows, and the readings alone cannot tell the two apart.
timeline=$output_directory/timeline.tsv
elapsed_between() {
    awk -F'\t' -v from="$1" -v to="$2" \
        '$2 == from { start = $1 }
         $2 == to && start != "" { print $1 - start; exit }' "$timeline"
}
for bounded_arm in client_disconnect holder_release; do
    case $bounded_arm in
        client_disconnect) after=client_disconnect.client_release ;;
        holder_release)    after=holder_release.holder_release ;;
    esac
    waited=$(elapsed_between "$bounded_arm.signal" "$after")
    if [ -z "$waited" ]; then
        fail "$bounded_arm=timeline missing the signal or the intervention"
    elif [ "$waited" -ge 30000 ]; then
        pass "$bounded_arm=observed_the_bound ms=$waited"
    else
        fail "$bounded_arm=reported the bound after only ${waited} ms"
    fi
done

# The discriminating pair: the departure ends it inside a polling interval and
# the holder's release moves nothing.
disconnect_ms=$(read_field client_disconnect exit_ms_after_disconnect=)
case $disconnect_ms in
    ''|alive) fail "client_disconnect=$disconnect_ms expected an exit inside the polling interval" ;;
    *)
        if [ "$disconnect_ms" -le 5000 ]; then
            pass "client_disconnect=exit_on_departure ms=$disconnect_ms"
        else
            fail "client_disconnect=exit_ms=$disconnect_ms far past the polling interval"
        fi
        ;;
esac

release_ms=$(read_field holder_release exit_ms_after_holder_release=)
case $release_ms in
    alive) pass 'holder_release=no_effect' ;;
    '')    fail 'holder_release=unread' ;;
    *)     fail "holder_release=exit_ms=$release_ms, so the release ended a shutdown the client bounds" ;;
esac

later_ms=$(read_field holder_release exit_ms_after_later_disconnect=)
case $later_ms in
    ''|alive) fail "holder_release=later_disconnect=$later_ms expected the departure to end it" ;;
    *)        pass "holder_release=later_departure_ends_it ms=$later_ms" ;;
esac

# Retention and sanitization are read rather than assumed, because the probe
# writes a server log naming the model path into a tracked evidence directory.
for retained in no_intervention.server.log client_disconnect.server.log \
    holder_release.server.log timeline.tsv summary.tsv; do
    if [ -s "$output_directory/$retained" ]; then
        pass "retained=$retained"
    else
        fail "retained=$retained absent or empty"
    fi
done

if grep -rq "$HOME" "$output_directory" 2>/dev/null; then
    fail 'sanitization=a retained file carries the home prefix'
else
    pass 'sanitization=no home prefix in any retained file'
fi

# The reversed cell. Under a lease-bounded shutdown the departure has to move
# nothing and the release has to end it, which is the reading the client-bounded
# run above produced the other way round.
lease_output=$temporary_directory/out-lease
if QWEN_FAKE_LEASE_STALL=lease \
    QWEN_STALL_CANDIDATE_SERVER="$stub_scripts/fake-lease-llama-server.py" \
    QWEN_STALL_PROMOTED_SERVER="$stub_scripts/fake-lease-llama-server.py" \
    QWEN_STALL_MODEL="$temporary_directory/model.gguf" \
    QWEN_STALL_PORT=18198 \
    "$stub_scripts/probe-lease-shutdown-stall.sh" "$lease_output" \
    client_disconnect holder_release \
    >"$temporary_directory/run-lease.log" 2>&1; then
    pass 'lease_fixture=exit_zero'
else
    fail "lease_fixture=exit_nonzero $(tail -3 "$temporary_directory/run-lease.log" | tr '\n' ' ')"
fi

readings=$lease_output/readings.tsv
if [ -s "$readings" ]; then
    case $(read_field client_disconnect exit_ms_after_disconnect=) in
        alive) pass 'lease_fixture=departure_moves_nothing' ;;
        *)     fail "lease_fixture=client_disconnect ended a lease-bounded shutdown: $(read_field client_disconnect exit_ms_after_disconnect=)" ;;
    esac
    release_ms=$(read_field holder_release exit_ms_after_holder_release=)
    case $release_ms in
        ''|alive) fail "lease_fixture=holder_release=$release_ms expected the release to end it" ;;
        *)        pass "lease_fixture=release_ends_it ms=$release_ms" ;;
    esac
else
    fail 'lease_fixture=readings absent'
fi

# The staging negative control. With the stall off the fixture answers in about
# 0.2 s, so the in-flight arm's request completes before its signal and the
# staging has to refuse rather than signal a server with nothing in flight.
complete_output=$temporary_directory/out-complete
QWEN_STALL_CANDIDATE_SERVER="$stub_scripts/fake-lease-llama-server.py" \
    QWEN_STALL_PROMOTED_SERVER="$stub_scripts/fake-lease-llama-server.py" \
    QWEN_STALL_MODEL="$temporary_directory/model.gguf" \
    QWEN_STALL_PORT=18198 \
    "$stub_scripts/probe-lease-shutdown-stall.sh" "$complete_output" \
    candidate_in_flight \
    >"$temporary_directory/run-complete.log" 2>&1 || true

readings=$complete_output/readings.tsv
if [ -s "$readings" ] &&
    awk -F'\t' '$1 == "candidate_in_flight" && $2 == "refused" { found = 1 }
        END { exit !found }' "$readings"; then
    pass 'staging=refuses a request that completed before the signal'
else
    fail "staging=admitted a completed request: $(awk -F'\t' '$1 == "candidate_in_flight" { print $2 }' "$readings" 2>/dev/null | tr '\n' ' ')"
fi

if [ "$failures" -eq 0 ]; then
    printf 'test_probe_lease_shutdown_stall=accepted shapes=client,lease,none\n'
else
    printf 'test_probe_lease_shutdown_stall=rejected failures=%s\n' "$failures"
    exit 1
fi
