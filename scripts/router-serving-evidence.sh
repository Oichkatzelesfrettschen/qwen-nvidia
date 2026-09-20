#!/bin/sh
set -eu

# gpu-ownership: non-gpu-helper; reads files alone.

# The two verdicts admit-cuda-router-serving.sh reads off its own evidence,
# kept apart from the launch so each is calibrated against a known-good and
# a known-bad input without the appliance.
#
#   placement DEVICE_LINES CHILDREN
#       DEVICE_LINES holds the placement and breakdown lines the router
#       children wrote to the server log; CHILDREN is how many the admission
#       asked for. Prints one summary row, serving_device<TAB>result<TAB>detail.
#   verdict SUMMARY
#       SUMMARY is the serving-summary.tsv. Prints `rejecting=` naming every
#       check whose result is outside `accepted`, `observed`, and a `skipped`
#       that states its reason in the detail column; `none` when there is
#       none; and exits 1 when there is any.
#
# llama-server prefixes every log line with the writing process in brackets,
# so a placement is attributed to a child by that pid: two children asked for
# need two distinct pids reporting `using device CUDA0`. One line proves one
# child and says nothing about where the other allocated, so that reads
# `incomplete`; no line at all reads `unobserved`. Both are outside the
# accepting vocabulary because an admission that read no placement has not
# observed the fact it exists to observe.

usage() {
    printf 'usage: %s placement DEVICE_LINES CHILDREN | verdict SUMMARY\n' "$0" >&2
    exit 2
}

[ "$#" -ge 2 ] || usage
mode=$1

case $mode in
    placement)
        [ "$#" -eq 3 ] || usage
        lines_path=$2
        children=$3
        case $children in
            '' | *[!0-9]* | 0) usage ;;
        esac
        [ -r "$lines_path" ] || {
            printf 'device lines are unreadable: %s\n' "$lines_path" >&2
            exit 1
        }
        if grep -qE 'using device Vulkan0|\(Vulkan0 ' "$lines_path"; then
            printf 'serving_device\trejected\ta child allocated on Vulkan0\n'
            exit 0
        fi
        cuda_children=$(sed -n 's/^\[\([0-9][0-9]*\)\].*using device CUDA0.*/\1/p' \
            "$lines_path" | sort -u | wc -l)
        if [ "$cuda_children" -ge "$children" ]; then
            printf 'serving_device\taccepted\t%s children allocated on CUDA0\n' \
                "$cuda_children"
        elif [ "$cuda_children" -gt 0 ]; then
            printf 'serving_device\tincomplete\t%s of %s children named CUDA0\n' \
                "$cuda_children" "$children"
        else
            printf 'serving_device\tunobserved\tthe server log names no device buffer\n'
        fi
        ;;
    verdict)
        [ "$#" -eq 2 ] || usage
        summary=$2
        [ -r "$summary" ] || {
            printf 'summary is unreadable: %s\n' "$summary" >&2
            exit 1
        }
        rejecting=$(awk -F'\t' 'NR > 1 && $2 != "accepted" && $2 != "observed" &&
            !($2 == "skipped" && $3 != "") { print $1 "=" $2 }' "$summary" | paste -sd , -)
        printf 'rejecting=%s\n' "${rejecting:-none}"
        [ -z "$rejecting" ]
        ;;
    *) usage ;;
esac
