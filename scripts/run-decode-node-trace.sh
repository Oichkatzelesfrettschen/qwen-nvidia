#!/bin/sh
set -eu

# Partition one batch-1 decode token into where its wall time goes.
#
# evidence/ada/ncu-decode-baseline/ established that the mat-vec kernels moving
# the weights already run at the sustainable DRAM roofline, so the per-token
# slack between a measured token and the time that model's own bytes take to
# stream lives in launch, submission, and synchronization rather than in
# bandwidth. Nsight Compute cannot see that slack: it profiles one kernel at a
# time and serializes what it replays. Nsight Systems times the whole timeline,
# and `--cuda-graph-trace=node` is what makes a replayed CUDA graph legible as
# its own nodes rather than as one opaque launch, which is the granularity the
# gaps between nodes are visible at.
#
# The partition is per token, over five terms that sum to the token span:
# device kernel execution, device idle inside the span, CUDA API and graph
# launch host time, host computation covered by no CUDA call, and the
# synchronization the host blocks in. read-nsys-decode-partition.py computes
# them from the capture; this script owns the device, takes the captures, and
# records the state each ran under.
#
# Node granularity carries its own cost and nsys says so: `nsys profile --help`
# states that collecting node activities "may cause significant runtime
# overhead" where graph granularity "can reduce overhead to the minimal". A
# device-idle figure read from a node capture alone cannot separate the gaps
# the decode has from the gaps the instrument added, so each arm takes three
# observations of one shape rather than one:
#
#   untraced   llama-bench with no profiler, the token time being explained
#   graph      the same capture at graph granularity, one row per replay
#   node       the same capture at node granularity, one row per graph node
#
# The graph arm's device_busy is the replay's whole device span including its
# internal gaps, and the node arm's is the sum of the nodes alone, so the
# difference between the two device_idle figures is the time inside the graph
# that no node occupies. The difference between the two spans is what the
# instrument cost, and it bounds how much of that inter-node time is real.
#
# The arms run the repository's runtime-class order: the 2B distill is the
# primary performance target and leads, the 0.8B follows as the secondary fast
# target. Both run the production closure with no candidate patch, because the
# question is where a served token goes rather than what a patch moves.
#
# gpu-ownership: acquires

usage() {
    printf 'usage: %s OUTPUT_DIRECTORY [ARM_ID...]\n' "$0" >&2
    printf '\n' >&2
    printf 'Arms, in preregistered order:\n' >&2
    printf '  decode-2b-q4k   batch-1 decode on qwen38-2b-distill\n' >&2
    printf '  decode-08b-q8   batch-1 decode on qwen35-08b\n' >&2
    printf '\n' >&2
    printf '  QWEN_TRACE_NSYS     nsys, default the one on PATH\n' >&2
    printf '  QWEN_TRACE_BUILD    closure directory holding bin/llama-bench\n' >&2
    printf '  QWEN_TRACE_TOKENS   decoded tokens per arm, default 64\n' >&2
    printf '  QWEN_TRACE_KEEP_REP 1 retains the raw .nsys-rep beside the export\n' >&2
    printf '\n' >&2
    printf 'Each arm takes an untraced rate, a graph-granularity capture, and a\n' >&2
    printf 'node-granularity capture of one shape, so the instrument cost is\n' >&2
    printf 'measured beside the gaps it is used to find.\n' >&2
    exit 2
}

[ "$#" -ge 1 ] || usage
output_directory=$1
shift

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
registry_reader=${QWEN_MODEL_REGISTRY_SCRIPT:-"$script_directory/model-registry.sh"}
models_directory=${QWEN_MODELS_DIRECTORY:-"${HOME:?}/models"}
sweep_wrapper=$script_directory/cuda-runtime-env.sh
partition_reader=$script_directory/read-nsys-decode-partition.py
latch=$script_directory/gpu-state-latch.sh
nsys_binary=${QWEN_TRACE_NSYS:-$(command -v nsys 2>/dev/null || echo /usr/bin/nsys)}
build_directory=${QWEN_TRACE_BUILD:-"${HOME:?}/src/llama.cpp-qwen-nvidia/build-appliance-current"}
bench_binary=$build_directory/bin/llama-bench
# Tokens per arm. The partition reports a per-token distribution rather than a
# mean, so the count sets how many samples that distribution holds; 64 leaves
# the capture small enough that node-granularity tracing overhead stays bounded
# while giving the steady-state window room past the first replay.
decode_tokens=${QWEN_TRACE_TOKENS:-64}
keep_rep=${QWEN_TRACE_KEEP_REP:-0}

fail() {
    printf 'run-decode-node-trace: %s\n' "$1" >&2
    exit 1
}

