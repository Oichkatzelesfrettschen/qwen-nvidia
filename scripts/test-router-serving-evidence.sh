#!/bin/sh
set -eu

# Calibrate scripts/router-serving-evidence.sh against the placement lines a
# retained router admission wrote and against each way that evidence goes
# missing, so the admission's verdict is known to reject the inputs it must
# reject before it counts. The known-bad inputs are the ones the admission
# once accepted: a teardown that reported incomplete, and a server log that
# named no device at all.

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
helper=$script_directory/router-serving-evidence.sh
work_directory=$(mktemp -d "${TMPDIR:-/tmp}/router-serving-evidence.XXXXXX")
trap 'rm -rf "$work_directory"' EXIT INT TERM

failures=0
report() {
    printf '%s=%s\n' "$1" "$2"
    [ "$2" = accepted ] || failures=$((failures + 1))
}

# Two children, each printing its placement line and its breakdown, the way
# evidence/ada/promotion-de074f9738b8/device-lines.txt records them.
lines=$work_directory/device-lines.txt
cat >"$lines" <<'LINES'
[34903] 0.00.208.403 I llama_prepare_model_devices: using device CUDA0 (NVIDIA GeForce RTX 4070 Ti) (0000:0b:00.0) - 9212 MiB free
[34903] 0.00.500.000 I common_memory_breakdown_print: | memory breakdown [MiB] | total   free    self   model   context   compute    unaccounted |
[34903] 0.00.500.001 I common_memory_breakdown_print: |   - CUDA0 (RTX 4070 Ti) | 11933 = 8000 +  (1200 =  1000 +   100 +  100) +   2733 |
[58253] 0.00.231.235 I llama_prepare_model_devices: using device CUDA0 (NVIDIA GeForce RTX 4070 Ti) (0000:0b:00.0) - 9206 MiB free
[58253] 0.00.500.002 I common_memory_breakdown_print: |   - CUDA0 (RTX 4070 Ti) | 11933 = 8000 +  (1200 =  1000 +   100 +  100) +   2733 |
LINES

placement=$("$helper" placement "$lines" 2)
case $placement in
    "serving_device	accepted	2 children allocated on CUDA0")
        report two_children_accepted accepted ;;
    *) report two_children_accepted rejected; printf '%s\n' "$placement" >&2 ;;
esac

# The same child printing twice is one child, so a second child that printed
# nothing leaves the admission short of positive evidence for it.
grep -v '^\[58253\]' "$lines" >"$work_directory/one-child.txt"
placement=$("$helper" placement "$work_directory/one-child.txt" 2)
case $placement in
    "serving_device	incomplete	1 of 2 children named CUDA0")
        report one_child_incomplete accepted ;;
    *) report one_child_incomplete rejected; printf '%s\n' "$placement" >&2 ;;
esac

: >"$work_directory/empty.txt"
placement=$("$helper" placement "$work_directory/empty.txt" 2)
case $placement in
    "serving_device	unobserved	"*) report no_lines_unobserved accepted ;;
    *) report no_lines_unobserved rejected; printf '%s\n' "$placement" >&2 ;;
esac

{
    cat "$lines"
    printf '[61000] 0.00.300.000 I llama_prepare_model_devices: using device Vulkan0 (NVIDIA GeForce RTX 4070 Ti) - 9000 MiB free\n'
} >"$work_directory/vulkan.txt"
placement=$("$helper" placement "$work_directory/vulkan.txt" 2)
case $placement in
    "serving_device	rejected	"*) report vulkan_child_rejected accepted ;;
    *) report vulkan_child_rejected rejected; printf '%s\n' "$placement" >&2 ;;
esac

# A summary every row of which is accepted or observed is the accepting shape.
summary=$work_directory/serving-summary.tsv
{
    printf 'check\tresult\tdetail\n'
    printf 'launch\taccepted\trouter_max=1\n'
    printf 'health\taccepted\twaited=0s\n'
    printf 'resident_children\tobserved\t1:qwen35-08b\n'
    printf 'teardown\taccepted\tsession retired\n'
    printf 'teardown_exclusion\tskipped\trouter children hold the compute lease\n'
    printf 'serving_device\taccepted\t2 children allocated on CUDA0\n'
} >"$summary"
if verdict=$("$helper" verdict "$summary") && [ "$verdict" = 'rejecting=none' ]; then
    report clean_summary_accepted accepted
else
    report clean_summary_accepted rejected
    printf '%s\n' "$verdict" >&2
fi

# Each mutation moves exactly one row outside the vocabulary and the verdict
# has to name that row, so a rejection for some other reason reads as a
# failure here rather than as calibration.
mutate() {
    awk -F'\t' -v check="$1" -v result="$2" -v OFS='\t' \
        '$1 == check { $2 = result } { print }' "$summary"
}
for mutation in 'serving_device unobserved' 'serving_device incomplete' \
    'teardown failed' 'health timeout' 'launch failed'; do
    mutated_check=${mutation% *}
    mutated_result=${mutation#* }
    mutate "$mutated_check" "$mutated_result" >"$work_directory/mutated.tsv"
    set +e
    verdict=$("$helper" verdict "$work_directory/mutated.tsv")
    verdict_status=$?
    set -e
    if [ "$verdict_status" -eq 1 ] &&
        [ "$verdict" = "rejecting=$mutated_check=$mutated_result" ]; then
        report "${mutated_check}_${mutated_result}_rejected" accepted
    else
        report "${mutated_check}_${mutated_result}_rejected" rejected
        printf 'status=%s %s\n' "$verdict_status" "$verdict" >&2
    fi
done

# A skip carries its reason or it is a check that did not run and said
# nothing, which is the shape the vocabulary exists to refuse.
awk -F'\t' -v OFS='\t' '$1 == "teardown_exclusion" { $3 = "" } { print }' "$summary" \
    >"$work_directory/unexplained-skip.tsv"
set +e
verdict=$("$helper" verdict "$work_directory/unexplained-skip.tsv")
verdict_status=$?
set -e
if [ "$verdict_status" -eq 1 ] && [ "$verdict" = 'rejecting=teardown_exclusion=skipped' ]; then
    report unexplained_skip_rejected accepted
else
    report unexplained_skip_rejected rejected
    printf 'status=%s %s\n' "$verdict_status" "$verdict" >&2
fi

if [ "$failures" -eq 0 ]; then
    printf 'router_serving_evidence=accepted\n'
    exit 0
fi
printf 'router_serving_evidence=rejected failures=%s\n' "$failures" >&2
exit 1
