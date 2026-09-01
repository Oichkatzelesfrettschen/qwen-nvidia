#!/bin/sh
set -eu

# Admit one representation row of an already-registered checkpoint on CUDA0.
# A representation row shares learned weights with its control and differs in
# value type alone, so admission reads the publisher digest through the row's
# own fetch script, reads the GGUF header for the value population the row
# claims, requires verify-representation-pair.py to read control and subject
# as one architecture at one tensor layout, and then loads the artifact under
# test-strict-cuda-placement.sh with the device owned and the kernel ring
# read before and after. The registry under test is the one named on the
# command line, so a candidate row is admitted from a copy and the canonical
# registry gains the row after the run accepts it.
#
# A pass admits the artifact as a load subject at its registry ceiling. It
# measures no rate and validates no depth: those belong to an uninstrumented
# paired sweep and a filled-depth arm of their own.

usage() {
    printf 'usage: %s REGISTRY MODEL_ID CONTROL_MODEL_ID VALUE_TYPE OUTPUT_DIRECTORY\n' "$0" >&2
    printf 'environment: QWEN_LLAMA_SERVER  default build-appliance-current/bin/llama-server\n' >&2
    printf '             QWEN_MODEL_ROOT    default $HOME/models\n' >&2
    printf '             QWEN_DMESG         command reading the kernel ring, default "sudo -n dmesg"\n' >&2
    exit 2
}
[ "$#" -eq 5 ] || usage
registry=$1
model_id=$2
control_id=$3
value_type=$4
output_directory=$5
[ -f "$registry" ] || usage

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
llama_server=${QWEN_LLAMA_SERVER:-"${HOME:?}/src/llama.cpp-qwen-nvidia/build-appliance-current/bin/llama-server"}
model_root=${QWEN_MODEL_ROOT:-"${HOME:?}/models"}
dmesg_command=${QWEN_DMESG:-sudo -n dmesg}
hazard_pattern='NV_ERR_INVALID_STATE|dmaAllocMapping|mapping_reuse|mmuWalkMap|NVRM[^[:cntrl:]]*Xid|GPU has fallen off the bus|RmInitAdapter failed|GPU reset|ring[^[:cntrl:]]*timeout|VM fault|device los[ts]'

mkdir -p "$output_directory"
checks=$output_directory/checks.tsv
printf 'check\toutcome\tdetail\n' >"$checks"
failures=0

record() {
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$checks"
    printf 'check=%s outcome=%s %s\n' "$1" "$2" "$3"
    [ "$2" = pass ] || failures=$((failures + 1))
}

# The registry is validated whole by the query, so a malformed copy refuses
# ahead of any device time.
row=$(QWEN_MODEL_REGISTRY=$registry "$script_directory/model-registry.sh" id "$model_id") ||
    { record registry_row fail "model_id=$model_id registry=$registry"; exit 1; }
printf '%s\n' "$row" >"$output_directory/registry-row.txt"
field() { printf '%s\n' "$row" | sed -n "s/^$1=//p"; }
model_file=$(field model_file)
fetch_script=$(field fetch_script)
projector=$(field projector)
context_ceiling=$(field context_ceiling)
tier=$(field tier)
record registry_row pass "model_id=$model_id tier=$tier context_ceiling=$context_ceiling"
if [ "$projector" != none ]; then
    record projector_absent fail "projector=$projector"
    exit 1
fi
control_row=$(QWEN_MODEL_REGISTRY=$registry "$script_directory/model-registry.sh" id "$control_id") ||
    { record control_row fail "model_id=$control_id"; exit 1; }
control_file=$(printf '%s\n' "$control_row" | sed -n 's/^model_file=//p')
record control_row pass "control_id=$control_id"

model_path=$model_root/$model_file
control_path=$model_root/$control_file

# The publisher digest through the row's own fetch script, which verifies an
# existing file in place and downloads one that is absent.
fetch_status=$("$script_directory/$fetch_script" "$(dirname -- "$model_path")" 2>"$output_directory/fetch.err") ||
    { record artifact_digest fail "fetch_script=$fetch_script"; exit 1; }
