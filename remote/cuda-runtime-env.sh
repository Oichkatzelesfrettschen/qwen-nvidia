#!/bin/sh
set -eu

# Scrub the ambient backend environment, apply one named CUDA profile, and exec
# the command.
#
# A profile is defined by what it exports after the scrub, so a named profile
# means one thing regardless of what the calling shell held. Every GGML_CUDA_*
# and GGML_VK_* variable the backends read is unset first, which makes an
# ambient setting reach the server only through the `custom` profile that
# captures it beforehand.
#
# The variables come from the backend's own getenv calls in
# ggml/src/ggml-cuda: GGML_CUDA_DISABLE_GRAPHS, GGML_CUDA_DISABLE_FUSION,
# GGML_CUDA_GRAPH_OPT, GGML_CUDA_PDL, GGML_CUDA_REGISTER_HOST,
# GGML_CUDA_NO_PINNED, GGML_CUDA_ENABLE_UNIFIED_MEMORY, GGML_CUDA_DEVICES,
# GGML_CUDA_ALLREDUCE, GGML_CUDA_CUBLAS_COMPUTE_TYPE, and
# GGML_OP_OFFLOAD_MIN_BATCH. A profile that names none of them measures the
# build's own defaults, which is what `default` is for.
#
# `unified` is the residency lever rather than a performance one:
# GGML_CUDA_ENABLE_UNIFIED_MEMORY lets an allocation exceed the 12 GiB carve-out
# by paging over PCIe, which trades a refusal to load for a decode rate bound by
# the link. A pairing that fits refuses this profile on principle -- paging what
# fits is pure loss -- so it belongs to the arms that would otherwise not run.

if [ "$#" -eq 0 ]; then
    printf 'usage: %s COMMAND [ARG ...]\n' "$0" >&2
    printf '  QWEN_CUDA_PROFILE  default, no-graphs, no-fusion, pdl, unified, custom\n' >&2
    printf '  QWEN_CUDA_DEVICES  CUDA_VISIBLE_DEVICES value, default 0\n' >&2
    exit 2
fi

cuda_profile=${QWEN_CUDA_PROFILE:-default}
cuda_devices=${QWEN_CUDA_DEVICES:-0}

# `custom` needs its inputs, so they are recorded before the scrub removes them.
requested_disable_graphs=${GGML_CUDA_DISABLE_GRAPHS:-}
requested_disable_fusion=${GGML_CUDA_DISABLE_FUSION:-}
requested_graph_opt=${GGML_CUDA_GRAPH_OPT:-}
requested_pdl=${GGML_CUDA_PDL:-}
requested_register_host=${GGML_CUDA_REGISTER_HOST:-}
requested_no_pinned=${GGML_CUDA_NO_PINNED:-}
requested_unified_memory=${GGML_CUDA_ENABLE_UNIFIED_MEMORY:-}
requested_cublas_compute_type=${GGML_CUDA_CUBLAS_COMPUTE_TYPE:-}
requested_op_offload_min_batch=${GGML_OP_OFFLOAD_MIN_BATCH:-}

unset GGML_CUDA_ALLREDUCE
unset GGML_CUDA_CUBLAS_COMPUTE_TYPE
unset GGML_CUDA_DEVICES
unset GGML_CUDA_DISABLE_FUSION
unset GGML_CUDA_DISABLE_GRAPHS
unset GGML_CUDA_ENABLE_UNIFIED_MEMORY
unset GGML_CUDA_GRAPH_OPT
unset GGML_CUDA_NO_PINNED
unset GGML_CUDA_PDL
unset GGML_CUDA_REGISTER_HOST
unset GGML_OP_OFFLOAD_MIN_BATCH
unset GGML_VK_DISABLE_FUSION
unset GGML_VK_DISABLE_GRAPH_OPTIMIZE
unset GGML_VK_LOW_PRIORITY
unset GGML_VK_MAX_NODES_PER_SUBMIT
unset GGML_VK_SERIALIZE_SUBMISSIONS
unset GGML_VK_VISIBLE_DEVICES
unset MESA_VK_DEVICE_SELECT
unset VK_DRIVER_FILES
unset VK_ICD_FILENAMES
unset VK_INSTANCE_LAYERS
unset VK_LAYER_PATH
unset VK_LOADER_LAYERS_ENABLE

export CUDA_VISIBLE_DEVICES=$cuda_devices
export LLAMA_NO_CPU_FALLBACK=1

case $cuda_profile in
    default)
        ;;
    no-graphs)
        export GGML_CUDA_DISABLE_GRAPHS=1
        ;;
    no-fusion)
        export GGML_CUDA_DISABLE_FUSION=1
        ;;
    pdl)
        export GGML_CUDA_PDL=1
        ;;
    unified)
        export GGML_CUDA_ENABLE_UNIFIED_MEMORY=1
        ;;
    custom)
        [ -z "$requested_disable_graphs" ] ||
            export GGML_CUDA_DISABLE_GRAPHS=$requested_disable_graphs
        [ -z "$requested_disable_fusion" ] ||
            export GGML_CUDA_DISABLE_FUSION=$requested_disable_fusion
        [ -z "$requested_graph_opt" ] ||
            export GGML_CUDA_GRAPH_OPT=$requested_graph_opt
        [ -z "$requested_pdl" ] ||
            export GGML_CUDA_PDL=$requested_pdl
        [ -z "$requested_register_host" ] ||
            export GGML_CUDA_REGISTER_HOST=$requested_register_host
        [ -z "$requested_no_pinned" ] ||
            export GGML_CUDA_NO_PINNED=$requested_no_pinned
        [ -z "$requested_unified_memory" ] ||
            export GGML_CUDA_ENABLE_UNIFIED_MEMORY=$requested_unified_memory
        [ -z "$requested_cublas_compute_type" ] ||
            export GGML_CUDA_CUBLAS_COMPUTE_TYPE=$requested_cublas_compute_type
        [ -z "$requested_op_offload_min_batch" ] ||
            export GGML_OP_OFFLOAD_MIN_BATCH=$requested_op_offload_min_batch
        ;;
    *)
        printf 'unknown CUDA profile: %s\n' "$cuda_profile" >&2
        exit 2
        ;;
esac
export QWEN_CUDA_PROFILE=$cuda_profile

exec "$@"
