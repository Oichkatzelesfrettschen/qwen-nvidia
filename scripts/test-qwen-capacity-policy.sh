#!/bin/sh
set -eu

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
policy=$script_directory/qwen-capacity-policy.sh
fake_server=$script_directory/test-fixtures/fake-llama-server.sh
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

model_path=$temporary_directory/model.gguf
output_path=$temporary_directory/policy.out
fake_icd=$temporary_directory/nvidia_icd.json
: > "$model_path"
: > "$fake_icd"

# Both wrappers apply one scheduling policy rather than inheriting one:
# QWEN_SERVING_NICE at 0 and QWEN_SERVING_CPU_LIST at the online CPU set. A
# hardcoded CPU list would drift from whatever set this host reports, so the
# expectation is read from the same authority the wrapper reads.
expected_cpu_list=$(cat /sys/devices/system/cpu/online)

# QWEN_SERVING_BACKEND defaults to cuda, so a launch naming no backend routes
# through cuda-runtime-env.sh with --device CUDA0 and its own profile default.
QWEN_POLICY_TEST_OUTPUT=$output_path \
    "$policy" "$fake_server" "$model_path" 24576 8080

grep -Fx "affinity=$expected_cpu_list" "$output_path" >/dev/null
grep -Fx 'nice=0' "$output_path" >/dev/null
grep -Fx 'profile=default' "$output_path" >/dev/null
grep -Fx 'cuda_disable_graphs=unset' "$output_path" >/dev/null
grep -Fx 'cuda_disable_fusion=unset' "$output_path" >/dev/null
grep -Fx 'cuda_pdl=unset' "$output_path" >/dev/null
grep -Fx 'cuda_unified_memory=unset' "$output_path" >/dev/null
grep -Fx 'cuda_devices=0' "$output_path" >/dev/null
grep -Fx 'low=unset' "$output_path" >/dev/null
grep -Fx 'duty=unset' "$output_path" >/dev/null
grep -Fx 'serialized=unset' "$output_path" >/dev/null
grep -Fx 'max_nodes=unset' "$output_path" >/dev/null
grep -Fx 'amd_priority=unset' "$output_path" >/dev/null
grep -Fx 'memory_priority=unset' "$output_path" >/dev/null
grep -Fx 'allow_graphics=unset' "$output_path" >/dev/null
grep -Fx 'strict=1' "$output_path" >/dev/null

expected_arguments='--model
'"$model_path"'
--host
127.0.0.1
--port
8080
--alias
qwen-apu
--cors-origins
localhost
--no-ui
--log-verbosity
4
--device
CUDA0
--split-mode
none
--n-gpu-layers
all
--override-tensor
.*=CUDA0
--fit
off
--parallel
1
--threads
6
--threads-batch
6
--ctx-checkpoints
0
--cache-ram
0
--no-context-shift
--offline
--ctx-size
24576
--batch-size
128
--ubatch-size
32
--flash-attn
on
--cache-type-k
q8_0
--cache-type-v
q4_0'

actual_arguments=$(sed -n 's/^argument=//p' "$output_path")
if [ "$actual_arguments" != "$expected_arguments" ]; then
    printf 'fixed policy arguments differ from the expected sequence\n' >&2
    # Both sides carry argument values alone. Diffing the expected list against
    # the raw capture reports the profile block as a difference and buries the
    # one argument that moved.
    printf '%s\n' "$expected_arguments" >"$temporary_directory/expected.txt"
    printf '%s\n' "$actual_arguments" >"$temporary_directory/actual.txt"
    diff -u "$temporary_directory/expected.txt" \
        "$temporary_directory/actual.txt" >&2 || true
    exit 1
fi

# QWEN_SERVING_BACKEND=vulkan routes the identical scheduling policy through
# vulkan-runtime-env.sh instead, naming --device Vulkan0 and reading the ICD
# pin from QWEN_VULKAN_ICD. Its default profile exports nothing beyond the
# scrub, so every GGML_VK_* name the scrub removes reads back unset and the
# display and compositor names this wrapper unsets read back unset too.
vulkan_output_path=$temporary_directory/policy-vulkan.out
QWEN_SERVING_BACKEND=vulkan QWEN_VULKAN_ICD=$fake_icd \
    QWEN_POLICY_TEST_OUTPUT=$vulkan_output_path \
    "$policy" "$fake_server" "$model_path" 24576 8090

grep -Fx "affinity=$expected_cpu_list" "$vulkan_output_path" >/dev/null
grep -Fx 'nice=0' "$vulkan_output_path" >/dev/null
grep -Fx 'profile=default' "$vulkan_output_path" >/dev/null
grep -Fx 'low=unset' "$vulkan_output_path" >/dev/null
grep -Fx 'duty=unset' "$vulkan_output_path" >/dev/null
grep -Fx 'serialized=unset' "$vulkan_output_path" >/dev/null
grep -Fx 'max_nodes=unset' "$vulkan_output_path" >/dev/null
grep -Fx 'allow_graphics=unset' "$vulkan_output_path" >/dev/null
grep -Fx 'strict=1' "$vulkan_output_path" >/dev/null
grep -Fx 'display=unset' "$vulkan_output_path" >/dev/null
grep -Fx 'wayland=unset' "$vulkan_output_path" >/dev/null
grep -Fx 'argument=--device' "$vulkan_output_path" >/dev/null
grep -Fx 'argument=Vulkan0' "$vulkan_output_path" >/dev/null
vulkan_arguments=$(sed -n 's/^argument=//p' "$vulkan_output_path" | tr '\n' ' ')
case $vulkan_arguments in
    *'--override-tensor .*=Vulkan0 '*) ;;
    *)
        printf 'the Vulkan arm did not carry the Vulkan0 tensor placement: %s\n' \
            "$vulkan_arguments" >&2
        exit 1
        ;;
esac

# The KV cache triple comes from the registry row the model path resolves to,
# and the three environment variables override it, so a cache factorial runs
# through the served path. A value outside what llama-server accepts is refused
# before the server sees it.
cache_output=$temporary_directory/cache-policy.out
if QWEN_CACHE_TYPE_K=f16 QWEN_CACHE_TYPE_V=f16 QWEN_FLASH_ATTN=off \
    QWEN_VULKAN_ICD=$fake_icd QWEN_POLICY_TEST_OUTPUT=$cache_output \
    "$policy" "$fake_server" "$model_path" 4096 18080 \
    >"$temporary_directory/cache-ceiling.stdout" \
    2>"$temporary_directory/cache-ceiling.stderr"; then
    printf 'policy reused the registered ceiling for an overridden cache tuple\n' >&2
    exit 1
fi
grep -F 'cache-policy overrides require a positive QWEN_CACHE_OVERRIDE_CONTEXT_CEILING' \
    "$temporary_directory/cache-ceiling.stderr" >/dev/null

QWEN_CACHE_TYPE_K=f16 QWEN_CACHE_TYPE_V=f16 QWEN_FLASH_ATTN=off \
    QWEN_CACHE_OVERRIDE_CONTEXT_CEILING=4096 \
    QWEN_VULKAN_ICD=$fake_icd QWEN_POLICY_TEST_OUTPUT=$cache_output \
    "$policy" "$fake_server" "$model_path" 4096 18080
cache_arguments=$(sed -n 's/^argument=//p' "$cache_output" | tr '\n' ' ')
case $cache_arguments in
    *'--flash-attn off '*'--cache-type-k f16 --cache-type-v f16 '*) ;;
    *)
        printf 'cache overrides did not reach the argument list: %s\n' \
            "$cache_arguments" >&2
        exit 1
        ;;
esac

if QWEN_CACHE_TYPE_K=f16 QWEN_CACHE_TYPE_V=f16 QWEN_FLASH_ATTN=off \
    QWEN_CACHE_OVERRIDE_CONTEXT_CEILING=24577 \
    QWEN_VULKAN_ICD=$fake_icd QWEN_POLICY_TEST_OUTPUT=$cache_output \
    "$policy" "$fake_server" "$model_path" 4096 18080 \
    >"$temporary_directory/cache-high.stdout" \
    2>"$temporary_directory/cache-high.stderr"; then
    printf 'policy accepted an override ceiling above the registered ceiling\n' >&2
    exit 1
fi
grep -F 'cache override ceiling must not exceed the registered ceiling: 24577 > 24576' \
    "$temporary_directory/cache-high.stderr" >/dev/null

if QWEN_CACHE_TYPE_K=f16 QWEN_CACHE_TYPE_V=f16 QWEN_FLASH_ATTN=off \
    QWEN_CACHE_OVERRIDE_CONTEXT_CEILING=4096 \
    QWEN_VULKAN_ICD=$fake_icd QWEN_POLICY_TEST_OUTPUT=$cache_output \
    "$policy" "$fake_server" "$model_path" 4097 18080 \
    >"$temporary_directory/cache-context.stdout" \
    2>"$temporary_directory/cache-context.stderr"; then
    printf 'policy accepted a context above the cache override ceiling\n' >&2
    exit 1
