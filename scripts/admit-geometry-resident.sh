#!/bin/sh
set -eu

# Run the bounded resident session and its one-shot control against the device,
# interleaved, and retain what separates them. The script compiles the runtime,
# copies the profile ledger with the one-shot and the bounded-resident rows
# raised to validator-gated for this run alone, takes the GPU owner lock, and
# then alternates blocks: one block of one-shot requests, one bounded resident
# session serving the same count at the same ray count, and so on. Both arms
# run through scripts/geometry-resident-driver.py, which takes the compute
# lease around every request, holds none between them, and puts every fresh
# device result through the independent host reference ray by ray.
#
# What the arms differ in is residency, and the record says so per request: the
# resident session pays the six setup stages once and six stages per request,
# the control pays all thirteen every time, and the sum over a session is what
# a comparison rests on rather than a warm request quoted alone. The driver
# samples the driver's own residency for the worker process while it is idle,
# so the memory a session holds between requests is read off the device rather
# than taken from the worker's own accounting.
#
# The rows in scripts/geometry-profiles.tsv stay refused; promotion is a
# separate transition this proof informs.
#
# gpu-ownership: acquires the owner lock for its whole run.

# The output directory holds a build, six records and a sampler capture per
# run, none of which is tracked: .local-artifacts/ is where the checkout keeps
# a capture, and the retained form is what evidence/ada/geometry-resident-session
# carries.
usage() {
    printf 'usage: %s OUTPUT_DIRECTORY [RAYS] [REQUESTS] [BLOCKS]\n' "$0" >&2
    printf '       the output directory belongs under .local-artifacts/\n' >&2
    exit 2
}
[ "$#" -ge 1 ] && [ "$#" -le 4 ] || usage
output_directory=$1
rays=${2:-262144}
requests=${3:-4}
blocks=${4:-3}
for count in "$rays" "$requests" "$blocks"; do
    case $count in '' | *[!0-9]* | 0*) usage ;; esac
done
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PYTHON=${PYTHON:-python3}
one_shot_profile=${QWEN_GEOMETRY_PROFILE:-geometry-cube-orbit-a}
resident_profile=${QWEN_GEOMETRY_RESIDENT_PROFILE:-geometry-cube-orbit-a-resident}

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

