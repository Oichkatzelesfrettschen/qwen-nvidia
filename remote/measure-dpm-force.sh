#!/bin/sh
set -eu

# Measure the effect of the global high-performance governor.
#
# Writing `high` to `power_dpm_force_performance_level` can move SCLK, FCLK,
# and other device power domains together. This experiment therefore measures
# the global governor policy and records both SCLK and the legacy
# `pp_dpm_mclk` FCLK surface; it makes no isolated memory-clock claim. The
# original value is restored from an EXIT trap so an interrupted run leaves the
# laptop on its own governor.
#
# Arms alternate between the two settings rather than running one block each.
# Repeating the same flags ten minutes apart already measured a 4.2% spread on
# this part, which is larger than the effect being looked for, so a block design
# would let that drift stand in for the result.
#
# The requested global level is verified before each arm's rate is trusted. A
# write that the SMU declines leaves the governor where it was and returns a
# number that looks like a measurement of a change that never happened.

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    printf 'usage: %s MODEL_PATH [OUTPUT_DIRECTORY]\n' "$0" >&2
    exit 2
fi

model_path=$1
output_directory=${2:-"${HOME:?}/qwen-dpm-force"}
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
bench=${QWEN_LLAMA_BENCH:-"${HOME:?}/src/llama.cpp-qwen-nvidia/build-qwen-cuda-sm89/bin/llama-bench"}
clock_sampler=${QWEN_CLOCK_SAMPLER:-"$script_directory/sample-gpu-clocks.sh"}
drm_device=${QWEN_DRM_DEVICE:-/sys/class/drm/card1/device}
level_node=$drm_device/power_dpm_force_performance_level
rounds=${QWEN_DPM_ROUNDS:-2}

case $rounds in
    '' | *[!0-9]* | 0)
        printf 'DPM rounds must be a positive integer: %s\n' "$rounds" >&2
        exit 2
        ;;
esac

if [ ! -x "$bench" ] || [ ! -f "$model_path" ]; then
    printf 'llama-bench and the model must both exist\n' >&2
    exit 2
fi
if [ ! -r "$level_node" ]; then
    printf 'performance level node is unreadable: %s\n' "$level_node" >&2
    exit 2
fi
if pgrep -x llama-server >/dev/null 2>&1 || pgrep -x llama-bench >/dev/null 2>&1; then
    printf 'another llama process holds the device\n' >&2
    exit 2
fi
if ! sudo -n true 2>/dev/null; then
    printf 'root is required to write %s and no cached credential exists\n' \
        "$level_node" >&2
    exit 2
fi

original_level=$(cat "$level_node")
sampler_pid=''
stop_sampler() {
    [ -n "$sampler_pid" ] || return 0
    kill "$sampler_pid" 2>/dev/null || true
    wait "$sampler_pid" 2>/dev/null || true
    sampler_pid=''
}
restore_level() {
    printf '%s' "$original_level" | sudo -n tee "$level_node" >/dev/null 2>&1 || true
    printf 'restored_level=%s actual=%s\n' \
        "$original_level" "$(cat "$level_node" 2>/dev/null)"
}
cleanup() {
    stop_sampler
    restore_level
}
trap 'cleanup' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$output_directory"
summary=$output_directory/dpm-summary.tsv
printf 'arm\tlevel\tfclk_before_load\tdecode_tok_s\tstatus\tfclk_modal\tsclk_max\ttemp_c_max\n' \
    >"$summary"

measurement_failed=0

selected_mclk() {
    awk '/\*/ { gsub(/Mhz|:/, "", $2); print $2; exit }' \
        "$drm_device/pp_dpm_mclk" 2>/dev/null
}

run_arm() {
    arm_index=$1
    arm_level=$2
    arm_label=round$arm_index-$arm_level
    arm_log=$output_directory/$arm_label.log
    arm_samples=$output_directory/$arm_label.clocks.tsv

    printf '%s' "$arm_level" | sudo -n tee "$level_node" >/dev/null
    applied_level=$(cat "$level_node")
    if [ "$applied_level" != "$arm_level" ]; then
        printf 'performance level did not take: asked %s, node reads %s\n' \
            "$arm_level" "$applied_level" >&2
        exit 1
    fi
    selected_fclk=$(selected_mclk)
    if [ -z "$selected_fclk" ]; then
        printf 'selected FCLK is unreadable after applying %s\n' \
            "$arm_level" >&2
        return 1
    fi

    printf 'arm_start_utc=%s label=%s level=%s mclk_before_load=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$arm_label" "$applied_level" \
        "$selected_fclk"
    "$clock_sampler" "$arm_samples" 1 &
    sampler_pid=$!
    set +e
    nice -n 19 ionice -c 3 "$bench" -m "$model_path" \
        -ngl 99 -t 2 -r 3 -p 0 -n 64 -o md >"$arm_log" 2>&1
    arm_status=$?
    set -e
    stop_sampler

    if [ "$arm_status" -eq 0 ]; then
        decode=$(awk -F'|' '$0 ~ /\| *tg[0-9]+( @ d[0-9]+)? *\|/ {
                                split($(NF - 1), parts, /[^0-9.]+/)
                                for (i = 1; i <= 3; i++) {
                                    if (parts[i] != "") { rate = parts[i]; break }
                                }
                                spread = parts[i + 1]
                            }
                            END {
                                if (rate == "") { print "n/a" }
                                else { printf "%s+/-%s\n", rate, (spread == "" ? "0" : spread) }
                            }' "$arm_log")
    else
        decode=n/a
    fi
    clock_report=$(awk -F'\t' '
        $1 ~ /^[0-9]+([.][0-9]+)?$/ { count[$1]++; clock_samples++ }
        $2 ~ /^[0-9]+([.][0-9]+)?$/ {
          if ($2 + 0 > sclk_max) { sclk_max = $2 + 0 }
          sclk_samples++
        }
        $3 ~ /^[0-9]+([.][0-9]+)?$/ {
          if ($3 + 0 > temp_max) { temp_max = $3 + 0 }
          temperature_samples++
        }
        END {
            for (step in count) {
                if (count[step] > best) { best = count[step]; modal = step }
            }
            printf "%s\t%s\t%s",
                (clock_samples ? modal : "unavailable"),
                (sclk_samples ? sclk_max : "unavailable"),
                (temperature_samples ? sprintf("%.1f", temp_max / 1000) : "unavailable")
        }' "$arm_samples")

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$arm_label" "$applied_level" \
        "$selected_fclk" "$decode" "$arm_status" "$clock_report" >>"$summary"
    printf 'arm_stop_utc=%s label=%s decode=%s status=%s clocks=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$arm_label" "$decode" "$arm_status" \
        "$(printf '%s' "$clock_report" | tr '\t' ' ')"

    if [ "$arm_status" -ne 0 ] || [ "$decode" = n/a ]; then
        return 1
    fi
    return 0
}

round=1
while [ "$round" -le "$rounds" ]; do
    run_arm "$round" auto || measurement_failed=1
    run_arm "$round" high || measurement_failed=1
    round=$((round + 1))
done

if [ "$measurement_failed" -ne 0 ]; then
    printf 'dpm_force=failed output_directory=%s\n' "$output_directory" >&2
    cat "$summary"
    exit 1
fi

printf 'dpm_force=completed output_directory=%s\n' "$output_directory"
cat "$summary"