[ -x "$nsys_binary" ] || fail "nsys is unusable: $nsys_binary"
[ -x "$bench_binary" ] || fail "llama-bench is unusable: $bench_binary"
[ -x "$partition_reader" ] || fail "the partition reader is unusable: $partition_reader"

# One row per arm: id, model, and the cache triple the registry serves it at.
arm_matrix="decode-2b-q4k	qwen38-2b-distill
decode-08b-q8	qwen35-08b"

mkdir -p "$output_directory"
summary=$output_directory/summary.tsv
: >"$summary"

QWEN_GPU_OWNERSHIP_LOCK=${QWEN_GPU_OWNERSHIP_LOCK:-/tmp/qwen-ad104-gpu-0.lock}
export QWEN_GPU_OWNERSHIP_LOCK
. "$script_directory/gpu-workload-ownership.sh"
gpu_ownership_require || exit $?
[ ! -x "$latch" ] || "$latch" require-clear || fail 'the GPU state latch is set'

if dmesg --color=never >/dev/null 2>&1; then
    dmesg_command='dmesg'
elif sudo -n dmesg --color=never >/dev/null 2>&1; then
    dmesg_command='sudo -n dmesg'
else
    fail 'the kernel ring is unreadable, so no stop condition can be observed'
fi
hazard_pattern='ring[^[:cntrl:]]*timeout|GPU reset|NVRM[^[:cntrl:]]*Xid|has fallen off the bus|RmInitAdapter failed|NV_ERR_NO_MEMORY'

ring_signatures() {
    count=$($dmesg_command --color=never 2>/dev/null | grep -Eac "$hazard_pattern" 2>/dev/null || :)
    case $count in
        '' | *[!0-9]*) printf '0\n' ;;
        *) printf '%s\n' "$count" ;;
    esac
}

client_set() {
    nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null |
        tr -d ' ' | sort | tr '\n' ','
}

ring_open=$(ring_signatures)
clients_open=$(client_set)
printf 'kernel_ring\topen\t%s\n' "$ring_open" >>"$summary"
printf 'clients\topen\t%s\n' "$clients_open" >>"$summary"
build_configuration_sha256=$(cut -d ' ' -f 1 \
    "$build_directory/build-configuration.sha256" 2>/dev/null || echo unavailable)
printf 'closure\t%s\t%s\n' "$build_directory" "$build_configuration_sha256" >>"$summary"
printf 'bench_binary_sha256\t%s\n' \
    "$(sha256sum "$bench_binary" | cut -d ' ' -f 1)" >>"$summary"
printf 'nsys_version\t%s\n' \
    "$("$nsys_binary" --version 2>/dev/null | sed -n 's/.*version \([0-9.]*\).*/\1/p')" >>"$summary"
printf 'decode_tokens\t%s\n' "$decode_tokens" >>"$summary"

