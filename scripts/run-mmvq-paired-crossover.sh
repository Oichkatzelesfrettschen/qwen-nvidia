#!/bin/sh
set -eu

# The promotion-grade crossover campaign. Two llama-bench closures that differ
# in one dispatch threshold are compared width by width as pairs: for each
# width, QWEN_PAIRED_PAIRS pairs of single observations, control then subject
# on odd pairs and subject then control on even ones, so linear drift and
# order bias cancel inside the pair rather than accumulating across a block.
# Every observation is one process load and two timed runs read as per-run
# samples, the first uncounted and the second the observation: llama-bench's
# own warm-up leaves the first timed prefill about three times slow on this
# card (1115 then 3430, 3115, 3404, 3486, 3370 tok/s at seventeen columns),
# so the run after it is the first warm one. Each is admitted by
# gpu-quiescence-gate.sh against the
# baseline registered at the start of the campaign, so a card still hot from
# the last observation or a desktop client that has become busy delays the
# next observation and refuses it after the settling window rather than
# running it hot. Control observations open and close the campaign at the
# first width, and their span is the drift the paired ratios are read
# against. Each observation is one row; the summary reads the paired ratios
# as median, geometric mean, MAD, and interquartile range, and admits a
# threshold only where every width below it is admitted in this campaign.

usage() {
    printf 'usage: %s CONTROL_BENCH SUBJECT_BENCH MODEL_ID OUTPUT_DIRECTORY\n' "$0" >&2
    printf 'environment: QWEN_PAIRED_WIDTHS    default "17 18 19 20"\n' >&2
    printf '             QWEN_PAIRED_PAIRS     default 10\n' >&2
    printf '             QWEN_PAIRED_GENERATE  decode control tokens, default 32\n' >&2
    printf '             QWEN_PAIRED_FLOOR     preregistered paired-gain floor, default 0.051\n' >&2
    printf '             QWEN_PAIRED_THREADS   default 6\n' >&2
    printf '             QWEN_PAIRED_LOCK_CLOCKS  SM MHz to pin for the campaign through sudo -n nvidia-smi, default unset\n' >&2
    printf '             QWEN_MODEL_ROOT       default $HOME/models\n' >&2
    exit 2
}
[ "$#" -eq 4 ] || usage
control_bench=$1
subject_bench=$2
model_id=$3
output_directory=$4
[ -x "$control_bench" ] && [ -x "$subject_bench" ] || usage

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
widths=${QWEN_PAIRED_WIDTHS:-"17 18 19 20"}
pairs=${QWEN_PAIRED_PAIRS:-10}
generate=${QWEN_PAIRED_GENERATE:-32}
floor=${QWEN_PAIRED_FLOOR:-0.051}
threads=${QWEN_PAIRED_THREADS:-6}
model_root=${QWEN_MODEL_ROOT:-"${HOME:?}/models"}
wrapper=$script_directory/cuda-runtime-env.sh
gate=$script_directory/gpu-quiescence-gate.sh

row=$("$script_directory/model-registry.sh" id "$model_id")
field() { printf '%s\n' "$row" | sed -n "s/^$1=//p"; }
model_path=$model_root/$(field model_file)
cache_type_k=$(field cache_type_k)
cache_type_v=$(field cache_type_v)
flash_attention=1
[ "$(field flash_attention)" = on ] || flash_attention=0

# Four pairs is the floor every derived statistic in the summary needs:
# statistics.quantiles requires four points, and the control-drift read
# compares the first three control observations against the last three, whose
# slices coincide at three pairs or fewer and report no movement for a control
# that moved. The refusal is here rather than in the summary because the
# device time is spent before the summary runs.
[ "$pairs" -ge 4 ] || { printf 'refused: paired promotion analysis requires at least four pairs\n' >&2; exit 2; }

mkdir -p "$output_directory"
scrub_home() { sed "s|${HOME:?}|\$HOME|g"; }
. "$script_directory/gpu-workload-ownership.sh"
gpu_ownership_require >"$output_directory/ownership-start.txt"
"$script_directory/gpu-state-latch.sh" require-clear >"$output_directory/gpu-state-latch.txt"

