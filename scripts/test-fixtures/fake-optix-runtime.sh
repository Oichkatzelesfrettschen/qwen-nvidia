#!/bin/sh
set -eu

# Stand in for optix-ray-runtime on a host without the card. It takes the
# runtime's argv, prints the one JSON line the service parses, and misbehaves
# on the mode in fake-mode beside it: `ok` answers with every GPU proof held
# and the reference agreeing on every ray, `cpu` answers with
# launch_completed false the way a runtime that never reached the device
# would, `disagree` answers with one ray the host reference contradicts,
# `crash` exits 1 with the runtime's refusal line, `hang` sleeps past any
# deadline, `prose` prints text where JSON is expected, `stage-sum` reports
# stage timings that add past the wall time they were taken inside, and
# `cache-claim` reports the disk cache enabled on a run that disabled it.

[ "$#" -eq 5 ] || { printf 'usage: fake-optix-runtime SCENE QUERY_SET RAY_COUNT DEVICE_INDEX MODULE_CACHE\n' >&2; exit 2; }
scene=$1
query_set=$2
rays=$3
device=$4
module_cache=$5
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
mode=ok
[ -r "$here/fake-mode" ] && mode=$(cat "$here/fake-mode")
[ "$scene" = cube-and-plane ] || { printf 'optix_runtime=rejected reason=unknown_scene\n' >&2; exit 1; }
[ "$query_set" = orbit ] || { printf 'optix_runtime=rejected reason=unknown_query_set\n' >&2; exit 1; }
case $module_cache in
    enabled | disabled) ;;
    *) printf 'optix_runtime=rejected reason=unknown_module_cache\n' >&2; exit 1 ;;
esac
printf 'pid=%s nice=%s\n' "$$" "$(awk '{print $19}' /proc/self/stat)" >"$here/runtime-marker.txt"
case $mode in
    crash) printf 'optix_runtime=rejected reason=optix_context_failed\n' >&2; exit 1 ;;
    hang) trap '' TERM; sleep 600; exit 0 ;;
    flood) head -c 2097152 /dev/zero | tr '\0' 'x'; exit 0 ;;
    prose) printf 'the launch completed\n'; exit 0 ;;
esac
launch=true
agree=$rays
disagree=0
case $mode in
    cpu) launch=false ;;
    disagree) agree=$((rays - 1)); disagree=1 ;;
esac
hits=$((rays * 3 / 4))
misses=$((rays - hits))

# The stages partition one run, so they sum under the wall time, and the module
# stage is the one the disk cache governs: a cold row compiles the PTX where a
# warm row reads it back.
if [ "$module_cache" = enabled ]; then
    cache_enabled=true
    cache_location=$HOME/.cache/qwen-optix-module
    module_ms=1.5
else
    cache_enabled=false
    cache_location=
    module_ms=8.5
fi
wall_ms=12.5
case $mode in
    stage-sum) module_ms=200 ;;
    cache-claim) cache_enabled=true; cache_location=$HOME/.cache/qwen-optix-module ;;
esac
timings=$(printf '"scene_ms":0.1,"cuda_context_ms":0.4,"optix_context_ms":0.6,"accel_ms":0.3,"module_ms":%s,"pipeline_ms":0.7,"sbt_ms":0.1,"upload_ms":0.2,"launch_ms":0.4,"download_ms":0.2,"validate_ms":0.3,"teardown_ms":0.2' "$module_ms")
printf '{"scene":"%s","query_set":"%s","rays":%s,"hits":%s,"misses":%s,"t_min":2.5,"t_max":4.2,"t_mean":3.1,"primitive_hits":[%s,0,0,0,0,0,0,0,0,0,0,0,0,0],"reference_agreement":%s,"reference_disagreement":%s,"results_fnv1a64":"0123456789abcdef","wall_ms":%s,"launch_ms":0.4,"timings":{%s},"module_cache":{"requested":"%s","enabled":%s,"location":"%s"},"gpu":{"context_created":true,"gas_built":true,"pipeline_created":true,"launch_completed":%s,"optix_version":90100,"gas_bytes":4096,"device_name":"NVIDIA GeForce RTX 4070 Ti","device_index":%s}}\n' \
    "$scene" "$query_set" "$rays" "$hits" "$misses" "$hits" "$agree" "$disagree" \
    "$wall_ms" "$timings" "$module_cache" "$cache_enabled" "$cache_location" "$launch" "$device"
