#!/bin/sh
set -eu

# gpu-ownership: authorized-monitor; the probe queries the driver and opens no context.
#
# Records the CUDA virtual memory management contract of the device and the
# attention KV geometry of one registry row against it, ahead of any paged KV
# arm. The C probe reads CU_MEM_ALLOC_GRANULARITY_MINIMUM and
# CU_MEM_ALLOC_GRANULARITY_RECOMMENDED through cuMemGetAllocationGranularity,
# two fields because cuMemMap requires the first of an address, a size, and an
# offset while the pinned ggml VMM pool reads only the second. It creates no
# context and no allocation, and this wrapper samples the driver's client list
# while the probe holds itself alive to record that it appears in none. The
# geometry pass reads the GGUF header with gguf-py and states, per attention
# layer and per K and V, the row size, the tensor size at the row's default
# depth, whether a row divides the mapping unit, how many units the tensor
# intersects, and the tail the last unit wastes; a row that crosses a unit
# boundary is recorded as such rather than rounded into a cell-per-unit count.

usage() {
    cat >&2 <<'USAGE'
usage: probe-cuda-vmm-layout.sh OUTPUT_DIRECTORY [MODEL_ID...]

Writes probe.txt, clients.txt, and vmm-layout.tsv into OUTPUT_DIRECTORY.
Naming no MODEL_ID records qwen38-2b-distill.

  QWEN_PROBE_DEVICE   CUDA device index, default 0
  GGUF_PY_PATH        the pinned gguf-py, default $HOME/src/llama.cpp-qwen-nvidia/gguf-py
USAGE
    exit 2
}

[ "$#" -ge 1 ] || usage
output_directory=$1
shift
[ "$#" -gt 0 ] || set -- qwen38-2b-distill

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
registry_script=${QWEN_MODEL_REGISTRY_SCRIPT:-"$script_directory/model-registry.sh"}
models_directory=${QWEN_MODELS_DIRECTORY:-"${HOME:?}/models"}
gguf_py_path=${GGUF_PY_PATH:-"${HOME:?}/src/llama.cpp-qwen-nvidia/gguf-py"}
device_index=${QWEN_PROBE_DEVICE:-0}
case $device_index in '' | *[!0-9]*) usage ;; esac
cuda_include=${QWEN_CUDA_INCLUDE:-/opt/cuda/include}
[ -f "$cuda_include/cuda.h" ] || {
    printf 'refused: cuda.h is absent under %s\n' "$cuda_include" >&2
    exit 1
}
[ -d "$gguf_py_path/gguf" ] || {
    printf 'refused: gguf-py is absent: %s\n' "$gguf_py_path" >&2
    exit 1
}

umask 077
mkdir -p "$output_directory"
probe_binary=$output_directory/probe-cuda-vmm-layout
cc -std=c11 -Wall -Wextra -Werror -I"$cuda_include" \
    -o "$probe_binary" "$script_directory/probe-cuda-vmm-layout.c" -lcuda

# The probe holds for 1500 ms after its reads; three samples of the compute
# client list inside that hold are what prove it opened no context. A sample
# counts only where nvidia-smi answered and the probe was alive at the
# instant of the query, since an unanswered query or a sample after exit
# states nothing about the probe; the probe is identified by its pid rather
# than by a name a foreign process could share.
QWEN_PROBE_HOLD_MS=1500 "$probe_binary" "$device_index" >"$output_directory/probe.txt" 2>&1 &
probe_pid=$!
: >"$output_directory/clients.txt"
sample=0
samples_answered=0
samples_alive=0
probe_client_lines=0
while [ "$sample" -lt 3 ]; do
    sleep 0.4
    printf 'sample=%s\n' "$sample" >>"$output_directory/clients.txt"
    alive_before=0; kill -0 "$probe_pid" 2>/dev/null && alive_before=1
    if nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader \
        >"$output_directory/clients.sample" 2>&1; then
        samples_answered=$((samples_answered + 1))
        alive_after=0; kill -0 "$probe_pid" 2>/dev/null && alive_after=1
        if [ "$alive_before" -eq 1 ] && [ "$alive_after" -eq 1 ]; then
            samples_alive=$((samples_alive + 1))
        fi
        probe_client_lines=$((probe_client_lines + $(awk -F', ' -v pid="$probe_pid" '$1 == pid { count++ } END { print count + 0 }' "$output_directory/clients.sample")))
        printf 'answered=yes alive_before=%s alive_after=%s\n' "$alive_before" "$alive_after" >>"$output_directory/clients.txt"
        cat "$output_directory/clients.sample" >>"$output_directory/clients.txt"
    else
        printf 'answered=no\n' >>"$output_directory/clients.txt"
    fi
    sample=$((sample + 1))
done
rm -f "$output_directory/clients.sample"
probe_status=0
wait "$probe_pid" || probe_status=$?
printf 'probe_exit=%s\nprobe_samples_answered=%s\nprobe_alive_samples=%s\nprobe_client_samples=%s\n' \
    "$probe_status" "$samples_answered" "$samples_alive" "$probe_client_lines" \
    >>"$output_directory/probe.txt"
