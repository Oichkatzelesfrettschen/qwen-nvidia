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
# `cache-claim` reports the disk cache enabled on a run that disabled it, and
# `rounding` reports stages summing exactly the (stages + 1) half-steps above
# the wall time that three-decimal serialization can produce on a correct run.
#
# The resident form takes `resident` where the ray count stands and the five
# session bounds after the module cache, and serves one request per line on
# stdin the way the compiled runtime does. Its misbehaving modes are the
# claims a supervisor cannot check any other way: `resident-bounds` reads back
# a session other than the one it was given, `resident-protocol` speaks a
# version this tree does not, `resident-holds` retires still holding device
# memory, `resident-served` retires having served more than it was sent,
# `resident-disagree` answers with one ray the host reference contradicts,
# `resident-silent-retire` destroys on reaching its own bound without asking
# for the lease that destruction runs under, and `resident-unauthorized`
# announces the retirement and destroys without waiting for the answer,
# `resident-refuses` answers a well-formed request with a refusal that is no
# bound of its own, so the session goes on and the supervisor is what ends it,
# and
# `resident-early-retire` reaches its idle interval after one request, which
# is the bound a supervisor meets between requests rather than in answer to
# one, and `resident-overallocates` answers a request holding more than the
# application ceiling admits while staying well inside the residency
# allowance, which is the case a single ceiling over both readings cannot
# catch.

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
mode=ok
[ -r "$here/fake-mode" ] && mode=$(cat "$here/fake-mode")
PYTHON=${PYTHON:-python3}
scene=$1
query_set=$2

# The line protocol's version is geometry_protocol.py's, read from that module
# rather than written here: the compiled runtime has it compiled in from the
# same place, so a fixture that carried its own copy would pass a version the
# real binary would fail.
resident_protocol_version() {
    "$PYTHON" -c 'import sys; sys.path.insert(0, sys.argv[1]); import geometry_protocol; print(geometry_protocol.PROTOCOL_VERSION)' \
        "$here/../"
}

if [ "${3:-}" = resident ]; then
    [ "$#" -eq 10 ] || { printf 'usage: fake-optix-runtime SCENE QUERY_SET resident DEVICE MODULE_CACHE REQUESTS SECONDS IDLE RESIDENCY_BUDGET APPLICATION_BUDGET\n' >&2; exit 2; }
    device=$4
    module_cache=$5
    requests=$6
    seconds=$7
    idle=$8
    budget=$9
    application_budget=${10}
    version=$(resident_protocol_version)
    [ "$mode" = resident-protocol ] && version=$((version + 1))
    ready_requests=$requests
    [ "$mode" = resident-bounds ] && ready_requests=$((requests + 1))
    if [ "$module_cache" = enabled ]; then
        cache_enabled=true
        cache_location=$HOME/.cache/qwen-optix-module
    else
        cache_enabled=false
        cache_location=
    fi
    printf '{"protocol":%s,"event":"ready","scene":"%s","query_set":"%s","module_cache":{"requested":"%s","enabled":%s,"location":"%s"},"gpu":{"context_created":true,"gas_built":true,"pipeline_created":true,"optix_version":90100,"gas_bytes":4096,"device_name":"NVIDIA GeForce RTX 4070 Ti","device_index":%s},"timings":{"cuda_context_ms":120.0,"optix_context_ms":40.0,"accel_ms":0.2,"module_ms":1.5,"pipeline_ms":8.0,"sbt_ms":0.1},"startup_ms":170.0,"device_allocated_bytes":16777216,"session_requests":%s,"session_seconds":%s,"idle_timeout_s":%s,"residency_budget_mib":%s,"application_budget_mib":%s}\n' \
        "$version" "$scene" "$query_set" "$module_cache" "$cache_enabled" "$cache_location" \
        "$device" "$ready_requests" "$seconds" "$idle" "$budget" "$application_budget"
    served=0
    reason=shutdown
    request_allocated=16777216
    [ "$mode" = resident-overallocates ] && request_allocated=134217728
    while IFS= read -r line; do
        request_id=$(printf '%s' "$line" | sed -n 's/.*"request_id":"\([A-Za-z0-9_-]*\)".*/\1/p')
        action=$(printf '%s' "$line" | sed -n 's/.*"action":"\([A-Za-z0-9_-]*\)".*/\1/p')
        [ "$action" = shutdown ] && { reason=shutdown; break; }
        rays=$(printf '%s' "$line" | sed -n 's/.*"rays":\([0-9]*\).*/\1/p')
        [ -n "$rays" ] || { reason=shutdown; break; }
        if [ "$mode" = resident-refuses ]; then
            printf '{"protocol":%s,"event":"refused","request_id":"%s","reason":"invalid_argument","detail":"the line names no query of 1 to 1048576 rays"}\n' \
                "$version" "$request_id"
            continue
        fi
        if [ "$mode" = resident-budget ]; then
            printf '{"protocol":%s,"event":"refused","request_id":"%s","reason":"budget_exceeded","detail":"%s rays would take the session past its application allocation ceiling"}\n' \
                "$version" "$request_id" "$rays"
            reason=budget_exceeded
            break
        fi
        served=$((served + 1))
        agree=$rays
        disagree=0
        [ "$mode" = resident-disagree ] && { agree=$((rays - 1)); disagree=1; }
        hits=$((rays * 3 / 4))
        misses=$((rays - hits))
        printf '{"protocol":%s,"event":"result","request_id":"%s","residency":{"request_index":%s,"session_age_s":1.5,"device_allocated_bytes":%s,"requests_remaining":%s},"result":{"scene":"%s","query_set":"%s","rays":%s,"hits":%s,"misses":%s,"t_min":2.5,"t_max":4.2,"t_mean":3.1,"primitive_hits":[%s,0,0,0,0,0,0,0,0,0,0,0,0,0],"reference_agreement":%s,"reference_disagreement":%s,"results_fnv1a64":"0123456789abcdef","wall_ms":12.5,"launch_ms":0.4,"timings":{"scene_ms":0.1,"upload_ms":0.2,"launch_ms":0.4,"download_ms":0.2,"reference_ms":0.2,"compare_ms":0.1},"module_cache":{"requested":"%s","enabled":%s,"location":"%s"},"gpu":{"context_created":true,"gas_built":true,"pipeline_created":true,"launch_completed":true,"optix_version":90100,"gas_bytes":4096,"device_name":"NVIDIA GeForce RTX 4070 Ti","device_index":%s}}}\n' \
            "$version" "$request_id" "$served" "$request_allocated" "$((requests - served))" "$scene" "$query_set" \
            "$rays" "$hits" "$misses" "$hits" "$agree" "$disagree" "$module_cache" \
            "$cache_enabled" "$cache_location" "$device"
        [ "$served" -ge "$requests" ] && { reason=request_limit; break; }
        [ "$mode" = resident-early-retire ] && { reason=idle_timeout; break; }
    done
    # Destroying device state is compute, and a session that reaches a bound
    # of its own reaches it while the supervisor holds no lease. So it
    # announces the retirement it wants and waits for the shutdown line the
    # supervisor sends holding that lease; a retirement the supervisor asked
    # for is authorized already.
    authorized=false
    [ "$reason" = shutdown ] && authorized=true
    if [ "$authorized" = false ] && [ "$mode" != resident-silent-retire ]; then
        printf '{"protocol":%s,"event":"retiring","reason":"%s","requests_served":%s,"session_age_s":2.0}\n' \
            "$version" "$reason" "$served"
        # A request the supervisor sent before it read the notice is already
        # on the wire, so lines are read until the shutdown arrives or the
        # pipe closes. Such a query goes unanswered: the session is over.
        if [ "$mode" != resident-unauthorized ]; then
            while IFS= read -r line; do
                action=$(printf '%s' "$line" | sed -n 's/.*"action":"\([A-Za-z0-9_-]*\)".*/\1/p')
                [ "$action" = shutdown ] && { authorized=true; break; }
            done
        fi
    fi
    retired_bytes=0
    [ "$mode" = resident-holds ] && retired_bytes=16777216
    retired_served=$served
    [ "$mode" = resident-served ] && retired_served=$((served + 1))
    printf '{"protocol":%s,"event":"retired","reason":"%s","requests_served":%s,"session_age_s":2.5,"timings":{"teardown_ms":7.5},"device_allocated_bytes":%s,"authorized":%s}\n' \
        "$version" "$reason" "$retired_served" "$retired_bytes" "$authorized"
    exit 0