# A seventeen-column prefill of the 0.8B runs in about five milliseconds, and
# the card ramps from its 1275 MHz idle to 2835 MHz over longer than that, so
# a single observation on an idle card measures the ramp rather than the
# kernel: one such read gave 543 tok/s against 3240 under sustained load.
# QWEN_PAIRED_LOCK_CLOCKS names the SM clock the campaign pins through
# `nvidia-smi --lock-gpu-clocks` for its whole duration and releases on exit,
# so every observation runs at one clock state and the quiescence band on the
# clock reads the pinned value. The pin is a driver state change on the
# workstation, reversible, and recorded beside the observations.
lock_clocks=${QWEN_PAIRED_LOCK_CLOCKS:-}
clocks_locked=0
release_clocks() {
    [ "$clocks_locked" -eq 1 ] || return 0
    sudo -n nvidia-smi --reset-gpu-clocks >/dev/null 2>&1 || sudo -n nvidia-smi -rgc >/dev/null 2>&1 || :
    clocks_locked=0
    printf 'gpu_clocks=released\n'
}
trap release_clocks EXIT HUP INT TERM
if [ -n "$lock_clocks" ]; then
    { sudo -n nvidia-smi --lock-gpu-clocks="$lock_clocks,$lock_clocks"; } >"$output_directory/clock-lock.txt" 2>&1 || {
        printf 'clock lock refused: %s\n' "$(cat "$output_directory/clock-lock.txt")" >&2
        exit 75
    }
    clocks_locked=1
    sleep 2
    printf 'gpu_clocks=locked sm_mhz=%s observed=%s\n' "$lock_clocks" \
        "$(nvidia-smi --query-gpu=clocks.sm --format=csv,noheader,nounits | head -1)" | tee -a "$output_directory/clock-lock.txt"
fi
# The baseline is compared verbatim against live reads for the whole run, so
# it stays unscrubbed in the working file and the retained copy is written
# with the home prefix replaced once the campaign ends.
baseline=$output_directory/quiescence-baseline.raw.tsv

for bench in "$control_bench" "$subject_bench"; do
    printf '%s\t%s\n' "$(sha256sum "$bench" | cut -d ' ' -f 1)" "$(printf '%s' "$bench" | scrub_home)"
done >"$output_directory/bench-digests.tsv"

observations=$output_directory/observations.tsv
printf 'phase\twidth\tpair\tposition\tclosure\tsettle_waited_s\tsettle_power_w\tsettle_temperature_c\tsettle_clocks_sm_mhz\tsettle_utilization_gpu\tpp_tok_s\ttg_tok_s\tstatus\tpp_cold_tok_s\ttg_cold_tok_s\n' >"$observations"

