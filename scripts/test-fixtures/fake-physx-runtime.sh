#!/bin/sh
set -eu

# Stand in for physx-rigid-runtime on a host without the SDK or the card. It
# takes the runtime's argv, prints the one JSON line the service parses, and
# misbehaves on the mode in fake-mode beside it: `ok` answers with every GPU proof held,
# `cpu` answers with gpu_dynamics_active false the way a PhysX CPU fallback
# would, `crash` exits 1 with the runtime's refusal line, `hang` sleeps past
# any deadline, and `prose` prints text where JSON is expected.

[ "$#" -eq 5 ] || { printf 'usage: fake-physx-runtime SCENE TIMESTEP_S STEPS GRAVITY_Y DEVICE_INDEX\n' >&2; exit 2; }
scene=$1
timestep=$2
steps=$3
device=$5
# The service hands the runtime a fixed environment, so the mode and the
# marker live beside this script rather than in variables: a test copies it
# into a directory of its own and writes fake-mode there.
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
mode=ok
[ -r "$here/fake-mode" ] && mode=$(cat "$here/fake-mode")
[ "$scene" = d6-chain-4 ] || { printf 'physx_runtime=rejected reason=unknown_scene\n' >&2; exit 1; }
printf 'pid=%s nice=%s\n' "$$" "$(awk '{print $19}' /proc/self/stat)" >"$here/runtime-marker.txt"
case $mode in
    crash) printf 'physx_runtime=rejected reason=cuda_context_invalid\n' >&2; exit 1 ;;
    hang) sleep 3600 ;;
    prose) printf 'the simulation ran fine\n'; exit 0 ;;
esac
active=true
[ "$mode" = cpu ] && active=false
printf '{"gpu":{"cuda_context_valid":true,"gpu_dynamics_requested":true,"gpu_broadphase_requested":true,"gpu_dynamics_active":%s,"device_name":"NVIDIA GeForce RTX 4070 Ti","device_index":%s},' "$active" "$device"
printf '"bodies":[{"id":"box-0","position":[1.2,5.1,0],"orientation":[0,0,0.1,0.995],"linear_velocity":[0,-1,0],"angular_velocity":[0,0,0.2],"sleeping":false}],'
printf '"joints":[{"id":"joint-0","body0":"anchor","body1":"box-0","twist_rad":0.01,"swing_y_rad":0.2,"swing_z_rad":0,"broken":false}],'
printf '"contacts":{"pairs":0,"touching":0},"steps":%s,"timestep_s":%s,"simulate_ms":12.5,"wall_ms":40.0}\n' "$steps" "$timestep"
