#!/bin/sh
set -eu

# Reduce the probe's sample stream to the figures that describe desktop service.
state_directory=${QWEN_WEBUI_STATE_DIRECTORY:-"${HOME:?}/qwen-webui-state"}
log=${1:-$state_directory/graphics-latency.log}

if [ ! -s "$log" ]; then
    printf 'samples=0\n'
    exit 0
fi

grep '^sample' "$log" |
    awk '{for(i=1;i<=NF;i++){split($i,a,"=");v[a[1]]=a[2]} print v["elapsed_us"]+0}' |
    sort -n >"$state_directory/.probe-sorted"

total=$(wc -l <"$state_directory/.probe-sorted")
if [ "$total" -eq 0 ]; then
    printf 'samples=0\n'
    rm -f "$state_directory/.probe-sorted"
    exit 0
fi

at() { awk -v k="$1" 'NR==k{print;exit}' "$state_directory/.probe-sorted"; }
printf 'samples=%s\n' "$total"
printf 'mean=%s\n' "$(awk '{s+=$1} END{printf "%d", s/NR}' "$state_directory/.probe-sorted")"
printf 'p50=%s\n' "$(at $((total * 50 / 100)))"
printf 'p90=%s\n' "$(at $((total * 90 / 100)))"
printf 'p99=%s\n' "$(at $((total * 99 / 100)))"
printf 'max=%s\n' "$(tail -1 "$state_directory/.probe-sorted")"
# One 60 Hz frame is 16,667 us; submissions inside it are invisible to a user.
printf 'frame_ok_pct=%s\n' \
    "$(awk -v t="$total" '$1<=16667{c++} END{printf "%.2f", 100*c/t}' \
        "$state_directory/.probe-sorted")"
printf 'breaches=%s\n' "$(grep -c '^probe_breach' "$log" || true)"
rm -f "$state_directory/.probe-sorted"
