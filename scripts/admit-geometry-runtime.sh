#!/bin/sh
set -eu

# Run the geometry lane once on the device and retain the proof that the ray
# query ran through OptiX on the GPU. The script compiles the runtime, copies
# the profile ledger with one row raised to validator-gated as the test
# subject, takes the GPU owner lock, starts geometry-service.py as an
# ordinary-user child holding the compute lease, sends one geometry_ray_query
# request over the service socket, samples the driver's compute-client list
# while the job runs, and reads every claim off the reply: the OptiX device
# context, the acceleration structure with its byte count, the pipeline, the
# completed launch, the device name, the requested ray count, hits on the
# cube and the ground beside misses above them, and the host reference
# agreeing on every ray. The service is then stopped, the teardown check
# proves no service, runtime, socket, or held lease survives, and the client
# list is inspected clean before the lock is released. The row in
# scripts/geometry-profiles.tsv stays refused; promotion is a separate
# transition this proof informs.
#
# gpu-ownership: acquires the owner lock for its whole run.

usage() {
    printf 'usage: %s OUTPUT_DIRECTORY [RAYS]\n' "$0" >&2
    exit 2
}
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
output_directory=$1
rays=${2:-262144}
case $rays in '' | *[!0-9]* | 0*) usage ;; esac
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
profile_id=${QWEN_GEOMETRY_PROFILE:-geometry-cube-orbit-a}

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