fi
grep -F 'context size exceeds the admitted ceiling for this cache policy: 4097 > 4096' \
    "$temporary_directory/cache-context.stderr" >/dev/null

# A fabricated registry carries a triple the fallback never produces, so this
# check separates the registry read from the built-in default.
fabricated_registry=$temporary_directory/models.tsv
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    fabricated research fabricated.gguf download-qwen38-4b-distill-q4km.sh \
    4096 8192 8192 q5_1 iq4_nl auto none - - - untested candidate 256 64 4096 - \
    unmeasured refused - off - \
    >"$fabricated_registry"
registry_model=$temporary_directory/fabricated.gguf
: >"$registry_model"
router_model_root=$temporary_directory
QWEN_MODEL_REGISTRY=$fabricated_registry QWEN_VULKAN_ICD=$fake_icd \
    QWEN_MODEL_ROOT=$router_model_root \
    QWEN_POLICY_TEST_OUTPUT=$cache_output \
    "$policy" "$fake_server" "$registry_model" 4096 18080
cache_arguments=$(sed -n 's/^argument=//p' "$cache_output" | tr '\n' ' ')
case $cache_arguments in
    *'--batch-size 256 --ubatch-size 64 '*'--flash-attn auto '*'--cache-type-k q5_1 --cache-type-v iq4_nl '*) ;;
    *)
        printf 'registry cache row did not reach the argument list: %s\n' \
            "$cache_arguments" >&2
        exit 1
        ;;
esac

if QWEN_CACHE_TYPE_K=q3_k QWEN_VULKAN_ICD=$fake_icd \
    QWEN_POLICY_TEST_OUTPUT=$cache_output \
    "$policy" "$fake_server" "$model_path" 4096 18080 \
    >"$temporary_directory/cache-type.stdout" \
    2>"$temporary_directory/cache-type.stderr"; then
    printf 'policy accepted a cache type llama-server rejects\n' >&2
    exit 1
fi
grep -F 'cache type is outside the set llama-server accepts' \
    "$temporary_directory/cache-type.stderr" >/dev/null

if QWEN_FLASH_ATTN=1 QWEN_VULKAN_ICD=$fake_icd \
    QWEN_POLICY_TEST_OUTPUT=$cache_output \
    "$policy" "$fake_server" "$model_path" 4096 18080 \
    >"$temporary_directory/flash.stdout" \
    2>"$temporary_directory/flash.stderr"; then
    printf 'policy accepted a flash attention value outside on, off, auto\n' >&2
    exit 1
fi
grep -F 'flash attention must be on, off, or auto' \
    "$temporary_directory/flash.stderr" >/dev/null

profile_output=$temporary_directory/profile-policy.out

# cuda-runtime-env.sh takes default, no-graphs, no-fusion, pdl, unified, and
# custom via QWEN_CUDA_PROFILE. A named profile is defined by what it exports
# after the scrub, so no-graphs exports GGML_CUDA_DISABLE_GRAPHS alone.
QWEN_CUDA_PROFILE=no-graphs \
    QWEN_POLICY_TEST_OUTPUT=$profile_output \
    "$policy" "$fake_server" "$model_path" 4096 18081
grep -Fx 'profile=no-graphs' "$profile_output" >/dev/null
grep -Fx 'cuda_disable_graphs=1' "$profile_output" >/dev/null
grep -Fx 'cuda_disable_fusion=unset' "$profile_output" >/dev/null
grep -Fx 'cuda_pdl=unset' "$profile_output" >/dev/null
grep -Fx 'cuda_unified_memory=unset' "$profile_output" >/dev/null

# custom restores only what the caller asked for, captured ahead of the scrub,
# so a caller that names GGML_CUDA_DISABLE_FUSION and GGML_CUDA_PDL sees both
# and nothing else the scrub removed.
GGML_CUDA_DISABLE_FUSION=1 GGML_CUDA_PDL=1 QWEN_CUDA_PROFILE=custom \
    QWEN_POLICY_TEST_OUTPUT=$profile_output \
    "$policy" "$fake_server" "$model_path" 4096 18082
grep -Fx 'profile=custom' "$profile_output" >/dev/null
grep -Fx 'cuda_disable_graphs=unset' "$profile_output" >/dev/null
grep -Fx 'cuda_disable_fusion=1' "$profile_output" >/dev/null
grep -Fx 'cuda_pdl=1' "$profile_output" >/dev/null
grep -Fx 'cuda_unified_memory=unset' "$profile_output" >/dev/null

if QWEN_CUDA_PROFILE=unknown \
    QWEN_POLICY_TEST_OUTPUT=$profile_output \
    "$policy" "$fake_server" "$model_path" 4096 18083 \
    >"$temporary_directory/cuda-profile.stdout" \
    2>"$temporary_directory/cuda-profile.stderr"; then
    printf 'policy accepted an unknown CUDA profile\n' >&2
    exit 1
fi
grep -F 'unknown CUDA profile' "$temporary_directory/cuda-profile.stderr" >/dev/null

# vulkan-runtime-env.sh takes default and custom alone via QWEN_VULKAN_PROFILE.
# custom restores GGML_VK_MAX_NODES_PER_SUBMIT and GGML_VK_SERIALIZE_SUBMISSIONS
# from the caller's own ambient values, captured ahead of the same scrub.
GGML_VK_MAX_NODES_PER_SUBMIT=16 GGML_VK_SERIALIZE_SUBMISSIONS=1 \
    QWEN_SERVING_BACKEND=vulkan QWEN_VULKAN_PROFILE=custom \
    QWEN_VULKAN_ICD=$fake_icd \
    QWEN_POLICY_TEST_OUTPUT=$profile_output \
    "$policy" "$fake_server" "$model_path" 4096 18084
grep -Fx 'profile=custom' "$profile_output" >/dev/null
grep -Fx 'serialized=1' "$profile_output" >/dev/null
grep -Fx 'max_nodes=16' "$profile_output" >/dev/null

# The submission profiles the prior host's Vulkan driver carried --
# low-serialized, low-async, paced-60 -- name settings no run on this device
# has moved, so vulkan-runtime-env.sh refuses the name outright rather than
# silently accepting it as a no-op.
if QWEN_SERVING_BACKEND=vulkan QWEN_VULKAN_PROFILE=low-serialized \
    QWEN_VULKAN_ICD=$fake_icd \
    QWEN_POLICY_TEST_OUTPUT=$profile_output \
    "$policy" "$fake_server" "$model_path" 4096 18085 \
    >"$temporary_directory/retired-profile.stdout" \
    2>"$temporary_directory/retired-profile.stderr"; then
    printf 'policy accepted the retired low-serialized Vulkan profile\n' >&2
    exit 1
fi
grep -F 'unknown Vulkan profile' "$temporary_directory/retired-profile.stderr" \
    >/dev/null

static_path=$temporary_directory/webui
static_output_path=$temporary_directory/static-policy.out
api_key_file=$temporary_directory/api.key
mkdir -p "$static_path"
: > "$static_path/index.html"
printf 'synthetic-test-key\n' >"$api_key_file"
chmod 600 "$api_key_file"
QWEN_VULKAN_ICD=$fake_icd QWEN_POLICY_TEST_OUTPUT=$static_output_path \
    "$policy" "$fake_server" "$model_path" 4096 18080 "$static_path" \
    "$api_key_file"
grep -Fx 'argument=--path' "$static_output_path" >/dev/null
grep -Fx "argument=$static_path" "$static_output_path" >/dev/null
grep -Fx 'argument=--ui' "$static_output_path" >/dev/null
grep -Fx 'argument=--api-key-file' "$static_output_path" >/dev/null
grep -Fx "argument=$api_key_file" "$static_output_path" >/dev/null
if grep -Fx 'argument=--no-ui' "$static_output_path" >/dev/null; then
    printf 'static policy disabled the Web UI\n' >&2
    exit 1
fi

if QWEN_VULKAN_ICD=$fake_icd QWEN_POLICY_TEST_OUTPUT=$output_path \
    "$policy" "$fake_server" "$model_path" 4096 18080 \
    "$temporary_directory/missing-webui" "$api_key_file" \
    >"$temporary_directory/static-path.stdout" \
    2>"$temporary_directory/static-path.stderr"; then
    printf 'policy accepted a static path without index.html\n' >&2
    exit 1
fi
grep -F 'static path must contain index.html' \
    "$temporary_directory/static-path.stderr" >/dev/null

