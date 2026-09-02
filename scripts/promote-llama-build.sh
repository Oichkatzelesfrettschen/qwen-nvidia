#!/bin/sh
set -eu

# The serving path names one build directory, so measuring a second build arm
# means editing the control script and a rollback means editing it back. This
# promotes a preset behind a symlink instead: qwen-webui-control.sh resolves
# build-appliance-current, and switching arms is one atomic rename.
#
# Promotion is a gate rather than a rename. The manifest must exist and name the
# preset, the executable must report its own version, and it must complete one
# token entirely on CUDA0, because a binary that loads and then falls back to
# the CPU backend serves at a third of the rate while looking healthy. CUDA is
# the serving backend, so CUDA admission decides promotion; a build that also
# carries libggml-vulkan.so takes an additional Vulkan fallback admission, and
# a CUDA-only build reports fallback_vulkan=not-built rather than failing.
#
# The gate reads an image through llama-mtmd-cli for the same reason it decodes
# a token through llama-cli: the projector path fails by answering wrongly. A
# projector of matching dimensions loads cleanly while writing image tokens the
# language model reads nothing from, so a binary that serves text correctly and
# describes every image from the prompt alone passes every text check.

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    printf 'usage: %s PRESET [SOURCE_DIRECTORY]\n' "$0" >&2
    printf '  --rollback restores the retained previous target\n' >&2
    exit 2
fi

preset=$1
source_directory=${2:-"${HOME:?}/src/llama.cpp-qwen-nvidia"}
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
current_link=$source_directory/build-appliance-current
previous_link=$source_directory/build-appliance-previous

if [ "$preset" = --rollback ]; then
    if [ ! -L "$previous_link" ]; then
        printf 'no retained previous target to roll back to: %s\n' "$previous_link" >&2
        exit 1
    fi
    rollback_target=$(readlink "$previous_link")
    ln -sfn "$rollback_target" "$current_link.new"
    mv -T "$current_link.new" "$current_link"
    printf 'promotion=rolled-back target=%s\n' "$rollback_target"
    exit 0
fi

build_directory=$source_directory/build-$preset
manifest_path=$build_directory/artifact-manifest.tsv
server_path=$build_directory/bin/llama-server
client_path=$build_directory/bin/llama-cli

if [ ! -x "$server_path" ]; then
    printf 'preset has no executable llama-server: %s\n' "$server_path" >&2
    exit 1
fi

if [ ! -x "$client_path" ]; then
    printf 'preset has no executable llama-cli: %s\n' "$client_path" >&2
    exit 1
fi

multimodal_path=$build_directory/bin/llama-mtmd-cli
if [ ! -x "$multimodal_path" ]; then
    printf 'preset has no executable llama-mtmd-cli: %s\n' "$multimodal_path" >&2
    exit 1
fi

if [ ! -r "$manifest_path" ]; then
    printf 'preset has no artifact manifest: %s\n' "$manifest_path" >&2
    exit 1
fi

manifest_preset=$(awk -F'\t' '$1 == "preset" { print $2; exit }' "$manifest_path")
if [ "$manifest_preset" != "$preset" ]; then
    printf 'manifest names a different preset: %s against %s\n' \
        "$manifest_preset" "$preset" >&2
    exit 1
fi

# Every hashed object in the manifest must still hash to what the build recorded,
# so a rebuild of one dependency under a promoted tree is caught here rather than
# in a serving difference nobody attributes. hash-load-closure.sh writes
# `role<TAB>basename<TAB>bytes<TAB>sha256` and the objects sit beside the
# executable, so the basename resolves against bin/.
manifest_object_count=0
manifest_drift=''
while IFS="$(printf '\t')" read -r object_role object_name object_bytes object_digest; do
    case $object_role in
        executable | linked | loadable) ;;
        *) continue ;;
    esac
    manifest_object_count=$((manifest_object_count + 1))
    object_path=$build_directory/bin/$object_name
    if [ ! -f "$object_path" ]; then
        manifest_drift="$manifest_drift$object_name missing
"
        continue
    fi
    actual_bytes=$(stat -c %s "$object_path")
    actual_digest=$(sha256sum "$object_path" | cut -d ' ' -f 1)
    if [ "$actual_bytes" != "$object_bytes" ] || [ "$actual_digest" != "$object_digest" ]; then
        manifest_drift="$manifest_drift$object_name changed
"
    fi
done <"$manifest_path"

# A manifest that names no hashable object would otherwise pass this gate
# without checking anything, which is the failure mode the gate exists against.
if [ "$manifest_object_count" -eq 0 ]; then
    printf 'manifest names no executable, linked, or loadable object: %s\n' \
        "$manifest_path" >&2
    exit 1
fi

if [ -n "$manifest_drift" ]; then
    printf 'manifest objects no longer match the build:\n%s' "$manifest_drift" >&2
    exit 1
fi