[ "$probe_status" -eq 0 ] || {
    printf 'refused: the probe exited %s; see %s\n' "$probe_status" "$output_directory/probe.txt" >&2
    exit 1
}
[ "$samples_answered" -eq 3 ] && [ "$samples_alive" -eq 3 ] || {
    printf 'refused: %s of 3 client samples answered and %s found the probe alive; absence is unmeasured\n' \
        "$samples_answered" "$samples_alive" >&2
    exit 1
}
[ "$probe_client_lines" -eq 0 ] || {
    printf 'refused: the probe pid appeared in the compute client list %s times\n' "$probe_client_lines" >&2
    exit 1
}
minimum=$(sed -n 's/^granularity_minimum=//p' "$output_directory/probe.txt")
recommended=$(sed -n 's/^granularity_recommended=//p' "$output_directory/probe.txt")
case $minimum in '' | *[!0-9]*)
    printf 'refused: the probe reports no numeric minimum granularity: %s\n' "$minimum" >&2
    exit 1 ;;
esac

layout=$output_directory/vmm-layout.tsv
printf 'model_id\tlayer\toperand\tggml_type\tn_embd_gqa\tdepth\trow_bytes\tlogical_tensor_bytes\tunit\tunit_bytes\trow_divides_unit\trows_per_unit\tunits_intersected\ttail_waste_bytes\n' >"$layout"
for model_id in "$@"; do
    model_file=$("$registry_script" id "$model_id" model_file)
    model_path=$models_directory/$model_file
    [ -f "$model_path" ] || {
        printf 'refused: model absent: %s\n' "$model_path" >&2
        exit 1
    }
    depth=$("$registry_script" id "$model_id" context_default)
    cache_type_k=$("$registry_script" id "$model_id" cache_type_k)
    cache_type_v=$("$registry_script" id "$model_id" cache_type_v)
    PYTHONPATH=$gguf_py_path python3 - "$model_id" "$model_path" "$depth" \
        "$cache_type_k" "$cache_type_v" "$minimum" "$recommended" >>"$layout" <<'PY'
import sys

from gguf import GGUFReader

model_id, model_path, depth, type_k, type_v, minimum, recommended = sys.argv[1:8]
depth, minimum, recommended = int(depth), int(minimum), int(recommended)
# Bytes per block of 32 elements, from ggml's type traits; f16 and bf16 are
# two bytes per element and f32 four.
ROW_BYTES = {"q8_0": (34, 32), "q4_0": (18, 32), "q4_1": (20, 32), "q5_0": (22, 32),
             "q5_1": (24, 32), "f16": (2, 1), "bf16": (2, 1), "f32": (4, 1)}
reader = GGUFReader(model_path)
fields = reader.fields
arch = fields["general.architecture"].contents()


def field(name, default=None):
    key = "%s.%s" % (arch, name)
    return fields[key].contents() if key in fields else default


block_count = int(field("block_count"))
nextn = int(field("nextn_predict_layers", 0) or 0)
n_layer = block_count - nextn
head_count_kv = field("attention.head_count_kv")
key_length = int(field("attention.key_length", field("embedding_length") // int(field("attention.head_count"))))
value_length = int(field("attention.value_length", key_length))
interval = int(field("full_attention_interval", 0) or 0)


def kv_heads(il):
    if isinstance(head_count_kv, list):
        return int(head_count_kv[il])
    return int(head_count_kv)


def is_attention(il):
    # llama_hparams::set_recr_pattern with dense_first false: a layer is
    # recurrent where il % interval < interval - 1, so attention sits at the
    # last position of every interval; with no interval every layer with a KV
    # head is attention.
    if interval:
        return il % interval == interval - 1
    return kv_heads(il) > 0


for il in range(n_layer):
    if not is_attention(il):
        continue
    for operand, ggml_type, head_dim in (("K", type_k, key_length), ("V", type_v, value_length)):
        n_embd_gqa = head_dim * kv_heads(il)
        block_bytes, block_elements = ROW_BYTES[ggml_type]
        row_bytes = n_embd_gqa // block_elements * block_bytes
        tensor_bytes = row_bytes * depth
        for unit_name, unit in (("minimum", minimum), ("recommended", recommended)):
            divides = unit % row_bytes == 0
            units = -(-tensor_bytes // unit)
            print("\t".join(str(value) for value in (
                model_id, il, operand, ggml_type, n_embd_gqa, depth, row_bytes, tensor_bytes,
                unit_name, unit, "yes" if divides else "no",
                unit // row_bytes if divides else "%.3f" % (unit / row_bytes),
                units, units * unit - tensor_bytes)))
PY
done
sed -i "s#${HOME:?}#\$HOME#g" "$output_directory/probe.txt" "$output_directory/clients.txt"
cat "$output_directory/probe.txt"
printf 'vmm_layout=%s rows=%s\n' "$layout" "$(($(wc -l <"$layout") - 1))"
