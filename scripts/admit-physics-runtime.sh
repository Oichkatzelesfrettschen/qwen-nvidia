#!/bin/sh
set -eu

# Run the physics lane once on the device and retain the proof that the D6
# chain simulated on the GPU. The script compiles the runtime, copies the
# profile ledger with one row raised to validator-gated as the test subject,
# takes the GPU owner lock, starts physics-service.py as an ordinary-user
# child holding the compute lease, sends one physics_simulate_rigid request
# over the service socket, samples the driver's compute-client list while the
# job runs, and reads every claim off the reply: contextIsValid, GPU dynamics
# and broad phase read back from the scene, the device name, the requested
# step count, four unbroken joints, and a chain state that hangs from the
# anchor above the ground plane. The service is then stopped, the teardown
# check proves no service, runtime, socket, or held lease survives, and the
# client list is inspected clean before the lock is released. The row in
# scripts/physics-profiles.tsv stays refused; promotion is a separate
# transition this proof informs.

usage() {
    printf 'usage: %s OUTPUT_DIRECTORY [STEPS]\n' "$0" >&2
    exit 2
}
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
output_directory=$1
steps=${2:-3600}
case $steps in '' | *[!0-9]* | 0*) usage ;; esac
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
profile_id=${QWEN_PHYSICS_PROFILE:-physics-d6-chain-a}

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
"$script_directory/verify-nvidia-sdk.sh" | tee "$output_directory/sdk-verify.txt"
"$script_directory/build-physics-runtime.sh" "$output_directory/physx-rigid-runtime" |
    tee "$output_directory/build.txt"
runtime_sha256=$(sed -n 's/^physics_runtime_sha256=//p' "$output_directory/build.txt")
record physics_runtime_sha256 "$runtime_sha256"
record ordinary_user_uid "$(id -u)"
check ordinary_user "$([ "$(id -u)" -ne 0 ] && printf yes || printf no)" yes

# The subject profile stays refused in the tree; the copy raises it for this
# run alone and the record names both readings.
in_tree_policy=$(awk -F '\t' -v id="$profile_id" '!/^#/ && $1 == id { print $9 }' \
    "$script_directory/physics-profiles.tsv")
[ -n "$in_tree_policy" ] || { printf 'profile %s is absent from the ledger\n' "$profile_id" >&2; exit 1; }
record in_tree_execution_policy "$in_tree_policy"
awk -F '\t' -v OFS='\t' -v id="$profile_id" '!/^#/ && $1 == id { $9 = "validator-gated" } { print }' \
    "$script_directory/physics-profiles.tsv" >"$output_directory/physics-profiles.tsv"
record subject_execution_policy validator-gated
max_steps=$(awk -F '\t' -v id="$profile_id" '!/^#/ && $1 == id { print $4 }' "$output_directory/physics-profiles.tsv")
record steps_requested "$steps"
record profile_max_steps "$max_steps"

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
socket_path=${XDG_RUNTIME_DIR:-/tmp}/qwen-physics-admit.$$.sock
record socket_path "$(printf '%s' "$socket_path" | scrub_home)"

# Every child is launched with 9>&- so the owner claim ends with this script.
python3 "$script_directory/physics-service.py" --state-dir "$output_directory/state" \
    --profiles "$output_directory/physics-profiles.tsv" --runtime "$output_directory/physx-rigid-runtime" \
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

# The sampler reads the driver's client list and the lease ten times a second
# for the whole job, so the runtime's own CUDA context and the held lease are
# observed rather than inferred from the reply.
sample_clients() {
    while :; do
        stamp=$(date +%s.%N)
        held=$(flock -n "$QWEN_GPU_COMPUTE_LEASE" true 2>/dev/null && printf free || printf held)
        nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null |
            sed "s|^|$stamp\t$held\t|" || :
        printf '%s\t%s\ttick\n' "$stamp" "$held"
        sleep 0.1
    done
}
sample_clients >"$output_directory/clients-during.raw" 9>&- &
sampler_pid=$!

request_started=$(date +%s.%N)
python3 - "$socket_path" "$profile_id" "$steps" >"$output_directory/reply.json" <<'PY'
import json, socket, sys
path, profile, steps = sys.argv[1], sys.argv[2], int(sys.argv[3])
message = {"protocol": 1, "action": "physics_simulate_rigid", "request_id": "admit-d6", "profile_id": profile, "steps": steps}
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
python3 - "$output_directory/reply.json" "$steps" "$device_name_smi" >"$output_directory/reply-facts.tsv" <<'PY'
import json, math, sys
reply = json.load(open(sys.argv[1]))
steps, smi_name = int(sys.argv[2]), sys.argv[3]
facts = {"status": reply.get("status"), "reason": reply.get("reason") or "-"}
result = reply.get("result") or {}
gpu = result.get("gpu") or {}
for key in ("cuda_context_valid", "gpu_dynamics_requested", "gpu_broadphase_requested", "gpu_dynamics_active"):
    facts[key] = str(gpu.get(key)).lower()