sampler_pid=''
cleanup() {
    status=$?
    if [ -n "$sampler_pid" ]; then kill "$sampler_pid" 2>/dev/null || :; fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

"$script_directory/gpu-state-latch.sh" require-clear
"$script_directory/gpu-state-latch.sh" status | scrub_home | tee "$output_directory/latch.txt"
"$script_directory/build-geometry-runtime.sh" "$output_directory/optix-ray-runtime" |
    tee "$output_directory/build.txt"
runtime_sha256=$(sed -n 's/^geometry_runtime_sha256=//p' "$output_directory/build.txt")
record geometry_runtime_sha256 "$runtime_sha256"
record optix_header_version "$(sed -n 's/^optix_version=//p' "$output_directory/build.txt")"
# The binary carries the protocol version it was compiled against, and the
# driver refuses a worker that speaks another. Recording both readings is what
# makes a later divergence legible rather than a failed run.
record runtime_protocol_version "$(sed -n 's/^geometry_protocol_version=//p' "$output_directory/build.txt")"
record module_protocol_version "$("$PYTHON" -c 'import sys; sys.path.insert(0, sys.argv[1]); import geometry_protocol; print(geometry_protocol.PROTOCOL_VERSION)' "$script_directory")"
check ordinary_user "$([ "$(id -u)" -ne 0 ] && printf yes || printf no)" yes

# The subject rows stay refused in the tree; the copy raises both for this run
# alone and the record names both readings.
for profile_id in "$one_shot_profile" "$resident_profile"; do
    in_tree_policy=$(awk -F '\t' -v id="$profile_id" '!/^#/ && $1 == id { print $6 }' \
        "$script_directory/geometry-profiles.tsv")
    [ -n "$in_tree_policy" ] || { printf 'profile %s is absent from the ledger\n' "$profile_id" >&2; exit 1; }
    record "in_tree_execution_policy.$profile_id" "$in_tree_policy"
done
awk -F '\t' -v OFS='\t' -v one="$one_shot_profile" -v resident="$resident_profile" \
    '!/^#/ && ($1 == one || $1 == resident) { $6 = "validator-gated" } { print }' \
    "$script_directory/geometry-profiles.tsv" >"$output_directory/geometry-profiles.tsv"
record subject_execution_policy validator-gated
session_requests=$(awk -F '\t' -v id="$resident_profile" '!/^#/ && $1 == id { print $10 }' "$output_directory/geometry-profiles.tsv")
residency_budget_mib=$(awk -F '\t' -v id="$resident_profile" '!/^#/ && $1 == id { print $13 }' "$output_directory/geometry-profiles.tsv")
record session_requests_declared "$session_requests"
record residency_budget_mib "$residency_budget_mib"
record requests_per_block "$requests"
record blocks "$blocks"
record rays_requested "$rays"
[ "$requests" -le "$session_requests" ] ||
    { printf 'requests %s exceed the session the row declares (%s)\n' "$requests" "$session_requests" >&2; exit 2; }

. "$script_directory/gpu-workload-ownership.sh"
gpu_ownership_require >"$output_directory/ownership-before.raw"
scrub_ownership() {
    sed -E -e 's|^(cuda_client) pid=[0-9]+ name=([^ ]+).* used=([0-9]+ MiB) .* verdict=(.*)$|\1 name=\2 used=\3 verdict=\4|' \
        -e 's|name=[^ ]*/([^ /]+)|name=\1|' -e 's|^(named_llama_server_pids)=.*$|\1=redacted|' | scrub_home
}
scrub_ownership <"$output_directory/ownership-before.raw" >"$output_directory/ownership-before.txt"
rm -f "$output_directory/ownership-before.raw"
"$script_directory/device-environment-identity.sh" "$output_directory/device-environment.tsv"

# The conditions a run carried. A stage's absolute timing on this host has
# resisted three explanations, so what the arms are compared on is their ratio
# to each other inside one run; the load and the utilization either side say
# whether a run belongs beside another at all.
record host_load_1m_before "$(cut -d ' ' -f 1 /proc/loadavg)"
record gpu_utilization_before_percent "$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits -i 0)"

QWEN_GPU_COMPUTE_LEASE=$output_directory/state/vulkan-workload.lock
export QWEN_GPU_COMPUTE_LEASE
: >"$QWEN_GPU_COMPUTE_LEASE"

# The sampler reads the driver's compute-client list and the lease ten times a
# second for the whole run. What it answers is the question the worker's own
# accounting cannot: how much device memory the process holds while the lease
# reads free, which is the residency the ledger row admits.
sample_residency() {
    while :; do
        stamp=$(date +%s.%N)
        held=$(flock -n "$QWEN_GPU_COMPUTE_LEASE" true 2>/dev/null && printf free || printf held)
        nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null |
            sed "s|^|$stamp\t$held\t|" || :
        printf '%s\t%s\ttick\n' "$stamp" "$held"
        sleep 0.1
    done
}
sample_residency >"$output_directory/residency-during.raw" 9>&- &
sampler_pid=$!

# The arms alternate rather than running in two batches, so a drift in the host
# over the run reaches both arms rather than one. Each block writes its own
# record and its own runtime stderr.
block=1
while [ "$block" -le "$blocks" ]; do
    for arm in one-shot resident; do
        case $arm in
            one-shot) profile_id=$one_shot_profile ;;
            resident) profile_id=$resident_profile ;;
        esac
        run_id="b${block}${arm}"
        run_id=$(printf '%s' "$run_id" | tr -cd 'A-Za-z0-9_-')
        started=$(date +%s.%N)
        "$PYTHON" "$script_directory/geometry-resident-driver.py" \
            --profiles "$output_directory/geometry-profiles.tsv" \
            --profile-id "$profile_id" \
            --runtime "$output_directory/optix-ray-runtime" \
            --state-dir "$output_directory/state" \
            --record "$output_directory/record-$arm-$block.tsv" \
            --stderr "$output_directory/runtime-$arm-$block.err" \
            --mode "$arm" --requests "$requests" --rays "$rays" --run-id "$run_id" 9>&- \
            >"$output_directory/driver-$arm-$block.out" 2>"$output_directory/driver-$arm-$block.err" ||
            { record "driver_failed.$arm.$block" "$(tail -n 2 "$output_directory/driver-$arm-$block.err" | scrub_home)"; checks_failed=$((checks_failed + 1)); }
        ended=$(date +%s.%N)
        record "session_wall_s.$arm.$block" "$(printf '%s %s' "$started" "$ended" | awk '{ printf "%.3f", $2 - $1 }')"
    done
    block=$((block + 1))