empty_key_file=$temporary_directory/empty-api.key
: >"$empty_key_file"
if QWEN_VULKAN_ICD=$fake_icd QWEN_POLICY_TEST_OUTPUT=$output_path \
    "$policy" "$fake_server" "$model_path" 4096 18080 "$static_path" \
    "$empty_key_file" >"$temporary_directory/api-key.stdout" \
    2>"$temporary_directory/api-key.stderr"; then
    printf 'policy accepted an empty API key file\n' >&2
    exit 1
fi
grep -F 'API key file must be a non-empty regular file' \
    "$temporary_directory/api-key.stderr" >/dev/null

# A static path alone serves the page without authentication, which the policy
# admits because the key authenticates callers rather than granting the model a
# capability it otherwise withholds. The reverse pairing stays refused: a key
# with nothing to serve names a caller mistake.
if ! QWEN_VULKAN_ICD=$fake_icd QWEN_POLICY_TEST_OUTPUT=$output_path \
    "$policy" "$fake_server" "$model_path" 4096 18080 "$static_path" \
    >"$temporary_directory/unpaired-static.stdout" \
    2>"$temporary_directory/unpaired-static.stderr"; then
    printf 'policy refused a static path served without an API key\n' >&2
    cat "$temporary_directory/unpaired-static.stderr" >&2
    exit 1
fi
if sed -n 's/^argument=//p' "$output_path" | grep -Fqx -- --api-key-file; then
    printf 'policy passed --api-key-file with no key file supplied\n' >&2
    exit 1
fi

if QWEN_VULKAN_ICD=$fake_icd QWEN_POLICY_TEST_OUTPUT=$output_path \
    "$policy" "$fake_server" "$model_path" 4096 18080 '' \
    "$temporary_directory/api.key" \
    >"$temporary_directory/unpaired-key.stdout" \
    2>"$temporary_directory/unpaired-key.stderr"; then
    printf 'policy accepted an API key file with no static path\n' >&2
    exit 1
fi
grep -F 'an API key file requires a static path' \
    "$temporary_directory/unpaired-key.stderr" >/dev/null

if LLAMA_ARG_N_PARALLEL=2 QWEN_VULKAN_ICD=$fake_icd \
    QWEN_POLICY_TEST_OUTPUT=$output_path \
    "$policy" "$fake_server" "$model_path" 24576 8080 \
    >"$temporary_directory/override.stdout" \
    2>"$temporary_directory/override.stderr"; then
    printf 'policy accepted a LLAMA_ARG_* override\n' >&2
    exit 1
fi
grep -F 'environment overrides are forbidden' \
    "$temporary_directory/override.stderr" >/dev/null

if QWEN_VULKAN_ICD=$fake_icd QWEN_POLICY_TEST_OUTPUT=$output_path \
    "$policy" "$fake_server" "$model_path" 24576 80 \
    >"$temporary_directory/port.stdout" \
    2>"$temporary_directory/port.stderr"; then
    printf 'policy accepted a privileged port\n' >&2
    exit 1
fi
grep -F 'port must be an integer from 1024 through 65535' \
    "$temporary_directory/port.stderr" >/dev/null

if QWEN_VULKAN_ICD=$fake_icd QWEN_POLICY_TEST_OUTPUT=$output_path \
    "$policy" "$fake_server" "$model_path" 24577 8080 \
    >"$temporary_directory/context.stdout" \
    2>"$temporary_directory/context.stderr"; then
    printf 'policy accepted a context above the registered ceiling\n' >&2
    exit 1
fi
grep -F 'context size exceeds the admitted ceiling for this cache policy: 24577 > 24576' \
    "$temporary_directory/context.stderr" >/dev/null

# Router mode replaces the single model with a preset file and a resident-model
# limit, and drops the fixed alias because the preset supplies one per
# checkpoint. Every guard flag stays, because llama-server cascades this argv
# onto each child it spawns.
append_complete_router_section() {
    router_section_file=$1
    {
        printf '[fabricated]\n'
        printf 'LLAMA_ARG_MODEL = %s\n' "$registry_model"
        printf 'LLAMA_ARG_CTX_SIZE = 4096\n'
        printf 'LLAMA_ARG_CACHE_TYPE_K = q5_1\n'
        printf 'LLAMA_ARG_CACHE_TYPE_V = iq4_nl\n'
        printf 'LLAMA_ARG_FLASH_ATTN = auto\n'
        printf 'LLAMA_ARG_BATCH = 256\n'
        printf 'LLAMA_ARG_UBATCH = 64\n'
    } >>"$router_section_file"
}
router_presets=$temporary_directory/router-presets.ini
: >"$router_presets"
append_complete_router_section "$router_presets"
router_output=$temporary_directory/router.out
QWEN_MODEL_REGISTRY=$fabricated_registry QWEN_MODEL_ROOT=$router_model_root \
QWEN_VULKAN_ICD=$fake_icd \
    QWEN_POLICY_TEST_OUTPUT=$router_output \
    QWEN_ROUTER=1 QWEN_ROUTER_PRESETS=$router_presets QWEN_ROUTER_MAX=1 \
    "$policy" "$fake_server" "$model_path" 4096 18080
router_arguments=$(sed -n 's/^argument=//p' "$router_output" | tr '\n' ' ')
case $router_arguments in
    *"--models-preset $router_presets --models-max 1 "*) ;;
    *)
        printf 'router preset arguments did not reach the argument list: %s\n' \
            "$router_arguments" >&2
        exit 1
        ;;
esac

# Preset validation consumes the same router-child quarantine authority as
# generation. A persisted section can match models.tsv exactly and still lose
# admission when a later model- or profile-scope quarantine row arrives.
router_model_quarantine=$temporary_directory/router-model-quarantine.tsv
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    fabricated-model model fabricated no-validated-safe-tuple - - - - - - \
    evidence/x.md evidence/y.md evidence/z.md router-child \
    >"$router_model_quarantine"
if QWEN_MODEL_REGISTRY=$fabricated_registry \
    QWEN_QUARANTINE_REGISTRY=$router_model_quarantine \
    QWEN_MODEL_ROOT=$router_model_root QWEN_VULKAN_ICD=$fake_icd \
    QWEN_POLICY_TEST_OUTPUT=$router_output QWEN_ROUTER=1 \
    QWEN_ROUTER_PRESETS=$router_presets \
    "$policy" "$fake_server" "$registry_model" 4096 18080 \
    >"$temporary_directory/router-model-quarantine.stdout" \
    2>"$temporary_directory/router-model-quarantine.stderr"; then
    printf 'router accepted a stale preset under model quarantine\n' >&2
    exit 1
fi
grep -F 'router preset section fabricated is excluded by model quarantine' \
    "$temporary_directory/router-model-quarantine.stderr" >/dev/null

router_profile_quarantine=$temporary_directory/router-profile-quarantine.tsv
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    fabricated-profile profile fabricated ring-timeout-only 4096 256 64 \
    q5_1 iq4_nl auto evidence/x.md evidence/y.md evidence/z.md any \
    >"$router_profile_quarantine"
if QWEN_MODEL_REGISTRY=$fabricated_registry \
    QWEN_QUARANTINE_REGISTRY=$router_profile_quarantine \
    QWEN_MODEL_ROOT=$router_model_root QWEN_VULKAN_ICD=$fake_icd \
    QWEN_POLICY_TEST_OUTPUT=$router_output QWEN_ROUTER=1 \
    QWEN_ROUTER_PRESETS=$router_presets \
    "$policy" "$fake_server" "$registry_model" 4096 18080 \
    >"$temporary_directory/router-profile-quarantine.stdout" \
    2>"$temporary_directory/router-profile-quarantine.stderr"; then
    printf 'router accepted a stale preset under profile quarantine\n' >&2
    exit 1
fi
grep -F 'router preset section fabricated is excluded by profile quarantine' \
    "$temporary_directory/router-profile-quarantine.stderr" >/dev/null

# An ambient research override cannot bless a preset that records no override.
# The persisted marker governs both section admission and later loopback policy.
marker_zero_router_presets=$temporary_directory/marker-zero-router-presets.ini
printf '%s\n' '# qwen_router_include_quarantine=0' \
    >"$marker_zero_router_presets"
append_complete_router_section "$marker_zero_router_presets"
if QWEN_MODEL_REGISTRY=$fabricated_registry \
    QWEN_QUARANTINE_REGISTRY=$router_profile_quarantine \
    QWEN_MODEL_ROOT=$router_model_root QWEN_VULKAN_ICD=$fake_icd \
    QWEN_ROUTER_INCLUDE_QUARANTINE=1 \
    QWEN_POLICY_TEST_OUTPUT=$router_output QWEN_ROUTER=1 \
    QWEN_ROUTER_PRESETS=$marker_zero_router_presets \
    "$policy" "$fake_server" "$registry_model" 4096 18080 \
    >"$temporary_directory/marker-zero-router.stdout" \
    2>"$temporary_directory/marker-zero-router.stderr"; then
    printf 'ambient override admitted a marker-zero stale preset\n' >&2
    exit 1
