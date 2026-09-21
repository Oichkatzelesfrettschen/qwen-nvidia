#!/bin/sh
set -eu

# Reach every way a bounded resident session ends, on the card, and record what
# owned the destruction at each of them.
#
# Destroying device state is compute: it frees allocations, tears down an
# acceleration structure, a pipeline and a context. A session ending on the
# supervisor's word ends while the supervisor holds the compute lease. A
# session ending on a bound of its own -- its request count, its wall seconds,
# its idle interval -- reaches that moment while the supervisor holds nothing,
# so the worker announces the retirement it wants and waits for the shutdown
# line the supervisor sends holding the lease. This drives each of those ends
# and checks the reason the worker cites, that the supervisor authorized the
# destruction, and that no worker outlives the run.
#
# Two arms deny the supervisor its residency reading instead. The profile row's
# memory allowance is enforced by that reading, so a probe that answers nothing
# leaves it enforcing nothing; the session ends rather than continuing against
# an allowance never tested, and the worker goes under a lease taken to end it.
#
# One arm drives the binary directly. optix-ray-runtime reads its request line
# a byte at a time under a deadline it recomputes each time round, so a sender
# dripping an unfinished line cannot extend the session past the wall bound
# that governs it. A relative timeout renewed per byte would, and the session
# age is checked only between requests, so the drip would run unbounded.
#
# The subject rows stay refused in scripts/geometry-profiles.tsv; the copy
# raises them for this run alone and the record names both readings.
#
# gpu-ownership: acquires the owner lock for its whole run.

usage() {
    printf 'usage: %s OUTPUT_DIRECTORY [RAYS]\n' "$0" >&2
    printf '       the output directory belongs under .local-artifacts/\n' >&2
    exit 2
}
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
output_directory=$1
rays=${2:-65536}
case $rays in '' | *[!0-9]* | 0*) usage ;; esac
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PYTHON=${PYTHON:-python3}
probe=$script_directory/test-fixtures/fake-residency-probe.sh

if [ -e "$output_directory" ] && [ -n "$(ls -A "$output_directory" 2>/dev/null)" ]; then
    printf 'refused: output directory exists and is not empty: %s\n' "$output_directory" >&2
    exit 2
fi
mkdir -p "$output_directory/state"
output_directory=$(CDPATH='' cd -- "$output_directory" && pwd)
scrub_home() { sed "s|${HOME:?}|\$HOME|g"; }
summary=$output_directory/summary.tsv
checks_total=0
checks_failed=0
check() {
    checks_total=$((checks_total + 1))
    if [ "$2" = "$3" ]; then
        printf '%s\taccepted\t%s\n' "$1" "$2" >>"$summary"
    else
        checks_failed=$((checks_failed + 1))
        printf '%s\trejected\tobserved=%s expected=%s\n' "$1" "$2" "$3" >>"$summary"
        printf 'rejected: %s observed=%s expected=%s\n' "$1" "$2" "$3" >&2
    fi
}
record() { printf '%s\t%s\n' "$1" "$2" >>"$summary"; }
: >"$summary"

trap 'exit 130' INT
trap 'exit 143' TERM

"$script_directory/gpu-state-latch.sh" require-clear
"$script_directory/build-geometry-runtime.sh" "$output_directory/optix-ray-runtime" |
    tee "$output_directory/build.txt"
runtime=$output_directory/optix-ray-runtime
record geometry_runtime_sha256 "$(sed -n 's/^geometry_runtime_sha256=//p' "$output_directory/build.txt")"
record runtime_protocol_version "$(sed -n 's/^geometry_protocol_version=//p' "$output_directory/build.txt")"
record retirement_authorization_s "$(sed -n 's/^geometry_retirement_authorization_s=//p' "$output_directory/build.txt")"
check ordinary_user "$([ "$(id -u)" -ne 0 ] && printf yes || printf no)" yes

# The calibration rows stay refused in the tree; the copy raises them for
# this run alone and the record names what the tree reads.
for profile_id in geometry-cube-orbit-a-retire geometry-cube-orbit-a-wall \
                  geometry-cube-orbit-a-appbudget; do
    in_tree_policy=$(awk -F '\t' -v id="$profile_id" '!/^#/ && $1 == id { print $6 }' \
        "$script_directory/geometry-profiles.tsv")
    [ -n "$in_tree_policy" ] || { printf 'profile %s is absent from the ledger\n' "$profile_id" >&2; exit 1; }
    record "in_tree_execution_policy.$profile_id" "$in_tree_policy"