done
kill "$sampler_pid" 2>/dev/null || :; wait "$sampler_pid" 2>/dev/null || :; sampler_pid=''

record host_load_1m_after "$(cut -d ' ' -f 1 /proc/loadavg)"
record gpu_utilization_after_percent "$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits -i 0)"

# The sampler's raw capture names process paths, so it takes the same scrub
# both other device harnesses take before anything reads it.
. "$script_directory/compute-client-record.sh"
qwen_compute_client_record <"$output_directory/residency-during.raw" |
    scrub_home >"$output_directory/residency-during.tsv"
rm -f "$output_directory/residency-during.raw"

# Every request in both arms answered, and every one of them met the reference.
served=$(awk -F '\t' '$1 == "one-shot" || $1 == "resident"' "$output_directory"/record-*.tsv | wc -l)
expected=$((requests * blocks * 2))
check requests_served "$served" "$expected"
disagreements=$(awk -F '\t' '($1 == "one-shot" || $1 == "resident") && $9 != "0" { print }' "$output_directory"/record-*.tsv | wc -l)
check reference_disagreements "$disagreements" 0
retirements=$(awk -F '\t' '$1 == "resident-retire"' "$output_directory"/record-resident-*.tsv | wc -l)
check resident_sessions_retired "$retirements" "$blocks"
holding=$(awk -F '\t' '$1 == "resident-retire" && $11 != "0" { print }' "$output_directory"/record-resident-*.tsv | wc -l)
check retired_holding_device_memory "$holding" 0

# The residency the driver read off the device while no request was in flight.
# A resident session shows a compute client with the lease free; the control
# arm's runtime exists only while its request runs, so a client seen with the
# lease free in an interval where only the control ran would be a process
# neither arm accounts for.
idle_clients=$(awk -F '\t' '$2 == "free" && $3 ~ /optix-ray-runtime/ { print $3 }' "$output_directory/residency-during.tsv" | wc -l)
record runtime_clients_observed_with_lease_free_sampled "$idle_clients"

# The experiment's own claim, read off the driver: a process holding device
# memory at a moment when the compute lease is free is memory residency
# without compute ownership. The sampler beside this run cannot decide it --
# the gap between two requests is shorter than the interval it samples at --
# so the driver takes the reading itself, with the lease checked free and no
# request in flight, and every such reading is a row here.
idle_readings=$(awk -F '\t' '$1 ~ /^resident-idle/ && $12 != "" { print $12 }' "$output_directory"/record-resident-*.tsv)
idle_rows=$(printf '%s\n' "$idle_readings" | grep -c '[0-9]' || :)
idle_positive=$(printf '%s\n' "$idle_readings" | awk '$1 + 0 > 0' | wc -l)
record idle_residency_readings "$idle_rows"
record idle_residency_mib "$(printf '%s ' $idle_readings)"
check residency_observed_without_the_lease "$([ "$idle_rows" -gt 0 ] && [ "$idle_positive" -eq "$idle_rows" ] && printf yes || printf no)" yes
peak_mib=$(awk -F '\t' '$3 ~ /optix-ray-runtime/ { split($3, f, " "); if (f[2] + 0 > peak) peak = f[2] + 0 } END { print peak + 0 }' "$output_directory/residency-during.tsv")
record peak_runtime_residency_mib "$peak_mib"
check residency_within_budget "$([ "$peak_mib" -le "$residency_budget_mib" ] && printf yes || printf no)" yes

check teardown "$("$script_directory/geometry-teardown-check.sh" "$output_directory/state" |
    scrub_home | tee "$output_directory/teardown.txt" |
    sed -n 's/^geometry_teardown=\([a-z]*\).*/\1/p')" clean
gpu_ownership_require >"$output_directory/ownership-after.raw"
scrub_ownership <"$output_directory/ownership-after.raw" >"$output_directory/ownership-after.txt"
rm -f "$output_directory/ownership-after.raw"
after_clients=$(grep -c '^cuda_client' "$output_directory/ownership-after.txt" || :)
record cuda_clients_after "$after_clients"

record checks_total "$checks_total"
record checks_failed "$checks_failed"
if [ "$checks_failed" -eq 0 ]; then
    printf 'geometry_resident_admission=accepted checks=%s\n' "$checks_total"
else
    printf 'geometry_resident_admission=rejected checks=%s failed=%s\n' "$checks_total" "$checks_failed" >&2
    exit 1
fi