# The smoke consumers must be manifest-owned executables. An executable found
# beside the recorded build can come from an older arm and still produce a
# plausible answer, so filesystem presence alone does not bind either smoke
# result to the promoted artifact set.
for required_executable in llama-server llama-cli llama-mtmd-cli; do
    required_executable_count=$(awk -F'\t' -v object="$required_executable" '
        $1 == "executable" && $2 == object && NF == 4 { count++ }
        END { print count + 0 }
    ' "$manifest_path")
    if [ "$required_executable_count" -ne 1 ]; then
        printf 'manifest requires exactly one executable row for %s, found %s\n' \
            "$required_executable" "$required_executable_count" >&2
        exit 1
    fi
done

# Recompute the multimodal consumer's current load closure and require every
# exact row in the recorded manifest. This catches a CLI copied in after the
# build as well as a dependency that only the projector path loads.
if ! multimodal_closure_with_header=$(
    "$script_directory/hash-load-closure.sh" "$multimodal_path"
); then
    printf 'multimodal load-closure enumeration failed: %s\n' \
        "$multimodal_path" >&2
    exit 1
fi
multimodal_closure=$(printf '%s\n' "$multimodal_closure_with_header" | sed 1d)
while IFS= read -r closure_row; do
    [ -n "$closure_row" ] || continue
    if ! grep -F -x -- "$closure_row" "$manifest_path" >/dev/null; then
        printf 'manifest omits llama-mtmd-cli closure row: %s\n' \
            "$closure_row" >&2
        exit 1
    fi
done <<EOF
$multimodal_closure
EOF

# Resolve every smoke input before either device workload begins. A promotion
# with one absent input is already invalid, so the gate reports that deterministic
# boundary without spending device time or masking it behind another smoke.
promotion_model=${QWEN_PROMOTION_MODEL:-"${HOME:?}/models/Qwen3.8-2B-Distill-GGUF/Qwen3.8-2B-Q4_K_M.gguf"}
promotion_vision_model=${QWEN_PROMOTION_VISION_MODEL:-"${HOME:?}/models/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf"}
promotion_image=${QWEN_PROMOTION_IMAGE:-$script_directory/quality-images/shapes.png}
promotion_projector=''
if [ -f "$promotion_vision_model" ]; then
    promotion_projector=$("$script_directory/select-projector.sh" \
        "$promotion_vision_model" 2>/dev/null) || promotion_projector=''
fi
if [ ! -f "$promotion_model" ]; then
    printf 'promotion model is absent: %s\n' "$promotion_model" >&2
    exit 1
fi
if [ ! -f "$promotion_vision_model" ] || [ ! -f "$promotion_projector" ] ||
    [ ! -f "$promotion_image" ]; then
    printf 'multimodal promotion inputs are incomplete: model=%s projector=%s image=%s\n' \
        "$([ -f "$promotion_vision_model" ] && printf present || printf absent)" \
        "$([ -f "$promotion_projector" ] && printf present || printf absent)" \
        "$([ -f "$promotion_image" ] && printf present || printf absent)" >&2
    exit 1
fi

# Both smoke stages below load a model onto the named device with one token
# decoded through it, so promotion takes the campaign authority. It is taken here
# rather than at argument validation because everything above reads files: the
# closure hash, the manifest comparison, and the backend-library check answer
# without the device, and a build inspected while the workstation serves stays
# answerable.
. "$script_directory/gpu-workload-ownership.sh"
gpu_ownership_require || exit $?

"$server_path" --version >/dev/null 2>&1 || {
    printf 'llama-server does not report a version: %s\n' "$server_path" >&2
    exit 1
}

"$multimodal_path" --version >/dev/null 2>&1 || {
    printf 'llama-mtmd-cli does not report a version: %s\n' "$multimodal_path" >&2
    exit 1
}

# The Vulkan backend library decides the fallback fact: a build that carries
# libggml-vulkan.so takes the Vulkan fallback admission, a CUDA-only build
# reports not-built. A manifest that names either backend field must agree
# with the build, so a manifest copied from another closure is caught here.
fallback_backend=none
if [ -e "$build_directory/bin/libggml-vulkan.so" ]; then
    fallback_backend=Vulkan0
fi
manifest_serving=$(awk -F'\t' '$1 == "serving_backend" { print $2; exit }' "$manifest_path")
manifest_fallback=$(awk -F'\t' '$1 == "fallback_backend" { print $2; exit }' "$manifest_path")
if [ -n "$manifest_serving" ] && [ "$manifest_serving" != CUDA0 ]; then
    printf 'manifest names a serving backend other than CUDA0: %s\n' \
        "$manifest_serving" >&2
    exit 1
fi
if [ -n "$manifest_fallback" ] && [ "$manifest_fallback" != "$fallback_backend" ]; then
    printf 'manifest fallback_backend %s disagrees with the build: %s\n' \
        "$manifest_fallback" "$fallback_backend" >&2
    exit 1
fi

# One token, all layers on one named device, no CPU fallback admitted. The
# model is required because the check is that the device path completes, not
# that the binary runs.
#
# -v is required: llama-cli prints no loader line at the default verbosity, so
# the placement test would read an empty log and pass whatever it is given.
#
# The owner of the model buffer is the discriminating fact. At -ngl 0 this
# build reports a host model buffer and reserves output, KV, and recurrent
# buffers on CPU, so matching the word CPU would catch those three and miss
# the weights that left the device.
run_strict_smoke() {
    smoke_device=$1
    strict_output=$(LLAMA_NO_CPU_FALLBACK=1 nice -n 19 "$client_path" \
        --model "$promotion_model" --device "$smoke_device" --n-gpu-layers all \
        --override-tensor ".*=$smoke_device" --no-warmup --ctx-size 256 \
        --n-predict 1 --temp 0 --prompt 'ok' --single-turn -v 2>&1) || {
            printf 'strict %s one-token check failed:\n%s\n' \
                "$smoke_device" "$strict_output" >&2
            exit 1
        }
    case $strict_output in
        *"load_tensors:"*"model buffer size"*) ;;
        *)
            printf 'strict %s check produced no model buffer line: placement is unproven\n' \
                "$smoke_device" >&2
            exit 1
            ;;
    esac
    misplaced_weights=$(printf '%s\n' "$strict_output" |
        awk -v device="$smoke_device" '/load_tensors:.*model buffer size/ {
                size = $(NF - 1) + 0
                if (size <= 0) { next }
                owner = ""
                for (field = 1; field <= NF; field++) {
                    if ($field == "model") { owner = $(field - 1) }
                }
                if (owner != device) {
                    printf "%s holds %s MiB of weights\n", owner, size
                }
            }')
    if [ -n "$misplaced_weights" ]; then
        printf 'strict %s check placed weights off the device:\n%s\n' \
            "$smoke_device" "$misplaced_weights" >&2
        exit 1
    fi
}