facts["device_name"] = gpu.get("device_name", "-")
facts["device_name_matches_nvidia_smi"] = "yes" if gpu.get("device_name") == smi_name else "no"
facts["device_index"] = str(gpu.get("device_index"))
facts["steps"] = str(result.get("steps"))
facts["simulate_ms"] = str(result.get("simulate_ms"))
facts["wall_ms"] = str(result.get("wall_ms"))
bodies = result.get("bodies") or []
joints = result.get("joints") or []
facts["body_count"] = str(len(bodies))
facts["joint_count"] = str(len(joints))
facts["joints_unbroken"] = "yes" if joints and not any(j.get("broken") for j in joints) else "no"
# The chain hangs from an anchor at y=6 over a ground plane at y=0 with 0.5
# half-extent boxes, so every center sits below the anchor and above 0.5, and
# consecutive centers stay one joint span (1.2) apart within the solver's slack.
above_ground = all(b["position"][1] > 0.5 for b in bodies) if bodies else False
below_anchor = all(b["position"][1] < 6.0 for b in bodies) if bodies else False
spans = []
previous = None
for body in bodies:
    if previous is not None:
        spans.append(math.dist(previous["position"], body["position"]))
    previous = body
facts["bodies_above_ground"] = "yes" if above_ground else "no"
facts["bodies_below_anchor"] = "yes" if below_anchor else "no"
facts["link_spans"] = ",".join("%.3f" % s for s in spans) or "-"
facts["chain_intact"] = "yes" if spans and all(abs(s - 1.2) < 0.12 for s in spans) else "no"
facts["bodies_finite"] = "yes" if bodies and all(math.isfinite(c) for b in bodies for k in ("position", "linear_velocity") for c in b[k]) else "no"
facts["runtime_sha256"] = result.get("runtime_sha256", "-")
for key, value in facts.items():
    print("%s\t%s" % (key, value))
PY
fact() { awk -F '\t' -v key="$1" '$1 == key { print $2 }' "$output_directory/reply-facts.tsv"; }
check reply_status "$(fact status)" completed
check cuda_context_valid "$(fact cuda_context_valid)" true
check gpu_dynamics_requested "$(fact gpu_dynamics_requested)" true
check gpu_broadphase_requested "$(fact gpu_broadphase_requested)" true
check gpu_dynamics_active "$(fact gpu_dynamics_active)" true
check device_name_matches_nvidia_smi "$(fact device_name_matches_nvidia_smi)" yes
record device_name_runtime "$(fact device_name)"
check steps_simulated "$(fact steps)" "$steps"
check body_count "$(fact body_count)" 4
check joint_count "$(fact joint_count)" 4
check joints_unbroken "$(fact joints_unbroken)" yes
check bodies_finite "$(fact bodies_finite)" yes
check bodies_above_ground "$(fact bodies_above_ground)" yes
check bodies_below_anchor "$(fact bodies_below_anchor)" yes
check chain_intact "$(fact chain_intact)" yes
record link_spans "$(fact link_spans)"
record simulate_ms "$(fact simulate_ms)"
record runtime_wall_ms "$(fact wall_ms)"
check reply_runtime_sha256 "$(fact runtime_sha256)" "$runtime_sha256"

# The during-run record keeps the runtime's client rows and the lease state
# with the pid removed; the count of ticks that saw the runtime is the claim.
awk -F '\t' -v OFS='\t' '$3 == "tick" { print; next }
    { split($3, row, ", "); n = split(row[1], path, "/"); split(row[3], memory, " ");
      print $1, $2, path[n] " " memory[1] " " memory[2] }' <"$output_directory/clients-during.raw" |
    scrub_home >"$output_directory/clients-during.tsv"
rm -f "$output_directory/clients-during.raw"
ticks=$(grep -c '	tick$' "$output_directory/clients-during.tsv" || :)
runtime_ticks=$(grep -c 'physx-rigid-runtime' "$output_directory/clients-during.tsv" || :)
held_ticks=$(grep -c '	held	tick$' "$output_directory/clients-during.tsv" || :)
record sampler_ticks "$ticks"
record runtime_client_ticks "$runtime_ticks"
record lease_held_ticks "$held_ticks"
check runtime_cuda_client_observed "$([ "$runtime_ticks" -gt 0 ] && printf yes || printf no)" yes
check lease_held_observed "$([ "$held_ticks" -gt 0 ] && printf yes || printf no)" yes
check lease_status_released "$(sed -n 's/^state=\([a-z]*\).*/\1/p' "$output_directory/state/vulkan-workload.status")" released
check lease_free_after "$(flock -n "$QWEN_GPU_COMPUTE_LEASE" true 2>/dev/null && printf yes || printf no)" yes

kill "$service_pid"
wait "$service_pid" || :
service_pid=''
check service_exit_clean "$(grep -c . "$output_directory/service.err" || :)" 0
sed -i "s|${HOME:?}|\$HOME|g" "$output_directory/service.out" "$output_directory/service.err"
check socket_removed "$([ -e "$socket_path" ] && printf present || printf absent)" absent
check teardown "$("$script_directory/physics-teardown-check.sh" "$output_directory/state" | sed -n 's/^physics_teardown=\([a-z]*\).*/\1/p')" clean
gpu_ownership_inspect >"$output_directory/ownership-after.raw" 2>&1 && inspect_status=0 || inspect_status=$?
scrub_ownership <"$output_directory/ownership-after.raw" >"$output_directory/ownership-after.txt"
rm -f "$output_directory/ownership-after.raw"
check cuda_clients_clean_after "$inspect_status" 0
check runtime_absent_after "$(grep -c 'physx-rigid-runtime' "$output_directory/ownership-after.txt" || :)" 0
sed -i "s|${HOME:?}|\$HOME|g" "$output_directory/state/physics-audit.log" "$summary" 2>/dev/null || :
rm -f "$output_directory/physx-rigid-runtime"

printf 'admit_physics_runtime=%s checks=%s rejected=%s\n' \
    "$([ "$checks_failed" -eq 0 ] && printf accepted || printf rejected)" "$checks_total" "$checks_failed" |
    tee -a "$summary"
[ "$checks_failed" -eq 0 ]