observe() {
    # observe PHASE WIDTH PAIR POSITION BENCH
    o_phase=$1; o_width=$2; o_pair=$3; o_position=$4; o_bench=$5
    o_closure=$(basename "$(dirname "$(dirname "$o_bench")")")
    o_label="$o_phase-b$o_width-p$o_pair-$o_position"
    if [ "${warming:-0}" -eq 1 ]; then
        settle="quiescence=warming label=$o_label waited_s=0 power_w=- temperature_c=- clocks_sm_mhz=- utilization_gpu=-"
    elif ! settle=$("$gate" wait "$baseline" "$o_label" 2>"$output_directory/$o_label.gate.err"); then
        printf '%s\t%s\t%s\t%s\t%s\t-\t-\t-\t-\t-\t-\t-\trefused-quiescence\t-\t-\n' \
            "$o_phase" "$o_width" "$o_pair" "$o_position" "$o_closure" >>"$observations"
        printf 'refused: %s\n' "$(cat "$output_directory/$o_label.gate.err")" >&2
        return 75
    fi
    rm -f "$output_directory/$o_label.gate.err"
    settle_field() { printf '%s\n' "$settle" | sed -n "s/.*$1=\([^ ]*\).*/\1/p"; }
    o_log=$output_directory/$o_label.log
    set +e
    QWEN_CUDA_PROFILE=default "$wrapper" "$o_bench" -m "$model_path" --device CUDA0 \
        -ngl 99 -ot '.*=CUDA0' -fa "$flash_attention" -ctk "$cache_type_k" -ctv "$cache_type_v" \
        -p "$o_width" -n "$generate" -r 2 -t "$threads" -o json >"$o_log" 2>"$o_log.err" 9>&-
    o_status=$?
    set -e
    samples=$(python3 - "$o_log" "$o_width" "$generate" <<'PYTHON' 2>/dev/null || printf '%s' '- - - -'
import json
import sys

rows = json.load(open(sys.argv[1], encoding="utf-8"))
want_p, want_g = int(sys.argv[2]), int(sys.argv[3])
pp = next(r["samples_ts"] for r in rows if r["n_prompt"] == want_p and r["n_gen"] == 0)
tg = next(r["samples_ts"] for r in rows if r["n_prompt"] == 0 and r["n_gen"] == want_g)
print(f"{pp[1]:.2f} {tg[1]:.2f} {pp[0]:.2f} {tg[0]:.2f}")
PYTHON
)
    pp=$(printf '%s' "$samples" | cut -d ' ' -f1)
    tg=$(printf '%s' "$samples" | cut -d ' ' -f2)
    pp_cold=$(printf '%s' "$samples" | cut -d ' ' -f3)
    tg_cold=$(printf '%s' "$samples" | cut -d ' ' -f4)
    [ "$pp" != - ] || pp=''
    [ "$tg" != - ] || tg=''
    [ "$o_status" -eq 0 ] && [ -n "$pp" ] && [ -n "$tg" ] || { pp=${pp:--}; tg=${tg:--}; o_status=failed; }
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$o_phase" "$o_width" "$o_pair" "$o_position" "$o_closure" \
        "$(settle_field waited_s)" "$(settle_field power_w)" "$(settle_field temperature_c)" \
        "$(settle_field clocks_sm_mhz)" "$(settle_field utilization_gpu)" "$pp" "$tg" \
        "$([ "$o_status" = 0 ] && printf ok || printf '%s' "$o_status")" "$pp_cold" "$tg_cold" >>"$observations"
    scrub_home <"$o_log" >"$o_log.scrubbed" && mv "$o_log.scrubbed" "$o_log"
    [ -s "$o_log.err" ] || rm -f "$o_log.err"
    [ "$o_status" = 0 ]
}

# The opening controls run ahead of the baseline and warm the card into the
# state the campaign then holds: a baseline read cold at 45 C refused every
# later observation at the 51 C the card settles to under repeated loads, and
# no settling window brings a running card back to its idle temperature.
# The opening observations are therefore gated by the ownership authority
# and the clock pin alone, and the baseline is registered from the state they
# leave behind.
first_width=${widths%% *}
opening=0
warming=1
while [ "$opening" -lt 3 ]; do
    opening=$((opening + 1))
    observe opening-control "$first_width" "$opening" 1 "$control_bench" || exit 75
done
warming=0
"$gate" baseline "$baseline" | scrub_home | tee "$output_directory/quiescence-baseline.txt"
for width in $widths; do
    pair=1
    while [ "$pair" -le "$pairs" ]; do
        if [ $((pair % 2)) -eq 1 ]; then
            observe paired "$width" "$pair" 1 "$control_bench" || exit 75
            observe paired "$width" "$pair" 2 "$subject_bench" || exit 75
        else
            observe paired "$width" "$pair" 1 "$subject_bench" || exit 75
            observe paired "$width" "$pair" 2 "$control_bench" || exit 75
        fi
        pair=$((pair + 1))
    done
    printf 'width=%s pairs=%s\n' "$width" "$pairs"
done
closing=0
while [ "$closing" -lt 3 ]; do
    closing=$((closing + 1))
    observe closing-control "$first_width" "$closing" 1 "$control_bench" || exit 75
done
scrub_home <"$baseline" >"$output_directory/quiescence-baseline.tsv"
rm -f "$baseline"
gpu_ownership_inspect >"$output_directory/ownership-end.raw" 2>&1 || :
scrub_home <"$output_directory/ownership-end.raw" >"$output_directory/ownership-end.txt"
rm -f "$output_directory/ownership-end.raw"