fi
grep -F 'router preset section fabricated is excluded by profile quarantine' \
    "$temporary_directory/marker-zero-router.stderr" >/dev/null

# Profile authority is tuple-exact. A quarantine at a neighbouring depth leaves
# the persisted 4096-token section admitted.
router_neighbour_quarantine=$temporary_directory/router-neighbour-quarantine.tsv
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    fabricated-neighbour profile fabricated ring-timeout-only 8192 256 64 \
    q5_1 iq4_nl auto evidence/x.md evidence/y.md evidence/z.md any \
    >"$router_neighbour_quarantine"
QWEN_MODEL_REGISTRY=$fabricated_registry \
QWEN_QUARANTINE_REGISTRY=$router_neighbour_quarantine \
QWEN_MODEL_ROOT=$router_model_root QWEN_VULKAN_ICD=$fake_icd \
QWEN_POLICY_TEST_OUTPUT=$router_output QWEN_ROUTER=1 \
QWEN_ROUTER_PRESETS=$router_presets \
    "$policy" "$fake_server" "$registry_model" 4096 18080
grep -Fx "argument=$router_presets" "$router_output" >/dev/null

# Missing or malformed authority stops router launch before a stale preset can
# be interpreted as admitted.
if QWEN_MODEL_REGISTRY=$fabricated_registry \
    QWEN_QUARANTINE_REGISTRY=$temporary_directory/absent-router-quarantine.tsv \
    QWEN_MODEL_ROOT=$router_model_root QWEN_VULKAN_ICD=$fake_icd \
    QWEN_POLICY_TEST_OUTPUT=$router_output QWEN_ROUTER=1 \
    QWEN_ROUTER_PRESETS=$router_presets \
    "$policy" "$fake_server" "$registry_model" 4096 18080 \
    >"$temporary_directory/absent-router-quarantine.stdout" \
    2>"$temporary_directory/absent-router-quarantine.stderr"; then
    printf 'router accepted missing quarantine authority\n' >&2
    exit 1
fi
grep -F 'router quarantine authority is unavailable' \
    "$temporary_directory/absent-router-quarantine.stderr" >/dev/null

malformed_router_quarantine=$temporary_directory/malformed-router-quarantine.tsv
printf 'malformed\trow\n' >"$malformed_router_quarantine"
if QWEN_MODEL_REGISTRY=$fabricated_registry \
    QWEN_QUARANTINE_REGISTRY=$malformed_router_quarantine \
    QWEN_MODEL_ROOT=$router_model_root QWEN_VULKAN_ICD=$fake_icd \
    QWEN_POLICY_TEST_OUTPUT=$router_output QWEN_ROUTER=1 \
    QWEN_ROUTER_PRESETS=$router_presets \
    "$policy" "$fake_server" "$registry_model" 4096 18080 \
    >"$temporary_directory/malformed-router-quarantine.stdout" \
    2>"$temporary_directory/malformed-router-quarantine.stderr"; then
    printf 'router accepted malformed quarantine authority\n' >&2
    exit 1
fi
grep -F 'router quarantine authority is unavailable' \
    "$temporary_directory/malformed-router-quarantine.stderr" >/dev/null

semantic_malformed_router_quarantine=$temporary_directory/semantic-malformed-router-quarantine.tsv
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    malformed-profile profile fabricated ring-timeout-only not-a-depth 256 64 \
    q5_1 iq4_nl auto evidence/x.md evidence/y.md evidence/z.md router-child \
    >"$semantic_malformed_router_quarantine"
if QWEN_MODEL_REGISTRY=$fabricated_registry \
    QWEN_QUARANTINE_REGISTRY=$semantic_malformed_router_quarantine \
    QWEN_MODEL_ROOT=$router_model_root QWEN_VULKAN_ICD=$fake_icd \
    QWEN_POLICY_TEST_OUTPUT=$router_output QWEN_ROUTER=1 \
    QWEN_ROUTER_PRESETS=$router_presets \
    "$policy" "$fake_server" "$registry_model" 4096 18080 \
    >"$temporary_directory/semantic-malformed-router-quarantine.stdout" \
    2>"$temporary_directory/semantic-malformed-router-quarantine.stderr"; then
    printf 'router accepted semantically malformed quarantine authority\n' >&2
    exit 1
fi
grep -F 'router quarantine authority is unavailable' \
    "$temporary_directory/semantic-malformed-router-quarantine.stderr" >/dev/null

# The router preflight subject sizes installed weights only. Its standalone
# context ceiling does not constrain other preset sections, and the listener
# carries none of the six per-checkpoint tuple flags.
QWEN_MODEL_REGISTRY=$fabricated_registry QWEN_MODEL_ROOT=$router_model_root \
QWEN_VULKAN_ICD=$fake_icd QWEN_POLICY_TEST_OUTPUT=$router_output QWEN_ROUTER=1 \
QWEN_ROUTER_PRESETS=$router_presets QWEN_ROUTER_MAX=1 \
    "$policy" "$fake_server" "$registry_model" 24576 18080
router_candidate_arguments=$(sed -n 's/^argument=//p' "$router_output" |
    tr '\n' ' ')
case " $router_candidate_arguments " in
    *' --models-preset '* ) ;;
    *)
        printf 'candidate-only router did not reach the argument list: %s\n' \
            "$router_candidate_arguments" >&2
        exit 1
        ;;
esac
for overridden_flag in --ctx-size --batch-size --ubatch-size --flash-attn \
    --cache-type-k --cache-type-v; do
    case " $router_candidate_arguments " in
        *" $overridden_flag "*)
            printf 'candidate-only router carries tuple flag %s: %s\n' \
                "$overridden_flag" "$router_candidate_arguments" >&2
            exit 1
            ;;
    esac
done

incomplete_router_presets=$temporary_directory/incomplete-router-presets.ini
sed '/^LLAMA_ARG_UBATCH =/d' "$router_presets" >"$incomplete_router_presets"
if QWEN_MODEL_REGISTRY=$fabricated_registry QWEN_MODEL_ROOT=$router_model_root \
    QWEN_VULKAN_ICD=$fake_icd \
    QWEN_POLICY_TEST_OUTPUT=$router_output QWEN_ROUTER=1 \
    QWEN_ROUTER_PRESETS=$incomplete_router_presets QWEN_ROUTER_MAX=1 \
    "$policy" "$fake_server" "$registry_model" 24576 18080 \
    >"$temporary_directory/incomplete-router.stdout" \
    2>"$temporary_directory/incomplete-router.stderr"; then
    printf 'router accepted a preset section with an incomplete tuple\n' >&2
    exit 1
fi
grep -F 'router preset section fabricated requires exactly one LLAMA_ARG_UBATCH, found 0' \
    "$temporary_directory/incomplete-router.stderr" >/dev/null
grep -F 'router presets do not carry complete admitted tuples:' \
    "$temporary_directory/incomplete-router.stderr" >/dev/null

unsafe_geometry_presets=$temporary_directory/unsafe-geometry-router-presets.ini
sed -e 's/^LLAMA_ARG_BATCH = 256$/LLAMA_ARG_BATCH = 2048/' \
    -e 's/^LLAMA_ARG_UBATCH = 64$/LLAMA_ARG_UBATCH = 512/' \
    "$router_presets" >"$unsafe_geometry_presets"
if QWEN_MODEL_REGISTRY=$fabricated_registry QWEN_MODEL_ROOT=$router_model_root \
    QWEN_VULKAN_ICD=$fake_icd \
    QWEN_POLICY_TEST_OUTPUT=$router_output QWEN_ROUTER=1 \
    QWEN_ROUTER_PRESETS=$unsafe_geometry_presets QWEN_ROUTER_MAX=1 \
    "$policy" "$fake_server" "$registry_model" 24576 18080 \
    >"$temporary_directory/unsafe-geometry-router.stdout" \
    2>"$temporary_directory/unsafe-geometry-router.stderr"; then
    printf 'router accepted a positive but unadmitted submission geometry\n' >&2
    exit 1
fi
grep -F 'router preset section fabricated carries LLAMA_ARG_BATCH 2048, registry admits 256' \
    "$temporary_directory/unsafe-geometry-router.stderr" >/dev/null

unknown_cache_presets=$temporary_directory/unknown-cache-router-presets.ini
sed 's/^LLAMA_ARG_CACHE_TYPE_K = q5_1$/LLAMA_ARG_CACHE_TYPE_K = q3_unknown/' \
    "$router_presets" >"$unknown_cache_presets"