service_pid=''
sampler_pid=''
cleanup() {
    status=$?
    if [ -n "$sampler_pid" ]; then kill "$sampler_pid" 2>/dev/null || :; fi
    if [ -n "$service_pid" ] && kill -0 "$service_pid" 2>/dev/null; then
        kill "$service_pid" 2>/dev/null || :
        wait "$service_pid" 2>/dev/null || :
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

"$script_directory/gpu-state-latch.sh" require-clear
"$script_directory/gpu-state-latch.sh" status | tee "$output_directory/latch.txt"
"$script_directory/build-geometry-runtime.sh" "$output_directory/optix-ray-runtime" |
    tee "$output_directory/build.txt"
runtime_sha256=$(sed -n 's/^geometry_runtime_sha256=//p' "$output_directory/build.txt")
record geometry_runtime_sha256 "$runtime_sha256"
record optix_header_version "$(sed -n 's/^optix_version=//p' "$output_directory/build.txt")"
record ptx_sha256 "$(sed -n 's/^ptx_sha256=//p' "$output_directory/build.txt")"
record ordinary_user_uid "$(id -u)"
check ordinary_user "$([ "$(id -u)" -ne 0 ] && printf yes || printf no)" yes

# The subject profile stays refused in the tree; the copy raises it for this
# run alone and the record names both readings.
in_tree_policy=$(awk -F '\t' -v id="$profile_id" '!/^#/ && $1 == id { print $6 }' \
    "$script_directory/geometry-profiles.tsv")
[ -n "$in_tree_policy" ] || { printf 'profile %s is absent from the ledger\n' "$profile_id" >&2; exit 1; }
record in_tree_execution_policy "$in_tree_policy"
awk -F '\t' -v OFS='\t' -v id="$profile_id" '!/^#/ && $1 == id { $6 = "validator-gated" } { print }' \
    "$script_directory/geometry-profiles.tsv" >"$output_directory/geometry-profiles.tsv"
record subject_execution_policy validator-gated
max_rays=$(awk -F '\t' -v id="$profile_id" '!/^#/ && $1 == id { print $4 }' "$output_directory/geometry-profiles.tsv")
record rays_requested "$rays"
record profile_max_rays "$max_rays"

. "$script_directory/gpu-workload-ownership.sh"
gpu_ownership_require >"$output_directory/ownership-before.raw"
scrub_ownership() {
    sed -E -e 's|^(cuda_client) pid=[0-9]+ name=([^ ]+).* used=([0-9]+ MiB) .* verdict=(.*)$|\1 name=\2 used=\3 verdict=\4|' \
        -e 's|name=[^ ]*/([^ /]+)|name=\1|' -e 's|^(named_llama_server_pids)=.*$|\1=redacted|' | scrub_home
}
scrub_ownership <"$output_directory/ownership-before.raw" >"$output_directory/ownership-before.txt"
rm -f "$output_directory/ownership-before.raw"
"$script_directory/device-environment-identity.sh" "$output_directory/device-environment.tsv"
device_name_smi=$(nvidia-smi --query-gpu=name --format=csv,noheader -i 0 | sed 's/^ *//; s/ *$//')
record device_name_nvidia_smi "$device_name_smi"

QWEN_GPU_COMPUTE_LEASE=$output_directory/state/vulkan-workload.lock
export QWEN_GPU_COMPUTE_LEASE
: >"$QWEN_GPU_COMPUTE_LEASE"
# AF_UNIX bounds a socket path at 107 bytes and an evidence directory under
# a worktree exceeds it, so the socket binds under the runtime directory and
# the state directory keeps the lease, the status line, and the audit log.
socket_path=${XDG_RUNTIME_DIR:-/tmp}/qwen-geometry-admit.$$.sock
record socket_path "$(printf '%s' "$socket_path" | scrub_home)"

# Every child is launched with 9>&- so the owner claim ends with this script.
python3 "$script_directory/geometry-service.py" --state-dir "$output_directory/state" \
    --profiles "$output_directory/geometry-profiles.tsv" --runtime "$output_directory/optix-ray-runtime" \
    --socket "$socket_path" --lease-wait-s 5 >"$output_directory/service.out" 2>"$output_directory/service.err" 9>&- &
service_pid=$!
waited=0
until grep -q '^listening' "$output_directory/service.out" 2>/dev/null; do
    kill -0 "$service_pid" 2>/dev/null || { cat "$output_directory/service.err" >&2; exit 1; }
    [ "$waited" -lt 100 ] || { printf 'service did not announce\n' >&2; exit 1; }
    sleep 0.1; waited=$((waited + 1))
done
record service_pid_uid "$(stat -c %u "/proc/$service_pid")"
check service_announced_runtime "$(sed -n 's/.*runtime_sha256=\([0-9a-f]*\).*/\1/p' "$output_directory/service.out")" "$runtime_sha256"

# The sampler reads the driver's client list, the runtime's own device
# handles, and the lease ten times a second for the whole job. NVML's
# compute-client list is read for the record; what proves the runtime
# reached the device is the kernel's view of the process, read out of /proc
# by pid: a descriptor on /dev/nvidia* and libnvoptix.so.1 in its mappings
# while the lease reads held. The runtime's comm is its first fifteen bytes.
sample_clients() {
    while :; do
        stamp=$(date +%s.%N)
        held=$(flock -n "$QWEN_GPU_COMPUTE_LEASE" true 2>/dev/null && printf free || printf held)
        nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null |
            sed "s|^|$stamp\t$held\t|" || :
        for runtime_pid in $(pgrep -x optix-ray-runti 2>/dev/null); do
            device_fds=$(find "/proc/$runtime_pid/fd" -maxdepth 1 -lname '/dev/nvidia*' 2>/dev/null | wc -l)
            optix_mapped=$(grep -c 'libnvoptix\.so' "/proc/$runtime_pid/maps" 2>/dev/null || :)
            printf '%s\t%s\truntime pid=%s device_fds=%s libnvoptix_maps=%s\n' "$stamp" "$held" "$runtime_pid" "$device_fds" "$optix_mapped"
        done
        printf '%s\t%s\ttick\n' "$stamp" "$held"
        sleep 0.1
    done
}
sample_clients >"$output_directory/clients-during.raw" 9>&- &
sampler_pid=$!

request_started=$(date +%s.%N)
python3 - "$socket_path" "$profile_id" "$rays" >"$output_directory/reply.json" <<'PY'
import json, socket, sys
path, profile, rays = sys.argv[1], sys.argv[2], int(sys.argv[3])
message = {"protocol": 1, "action": "geometry_ray_query", "request_id": "admit-orbit", "profile_id": profile, "rays": rays}
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
    connection.settimeout(300)
    connection.connect(path)
    connection.sendall((json.dumps(message) + "\n").encode())
    buffer = b""
    while b"\n" not in buffer:
        chunk = connection.recv(65536)
        if not chunk:
            break
        buffer += chunk
sys.stdout.write(buffer.decode())
PY
request_ended=$(date +%s.%N)
kill "$sampler_pid" 2>/dev/null || :; wait "$sampler_pid" 2>/dev/null || :; sampler_pid=''
record request_wall_s "$(printf '%s %s' "$request_started" "$request_ended" | awk '{ printf "%.3f", $2 - $1 }')"

# The reply is read by one Python pass that prints tab-separated facts; the
# shell compares each against its expectation.
python3 - "$output_directory/reply.json" "$rays" "$device_name_smi" >"$output_directory/reply-facts.tsv" <<'PY'
import json, sys
reply = json.load(open(sys.argv[1]))
rays, smi_name = int(sys.argv[2]), sys.argv[3]
facts = {"status": reply.get("status"), "reason": reply.get("reason") or "-"}
result = reply.get("result") or {}
gpu = result.get("gpu") or {}
for key in ("context_created", "gas_built", "pipeline_created", "launch_completed"):
    facts[key] = str(gpu.get(key)).lower()
facts["optix_version"] = str(gpu.get("optix_version"))
facts["gas_bytes"] = str(gpu.get("gas_bytes"))
facts["gas_bytes_positive"] = "yes" if isinstance(gpu.get("gas_bytes"), int) and gpu["gas_bytes"] > 0 else "no"
facts["device_name"] = gpu.get("device_name", "-")
facts["device_name_matches_nvidia_smi"] = "yes" if gpu.get("device_name") == smi_name else "no"
facts["device_index"] = str(gpu.get("device_index"))
facts["rays"] = str(result.get("rays"))
facts["hits"] = str(result.get("hits"))
facts["misses"] = str(result.get("misses"))
# the orbit set aims across the cube's height from three units out, so a
# set of any size hits the cube and the ground and misses above the cube
facts["hits_and_misses_present"] = "yes" if (result.get("hits") or 0) > 0 and (result.get("misses") or 0) > 0 else "no"
primitive_hits = result.get("primitive_hits") or []
facts["primitive_count"] = str(len(primitive_hits))
facts["cube_faces_hit"] = str(sum(1 for c in primitive_hits[:12] if c > 0))
facts["ground_hit"] = "yes" if len(primitive_hits) == 14 and (primitive_hits[12] + primitive_hits[13]) > 0 else "no"
facts["reference_agreement"] = str(result.get("reference_agreement"))
facts["reference_disagreement"] = str(result.get("reference_disagreement"))
facts["t_range"] = "%s..%s" % (result.get("t_min"), result.get("t_max"))
facts["results_fnv1a64"] = result.get("results_fnv1a64", "-")
facts["launch_ms"] = str(result.get("launch_ms"))
facts["wall_ms"] = str(result.get("wall_ms"))
facts["runtime_sha256"] = result.get("runtime_sha256", "-")
for key, value in facts.items():
    print("%s\t%s" % (key, value))
PY
fact() { awk -F '\t' -v key="$1" '$1 == key { print $2 }' "$output_directory/reply-facts.tsv"; }
check reply_status "$(fact status)" completed
check context_created "$(fact context_created)" true
check gas_built "$(fact gas_built)" true
check pipeline_created "$(fact pipeline_created)" true
check launch_completed "$(fact launch_completed)" true
check gas_bytes_positive "$(fact gas_bytes_positive)" yes
record gas_bytes "$(fact gas_bytes)"
record optix_version_runtime "$(fact optix_version)"
check device_name_matches_nvidia_smi "$(fact device_name_matches_nvidia_smi)" yes
record device_name_runtime "$(fact device_name)"
check rays_traced "$(fact rays)" "$rays"
check hits_and_misses_present "$(fact hits_and_misses_present)" yes
check primitive_count "$(fact primitive_count)" 14
check ground_hit "$(fact ground_hit)" yes
record cube_faces_hit "$(fact cube_faces_hit)"
record hits "$(fact hits)"
record misses "$(fact misses)"
check reference_disagreement "$(fact reference_disagreement)" 0
check reference_agreement "$(fact reference_agreement)" "$rays"
record t_range "$(fact t_range)"
record results_fnv1a64 "$(fact results_fnv1a64)"
record launch_ms "$(fact launch_ms)"
record runtime_wall_ms "$(fact wall_ms)"
check reply_runtime_sha256 "$(fact runtime_sha256)" "$runtime_sha256"

# The during-run record keeps the runtime's client rows and the lease state
# with the pid removed; the count of ticks that saw the runtime is the claim.
awk -F '\t' -v OFS='\t' '$3 == "tick" || $3 ~ /^runtime pid=/ { print; next }
    { split($3, row, ", "); n = split(row[1], path, "/"); split(row[3], memory, " ");
      print $1, $2, path[n] " " memory[1] " " memory[2] }' <"$output_directory/clients-during.raw" |
    scrub_home >"$output_directory/clients-during.tsv"
rm -f "$output_directory/clients-during.raw"
ticks=$(grep -c '	tick$' "$output_directory/clients-during.tsv" || :)
runtime_ticks=$(grep -c 'optix-ray-runtime' "$output_directory/clients-during.tsv" || :)
held_ticks=$(grep -c '	held	tick$' "$output_directory/clients-during.tsv" || :)
runtime_proc_ticks=$(grep -c '	runtime pid=' "$output_directory/clients-during.tsv" || :)
device_fd_ticks=$(grep -Ec '	runtime pid=[0-9]+ device_fds=[1-9]' "$output_directory/clients-during.tsv" || :)
optix_map_ticks=$(grep -Ec 'libnvoptix_maps=[1-9]' "$output_directory/clients-during.tsv" || :)
record sampler_ticks "$ticks"
record runtime_nvml_client_ticks "$runtime_ticks"
record runtime_proc_ticks "$runtime_proc_ticks"
record runtime_device_fd_ticks "$device_fd_ticks"
record runtime_libnvoptix_ticks "$optix_map_ticks"
record lease_held_ticks "$held_ticks"
check runtime_device_node_observed "$([ "$device_fd_ticks" -gt 0 ] && printf yes || printf no)" yes
check runtime_libnvoptix_observed "$([ "$optix_map_ticks" -gt 0 ] && printf yes || printf no)" yes
check lease_held_observed "$([ "$held_ticks" -gt 0 ] && printf yes || printf no)" yes
check lease_status_released "$(sed -n 's/^state=\([a-z]*\).*/\1/p' "$output_directory/state/vulkan-workload.status")" released
check lease_free_after "$(flock -n "$QWEN_GPU_COMPUTE_LEASE" true 2>/dev/null && printf yes || printf no)" yes

kill "$service_pid"
wait "$service_pid" || :
service_pid=''
check service_exit_clean "$(grep -c . "$output_directory/service.err" || :)" 0
sed -i "s|${HOME:?}|\$HOME|g" "$output_directory/service.out" "$output_directory/service.err"
check socket_removed "$([ -e "$socket_path" ] && printf present || printf absent)" absent
check teardown "$("$script_directory/geometry-teardown-check.sh" "$output_directory/state" | sed -n 's/^geometry_teardown=\([a-z]*\).*/\1/p')" clean
gpu_ownership_inspect >"$output_directory/ownership-after.raw" 2>&1 && inspect_status=0 || inspect_status=$?
scrub_ownership <"$output_directory/ownership-after.raw" >"$output_directory/ownership-after.txt"
rm -f "$output_directory/ownership-after.raw"
check cuda_clients_clean_after "$inspect_status" 0
check runtime_absent_after "$(grep -c 'optix-ray-runtime' "$output_directory/ownership-after.txt" || :)" 0
sed -i "s|${HOME:?}|\$HOME|g" "$output_directory/state/geometry-audit.log" "$summary" 2>/dev/null || :
rm -f "$output_directory/optix-ray-runtime"

printf 'admit_geometry_runtime=%s checks=%s rejected=%s\n' \
    "$([ "$checks_failed" -eq 0 ] && printf accepted || printf rejected)" "$checks_total" "$checks_failed" |
    tee -a "$summary"
[ "$checks_failed" -eq 0 ]