# The projector path carries a failure the text path cannot show: a projector
# that loads cleanly and writes image tokens the language model reads nothing
# from answers wrongly rather than erroring. The gate therefore reads an image
# whose content this repository declares and requires the answer to carry it.
#
# The vision model is its own variable. QWEN_PROMOTION_MODEL defaults to the 2B
# distill, which the registry lists as `projector: none`, so wiring the image
# smoke to that variable would either fail on a text-only checkpoint or skip
# without saying so.
#
# scripts/generate-quality-images.py draws shapes.png as a red square, a green
# circle, and a blue triangle. Two of the three names is the threshold: it
# refuses a reply that carries no image content while leaving room for a model
# that describes the image in fewer words than it holds shapes.
run_multimodal_smoke() {
    smoke_device=$1
    multimodal_output=$(nice -n 19 "$multimodal_path" \
        --model "$promotion_vision_model" --mmproj "$promotion_projector" \
        --image "$promotion_image" --device "$smoke_device" --n-gpu-layers all \
        --ctx-size 4096 --batch-size 128 --ubatch-size 32 --threads 1 \
        --n-predict 64 --temp 0 --seed 1 \
        --prompt 'Name the colours of the shapes in this image.' 2>&1) || {
            printf 'multimodal %s one-image check failed:\n%s\n' \
                "$smoke_device" "$multimodal_output" >&2
            exit 1
        }
    named_colours=0
    for colour in red green blue; do
        case $(printf '%s' "$multimodal_output" | tr 'A-Z' 'a-z') in
            *"$colour"*) named_colours=$((named_colours + 1)) ;;
        esac
    done
    if [ "$named_colours" -lt 2 ]; then
        printf 'multimodal %s check named %s of 3 declared colours:\n%s\n' \
            "$smoke_device" "$named_colours" "$multimodal_output" >&2
        exit 1
    fi
}

run_strict_smoke CUDA0
strict_cuda_state=passed
run_multimodal_smoke CUDA0
multimodal_cuda_state=passed

fallback_vulkan_state=not-built
if [ "$fallback_backend" = Vulkan0 ]; then
    run_strict_smoke Vulkan0
    run_multimodal_smoke Vulkan0
    fallback_vulkan_state=passed
fi

if [ -L "$current_link" ]; then
    ln -sfn "$(readlink "$current_link")" "$previous_link.new"
    mv -T "$previous_link.new" "$previous_link"
fi

ln -sfn "$build_directory" "$current_link.new"
mv -T "$current_link.new" "$current_link"

printf 'promotion=accepted preset=%s target=%s strict_cuda=%s multimodal_cuda=%s fallback_vulkan=%s previous=%s\n' \
    "$preset" "$build_directory" "$strict_cuda_state" "$multimodal_cuda_state" \
    "$fallback_vulkan_state" \
    "$([ -L "$previous_link" ] && readlink "$previous_link" || printf none)"