if QWEN_MODEL_REGISTRY=$fabricated_registry QWEN_MODEL_ROOT=$router_model_root \
    QWEN_VULKAN_ICD=$fake_icd \
    QWEN_POLICY_TEST_OUTPUT=$router_output QWEN_ROUTER=1 \
    QWEN_ROUTER_PRESETS=$unknown_cache_presets QWEN_ROUTER_MAX=1 \
    "$policy" "$fake_server" "$registry_model" 24576 18080 \
    >"$temporary_directory/unknown-cache-router.stdout" \
    2>"$temporary_directory/unknown-cache-router.stderr"; then
    printf 'router accepted a preset with an unknown cache encoding\n' >&2
    exit 1
fi
grep -F 'router preset section fabricated carries invalid LLAMA_ARG_CACHE_TYPE_K: q3_unknown' \
    "$temporary_directory/unknown-cache-router.stderr" >/dev/null

supported_cache_presets=$temporary_directory/supported-cache-router-presets.ini
sed 's/^LLAMA_ARG_CACHE_TYPE_K = q5_1$/LLAMA_ARG_CACHE_TYPE_K = f16/' \
    "$router_presets" >"$supported_cache_presets"
if QWEN_MODEL_REGISTRY=$fabricated_registry QWEN_MODEL_ROOT=$router_model_root \
    QWEN_VULKAN_ICD=$fake_icd \
    QWEN_POLICY_TEST_OUTPUT=$router_output QWEN_ROUTER=1 \
    QWEN_ROUTER_PRESETS=$supported_cache_presets QWEN_ROUTER_MAX=1 \
    "$policy" "$fake_server" "$registry_model" 24576 18080 \
    >"$temporary_directory/supported-cache-router.stdout" \
    2>"$temporary_directory/supported-cache-router.stderr"; then
    printf 'router accepted a supported but unadmitted cache encoding\n' >&2
    exit 1
fi
grep -F 'router preset section fabricated carries LLAMA_ARG_CACHE_TYPE_K f16, registry admits q5_1' \
    "$temporary_directory/supported-cache-router.stderr" >/dev/null

unregistered_router_presets=$temporary_directory/unregistered-router-presets.ini
sed 's/^\[fabricated\]$/[unregistered]/' \
    "$router_presets" >"$unregistered_router_presets"
if QWEN_MODEL_REGISTRY=$fabricated_registry QWEN_MODEL_ROOT=$router_model_root \
    QWEN_VULKAN_ICD=$fake_icd \
    QWEN_POLICY_TEST_OUTPUT=$router_output QWEN_ROUTER=1 \
    QWEN_ROUTER_PRESETS=$unregistered_router_presets QWEN_ROUTER_MAX=1 \
    "$policy" "$fake_server" "$registry_model" 24576 18080 \
    >"$temporary_directory/unregistered-router.stdout" \
    2>"$temporary_directory/unregistered-router.stderr"; then
    printf 'router accepted a preset section absent from the registry\n' >&2
    exit 1
fi
grep -F 'router preset section unregistered resolves to 0 registry rows' \
    "$temporary_directory/unregistered-router.stderr" >/dev/null

repointed_router_presets=$temporary_directory/repointed-router-presets.ini
alternate_model_root=$temporary_directory/alternate-model-root
alternate_model_path=$alternate_model_root/fabricated.gguf
mkdir -p "$alternate_model_root"
: >"$alternate_model_path"
sed "s|^LLAMA_ARG_MODEL = .*|LLAMA_ARG_MODEL = $alternate_model_path|" \
    "$router_presets" >"$repointed_router_presets"
if QWEN_MODEL_REGISTRY=$fabricated_registry QWEN_MODEL_ROOT=$router_model_root \
    QWEN_VULKAN_ICD=$fake_icd \
    QWEN_POLICY_TEST_OUTPUT=$router_output QWEN_ROUTER=1 \
    QWEN_ROUTER_PRESETS=$repointed_router_presets QWEN_ROUTER_MAX=1 \
    "$policy" "$fake_server" "$registry_model" 24576 18080 \
    >"$temporary_directory/repointed-router.stdout" \
    2>"$temporary_directory/repointed-router.stderr"; then
    printf 'router accepted a section pointed at another model file\n' >&2
    exit 1
fi
grep -F "router preset section fabricated carries LLAMA_ARG_MODEL $alternate_model_path, registry admits $router_model_root/fabricated.gguf" \
    "$temporary_directory/repointed-router.stderr" >/dev/null

# Registry tier changes invalidate persisted sections even when every runtime
# tuple field still matches. Archive and rejected rows never reach a generated
# router preset.
archived_registry=$temporary_directory/archived-models.tsv
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    fabricated research fabricated.gguf download-qwen38-4b-distill-q4km.sh \
    4096 8192 8192 q5_1 iq4_nl auto none - - - untested archive 256 64 4096 - unmeasured refused \
    - off - \
    >"$archived_registry"
if QWEN_MODEL_REGISTRY=$archived_registry QWEN_MODEL_ROOT=$router_model_root \
    QWEN_VULKAN_ICD=$fake_icd QWEN_POLICY_TEST_OUTPUT=$router_output \
    QWEN_ROUTER=1 QWEN_ROUTER_PRESETS=$router_presets \
    "$policy" "$fake_server" "$registry_model" 4096 18080 \
    >"$temporary_directory/archived-router.stdout" \
    2>"$temporary_directory/archived-router.stderr"; then
    printf 'router accepted a persisted section after archival\n' >&2
    exit 1
fi
grep -F 'router preset section fabricated has non-servable registry tier archive' \
    "$temporary_directory/archived-router.stderr" >/dev/null

# A quarantine tier requires both the durable override and model-scope
# router-child authority. The marker alone cannot manufacture that authority.
quarantine_tier_registry=$temporary_directory/quarantine-tier-models.tsv
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    fabricated research fabricated.gguf download-qwen38-4b-distill-q4km.sh \
    4096 8192 8192 q5_1 iq4_nl auto none - - - untested quarantine 256 64 4096 - unmeasured refused \
    - off - \
    >"$quarantine_tier_registry"
unowned_quarantine_preset=$temporary_directory/unowned-quarantine-tier.ini
printf '%s\n' '# qwen_router_include_quarantine=1' \
    >"$unowned_quarantine_preset"
append_complete_router_section "$unowned_quarantine_preset"
if QWEN_MODEL_REGISTRY=$quarantine_tier_registry \
    QWEN_MODEL_ROOT=$router_model_root QWEN_VULKAN_ICD=$fake_icd \
    QWEN_POLICY_TEST_OUTPUT=$router_output QWEN_ROUTER=1 \
    QWEN_ROUTER_PRESETS=$unowned_quarantine_preset \
    "$policy" "$fake_server" "$registry_model" 4096 18080 \
    >"$temporary_directory/unowned-quarantine-tier.stdout" \
    2>"$temporary_directory/unowned-quarantine-tier.stderr"; then
    printf 'router accepted a quarantine tier without model authority\n' >&2
    exit 1
fi
grep -F 'router preset section fabricated lacks an admitted model quarantine override' \
    "$temporary_directory/unowned-quarantine-tier.stderr" >/dev/null

case $router_arguments in
    *'--model '*)
        printf 'router mode still passed a single model: %s\n' \
            "$router_arguments" >&2
        exit 1
        ;;
esac
case $router_arguments in
    *'--device CUDA0 '*'--override-tensor .*=CUDA0 '*'--no-context-shift'*) ;;
    *)
        printf 'router mode dropped a guard flag: %s\n' "$router_arguments" >&2
        exit 1
        ;;
esac

# The pinned llama-ui declares exec_shell_command, write_file, and edit_file as
# ToolSource.SERVER, so llama-server executes them and the UI merely offers
# them. The server grants them through --tools, and the appliance binds 0.0.0.0,
# so the flag reaching either argv would put shell execution and file writing on
# the LAN behind a prompt-injectable model.
for tool_argv in "$actual_arguments" "$router_arguments"; do
    case " $tool_argv " in
        *' --tools '* | *' --tool '*)
            printf 'a tool grant reached the server argument list: %s\n' \
                "$tool_argv" >&2
            exit 1
            ;;
    esac
done

# server-models.cpp overlays the router's own CLI arguments on top of every
# model preset with common_preset::merge, which overwrites, so any of these six
# on the router argv silently replaces the same key in every section. Router
# mode leaves them to the preset file for that reason.
for overridden_flag in --ctx-size --batch-size --ubatch-size --flash-attn \
    --cache-type-k --cache-type-v; do
    case " $router_arguments " in
        *" $overridden_flag "*)
            printf 'router argv carries %s, which overwrites every model preset: %s\n' \
                "$overridden_flag" "$router_arguments" >&2
            exit 1
            ;;
    esac
