#!/bin/sh
set -eu

# Stand in for physx-rigid-runtime on a host without the SDK or the card. It
# takes the runtime's argv, prints the one JSON line the service parses, and
# misbehaves on the mode in fake-mode beside it: `ok` answers with every GPU proof held,
# `cpu` answers with gpu_dynamics_active false the way a PhysX CPU fallback
# would, `crash` exits 1 with the runtime's refusal line, `hang` sleeps past
# any deadline, `prose` prints text where JSON is expected, and `contacts`
# reports more touching pairs than pairs reaching narrow phase, which the
# counters cannot express and the protocol refuses. Three modes misreport the
# direct-GPU path specifically: `sleep-claim` answers a sleep state the path has
# no source for, `cuda-error` reports a driver error beside a successful read,
# and `path-mismatch` claims the scene holds the direct-GPU flag it declares it
# does not. `dropped-state` completes while reporting the GPU buffer overflow
# that means its own contacts were dropped, which the runtime refuses by name
# and the protocol refuses in a reply that reached it anyway. `joint-claim`
# answers joint angles on the direct-GPU path, where the accessors read poses
# the flag stopped copying back and report the frozen initial transform.

[ "$#" -eq 6 ] || { printf 'usage: fake-physx-runtime SCENE TIMESTEP_S STEPS GRAVITY_Y DEVICE_INDEX STATE_PATH\n' >&2; exit 2; }
scene=$1
timestep=$2
steps=$3
device=$5
state_path=$6
# The service hands the runtime a fixed environment, so the mode and the
# marker live beside this script rather than in variables: a test copies it
# into a directory of its own and writes fake-mode there.
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
mode=ok
[ -r "$here/fake-mode" ] && mode=$(cat "$here/fake-mode")
[ "$scene" = d6-chain-4 ] || { printf 'physx_runtime=rejected reason=unknown_scene\n' >&2; exit 1; }
case $state_path in
    readback | direct-gpu) ;;
    *) printf 'physx_runtime=rejected reason=unknown_state_path\n' >&2; exit 1 ;;
esac
printf 'pid=%s nice=%s\n' "$$" "$(awk '{print $19}' /proc/self/stat)" >"$here/runtime-marker.txt"
case $mode in
    crash) printf 'physx_runtime=rejected reason=cuda_context_invalid\n' >&2; exit 1 ;;
    hang) sleep 3600 ;;
    flood) head -c 2097152 /dev/zero | tr '\0' 'x'; exit 0 ;;
    prose) printf 'the simulation ran fine\n'; exit 0 ;;
esac
active=true
[ "$mode" = cpu ] && active=false

# The direct-GPU path has no source for a sleep state and counts its own
# transfers; the readback path leaves both unmeasured because PhysX performs
# those copies inside fetchResults and reports no count of them.
if [ "$state_path" = direct-gpu ]; then
    direct_active=true
    sleeping=null
    joint_state='"twist_rad":null,"swing_y_rad":null,"swing_z_rad":null,"broken":null'
    transfers='"transfers":{"counted":true,"device_reads":3,"device_to_host_copies":3,"bytes":144,"cuda_last_error":0}'
    divergence='"cpu_accessor_divergence":{"position_max":0.0,"linear_velocity_max":0.0}'
else
    direct_active=false
    sleeping=false
    joint_state='"twist_rad":0.01,"swing_y_rad":0.2,"swing_z_rad":0,"broken":false'
    transfers='"transfers":{"counted":false,"device_reads":null,"device_to_host_copies":null,"bytes":null,"cuda_last_error":null}'
    divergence='"cpu_accessor_divergence":null'
fi
messages='"physx_messages":{"total":0,"invalidating":0}'
case $mode in
    dropped-state) messages='"physx_messages":{"total":3,"invalidating":1}' ;;
    sleep-claim) sleeping=false ;;
    cuda-error) transfers='"transfers":{"counted":true,"device_reads":3,"device_to_host_copies":3,"bytes":144,"cuda_last_error":700}' ;;
    path-mismatch) direct_active=$([ "$direct_active" = true ] && printf false || printf true) ;;
    joint-claim) joint_state='"twist_rad":0,"swing_y_rad":0,"swing_z_rad":0,"broken":false' ;;
esac
printf '{"gpu":{"cuda_context_valid":true,"gpu_dynamics_requested":true,"gpu_broadphase_requested":true,"gpu_dynamics_active":%s,"direct_gpu_active":%s,"device_name":"NVIDIA GeForce RTX 4070 Ti","device_index":%s},' "$active" "$direct_active" "$device"
printf '"state_path":"%s",' "$state_path"
printf '"bodies":[{"id":"box-0","position":[1.2,5.1,0],"orientation":[0,0,0.1,0.995],"linear_velocity":[0,-1,0],"angular_velocity":[0,0,0.2],"sleeping":%s}],' "$sleeping"
printf '"joints":[{"id":"joint-0","body0":"anchor","body1":"box-0",%s}],' "$joint_state"
# The counts are distinct and ordered so the reply exercises the protocol's
# narrow-phase invariants rather than satisfying them with zeros: touching and
# cache hits are subsets of the pairs reaching narrow phase, and the solver and
# broad-phase counters belong to their own stages.
pairs=3
touching=2
[ "$mode" = contacts ] && touching=4
printf '"contacts":{"pairs":%s,"touching":%s,"cache_hits":1},' "$pairs" "$touching"
printf '"solver":{"active_constraints":1},"broadphase":{"adds":2,"removes":0},'
printf '%s,%s,%s,' "$transfers" "$divergence" "$messages"
printf '"steps":%s,"timestep_s":%s,"simulate_ms":12.5,"state_read_ms":0.4,"wall_ms":40.0}\n' "$steps" "$timestep"
