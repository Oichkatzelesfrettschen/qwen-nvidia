#!/bin/sh
set -eu

# Read what a kernel spends, from counters rather than from a rate.
#
# Every other profiling harness in this tree runs Nsight Systems, which times a
# launch and cannot say why the launch took that long. This one runs Nsight
# Compute over one kernel family per arm and retains the memory, occupancy, and
# scheduler counters that separate a launch-bound kernel from a
# bandwidth-bound one. evidence/ada/ncu-decode-baseline/ preregisters the arms,
# the retained fields, and what each outcome decides.
#
# ncu serializes and replays each profiled kernel, so a duration it reports is
# not a rate and never enters a rate comparison. The arm therefore runs as its
# own campaign under the owner lock with the appliance stopped, which is also
# what keeps the profiled process the only project client on the device.
#
# Counter collection needs the R610 profiler-device capability rather than the
# legacy RmProfilingAdminOnly key, which reports the registry state alone and
# stays at 1 here. The preflight reads the capability node the ordinary account
# can open and refuses ahead of the device when it cannot, since an
# ERR_NVGPUCTRPERM inside the run would leave a partial arm behind.
#
# gpu-ownership: acquires

usage() {
    cat >&2 <<'USAGE'
usage: run-ncu-kernel-baseline.sh OUTPUT_DIRECTORY [ARM_ID...]

Arms, in preregistered order:
  fixup-08b-q8    ne11=17 prefill on qwen35-08b, the stream-K fixup shape
  decode-08b-q8   batch-1 decode on qwen35-08b
  decode-2b-q4k   batch-1 decode on qwen38-2b-distill

  QWEN_NCU_BINARY     ncu, default the one on PATH
  QWEN_NCU_BUILD      closure directory holding bin/llama-bench
  QWEN_NCU_KEEP_REP   1 retains the raw .ncu-rep beside the extraction
USAGE
    exit 2
}

[ "$#" -ge 1 ] || usage
output_directory=$1
shift

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
registry_reader=${QWEN_MODEL_REGISTRY_SCRIPT:-"$script_directory/model-registry.sh"}
models_directory=${QWEN_MODELS_DIRECTORY:-"${HOME:?}/models"}
sweep_wrapper=$script_directory/cuda-runtime-env.sh
latch=$script_directory/gpu-state-latch.sh
ncu_binary=${QWEN_NCU_BINARY:-$(command -v ncu 2>/dev/null || echo /usr/bin/ncu)}
build_directory=${QWEN_NCU_BUILD:-"${HOME:?}/src/llama.cpp-qwen-nvidia/build-appliance-current"}
bench_binary=$build_directory/bin/llama-bench
keep_rep=${QWEN_NCU_KEEP_REP:-0}
# Launches profiled per arm, spread across whatever symbols the filter matches.
# Eight left two observations per symbol on the fixup arm, which reports a
# spread rather than a value, so the default takes ten per symbol on the four
# the fixup shape launches.
launch_count=${QWEN_NCU_LAUNCH_COUNT:-40}

fail() {
    printf 'run-ncu-kernel-baseline: %s\n' "$1" >&2
    exit 1
}

[ -x "$ncu_binary" ] || fail "ncu is unusable: $ncu_binary"
[ -x "$bench_binary" ] || fail "llama-bench is unusable: $bench_binary"

# One row per arm: id, model, ne11 prefill width, generated tokens, and the
# kernel-name regex ncu filters on. The fixup arm leads because #102's
# implementation choice is blocked on what it reports.
arm_matrix="fixup-08b-q8	qwen35-08b	17	0	regex:mul_mat_q
decode-08b-q8	qwen35-08b	0	32	regex:mul_mat_vec_q
decode-2b-q4k	qwen38-2b-distill	0	32	regex:mul_mat_vec_q"

if [ "$#" -gt 0 ]; then
    requested=$*
    selected=""
    for arm in $requested; do
        row=$(printf '%s\n' "$arm_matrix" | awk -F'\t' -v want="$arm" '$1 == want')
        [ -n "$row" ] || fail "no arm named $arm"
        selected=$(printf '%s\n%s' "$selected" "$row")
    done
    arm_matrix=$(printf '%s' "$selected" | sed '/^$/d')
fi

mkdir -p "$output_directory"
summary=$output_directory/summary.tsv
: >"$summary"

# The capability decides collection, and the functional open is what proves it:
# a mode bit states configuration while an open states capability.
capability_minor=$(awk '$1 == "profiler-device" { print $2 }' \
    /proc/driver/nvidia-caps/sys-minors 2>/dev/null || :)
[ -n "$capability_minor" ] ||
    fail 'profiler-device is absent from /proc/driver/nvidia-caps/sys-minors'
capability_node=/dev/nvidia-caps/nvidia-cap$capability_minor
[ -r "$capability_node" ] ||
    fail "the ordinary account cannot read $capability_node, so ncu collects no counters"
printf 'profiler_device_minor=%s node=%s readable=yes\n' \
    "$capability_minor" "$capability_node" >>"$summary"

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
# Two identities, because a reader greps for one of them. The configuration
# digest names the build directory and is what every other record in this tree
# calls the closure; the executable digest states which bytes ran. Printing the
# executable digest alone under the name `closure` puts an arm outside every
# search for the closure it profiled.
build_configuration_sha256=$(cut -d ' ' -f 1 \
    "$build_directory/build-configuration.sha256" 2>/dev/null || echo unavailable)