done

# server-models.cpp's preset.merge(base_preset) overwrites every model
# section with a router-parent speculation argument the same way it overwrites
# the six tuple flags above, so the four QWEN_SPEC_* variables are refused
# outright in router mode rather than reaching the argv where they would
# silently replace the registry's own per-checkpoint speculation_profile.
router_speculation_output=$temporary_directory/router-speculation.out
rm -f "$router_speculation_output"
if QWEN_MODEL_REGISTRY=$fabricated_registry QWEN_MODEL_ROOT=$router_model_root \
    QWEN_VULKAN_ICD=$fake_icd QWEN_POLICY_TEST_OUTPUT=$router_speculation_output \
    QWEN_ROUTER=1 QWEN_ROUTER_PRESETS=$router_presets \
    QWEN_SPEC_TYPE=draft-mtp \
    "$policy" "$fake_server" "$registry_model" 4096 18080 \
    >"$temporary_directory/router-spec-type.stdout" \
    2>"$temporary_directory/router-spec-type.stderr"; then
    printf 'router mode accepted QWEN_SPEC_TYPE\n' >&2
    exit 1
fi
grep -F 'router speculation is registry-owned' \
    "$temporary_directory/router-spec-type.stderr" >/dev/null
grep -F 'QWEN_SPEC_TYPE' "$temporary_directory/router-spec-type.stderr" >/dev/null
if [ -e "$router_speculation_output" ]; then
    printf 'fake server ran despite QWEN_SPEC_TYPE in router mode\n' >&2
    exit 1
fi

rm -f "$router_speculation_output"
if QWEN_MODEL_REGISTRY=$fabricated_registry QWEN_MODEL_ROOT=$router_model_root \
    QWEN_VULKAN_ICD=$fake_icd QWEN_POLICY_TEST_OUTPUT=$router_speculation_output \
    QWEN_ROUTER=1 QWEN_ROUTER_PRESETS=$router_presets \
    QWEN_SPEC_DRAFT_N_MAX=4 \
    "$policy" "$fake_server" "$registry_model" 4096 18080 \
    >"$temporary_directory/router-spec-n-max.stdout" \
    2>"$temporary_directory/router-spec-n-max.stderr"; then
    printf 'router mode accepted QWEN_SPEC_DRAFT_N_MAX\n' >&2
    exit 1
fi
grep -F 'router speculation is registry-owned' \
    "$temporary_directory/router-spec-n-max.stderr" >/dev/null
grep -F 'QWEN_SPEC_DRAFT_N_MAX' "$temporary_directory/router-spec-n-max.stderr" \
    >/dev/null
if [ -e "$router_speculation_output" ]; then
    printf 'fake server ran despite QWEN_SPEC_DRAFT_N_MAX in router mode\n' >&2
    exit 1
fi

rm -f "$router_speculation_output"
if QWEN_MODEL_REGISTRY=$fabricated_registry QWEN_MODEL_ROOT=$router_model_root \
    QWEN_VULKAN_ICD=$fake_icd QWEN_POLICY_TEST_OUTPUT=$router_speculation_output \
    QWEN_ROUTER=1 QWEN_ROUTER_PRESETS=$router_presets \
    QWEN_SPEC_DRAFT_P_MIN=0.5 \
    "$policy" "$fake_server" "$registry_model" 4096 18080 \
    >"$temporary_directory/router-spec-p-min.stdout" \
    2>"$temporary_directory/router-spec-p-min.stderr"; then
    printf 'router mode accepted QWEN_SPEC_DRAFT_P_MIN\n' >&2
    exit 1
fi
grep -F 'router speculation is registry-owned' \
    "$temporary_directory/router-spec-p-min.stderr" >/dev/null
grep -F 'QWEN_SPEC_DRAFT_P_MIN' "$temporary_directory/router-spec-p-min.stderr" \
    >/dev/null
if [ -e "$router_speculation_output" ]; then
    printf 'fake server ran despite QWEN_SPEC_DRAFT_P_MIN in router mode\n' >&2
    exit 1
fi

rm -f "$router_speculation_output"
if QWEN_MODEL_REGISTRY=$fabricated_registry QWEN_MODEL_ROOT=$router_model_root \
    QWEN_VULKAN_ICD=$fake_icd QWEN_POLICY_TEST_OUTPUT=$router_speculation_output \
    QWEN_ROUTER=1 QWEN_ROUTER_PRESETS=$router_presets \
    QWEN_SPEC_BACKEND_SAMPLING=1 \
    "$policy" "$fake_server" "$registry_model" 4096 18080 \
    >"$temporary_directory/router-spec-backend-sampling.stdout" \
    2>"$temporary_directory/router-spec-backend-sampling.stderr"; then
    printf 'router mode accepted QWEN_SPEC_BACKEND_SAMPLING\n' >&2
    exit 1
fi
grep -F 'router speculation is registry-owned' \
    "$temporary_directory/router-spec-backend-sampling.stderr" >/dev/null
grep -F 'QWEN_SPEC_BACKEND_SAMPLING' \
    "$temporary_directory/router-spec-backend-sampling.stderr" >/dev/null
if [ -e "$router_speculation_output" ]; then
    printf 'fake server ran despite QWEN_SPEC_BACKEND_SAMPLING in router mode\n' >&2
    exit 1
fi

# A router launch naming none of the four variables is admitted, which is what
# lets build-router-presets.sh keep emitting speculation into each section
# without qwen-capacity-policy.sh standing in its way.
rm -f "$router_speculation_output"
QWEN_MODEL_REGISTRY=$fabricated_registry QWEN_MODEL_ROOT=$router_model_root \
    QWEN_VULKAN_ICD=$fake_icd QWEN_POLICY_TEST_OUTPUT=$router_speculation_output \
    QWEN_ROUTER=1 QWEN_ROUTER_PRESETS=$router_presets \
    "$policy" "$fake_server" "$registry_model" 4096 18080
grep -Fx "argument=$router_presets" "$router_speculation_output" >/dev/null

# Single-model mode keeps the four variables as the experimental path: they
# still reach the server argv unchanged.
spec_single_output=$temporary_directory/spec-single.out
QWEN_SPEC_TYPE=draft-mtp QWEN_VULKAN_ICD=$fake_icd \
    QWEN_POLICY_TEST_OUTPUT=$spec_single_output \
    "$policy" "$fake_server" "$model_path" 4096 18080
spec_single_arguments=$(sed -n 's/^argument=//p' "$spec_single_output" | tr '\n' ' ')
case $spec_single_arguments in
    *'--spec-type draft-mtp '*) ;;
    *)
        printf 'single-model mode did not pass QWEN_SPEC_TYPE through: %s\n' \
            "$spec_single_arguments" >&2
        exit 1
        ;;
esac

# An unreadable preset file is refused rather than starting a router with no
# models, which would serve a picker listing nothing.
if QWEN_VULKAN_ICD=$fake_icd QWEN_POLICY_TEST_OUTPUT=$router_output \
    QWEN_ROUTER=1 QWEN_ROUTER_PRESETS=$temporary_directory/absent.ini \
    "$policy" "$fake_server" "$model_path" 4096 18080 \
    >"$temporary_directory/router.stdout" \
    2>"$temporary_directory/router.stderr"; then
    printf 'policy accepted router mode with an unreadable preset file\n' >&2
    exit 1
fi
grep -F 'router presets are unreadable' "$temporary_directory/router.stderr" >/dev/null

# A launcher-bound snapshot carries the digest measured before memory preflight.
# Any mutation before the server exec boundary invalidates the launch.
wrong_router_preset_sha256=0000000000000000000000000000000000000000000000000000000000000000
if QWEN_MODEL_REGISTRY=$fabricated_registry QWEN_MODEL_ROOT=$router_model_root \
    QWEN_VULKAN_ICD=$fake_icd QWEN_POLICY_TEST_OUTPUT=$router_output \
    QWEN_ROUTER=1 QWEN_ROUTER_PRESETS=$router_presets \
    QWEN_ROUTER_PRESET_SHA256=$wrong_router_preset_sha256 \
    "$policy" "$fake_server" "$registry_model" 4096 18080 \
    >"$temporary_directory/router-identity.stdout" \
    2>"$temporary_directory/router-identity.stderr"; then
    printf 'policy accepted a router preset with the wrong identity\n' >&2
    exit 1
fi
grep -F 'router preset identity changed:' \
    "$temporary_directory/router-identity.stderr" >/dev/null