printf '%s\n' "$fetch_status" >"$output_directory/fetch.out"
case $fetch_status in
    artifact_status=already_verified*|artifact_status=verified*)
        record artifact_digest pass "$(printf '%s' "$fetch_status" | tr ' ' '\n' | grep -E '^(artifact_status|sha256|source_revision)=' | tr '\n' ' ')" ;;
    *)
        record artifact_digest fail "$fetch_status"; exit 1 ;;
esac

# The header: architecture and the byte population by value type.
GGUF_PY_PATH=${GGUF_PY_PATH:-"${HOME:?}/src/llama.cpp-qwen-nvidia/gguf-py"} \
    python3 "$script_directory/gguf-tensor-census.py" --skip-hash --json "$model_path" \
    >"$output_directory/header-census.json" 2>"$output_directory/header-census.err" ||
    { record header_read fail "gguf-tensor-census.py refused"; exit 1; }
header_summary=$(python3 - "$output_directory/header-census.json" "$value_type" <<'PYTHON'
import json
import sys

census = json.load(open(sys.argv[1], encoding="utf-8"))[0]
summary = census["summary"]
by_type = summary["by_type"]
dominant = max(by_type, key=by_type.get)
total = sum(by_type.values())
share = by_type[dominant] / total
print(
    f"architecture={summary['architecture']} tensors={summary['tensor_count']} "
    f"dominant_type={dominant} dominant_share={share:.4f} "
    f"types={','.join(f'{k}:{v}' for k, v in sorted(by_type.items()))}"
)
if dominant != sys.argv[2]:
    raise SystemExit(f"dominant value type is {dominant} rather than {sys.argv[2]}")
PYTHON
) || { record header_read fail "value_type=$value_type"; exit 1; }
record header_read pass "$header_summary"

pair=$(python3 "$script_directory/verify-representation-pair.py" "$control_path" "$model_path" 2>"$output_directory/pair.err") ||
    { record representation_pair fail "control=$control_id"; exit 1; }
printf '%s\n' "$pair" >"$output_directory/pair.out"
case $pair in
    representation_pair=compatible*) record representation_pair pass "$pair" ;;
    *) record representation_pair fail "$pair"; exit 1 ;;
esac

# Device state ahead of the load: the latch, the ownership authority, and the
# kernel ring.
if latch=$("$script_directory/gpu-state-latch.sh" require-clear 2>&1); then
    record gpu_state_latch pass "$latch"
else
    record gpu_state_latch fail "$latch"; exit 1
fi

. "$script_directory/gpu-workload-ownership.sh"
# Client names carry the desktop's own command lines, so the home prefix is
# replaced before the classification is retained.
scrub_home() { sed "s|${HOME:?}|\$HOME|g"; }
ownership_scratch=$(mktemp)
if gpu_ownership_require >"$ownership_scratch" 2>"$output_directory/ownership-before.err"; then
    scrub_home <"$ownership_scratch" >"$output_directory/ownership-before.txt"
    rm -f "$ownership_scratch"
    record gpu_ownership_before pass "$(grep -c '^cuda_client' "$output_directory/ownership-before.txt" || :) clients"
else
    record gpu_ownership_before fail "$(cat "$output_directory/ownership-before.err")"; exit 1
fi

# The retained ring excerpt is the hazard-matching lines alone, since a whole
# ring carries usernames, paths, and interface addresses that stay out of the
# tree; the count is read from the same excerpt.
read_kernel_ring() {
    ring_scratch=$(mktemp)
    if ! $dmesg_command >"$ring_scratch" 2>>"$output_directory/dmesg.err"; then
        rm -f "$ring_scratch"
        return 1
    fi
    grep -Eai "$hazard_pattern" "$ring_scratch" >"$1" || :
    rm -f "$ring_scratch"
}
if ! read_kernel_ring "$output_directory/dmesg-hazards-before.txt"; then
    record kernel_ring_before fail "kernel ring unreadable through: $dmesg_command"; exit 1
