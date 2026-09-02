#!/bin/sh
set -eu

# gpu-quiescence-gate.sh against a fake nvidia-smi and a fake /proc. The fake
# answers the client query from one file and the counter query from another,
# so a test moves the device state by rewriting a file between calls and reads
# the gate's verdict from its exit status and its one summary line.

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
gate=$script_directory/gpu-quiescence-gate.sh
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT HUP INT TERM
failures=0
report() {
    printf 'check=%s outcome=%s\n' "$1" "$2"
    [ "$2" = pass ] || failures=$((failures + 1))
}

mkdir -p "$work/proc/100" "$work/proc/200"
printf '100 (kwin) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 0 0 1 0 4765 0 0 0\n' >"$work/proc/100/stat"
printf '200 (msedge) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 0 0 1 0 12875904 0 0 0\n' >"$work/proc/200/stat"
ln -s /usr/bin/env "$work/proc/100/exe"
ln -s /usr/bin/env "$work/proc/200/exe"
printf '100\n200\n' >"$work/clients"
printf '57.3, 50, 2835, 10501, 46, 5, 0, 0\n' >"$work/counters"
cat >"$work/nvidia-smi" <<FAKE
#!/bin/sh
case "\$*" in
    *query-compute-apps*) cat "$work/clients" ;;
    *query-gpu*) cat "$work/counters" ;;
    *) exit 2 ;;
esac
FAKE
chmod 755 "$work/nvidia-smi"
export QWEN_GPU_OWNERSHIP_NVIDIA_SMI=$work/nvidia-smi QWEN_GPU_OWNERSHIP_PROCFS=$work/proc

if QWEN_QUIESCENCE_SAMPLES=1 "$gate" baseline "$work/baseline.tsv" >"$work/baseline.out" &&
    grep -q 'quiescence_baseline=written' "$work/baseline.out" &&
    [ "$(awk -F'\t' '$1 == "power_w" { print $2 }' "$work/baseline.tsv")" = 57.3 ] &&
    grep -q '^clients	100//usr/bin/env/4765 200//usr/bin/env/12875904 $' "$work/baseline.tsv"; then
    report baseline_records_clients_and_medians pass
else
    report baseline_records_clients_and_medians fail
fi

if out=$(QWEN_QUIESCENCE_TIMEOUT_S=2 "$gate" wait "$work/baseline.tsv" steady) &&
    printf '%s' "$out" | grep -q 'quiescence=settled label=steady waited_s=0'; then
    report wait_settles_inside_band pass
else
    report wait_settles_inside_band fail
fi

# Power 40 W above the baseline settles only after the file returns to band;
# a two-second timeout ends it as refused with the counter named.
printf '97.3, 50, 2835, 10501, 46, 5, 0, 0\n' >"$work/counters"
set +e
QWEN_QUIESCENCE_TIMEOUT_S=2 "$gate" wait "$work/baseline.tsv" hot >/dev/null 2>"$work/hot.err"
status=$?
set -e
if [ "$status" -eq 75 ] && grep -q 'reason=settling-timeout' "$work/hot.err" &&
    grep -q 'power_w=97.3(base 57.3)' "$work/hot.err"; then
    report out_of_band_refused_after_timeout pass
else
    report out_of_band_refused_after_timeout "status-$status"
fi

# The band's own edge admits: 15 W over settles, and a raised encoder counter
# past the utilization band refuses by name.
printf '72.3, 50, 2835, 10501, 46, 5, 0, 0\n' >"$work/counters"
if QWEN_QUIESCENCE_TIMEOUT_S=1 "$gate" wait "$work/baseline.tsv" edge >/dev/null 2>&1; then
    report band_edge_admits pass
else
    report band_edge_admits fail
fi
printf '57.3, 50, 2835, 10501, 46, 5, 40, 0\n' >"$work/counters"
set +e
QWEN_QUIESCENCE_TIMEOUT_S=1 "$gate" wait "$work/baseline.tsv" encode >/dev/null 2>"$work/encode.err"
status=$?
set -e
if [ "$status" -eq 75 ] && grep -q 'utilization_encoder=40(base 0)' "$work/encode.err"; then
    report encoder_activity_refused pass
else
    report encoder_activity_refused "status-$status"
fi

# A client entering or leaving refuses at once, without a settling wait.
printf '57.3, 50, 2835, 10501, 46, 5, 0, 0\n' >"$work/counters"
printf '100\n' >"$work/clients"
set +e
start=$(date +%s)
QWEN_QUIESCENCE_TIMEOUT_S=30 "$gate" wait "$work/baseline.tsv" left >/dev/null 2>"$work/left.err"
status=$?
set -e
if [ "$status" -eq 75 ] && grep -q 'reason=client-set-changed' "$work/left.err" &&
    [ $(( $(date +%s) - start )) -lt 5 ]; then
    report client_set_change_refused_at_once pass
else
    report client_set_change_refused_at_once "status-$status"
fi

# The same pid with a new start time is a new process, not the registered one.
printf '100\n200\n' >"$work/clients"
printf '200 (msedge) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 0 0 1 0 99999999 0 0 0\n' >"$work/proc/200/stat"
set +e
QWEN_QUIESCENCE_TIMEOUT_S=1 "$gate" wait "$work/baseline.tsv" restarted >/dev/null 2>"$work/restarted.err"
status=$?
set -e
if [ "$status" -eq 75 ] && grep -q 'reason=client-set-changed' "$work/restarted.err"; then
    report restarted_client_refused pass
else
    report restarted_client_refused "status-$status"
fi

if [ "$failures" -eq 0 ]; then
    printf 'gpu_quiescence_gate=accepted checks=7\n'
else
    printf 'gpu_quiescence_gate=rejected failures=%s\n' "$failures" >&2
    exit 1
fi