identity_bin=$temporary_directory/identity-bin
identity_count=$temporary_directory/identity-count
mkdir -p "$identity_bin"
cat >"$identity_bin/sha256sum" <<'SHA256SUM'
#!/bin/sh
if [ "$1" != "$QWEN_ROUTER_PRESETS" ]; then
    exec "$QWEN_TEST_REAL_SHA256SUM" "$@"
fi
count=0
if [ -r "$QWEN_TEST_IDENTITY_COUNT" ]; then
    count=$(sed -n '1p' "$QWEN_TEST_IDENTITY_COUNT")
fi
count=$((count + 1))
printf '%s\n' "$count" >"$QWEN_TEST_IDENTITY_COUNT"
if [ "$count" -eq 1 ]; then
    exec "$QWEN_TEST_REAL_SHA256SUM" "$@"
fi
printf '%s  %s\n' \
    0000000000000000000000000000000000000000000000000000000000000000 "$1"
SHA256SUM
chmod +x "$identity_bin/sha256sum"
router_preset_identity=$(sha256sum "$router_presets")
router_preset_sha256=${router_preset_identity%% *}
if QWEN_MODEL_REGISTRY=$fabricated_registry QWEN_MODEL_ROOT=$router_model_root \
    QWEN_VULKAN_ICD=$fake_icd QWEN_POLICY_TEST_OUTPUT=$router_output \
    QWEN_ROUTER=1 QWEN_ROUTER_PRESETS=$router_presets \
    QWEN_ROUTER_PRESET_SHA256=$router_preset_sha256 \
    QWEN_TEST_IDENTITY_COUNT=$identity_count \
    QWEN_TEST_REAL_SHA256SUM=$(command -v sha256sum) \
    PATH="$identity_bin:$PATH" \
    "$policy" "$fake_server" "$registry_model" 4096 18080 \
    >"$temporary_directory/router-identity-race.stdout" \
    2>"$temporary_directory/router-identity-race.stderr"; then
    printf 'policy accepted a router preset mutated after validation\n' >&2
    exit 1
fi
grep -Fx 2 "$identity_count" >/dev/null
grep -F 'router preset identity changed:' \
    "$temporary_directory/router-identity-race.stderr" >/dev/null

# The final exec guard retains the identities validated by the policy across
# the runtime wrapper's own environment setup. QWEN_SERVING_BACKEND names no
# backend here, so the policy resolves cuda-runtime-env.sh, the default
# wrapper the production chain actually execs; a quarantine replacement inside
# that wrapper therefore rejects the assembled command before the fake server
# records it.
authority_race_tools=$temporary_directory/authority-race-tools
authority_race_quarantine=$temporary_directory/authority-race-quarantine.tsv
authority_race_output=$temporary_directory/authority-race.out
mkdir -p "$authority_race_tools"
cp "$policy" "$authority_race_tools/qwen-capacity-policy.sh"
cp "$script_directory/qwen-router-exec-guard.sh" \
    "$authority_race_tools/qwen-router-exec-guard.sh"
: >"$authority_race_quarantine"
cat >"$authority_race_tools/model-registry.sh" <<'REGISTRY'
#!/bin/sh
exec "$QWEN_TEST_REAL_MODEL_REGISTRY" "$@"
REGISTRY
cat >"$authority_race_tools/cuda-runtime-env.sh" <<'CUDA_ENV'
#!/bin/sh
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    authority-race profile fabricated ring-timeout-only \
    4096 256 64 q5_1 iq4_nl auto \
    evidence/x.md evidence/y.md evidence/z.md router-child \
    >"$QWEN_QUARANTINE_REGISTRY"