printf 'closure\t%s\t%s\n' "$build_directory" \
    "$build_configuration_sha256" >>"$summary"
printf 'bench_binary_sha256\t%s\n' \
    "$(sha256sum "$bench_binary" | cut -d ' ' -f 1)" >>"$summary"
printf 'ncu_version\t%s\n' \
    "$("$ncu_binary" --version 2>/dev/null | awk '/^Version/ { print $2 }')" >>"$summary"

sections='--section SpeedOfLight --section MemoryWorkloadAnalysis --section LaunchStats --section Occupancy --section SchedulerStats --section WarpStateStats'

printf '%s\n' "$arm_matrix" | while IFS="$(printf '\t')" read -r arm_id model_id ne11 generate_tokens kernel_filter; do
    [ -n "$arm_id" ] || continue
    arm_directory=$output_directory/$arm_id
    mkdir -p "$arm_directory"

    model_file=$("$registry_reader" id "$model_id" model_file) ||
        fail "no registry row matches id $model_id"
    model_path=$models_directory/$model_file
    [ -f "$model_path" ] || fail "arm $arm_id names an absent model: $model_path"
    cache_type_k=$("$registry_reader" id "$model_id" cache_type_k)
    cache_type_v=$("$registry_reader" id "$model_id" cache_type_v)

    {
        printf 'arm=%s\n' "$arm_id"
        printf 'model=%s\n' "$model_id"
        printf 'prefill_ne11=%s\n' "$ne11"
        printf 'generate_tokens=%s\n' "$generate_tokens"
        printf 'kernel_filter=%s\n' "$kernel_filter"
        printf 'cache_type_k=%s cache_type_v=%s\n' "$cache_type_k" "$cache_type_v"
    } >"$arm_directory/arm.txt"

    # --replay-mode kernel is the default and states the contract: each profiled
    # kernel runs several times behind one application launch, so the wall clock
    # of this process describes the profiler rather than the workload.
    # 9>&- closes the inherited owner descriptor in the profiled child, since a
    # workload that kept it would hold the claim alive past this campaign and
    # lock out the next session against a device nothing is using.
    #
    # cuda-runtime-env.sh scrubs the environment and then runs llama-bench as a
    # child rather than replacing itself, so application-only profiles the
    # wrapper and reports `No kernels were profiled`. --target-processes all is
    # what reaches the process that opens the context.
    #
    # The report goes to a file rather than to stdout because llama-bench writes
    # its own table there, and two writers on one stream leave a CSV no reader
    # can parse. The counters are exported from the report afterwards.
    "$ncu_binary" \
        --kernel-name "$kernel_filter" --launch-count "$launch_count" \
        --target-processes all \
        $sections \
        --export "$arm_directory/report" --force-overwrite \
        -- "$sweep_wrapper" "$bench_binary" -m "$model_path" --device CUDA0 \
        -ngl 99 -ot '.*=CUDA0' -fa 1 \
        -ctk "$cache_type_k" -ctv "$cache_type_v" \
        -p "$ne11" -n "$generate_tokens" -r 1 -o md \
        >"$arm_directory/profile.stdout" 2>"$arm_directory/profile.stderr" 9>&- || {
        printf '%s\tprofile-failed\t-\n' "$arm_id" >>"$summary"
        fail "arm $arm_id failed under ncu"
    }

    if grep -qi 'ERR_NVGPUCTRPERM' "$arm_directory/profile.stderr"; then
        fail "arm $arm_id refused on counter permission"
    fi
    if grep -qi 'No kernels were profiled' "$arm_directory/profile.stderr"; then
        fail "arm $arm_id profiled no kernel, so its filter reached nothing"
    fi

    "$ncu_binary" --import "$arm_directory/report.ncu-rep" \
        --csv --page raw >"$arm_directory/counters.csv" \
        2>"$arm_directory/import.stderr" 9>&- ||
        fail "arm $arm_id produced a report the importer refused"

    kernels=$(python3 -c '
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
names = {row.get("Kernel Name", "") for row in rows}
print(len(names))
' "$arm_directory/counters.csv")
    printf '%s\tprofiled\tdistinct_kernels=%s\n' "$arm_id" "$kernels" >>"$summary"

    clients_now=$(client_set)
    [ "$clients_now" = "$clients_open" ] ||
        fail "arm $arm_id ran while the client set moved: $clients_open -> $clients_now"
done

ring_close=$(ring_signatures)
printf 'kernel_ring\tclose\t%s\n' "$ring_close" >>"$summary"
printf 'clients\tclose\t%s\n' "$(client_set)" >>"$summary"
[ "$ring_close" = "$ring_open" ] ||
    fail "the kernel ring gained a signature: $ring_open -> $ring_close"

[ "$keep_rep" = 1 ] || find "$output_directory" -name '*.ncu-rep' -delete
# llama-bench prints the model path it loaded, so profile.stdout carries the
# home prefix the retention policy replaces; a scrub that named the other four
# suffixes and left this one failed the authority check on three retained files.
find "$output_directory" -type f \( -name '*.txt' -o -name '*.tsv' \
    -o -name '*.csv' -o -name '*.stderr' -o -name '*.stdout' \) \
    -exec sed -i "s#$HOME#\$HOME#g" {} +

printf 'ncu_kernel_baseline=complete output=%s\n' "$output_directory"
