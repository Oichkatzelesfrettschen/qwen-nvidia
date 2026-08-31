#!/bin/sh
set -eu

# Sample device state at sub-second cadence across a model transition. The
# 1 Hz cadence of sample-nvidia-clocks.sh resolves a serving steady state and
# blurs an eviction: a router switch at --models-max 1 frees and refills
# gigabytes of device memory inside a few seconds, and the trough between the
# victim's exit and the successor's allocation is the fact an evict-first
# admission reads. nvidia-smi's own -lms loop supplies the cadence, so the
# cost per row is one query rather than one process.
#
# Output is one TSV row per sample: driver timestamp, framebuffer used and
# reserved MiB, both utilization counters, SM clock, and power draw. The
# sampler runs for DURATION_S and then ends its one child by recorded pid.

usage() {
    printf 'usage: %s OUT_TSV [DURATION_S] [INTERVAL_MS]\n' "$0" >&2
    printf '  DURATION_S  sampling window, default 30\n' >&2
    printf '  INTERVAL_MS sample cadence, default 100\n' >&2
    exit 2
}

[ "$#" -ge 1 ] && [ "$#" -le 3 ] || usage

output_tsv=$1
duration_s=${2:-30}
interval_ms=${3:-100}

case $duration_s in
    '' | *[!0-9]* | 0) usage ;;
esac
case $interval_ms in
    '' | *[!0-9]* | 0) usage ;;
esac

command -v nvidia-smi >/dev/null 2>&1 || {
    printf 'nvidia-smi is absent from PATH\n' >&2
    exit 1
}

mkdir -p "$(dirname -- "$output_tsv")"
printf 'timestamp\tmemory_used_mib\tmemory_reserved_mib\tutilization_gpu_pct\tutilization_memory_pct\tsm_clock_mhz\tpower_draw_w\n' \
    >"$output_tsv"

nvidia-smi -lms "$interval_ms" \
    --query-gpu=timestamp,memory.used,memory.reserved,utilization.gpu,utilization.memory,clocks.sm,power.draw \
    --format=csv,noheader,nounits |
    awk -F', ' 'BEGIN { OFS = "\t" } { $1 = $1; print; fflush() }' \
    >>"$output_tsv" &
sampler_pid=$!

sleep "$duration_s"

# The recorded pid names the awk consumer; ending it closes the pipe and the
# SIGPIPE ends nvidia-smi on its next write. kill by number, never by pattern.
kill "$sampler_pid" 2>/dev/null || true
wait "$sampler_pid" 2>/dev/null || true

sample_rows=$(($(grep -c '' "$output_tsv") - 1))
printf 'transition_telemetry=complete rows=%s interval_ms=%s duration_s=%s output=%s\n' \
    "$sample_rows" "$interval_ms" "$duration_s" "$output_tsv"