exec "$@"
CUDA_ENV
chmod +x "$authority_race_tools"/*.sh
if QWEN_MODEL_REGISTRY=$fabricated_registry \
    QWEN_QUARANTINE_REGISTRY=$authority_race_quarantine \
    QWEN_MODEL_ROOT=$router_model_root QWEN_VULKAN_ICD=$fake_icd \
    QWEN_POLICY_TEST_OUTPUT=$authority_race_output QWEN_ROUTER=1 \
    QWEN_ROUTER_PRESETS=$router_presets \
    QWEN_TEST_REAL_MODEL_REGISTRY=$script_directory/model-registry.sh \
    "$authority_race_tools/qwen-capacity-policy.sh" \
        "$fake_server" "$registry_model" 4096 18080 \
        >"$temporary_directory/authority-race.stdout" \
        2>"$temporary_directory/authority-race.stderr"; then
    printf 'policy accepted quarantine authority replaced before exec\n' >&2
    exit 1
fi
grep -F 'router quarantine registry identity changed:' \
    "$temporary_directory/authority-race.stderr" >/dev/null
if [ -e "$authority_race_output" ]; then
    printf 'fake server ran after exec-boundary authority rejection\n' >&2
    exit 1
fi

# The final guard verifies the complete web-ledger identity as a fourth
# authority pair. A replacement after policy validation stops before the
# command records execution.
exec_guard=$script_directory/qwen-router-exec-guard.sh
guard_web_profiles=$temporary_directory/guard-web-profiles.tsv
guard_command=$temporary_directory/guard-command.sh
guard_command_output=$temporary_directory/guard-command.out
printf 'web-fixture\tfixture\tvalidator-gated\t4096\t4096\t5\t2\t12000\tyes\tno\t9/10\tvalidator-gated\n' \
    >"$guard_web_profiles"
cat >"$guard_command" <<'GUARD_COMMAND'
#!/bin/sh
printf 'executed\n' >"$QWEN_TEST_GUARD_COMMAND_OUTPUT"
GUARD_COMMAND
chmod +x "$guard_command"
guard_preset_sha256=$(sha256sum "$router_presets" | cut -d' ' -f1)
guard_model_sha256=$(sha256sum "$fabricated_registry" | cut -d' ' -f1)
guard_quarantine_sha256=$(sha256sum "$authority_race_quarantine" | cut -d' ' -f1)
guard_web_profiles_sha256=$(sha256sum "$guard_web_profiles" | cut -d' ' -f1)
printf 'changed\n' >>"$guard_web_profiles"
if QWEN_TEST_GUARD_COMMAND_OUTPUT=$guard_command_output \
    "$exec_guard" "$router_presets" "$guard_preset_sha256" \
    "$fabricated_registry" "$guard_model_sha256" \
    "$authority_race_quarantine" "$guard_quarantine_sha256" \
    "$guard_web_profiles" "$guard_web_profiles_sha256" "$guard_command" \
    >"$temporary_directory/web-ledger-guard.stdout" \
    2>"$temporary_directory/web-ledger-guard.stderr"; then
    printf 'exec guard accepted a replaced web profile ledger\n' >&2
    exit 1
fi
grep -F 'router web profile ledger identity changed:' \
    "$temporary_directory/web-ledger-guard.stderr" >/dev/null
if [ -e "$guard_command_output" ]; then
    printf 'guarded command ran after web-ledger identity rejection\n' >&2
    exit 1
fi

# A generated preset carries its quarantine override after the generation
# environment is gone. The launch derives loopback isolation from that durable
# file rather than from an ambient variable that can disappear on a later run.
quarantine_router_presets=$temporary_directory/quarantine-router-presets.ini
printf '%s\n' \
    '# Generated by scripts/build-router-presets.sh from the model registry.' \
    '# qwen_router_include_quarantine=1' \
    >"$quarantine_router_presets"
append_complete_router_section "$quarantine_router_presets"
printf 'LLAMA_ARG_TAGS = quarantine,research\n' \
    >>"$quarantine_router_presets"
QWEN_MODEL_REGISTRY=$fabricated_registry \
QWEN_QUARANTINE_REGISTRY=$router_profile_quarantine \
QWEN_MODEL_ROOT=$router_model_root QWEN_VULKAN_ICD=$fake_icd \
QWEN_POLICY_TEST_OUTPUT=$router_output QWEN_ROUTER=1 \
QWEN_ROUTER_PRESETS=$quarantine_router_presets QWEN_BIND_HOST=0.0.0.0 \
    "$policy" "$fake_server" "$model_path" 4096 18080 \
    2>"$temporary_directory/quarantine-router.stderr"
quarantine_router_arguments=$(sed -n 's/^argument=//p' "$router_output" |
    tr '\n' ' ')
case " $quarantine_router_arguments " in
    *' --host 127.0.0.1 '*) ;;
    *)
        printf 'preset-carried quarantine override did not force loopback: %s\n' \
            "$quarantine_router_arguments" >&2
        exit 1
        ;;
esac
grep -F 'quarantine override forces the listener to loopback' \
    "$temporary_directory/quarantine-router.stderr" >/dev/null

missing_quarantine_tag=$temporary_directory/missing-quarantine-tag.ini
sed 's/^LLAMA_ARG_TAGS = quarantine,research$/LLAMA_ARG_TAGS = research/' \
    "$quarantine_router_presets" >"$missing_quarantine_tag"
if QWEN_MODEL_REGISTRY=$fabricated_registry \
    QWEN_QUARANTINE_REGISTRY=$router_profile_quarantine \
    QWEN_MODEL_ROOT=$router_model_root QWEN_VULKAN_ICD=$fake_icd \
    QWEN_POLICY_TEST_OUTPUT=$router_output QWEN_ROUTER=1 \
    QWEN_ROUTER_PRESETS=$missing_quarantine_tag \
    "$policy" "$fake_server" "$model_path" 4096 18080 \
    >"$temporary_directory/missing-quarantine-tag.stdout" \
    2>"$temporary_directory/missing-quarantine-tag.stderr"; then
    printf 'policy accepted a research override without its quarantine tag\n' >&2
    exit 1
fi
grep -F 'router preset section fabricated carries unsafe quarantine tags:' \
    "$temporary_directory/missing-quarantine-tag.stderr" >/dev/null

default_quarantine_tag=$temporary_directory/default-quarantine-tag.ini
sed 's/^LLAMA_ARG_TAGS = quarantine,research$/LLAMA_ARG_TAGS = quarantine,research,default/' \
    "$quarantine_router_presets" >"$default_quarantine_tag"
if QWEN_MODEL_REGISTRY=$fabricated_registry \
    QWEN_QUARANTINE_REGISTRY=$router_profile_quarantine \
    QWEN_MODEL_ROOT=$router_model_root QWEN_VULKAN_ICD=$fake_icd \
    QWEN_POLICY_TEST_OUTPUT=$router_output QWEN_ROUTER=1 \
    QWEN_ROUTER_PRESETS=$default_quarantine_tag \
    "$policy" "$fake_server" "$model_path" 4096 18080 \
    >"$temporary_directory/default-quarantine-tag.stdout" \
    2>"$temporary_directory/default-quarantine-tag.stderr"; then
    printf 'policy accepted a default tag on a quarantined override section\n' >&2
    exit 1
fi
grep -F 'router preset section fabricated carries unsafe quarantine tags:' \
    "$temporary_directory/default-quarantine-tag.stderr" >/dev/null

candidate_quarantine_tag=$temporary_directory/candidate-quarantine-tag.ini
sed 's/^LLAMA_ARG_TAGS = quarantine,research$/LLAMA_ARG_TAGS = candidate,quarantine,research/' \
    "$quarantine_router_presets" >"$candidate_quarantine_tag"
if QWEN_MODEL_REGISTRY=$fabricated_registry \
    QWEN_QUARANTINE_REGISTRY=$router_profile_quarantine \
    QWEN_MODEL_ROOT=$router_model_root QWEN_VULKAN_ICD=$fake_icd \
    QWEN_POLICY_TEST_OUTPUT=$router_output QWEN_ROUTER=1 \
    QWEN_ROUTER_PRESETS=$candidate_quarantine_tag \
    "$policy" "$fake_server" "$model_path" 4096 18080 \
    >"$temporary_directory/candidate-quarantine-tag.stdout" \
    2>"$temporary_directory/candidate-quarantine-tag.stderr"; then
    printf 'policy accepted contradictory candidate and quarantine tags\n' >&2
    exit 1
fi
grep -F 'router preset section fabricated carries unsafe quarantine tags:' \
    "$temporary_directory/candidate-quarantine-tag.stderr" >/dev/null

# A generated file from before the provenance field existed is not assumed
# clean. Regeneration is required before a potentially persistent preset runs.
legacy_router_presets=$temporary_directory/legacy-router-presets.ini
printf '%s\n' \
    '# Generated by scripts/build-router-presets.sh from the model registry.' \
    >"$legacy_router_presets"
append_complete_router_section "$legacy_router_presets"
if QWEN_MODEL_REGISTRY=$fabricated_registry QWEN_MODEL_ROOT=$router_model_root \
    QWEN_VULKAN_ICD=$fake_icd QWEN_POLICY_TEST_OUTPUT=$router_output \
    QWEN_ROUTER=1 \
    QWEN_ROUTER_PRESETS=$legacy_router_presets \
    "$policy" "$fake_server" "$model_path" 4096 18080 \
    >"$temporary_directory/legacy-router.stdout" \
    2>"$temporary_directory/legacy-router.stderr"; then
    printf 'policy accepted a generated preset without quarantine provenance\n' >&2
    exit 1
fi
grep -F 'generated router presets omit quarantine provenance' \
    "$temporary_directory/legacy-router.stderr" >/dev/null

# A quarantined profile names one tuple of an otherwise servable checkpoint, so
# the policy refuses that tuple and serves every neighbour of it. Reproducing
# the quarantined geometry reset the compute ring on a live desktop on the
# prior host, which is why this is a refusal rather than a warning.
quarantine_registry=$temporary_directory/quarantine-models.tsv
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    quarantined research quarantined.gguf download-qwen38-4b-distill-q4km.sh \
    4096 16384 16384 q8_0 q4_0 on none - - - untested production 2048 512 4096 - \
    unmeasured refused - off - \
    >"$quarantine_registry"
quarantine_table=$temporary_directory/quarantine.tsv
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    quarantined-tuple profile quarantined ring-timeout-only 16384 2048 512 \
    q8_0 q4_0 on evidence/x.md evidence/y.md evidence/z.md any \
    >"$quarantine_table"
quarantine_model=$temporary_directory/quarantined.gguf
: >"$quarantine_model"

# The standalone policy consumes the quarantine query as a required safety
# input. A missing registry stops tuple construction before an unknown profile
# can reach the server.
if QWEN_MODEL_REGISTRY=$quarantine_registry \
    QWEN_QUARANTINE_REGISTRY=$temporary_directory/absent-quarantine.tsv \
    QWEN_VULKAN_ICD=$fake_icd QWEN_POLICY_TEST_OUTPUT=$cache_output \
    "$policy" "$fake_server" "$quarantine_model" 16384 18080 \
    >"$temporary_directory/absent-quarantine.stdout" \
    2>"$temporary_directory/absent-quarantine.stderr"; then
    printf 'policy accepted an unreadable quarantine registry\n' >&2
    exit 1
fi
grep -F 'quarantine registry is unreadable' \
    "$temporary_directory/absent-quarantine.stderr" >/dev/null

if QWEN_MODEL_REGISTRY=$quarantine_registry \
    QWEN_QUARANTINE_REGISTRY=$quarantine_table QWEN_VULKAN_ICD=$fake_icd \
    QWEN_POLICY_TEST_OUTPUT=$cache_output \
    "$policy" "$fake_server" "$quarantine_model" 16384 18080 \
    2>"$temporary_directory/quarantine.stderr"; then
    printf 'the policy built the quarantined tuple\n' >&2
    exit 1
fi
grep -F 'this tuple is quarantined' "$temporary_directory/quarantine.stderr" \
    >/dev/null

# The neighbouring depth under the same geometry is not quarantined and serves.
QWEN_MODEL_REGISTRY=$quarantine_registry \
    QWEN_QUARANTINE_REGISTRY=$quarantine_table QWEN_VULKAN_ICD=$fake_icd \
    QWEN_POLICY_TEST_OUTPUT=$cache_output \
    "$policy" "$fake_server" "$quarantine_model" 8192 18080
quarantine_neighbour=$(sed -n 's/^argument=//p' "$cache_output" | tr '\n' ' ')
case $quarantine_neighbour in
    *'--ctx-size 8192 '*'--batch-size 2048 --ubatch-size 512 '*) ;;
    *)
        printf 'the neighbouring depth did not build: %s\n' \
            "$quarantine_neighbour" >&2
        exit 1
        ;;
esac

# The same depth at the served geometry is a different tuple and serves.
QWEN_MODEL_REGISTRY=$quarantine_registry \
    QWEN_QUARANTINE_REGISTRY=$quarantine_table QWEN_VULKAN_ICD=$fake_icd \
    QWEN_BATCH_SIZE=128 QWEN_UBATCH_SIZE=32 \
    QWEN_POLICY_TEST_OUTPUT=$cache_output \
    "$policy" "$fake_server" "$quarantine_model" 16384 18080
quarantine_geometry=$(sed -n 's/^argument=//p' "$cache_output" | tr '\n' ' ')
case $quarantine_geometry in
    *'--ctx-size 16384 '*'--batch-size 128 --ubatch-size 32 '*) ;;
    *)
        printf 'the served geometry at the quarantined depth did not build: %s\n' \
            "$quarantine_geometry" >&2
        exit 1
        ;;
esac

printf 'qwen_capacity_policy=accepted\n'