python3 - "$observations" "$output_directory/paired-summary.tsv" "$floor" <<'PYTHON'
import csv
import math
import statistics
import sys
from collections import defaultdict

rows = list(csv.DictReader(open(sys.argv[1], encoding="utf-8"), delimiter="\t"))
floor = float(sys.argv[3])
ok = [r for r in rows if r["status"] == "ok"]
control_closure = next(r["closure"] for r in ok if r["phase"] == "opening-control")
opening = statistics.mean(float(r["pp_tok_s"]) for r in ok if r["phase"] == "opening-control")
closing = statistics.mean(float(r["pp_tok_s"]) for r in ok if r["phase"] == "closing-control")
span = abs(opening - closing) / opening
by = defaultdict(dict)
for r in ok:
    if r["phase"] != "paired":
        continue
    by[(int(r["width"]), int(r["pair"]))][r["closure"] == control_closure] = (float(r["pp_tok_s"]), float(r["tg_tok_s"]))
widths = sorted({w for w, _ in by})
verdicts = {}
with open(sys.argv[2], "w", encoding="utf-8") as h:
    h.write("width\tpairs\tratio_median\tratio_geomean\tratio_mad\tratio_iqr\tratio_min\tratio_max\ttg_ratio_median\tcontrol_span\tfloor\tclears_floor\tsample_count_valid\tpromotion_eligible\tineligibility_reason\twidth_admitted\tthreshold_admitted\n")
    for w in widths:
        ratios, tg_ratios = [], []
        for (ww, p), pair in by.items():
            if ww != w or True not in pair or False not in pair:
                continue
            ratios.append(pair[False][0] / pair[True][0])
            tg_ratios.append(pair[False][1] / pair[True][1])
        ratios.sort()
        # A width whose observations all failed leaves no complete pair. The
        # loop over widths continues, because a `failed` observation records
        # itself and returns without ending the campaign the way a refused
        # quiescence gate does, so the summary states the empty width rather
        # than raising out of statistics.median on the way to it.
        if not ratios:
            verdicts[w] = False
            h.write(f"{w}\t0\tn/a\tn/a\tn/a\tn/a\tn/a\tn/a\tn/a\t{span:.4f}\t{floor}\t"
                    "n/a\tno\tno\tinsufficient_pairs\tno\tno\n")
            continue
        med = statistics.median(ratios)
        geo = math.exp(sum(math.log(x) for x in ratios) / len(ratios))
        mad = statistics.median(abs(x - med) for x in ratios)
        # statistics.quantiles requires four points, so a width measured on
        # fewer pairs reaches the floor comparison through a substitute
        # interval its own sample size does not support. clears_floor reads
        # n/a there and the width is refused admission on sample count, which
        # the reader tells from a measured absence of gain by the pair of
        # fields rather than by one overloaded verdict.
        valid = len(ratios) >= 4
        if valid:
            q = statistics.quantiles(ratios, n=4)
            clears = "yes" if ((med - 1.0) > floor and (geo - 1.0) > floor and q[0] > 1.0) else "no"
            reason = "-" if clears == "yes" else "below_floor"
            iqr = f"{q[2] - q[0]:.4f}"
        else:
            clears = "n/a"
            reason = "insufficient_pairs"
            iqr = "n/a"
        admitted = clears == "yes"
        verdicts[w] = admitted
        threshold = all(verdicts[x] for x in widths if x <= w)
        h.write(f"{w}\t{len(ratios)}\t{med:.4f}\t{geo:.4f}\t{mad:.4f}\t{iqr}\t{ratios[0]:.4f}\t{ratios[-1]:.4f}\t{statistics.median(tg_ratios):.4f}\t{span:.4f}\t{floor}\t{clears}\t{'yes' if valid else 'no'}\t{'yes' if admitted else 'no'}\t{reason}\t{'yes' if admitted else 'no'}\t{'yes' if threshold else 'no'}\n")
selected = max([w for w in widths if all(verdicts[x] for x in widths if x <= w)], default=None)
print(open(sys.argv[2], encoding="utf-8").read())
print(f"control_span={span:.4f} floor={floor} selected_threshold={selected if selected else 'none'}")
PYTHON