done
awk -F '\t' -v OFS='\t' \
    '!/^#/ && ($1 == "geometry-cube-orbit-a-retire" || $1 == "geometry-cube-orbit-a-wall" ||
               $1 == "geometry-cube-orbit-a-appbudget") { $6 = "validator-gated" } { print }' \
    "$script_directory/geometry-profiles.tsv" >"$output_directory/geometry-profiles.tsv"
record subject_execution_policy validator-gated
record rays_requested "$rays"

. "$script_directory/gpu-workload-ownership.sh"
gpu_ownership_require >"$output_directory/ownership-before.raw"
sed -E -e 's|^(cuda_client) pid=[0-9]+ name=([^ ]+).* used=([0-9]+ MiB) .* verdict=(.*)$|\1 name=\2 used=\3 verdict=\4|' \
    -e 's|name=[^ ]*/([^ /]+)|name=\1|' -e 's|^(named_llama_server_pids)=.*$|\1=redacted|' \
    <"$output_directory/ownership-before.raw" | scrub_home >"$output_directory/ownership-before.txt"
rm -f "$output_directory/ownership-before.raw"
"$script_directory/device-environment-identity.sh" "$output_directory/device-environment.tsv"
record host_load_1m_before "$(cut -d ' ' -f 1 /proc/loadavg)"
record gpu_utilization_before_percent "$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits -i 0)"

QWEN_GPU_COMPUTE_LEASE=$output_directory/state/vulkan-workload.lock
export QWEN_GPU_COMPUTE_LEASE
: >"$QWEN_GPU_COMPUTE_LEASE"

# One session per way of ending. The interval is silence the supervisor holds
# no lease through, which is how the idle interval and the wall bound are
# reached at all; the probe column is the residency instrument, nvidia-smi
# where the reading is meant to succeed.
#
# The last two are one row at two ray counts. Its application ceiling is
# 16 MiB and a ray costs 24 bytes with its result 8, so 262,144 rays occupy
# 8 MiB and serve while 1,048,576 occupy 32 and are refused before a
# cudaMalloc runs. The pair is what shows the ceiling discriminating rather
# than failing every request, and the refusal is a bound the worker reached,
# so it retires authorized rather than being terminated.
#
# arm profile requests rays interval probe expect_exit expect_reason
arms="
shutdown geometry-cube-orbit-a-retire 1 default 0 device 0 shutdown
request-limit geometry-cube-orbit-a-retire 2 default 0 device 0 request_limit
idle-timeout geometry-cube-orbit-a-retire 2 default 5 device 0 idle_timeout
session-limit geometry-cube-orbit-a-wall 16 default 1 device 0 session_limit
residency-unread geometry-cube-orbit-a-retire 2 default 0 unread 1 terminated
residency-over geometry-cube-orbit-a-retire 2 default 0 over 1 terminated
application-serves geometry-cube-orbit-a-appbudget 1 262144 0 device 0 shutdown
application-ceiling geometry-cube-orbit-a-appbudget 1 1048576 0 device 0 budget_exceeded
"
printf '%s\n' "$arms" | while read -r arm profile requests arm_rays interval probe_mode expect_exit expect_reason; do
    [ -n "$arm" ] || continue
    [ "$arm_rays" = default ] && arm_rays=$rays
    set -- --profiles "$output_directory/geometry-profiles.tsv" --profile-id "$profile" \
        --runtime "$runtime" --state-dir "$output_directory/state" \
        --record "$output_directory/record-$arm.tsv" \
        --stderr "$output_directory/runtime-$arm.err" --mode resident \
        --requests "$requests" --rays "$arm_rays" --run-id "$arm" \
        --idle-between-requests-s "$interval"
    [ "$probe_mode" = device ] || set -- "$@" --residency-probe "$probe $probe_mode {pid}"
    status=0
    "$PYTHON" "$script_directory/geometry-resident-driver.py" "$@" 9>&- </dev/null \
        >"$output_directory/driver-$arm.out" 2>"$output_directory/driver-$arm.err" || status=$?
    check "exit.$arm" "$status" "$expect_exit"
    if [ "$expect_exit" -eq 0 ]; then
        check "retirement.$arm" \
            "$(sed -n 's/.*retirement=\([a-z_]*\).*/\1/p' "$output_directory/driver-$arm.out")" \
            "$expect_reason"
        check "authorized.$arm" \
            "$(sed -n 's/.*retirement_authorized=\([A-Za-z]*\).*/\1/p' "$output_directory/driver-$arm.out")" \
            True
    else
        # A run the residency reading ended names, in its own record, the
        # ownership the worker was destroyed under.
        check "terminated.$arm" \
            "$(awk -F '\t' 'END { print $1 }' "$output_directory/record-$arm.tsv")" \
            resident-terminated
        check "ownership.$arm" \
            "$(awk -F '\t' 'END { print $NF }' "$output_directory/record-$arm.tsv")" owned
    fi
    # Nothing the arm spawned survives it, and the lease it took is free.
    check "workers_after.$arm" "$(pgrep -f "$runtime" | wc -l)" 0
    check "lease_free_after.$arm" \
        "$(flock -n "$QWEN_GPU_COMPUTE_LEASE" true 2>/dev/null && printf free || printf held)" free