requested_arms=$*
printf '%s\n' "$arm_matrix" | while IFS='	' read -r arm_id model_id; do
    [ -n "$arm_id" ] || continue
    case $requested_arms in
    '') ;;
    *) case " $requested_arms " in *" $arm_id "*) ;; *) continue ;; esac ;;
    esac

    model_file=$("$registry_reader" id "$model_id" model_file)
    [ -n "$model_file" ] || fail "the registry names no model_file for $model_id"
    model_path=$models_directory/$model_file
    [ -f "$model_path" ] || fail "the model file is absent: $model_path"
    cache_type_k=$("$registry_reader" id "$model_id" cache_type_k)
    cache_type_v=$("$registry_reader" id "$model_id" cache_type_v)

    arm_directory=$output_directory/$arm_id
    mkdir -p "$arm_directory"
    {
        printf 'arm_id=%s\n' "$arm_id"
        printf 'model_id=%s\n' "$model_id"
        printf 'decode_tokens=%s\n' "$decode_tokens"
        printf 'cache_type_k=%s cache_type_v=%s\n' "$cache_type_k" "$cache_type_v"
    } >"$arm_directory/arm.txt"

    # The untraced rate is what everything else is compared against: a token
    # time taken with no profiler attached to it.
    "$sweep_wrapper" "$bench_binary" -m "$model_path" --device CUDA0 \
        -ngl 99 -ot '.*=CUDA0' -fa 1 \
        -ctk "$cache_type_k" -ctv "$cache_type_v" \
        -p 0 -n "$decode_tokens" -r 2 -o json \
        >"$arm_directory/untraced.json" 2>"$arm_directory/untraced.stderr" 9>&- || {
        printf '%s\tuntraced_failed\n' "$arm_id" >>"$summary"
        continue
    }
    # llama-bench's first timed run reads cold even after its own warm-up, so
    # the reported mean of two runs understates the served rate. samples_ts
    # carries the per-repetition figures and the second one is the warm
    # observation this tree compares against.
    untraced_tok_s=$(python3 -c '
import json, sys
runs = json.load(open(sys.argv[1]))
warm = [float(r["samples_ts"][-1]) for r in runs
        if str(r.get("n_gen", "0")) != "0" and r.get("samples_ts")]
print("%.2f" % max(warm) if warm else "-")
' "$arm_directory/untraced.json" 2>/dev/null || echo -)
    printf '%s\tuntraced\ttok_s=%s\n' "$arm_id" "$untraced_tok_s" >>"$summary"

    capture_failed=0
    for granularity in graph node; do
        # The two captures differ by this one option. Sampling and
        # context-switch tracing stay off in both, because the question is the
        # device timeline against the CUDA API timeline and each of those adds
        # host cost to a measurement whose host side is one of the terms.
        "$nsys_binary" profile \
            --trace=cuda --cuda-graph-trace="$granularity" \
            --sample=none --cpuctxsw=none \
            --output "$arm_directory/$granularity" --force-overwrite true \
            -- "$sweep_wrapper" "$bench_binary" -m "$model_path" --device CUDA0 \
            -ngl 99 -ot '.*=CUDA0' -fa 1 \
            -ctk "$cache_type_k" -ctv "$cache_type_v" \
            -p 0 -n "$decode_tokens" -r 1 -o md \
            >"$arm_directory/$granularity.stdout" \
            2>"$arm_directory/$granularity.stderr" 9>&- || {
            printf '%s\t%s\tprofile_failed\n' "$arm_id" "$granularity" >>"$summary"
            capture_failed=1
            break
        }

        "$nsys_binary" export --type sqlite --force-overwrite true \
            --output "$arm_directory/$granularity.sqlite" \
            "$arm_directory/$granularity.nsys-rep" \
            >"$arm_directory/$granularity-export.stdout" \
            2>"$arm_directory/$granularity-export.stderr" 9>&- || {
            printf '%s\t%s\texport_failed\n' "$arm_id" "$granularity" >>"$summary"
            capture_failed=1
            break
        }

        "$partition_reader" "$arm_directory/$granularity.sqlite" \
            --per-token "$arm_directory/$granularity-per-token.tsv" \
            >"$arm_directory/$granularity-partition.tsv" \
            2>"$arm_directory/$granularity-partition.stderr" || {
            printf '%s\t%s\tpartition_failed\n' "$arm_id" "$granularity" >>"$summary"
            capture_failed=1
            break
        }

        # The raw capture is a database rather than a measurement, and this
        # tree commits no raw Nsight database. The partition is what a later
        # reader needs; the digest states which bytes produced it.
        if [ "$keep_rep" != 1 ]; then
            sha256sum "$arm_directory/$granularity.nsys-rep" \
                >"$arm_directory/$granularity-removed-report.sha256"
            rm -f "$arm_directory/$granularity.nsys-rep"
        fi
        sha256sum "$arm_directory/$granularity.sqlite" \
            >"$arm_directory/$granularity-removed-export.sha256"
        rm -f "$arm_directory/$granularity.sqlite"
    done
    [ "$capture_failed" = 0 ] || continue

    for granularity in graph node; do
        tokens_seen=$(awk -F'\t' '$1 == "tokens_partitioned" { print $2 }' \
            "$arm_directory/$granularity-partition.tsv")
        median_span=$(awk -F'\t' '$1 == "median_span_ns" { print $2 }' \
            "$arm_directory/$granularity-partition.tsv")
        median_idle=$(awk -F'\t' '$1 == "median_device_idle_ns" { print $2 }' \
            "$arm_directory/$granularity-partition.tsv")
        printf '%s\t%s\tpartitioned\ttokens=%s median_span_ns=%s median_device_idle_ns=%s\n' \
            "$arm_id" "$granularity" "${tokens_seen:-0}" \
            "${median_span:--}" "${median_idle:--}" >>"$summary"
    done

done

ring_close=$(ring_signatures)
clients_close=$(client_set)
printf 'kernel_ring\tclose\t%s\n' "$ring_close" >>"$summary"
printf 'clients\tclose\t%s\n' "$clients_close" >>"$summary"
[ "$ring_open" = "$ring_close" ] ||
    fail "the kernel ring gained signatures during the run: $ring_open -> $ring_close"

# Every retained surface that names a path carries the home prefix the
# retention policy replaces: llama-bench prints the model path it loaded into
# both stdout streams, llama-bench's JSON carries it as a field, and the
# summary names the closure directory. The suffix list covers all of them
# rather than the four a first version named.
find "$output_directory" -type f \( -name '*.txt' -o -name '*.tsv' \
    -o -name '*.csv' -o -name '*.json' -o -name '*.stderr' \
    -o -name '*.stdout' -o -name '*.sha256' \) \
    -exec sed -i "s#$HOME#\$HOME#g" {} +

printf 'decode_node_trace=complete output=%s\n' "$output_directory"