fi
hazards_before=$(grep -c . "$output_directory/dmesg-hazards-before.txt" || :)
record kernel_ring_before pass "hazard_lines=$hazards_before"

# The load itself.
set +e
QWEN_TEST_EVIDENCE_DIRECTORY=$output_directory/strict-cuda-placement \
    "$script_directory/test-strict-cuda-placement.sh" \
    --llama-server "$llama_server" --model "$model_path" \
    >"$output_directory/strict-cuda-placement.out" 2>"$output_directory/strict-cuda-placement.err" 9>&-
placement_status=$?
set -e
placement_line=$(cat "$output_directory/strict-cuda-placement.out")
if [ "$placement_status" -eq 0 ]; then
    record strict_cuda_placement pass "$placement_line"
else
    record strict_cuda_placement fail "status=$placement_status $(tail -1 "$output_directory/strict-cuda-placement.err")"
fi
completion_sha256=$(printf '%s\n' "$placement_line" | sed -n 's/.*completion_sha256=\([0-9a-f]*\).*/\1/p')

# Device state after the load. The client set is read as the desktop covariate
# and compared by pid, so a server the check failed to end is a new client and
# refuses here; the ring count is compared exactly.
if gpu_ownership_inspect >"$ownership_scratch" 2>"$output_directory/ownership-after.err"; then
    scrub_home <"$ownership_scratch" >"$output_directory/ownership-after.txt"
    rm -f "$ownership_scratch"
    before_set=$(sed -n 's/^cuda_client pid=\([0-9]*\) .*/\1/p' "$output_directory/ownership-before.txt" | sort)
    after_set=$(sed -n 's/^cuda_client pid=\([0-9]*\) .*/\1/p' "$output_directory/ownership-after.txt" | sort)
    if [ "$before_set" = "$after_set" ]; then
        record gpu_ownership_after pass "client_set=unchanged"
    else
        record gpu_ownership_after fail "client_set=changed before=[$(printf '%s' "$before_set" | tr '\n' ' ')] after=[$(printf '%s' "$after_set" | tr '\n' ' ')]"
    fi
else
    record gpu_ownership_after fail "$(cat "$output_directory/ownership-after.err")"
fi
named_after=$(pgrep -x llama-server 2>/dev/null | tr '\n' ' ' || :)
if [ -z "$named_after" ]; then
    record server_teardown pass "named_llama_server_pids=-"
else
    record server_teardown fail "named_llama_server_pids=$named_after"
fi

if read_kernel_ring "$output_directory/dmesg-hazards-after.txt"; then
    hazards_after=$(grep -c . "$output_directory/dmesg-hazards-after.txt" || :)
    if [ "$hazards_after" = "$hazards_before" ]; then
        record kernel_ring_after pass "hazard_lines=$hazards_after delta=0"
    else
        record kernel_ring_after fail "hazard_lines=$hazards_after before=$hazards_before"
    fi
else
    record kernel_ring_after fail "kernel ring unreadable"
fi

server_identity=$("$llama_server" --version 2>&1 | tr '\n' ' ')
printf 'model_id\tcontrol_id\tvalue_type\tmodel_file\tllama_server\tserver_identity\tcompletion_sha256\tchecks\tfailures\n' \
    >"$output_directory/admission-summary.tsv"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$model_id" "$control_id" "$value_type" \
    "$model_file" "${llama_server#"$HOME"/}" "$server_identity" "${completion_sha256:--}" \
    "$(($(wc -l <"$checks") - 1))" "$failures" >>"$output_directory/admission-summary.tsv"
if [ "$failures" -eq 0 ]; then
    printf 'representation_admission=accepted model_id=%s value_type=%s completion_sha256=%s\n' \
        "$model_id" "$value_type" "${completion_sha256:--}"
else
    printf 'representation_admission=rejected model_id=%s failures=%s\n' "$model_id" "$failures" >&2
    exit 1
fi
