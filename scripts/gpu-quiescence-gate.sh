#!/bin/sh
set -eu

# The performance gate above the ownership authority. gpu-workload-ownership.sh
# answers whether another qwen campaign holds the device and records the
# desktop clients as a covariate, which is what serving needs. A one-to-four
# percent comparison needs more: the same clients throughout and a workload
# state that has returned to the baseline the campaign registered, since a
# client that is resident but busy, or a card still hot from the last arm,
# moves a small difference more than the mechanism under test does.
#
# `baseline` samples the device and writes the registered state: the exact
# compute-client identity set (pid, executable, start time) and the medians of
# power, temperature, SM and memory clock, and the four utilization counters
# over QWEN_QUIESCENCE_SAMPLES one-second reads. `wait` re-samples until every
# reading sits inside the band around that baseline and the client set is the
# registered one, and refuses with exit 75 after QWEN_QUIESCENCE_TIMEOUT_S
# rather than running hot. A client leaving or entering is refused at once,
# because no settling window brings a changed set back.

usage() {
    printf 'usage: %s baseline BASELINE_TSV\n' "$0" >&2
    printf '       %s wait BASELINE_TSV [LABEL]\n' "$0" >&2
    printf 'environment: QWEN_QUIESCENCE_SAMPLES    reads per baseline, default 5\n' >&2
    printf '             QWEN_QUIESCENCE_TIMEOUT_S  settling window, default 120\n' >&2
    printf '             QWEN_QUIESCENCE_POWER_W    band half-width, default 15\n' >&2
    printf '             QWEN_QUIESCENCE_TEMP_C     band half-width, default 6\n' >&2
    printf '             QWEN_QUIESCENCE_UTIL_PCT   band half-width, default 15\n' >&2
    printf '             QWEN_QUIESCENCE_CLOCK_MHZ  band half-width, default 300\n' >&2
    printf '             QWEN_GPU_OWNERSHIP_NVIDIA_SMI, QWEN_GPU_OWNERSHIP_PROCFS  fakes for tests\n' >&2
    exit 2
}
[ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage
mode=$1
baseline=$2
label=${3:-}
samples=${QWEN_QUIESCENCE_SAMPLES:-5}
timeout_s=${QWEN_QUIESCENCE_TIMEOUT_S:-120}
band_power=${QWEN_QUIESCENCE_POWER_W:-15}
band_temp=${QWEN_QUIESCENCE_TEMP_C:-6}
band_util=${QWEN_QUIESCENCE_UTIL_PCT:-15}
band_clock=${QWEN_QUIESCENCE_CLOCK_MHZ:-300}
nvidia_smi=${QWEN_GPU_OWNERSHIP_NVIDIA_SMI:-nvidia-smi}
procfs=${QWEN_GPU_OWNERSHIP_PROCFS:-/proc}

# One read of the state: the client set as pid/exe/start-time triples sorted,
# and the eight counters. The encoder and decoder counters name video work a
# browser does that the graphics counter alone hides.
read_clients() {
    "$nvidia_smi" --query-compute-apps=pid --format=csv,noheader 2>/dev/null |
        tr -d ' ' | while IFS= read -r pid; do
            [ -n "$pid" ] || continue
            exe=$(readlink "$procfs/$pid/exe" 2>/dev/null || printf 'unreadable')
            start=$(awk '{ print $22 }' "$procfs/$pid/stat" 2>/dev/null || printf 'unreadable')
            printf '%s/%s/%s\n' "$pid" "$exe" "$start"
        done | LC_ALL=C sort | tr '\n' ' '
}
read_counters() {
    "$nvidia_smi" --query-gpu=power.draw,temperature.gpu,clocks.sm,clocks.mem,utilization.gpu,utilization.memory,utilization.encoder,utilization.decoder \
        --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' | tr ',' '\t'
}

median_of() {
    # median of a whitespace list of numbers
    printf '%s\n' "$@" | LC_ALL=C sort -n | awk '{ v[NR] = $1 } END { if (NR % 2) print v[(NR + 1) / 2]; else printf "%.1f\n", (v[NR / 2] + v[NR / 2 + 1]) / 2 }'
}

case $mode in
    baseline)
        clients=$(read_clients)
        p=''; t=''; cs=''; cm=''; ug=''; um=''; ue=''; ud=''
        i=0
        while [ "$i" -lt "$samples" ]; do
            row=$(read_counters)
            [ -n "$row" ] || { printf 'quiescence: nvidia-smi answered nothing\n' >&2; exit 1; }
            p="$p $(printf '%s' "$row" | cut -f1)"; t="$t $(printf '%s' "$row" | cut -f2)"
            cs="$cs $(printf '%s' "$row" | cut -f3)"; cm="$cm $(printf '%s' "$row" | cut -f4)"
            ug="$ug $(printf '%s' "$row" | cut -f5)"; um="$um $(printf '%s' "$row" | cut -f6)"
            ue="$ue $(printf '%s' "$row" | cut -f7)"; ud="$ud $(printf '%s' "$row" | cut -f8)"
            i=$((i + 1))
            [ "$i" -lt "$samples" ] && sleep 1
        done
        {
            printf 'field\tvalue\n'
            printf 'clients\t%s\n' "$clients"
            printf 'power_w\t%s\n' "$(median_of $p)"
            printf 'temperature_c\t%s\n' "$(median_of $t)"
            printf 'clocks_sm_mhz\t%s\n' "$(median_of $cs)"
            printf 'clocks_mem_mhz\t%s\n' "$(median_of $cm)"
            printf 'utilization_gpu\t%s\n' "$(median_of $ug)"
            printf 'utilization_memory\t%s\n' "$(median_of $um)"
            printf 'utilization_encoder\t%s\n' "$(median_of $ue)"
            printf 'utilization_decoder\t%s\n' "$(median_of $ud)"
            printf 'samples\t%s\n' "$samples"
        } >"$baseline"
        printf 'quiescence_baseline=written path=%s clients=%s\n' "$baseline" "$(printf '%s' "$clients" | wc -w)"
        ;;
    wait)
        [ -f "$baseline" ] || { printf 'quiescence: baseline is absent: %s\n' "$baseline" >&2; exit 2; }
        field() { awk -F'\t' -v k="$1" '$1 == k { print $2 }' "$baseline"; }
        want_clients=$(field clients)
        b_p=$(field power_w); b_t=$(field temperature_c); b_cs=$(field clocks_sm_mhz); b_cm=$(field clocks_mem_mhz)
        b_ug=$(field utilization_gpu); b_um=$(field utilization_memory); b_ue=$(field utilization_encoder); b_ud=$(field utilization_decoder)
        elapsed=0
        while :; do
            clients=$(read_clients)
            if [ "$clients" != "$want_clients" ]; then
                printf 'quiescence=refused label=%s reason=client-set-changed registered=[%s] observed=[%s]\n' \
                    "$label" "$want_clients" "$clients" >&2
                exit 75
            fi
            row=$(read_counters)
            verdict=$(printf '%s\n' "$row" | awk -F'\t' -v bp="$b_p" -v bt="$b_t" -v bcs="$b_cs" -v bcm="$b_cm" \
                -v bug="$b_ug" -v bum="$b_um" -v bue="$b_ue" -v bud="$b_ud" \
                -v dp="$band_power" -v dt="$band_temp" -v du="$band_util" -v dc="$band_clock" '
                function out(name, v, b, d) { if (v > b + d || v < b - d) printf "%s=%s(base %s) ", name, v, b }
                {
                    out("power_w", $1, bp, dp); out("temperature_c", $2, bt, dt)
                    out("clocks_sm_mhz", $3, bcs, dc); out("clocks_mem_mhz", $4, bcm, dc)
                    out("utilization_gpu", $5, bug, du); out("utilization_memory", $6, bum, du)
                    out("utilization_encoder", $7, bue, du); out("utilization_decoder", $8, bud, du)
                }')
            if [ -z "$verdict" ]; then
                printf 'quiescence=settled label=%s waited_s=%s power_w=%s temperature_c=%s clocks_sm_mhz=%s utilization_gpu=%s\n' \
                    "$label" "$elapsed" "$(printf '%s' "$row" | cut -f1)" "$(printf '%s' "$row" | cut -f2)" \
                    "$(printf '%s' "$row" | cut -f3)" "$(printf '%s' "$row" | cut -f5)"
                exit 0
            fi
            if [ "$elapsed" -ge "$timeout_s" ]; then
                printf 'quiescence=refused label=%s reason=settling-timeout waited_s=%s outside_band=%s\n' \
                    "$label" "$elapsed" "$verdict" >&2
                exit 75
            fi
            sleep 1
            elapsed=$((elapsed + 1))
        done
        ;;
    *) usage ;;
esac