fi

[ "$#" -eq 5 ] || { printf 'usage: fake-optix-runtime SCENE QUERY_SET RAY_COUNT DEVICE_INDEX MODULE_CACHE\n' >&2; exit 2; }
rays=$3
device=$4
module_cache=$5
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
    # The thirteen stages below sum to 5.0 with module_ms at 1.5. A wall time
    # 0.007 ms under that is the largest excess thirteen stages rounded up and
    # one total rounded down can produce, so it is the boundary a correct run
    # can reach and the validator has to admit.
    rounding) module_ms=1.5; wall_ms=4.993 ;;
esac
timings=$(printf '"scene_ms":0.1,"cuda_context_ms":0.4,"optix_context_ms":0.6,"accel_ms":0.3,"module_ms":%s,"pipeline_ms":0.7,"sbt_ms":0.1,"upload_ms":0.2,"launch_ms":0.4,"download_ms":0.2,"reference_ms":0.2,"compare_ms":0.1,"teardown_ms":0.2' "$module_ms")
printf '{"scene":"%s","query_set":"%s","rays":%s,"hits":%s,"misses":%s,"t_min":2.5,"t_max":4.2,"t_mean":3.1,"primitive_hits":[%s,0,0,0,0,0,0,0,0,0,0,0,0,0],"reference_agreement":%s,"reference_disagreement":%s,"results_fnv1a64":"0123456789abcdef","wall_ms":%s,"launch_ms":0.4,"timings":{%s},"module_cache":{"requested":"%s","enabled":%s,"location":"%s"},"gpu":{"context_created":true,"gas_built":true,"pipeline_created":true,"launch_completed":%s,"optix_version":90100,"gas_bytes":4096,"device_name":"NVIDIA GeForce RTX 4070 Ti","device_index":%s}}\n' \
    "$scene" "$query_set" "$rays" "$hits" "$misses" "$hits" "$agree" "$disagree" \
    "$wall_ms" "$timings" "$module_cache" "$cache_enabled" "$cache_location" "$launch" "$device"