done

# The drip. A partial request line arriving a byte at a time cannot hold the
# session open: read_line recomputes what is left of one deadline each time
# round rather than restarting a relative timeout per byte. The session waits
# whichever of its idle interval and its remaining wall seconds is nearer,
# six seconds here, and a byte arrives every second, so a reader renewing its
# timeout per byte would still be reading when the thirty-second drip ended.
drip_seconds=30
drip_started=$(date +%s.%N)
{
    index=0
    while [ "$index" -lt "$drip_seconds" ]; do
        printf 'x'
        sleep 1
        index=$((index + 1))
    done
} | "$runtime" cube-and-plane orbit resident 0 enabled 16 8 6 512 40 \
    >"$output_directory/drip.out" 2>"$output_directory/drip.err" || :
drip_ended=$(date +%s.%N)
drip_elapsed=$(printf '%s %s' "$drip_started" "$drip_ended" | awk '{ printf "%.1f", $2 - $1 }')
record drip_elapsed_s "$drip_elapsed"
record drip_idle_bound_s 6
record drip_wall_bound_s 8
# What the drip falsifies is the moment the bound fires, which the notice
# carries: a reader renewing a six-second timeout on every byte would never
# reach it while a byte arrives every second, and would print no notice at
# all. The process then outlives that moment by its authorization window,
# because nothing is driving it to answer, which is the emergency path rather
# than the bound failing.
drip_announced_s=$(sed -n 's/.*"event":"retiring".*"session_age_s":\([0-9.]*\).*/\1/p' \
    "$output_directory/drip.out")
record drip_announced_s "${drip_announced_s:-none}"
check drip_announces_on_its_bound \
    "$(printf '%s' "${drip_announced_s:-999}" | awk '{ print ($1 < 10) ? "yes" : "no" }')" yes
check drip_ends_inside_its_authorization_window \
    "$(printf '%s' "$drip_elapsed" | awk '{ print ($1 < 45) ? "yes" : "no" }')" yes
check drip_retirement "$(sed -n 's/.*"event":"retired","reason":"\([a-z_]*\)".*/\1/p' "$output_directory/drip.out")" idle_timeout
# Nothing authorized that destruction, because nothing was driving the worker.
# The emergency path is the one a dead supervisor leaves, and it says so.
check drip_authorized "$(sed -n 's/.*"authorized":\([a-z]*\).*/\1/p' "$output_directory/drip.out")" false
check drip_emergency_recorded \
    "$(grep -c 'optix_runtime=emergency reason=retirement_unauthorized' "$output_directory/drip.err" || :)" 1

record host_load_1m_after "$(cut -d ' ' -f 1 /proc/loadavg)"
record gpu_utilization_after_percent "$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits -i 0)"
check workers_after_run "$(pgrep -f "$runtime" | wc -l)" 0
record cuda_clients_after "$(nvidia-smi --query-compute-apps=pid --format=csv,noheader | wc -l)"

# The check counts come from the subshell the arms ran in, which cannot pass a
# variable back, so the summary is the authority and is counted here.
checks_total=$(awk -F '\t' '$2 == "accepted" || $2 == "rejected"' "$summary" | wc -l)
checks_failed=$(awk -F '\t' '$2 == "rejected"' "$summary" | wc -l)
record checks_total "$checks_total"
record checks_failed "$checks_failed"
printf 'geometry_retirement=%s checks=%s failed=%s\n' \
    "$([ "$checks_failed" -eq 0 ] && printf accepted || printf rejected)" \
    "$checks_total" "$checks_failed"
[ "$checks_failed" -eq 0 ]
