#!/bin/sh
set -eu

# The promotion gate decides which binary serves, so a gate that passes an
# unchanged manifest and also passes a drifted one moves a build into service
# without checking it. Its first revision did exactly that: the drift filter
# expected three tab fields with a leading path where hash-load-closure.sh
# writes four with a basename, so it matched no row and every promotion passed.
# These checks run the gate against a fabricated build tree.

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
promoter=$script_directory/promote-llama-build.sh
work_directory=$(mktemp -d)
# Promotion takes the campaign authority ahead of its two smoke stages, so this
# test names its own lock file and its own driver. The production lock at
# /tmp/qwen-ad104-gpu-0.lock stays untouched and a serving workstation does not
# decide what a fixture promotion reports.
QWEN_GPU_OWNERSHIP_LOCK=$work_directory/campaign.lock
QWEN_GPU_OWNERSHIP_NVIDIA_SMI=$work_directory/nvidia-smi
QWEN_GPU_COMPUTE_LEASE=$work_directory/absent-lease.lock
printf '#!/bin/sh\nexit 0\n' >"$QWEN_GPU_OWNERSHIP_NVIDIA_SMI"
chmod +x "$QWEN_GPU_OWNERSHIP_NVIDIA_SMI"
export QWEN_GPU_OWNERSHIP_LOCK QWEN_GPU_OWNERSHIP_NVIDIA_SMI \
    QWEN_GPU_COMPUTE_LEASE
trap 'rm -rf "$work_directory"' EXIT INT TERM
failures=0

report() {
    printf '%s=%s\n' "$1" "$2"
    [ "$2" = accepted ] || failures=$((failures + 1))
}

preset=fixture-preset
build_directory=$work_directory/build-$preset
mkdir -p "$build_directory/bin"

# A shell script stands in for the executable: the gate runs `--version` and
# inspects the output of a one-token run, and both are behaviours rather than
# machine code.
cat >"$build_directory/bin/llama-server" <<'SERVER'
#!/bin/sh
[ "${1:-}" = --version ] && { printf 'version 0 (fixture)\n'; exit 0; }
exit 1
SERVER
chmod +x "$build_directory/bin/llama-server"
# The placement gate reads the owner of the model buffer line rather than the
# word CPU, so the fixture answers with the owner the --device argument named,
# which is what a healthy strict load prints for CUDA0 and Vulkan0 alike.
# QWEN_TEST_STRICT_PLACEMENT_OWNER moves the weights to another owner, which is
# what lets the gate be shown to fire rather than merely to stay silent.
cat >"$build_directory/bin/llama-cli" <<'CLIENT'
#!/bin/sh
: >"${QWEN_TEST_STRICT_SMOKE_MARKER:?}"
device=CUDA0
previous_argument=''
for argument; do
    [ "$previous_argument" = --device ] && device=$argument
    previous_argument=$argument
done
printf 'load_tensors: %s model buffer size = 1205.21 MiB\n' \
    "${QWEN_TEST_STRICT_PLACEMENT_OWNER:-$device}"
printf 'fixture device output\n'
CLIENT
cat >"$build_directory/bin/llama-mtmd-cli" <<'MULTIMODAL'
#!/bin/sh
if [ "${1:-}" = --version ]; then
    printf 'version 0 (fixture)\n'
    exit 0
fi
printf 'red square and green circle\n'
MULTIMODAL
chmod +x "$build_directory/bin/llama-cli" \
    "$build_directory/bin/llama-mtmd-cli"
printf 'fixture backend\n' >"$build_directory/bin/libggml-cuda.so"

write_manifest() {
    {
        printf 'preset\t%s\n' "$preset"
        printf 'commit\t0000000000000000000000000000000000000000\n'
        printf 'worktree\tclean\n'
        for object_name in llama-server llama-cli llama-mtmd-cli \
            libggml-cuda.so; do
            object_path=$build_directory/bin/$object_name
            object_role=loadable
            case $object_name in llama-*) object_role=executable ;; esac
            printf '%s\t%s\t%s\t%s\n' "$object_role" "$object_name" \
                "$(stat -c %s "$object_path")" \
                "$(sha256sum "$object_path" | cut -d ' ' -f 1)"
        done
    } >"$build_directory/artifact-manifest.tsv"
}
write_manifest

promotion_model=$work_directory/text-model.gguf
vision_directory=$work_directory/vision-model
promotion_vision_model=$vision_directory/vision-model.gguf
promotion_projector=$vision_directory/mmproj-F16.gguf
promotion_image=$work_directory/shapes.png
strict_smoke_marker=$work_directory/strict-smoke-ran
mkdir -p "$vision_directory"
for smoke_input in "$promotion_model" "$promotion_vision_model" \
    "$promotion_projector" "$promotion_image"; do
    : >"$smoke_input"
done
export QWEN_PROMOTION_MODEL=$promotion_model
export QWEN_PROMOTION_VISION_MODEL=$promotion_vision_model
export QWEN_PROMOTION_IMAGE=$promotion_image
export QWEN_TEST_STRICT_SMOKE_MARKER=$strict_smoke_marker

set +e
promotion_output=$("$promoter" "$preset" "$work_directory" 2>&1)
promotion_status=$?
set -e
case $promotion_status:$promotion_output in
    0:*strict_cuda=passed*multimodal_cuda=passed*backend_set=cuda*)
        report clean_manifest_promotes accepted ;;
    *) report clean_manifest_promotes rejected
       printf '%s\n' "$promotion_output" >&2 ;;
esac

# A closure carrying libggml-vulkan.so enumerates Vulkan0 beside CUDA0 for the
# same card, and that enumeration is what once placed a router child on
# Vulkan0, so promotion refuses the dual-backend build ahead of every smoke.
printf 'fixture vulkan backend\n' >"$build_directory/bin/libggml-vulkan.so"
set +e
dual_output=$("$promoter" "$preset" "$work_directory" 2>&1)
dual_status=$?
set -e
rm -f "$build_directory/bin/libggml-vulkan.so"
case $dual_status:$dual_output in
    0:*) report dual_backend_build_refused rejected
         printf 'a dual-backend build promoted: %s\n' "$dual_output" >&2 ;;
    *:*carries\ libggml-vulkan.so*) report dual_backend_build_refused accepted ;;
    *) report dual_backend_build_refused rejected
       printf '%s\n' "$dual_output" >&2 ;;
esac

# Partial helper output carries no usable identity when closure enumeration
# fails. The promotion gate must preserve the helper status instead of letting
# the final pipeline command convert that failure into a successful subset.
failing_closure_tools=$work_directory/failing-closure-tools
mkdir -p "$failing_closure_tools"
cp "$promoter" "$failing_closure_tools/promote-llama-build.sh"
cat >"$failing_closure_tools/hash-load-closure.sh" <<'CLOSURE'
#!/bin/sh
printf 'role\tbasename\tbytes\tsha256\n'
printf 'executable\tllama-mtmd-cli\t1\tpartial\n'
exit 1
CLOSURE
chmod +x "$failing_closure_tools/hash-load-closure.sh"
set +e
closure_failure_output=$(
    "$failing_closure_tools/promote-llama-build.sh" \
        "$preset" "$work_directory" 2>&1
)
closure_failure_status=$?
set -e
case $closure_failure_status:$closure_failure_output in
    0:*) report closure_enumeration_failure_propagates rejected ;;
    *:*multimodal\ load-closure\ enumeration\ failed*)
        report closure_enumeration_failure_propagates accepted ;;
    *) report closure_enumeration_failure_propagates rejected
       printf '%s\n' "$closure_failure_output" >&2 ;;
esac

if [ "$(readlink "$work_directory/build-appliance-current")" = "$build_directory" ]; then
    report current_link_points_at_preset accepted
else
    report current_link_points_at_preset rejected
fi

# The placement gate is only evidence if it can fail. Moving the model buffer to
# another owner is the failure the gate exists to catch, and a run printing no
# loader line at all leaves placement unproven rather than proven.
QWEN_TEST_STRICT_PLACEMENT_OWNER=Vulkan_Host
export QWEN_TEST_STRICT_PLACEMENT_OWNER
set +e
misplaced_output=$("$promoter" "$preset" "$work_directory" 2>&1)
misplaced_status=$?
set -e
unset QWEN_TEST_STRICT_PLACEMENT_OWNER
case $misplaced_status:$misplaced_output in
    0:*) report strict_placement_gate_fires rejected ;;
    *:*placed\ weights\ off\ the\ device*)
        report strict_placement_gate_fires accepted ;;
    *) report strict_placement_gate_fires rejected
       printf '%s\n' "$misplaced_output" >&2 ;;
esac

# Both smoke stages are mandatory promotion evidence. The symlink retains its
# accepted target when either stage lacks the input needed to run.
QWEN_PROMOTION_MODEL=$work_directory/absent-text-model.gguf
export QWEN_PROMOTION_MODEL
set +e
strict_absent_output=$("$promoter" "$preset" "$work_directory" 2>&1)
strict_absent_status=$?
set -e
export QWEN_PROMOTION_MODEL=$promotion_model
case $strict_absent_status:$strict_absent_output in
    0:*) report strict_input_required rejected ;;
    *:*promotion\ model\ is\ absent*) report strict_input_required accepted ;;
    *) report strict_input_required rejected
       printf '%s\n' "$strict_absent_output" >&2 ;;
esac

QWEN_PROMOTION_IMAGE=$work_directory/absent-image.png
export QWEN_PROMOTION_IMAGE
rm -f "$strict_smoke_marker"
set +e
vision_absent_output=$("$promoter" "$preset" "$work_directory" 2>&1)
vision_absent_status=$?
set -e
export QWEN_PROMOTION_IMAGE=$promotion_image
case $vision_absent_status:$vision_absent_output in
    0:*) report multimodal_inputs_required rejected ;;
    *:*multimodal\ promotion\ inputs\ are\ incomplete*)
        if [ ! -e "$strict_smoke_marker" ]; then
            report multimodal_inputs_required accepted
        else
            report multimodal_inputs_required rejected
            printf 'strict smoke ran before multimodal input validation\n' >&2
        fi
        ;;
    *) report multimodal_inputs_required rejected
       printf '%s\n' "$vision_absent_output" >&2 ;;
esac

# A matching executable row binds llama-mtmd-cli to the build manifest. Merely
# leaving an executable with that name beside the build cannot satisfy it.
nice -n 19 sed '/^executable\tllama-mtmd-cli\t/d' \
    "$build_directory/artifact-manifest.tsv" \
    >"$build_directory/artifact-manifest.tsv.without-mtmd"
mv "$build_directory/artifact-manifest.tsv.without-mtmd" \
    "$build_directory/artifact-manifest.tsv"
set +e
unmanifested_output=$("$promoter" "$preset" "$work_directory" 2>&1)
unmanifested_status=$?
set -e
case $unmanifested_status:$unmanifested_output in
    0:*) report multimodal_manifest_identity_required rejected ;;
    *:*requires\ exactly\ one\ executable\ row\ for\ llama-mtmd-cli*)
        report multimodal_manifest_identity_required accepted ;;
    *) report multimodal_manifest_identity_required rejected
       printf '%s\n' "$unmanifested_output" >&2 ;;
esac
write_manifest

# One byte of drift in a backend object must stop the promotion.
printf 'fixture backend, rebuilt\n' >"$build_directory/bin/libggml-cuda.so"
set +e
drift_output=$("$promoter" "$preset" "$work_directory" 2>&1)
drift_status=$?
set -e
case $drift_status:$drift_output in
    0:*) report drift_rejected rejected
         printf 'a drifted object promoted: %s\n' "$drift_output" >&2 ;;
    *:*libggml-cuda.so\ changed*) report drift_rejected accepted ;;
    *) report drift_rejected rejected
       printf '%s\n' "$drift_output" >&2 ;;
esac
write_manifest

# A missing object is drift too, and it must not read as an empty check.
mv "$build_directory/bin/libggml-cuda.so" "$build_directory/bin/libggml-cuda.so.moved"
set +e
missing_output=$("$promoter" "$preset" "$work_directory" 2>&1)
missing_status=$?
set -e
case $missing_status:$missing_output in
    0:*) report missing_object_rejected rejected ;;
    *:*libggml-cuda.so\ missing*) report missing_object_rejected accepted ;;
    *) report missing_object_rejected rejected
       printf '%s\n' "$missing_output" >&2 ;;
esac
mv "$build_directory/bin/libggml-cuda.so.moved" "$build_directory/bin/libggml-cuda.so"

# A manifest whose object rows are absent must fail rather than pass an empty
# loop, which is the defect this suite exists for.
{
    printf 'preset\t%s\n' "$preset"
    printf 'commit\t0000000000000000000000000000000000000000\n'
} >"$build_directory/artifact-manifest.tsv"
set +e
empty_output=$("$promoter" "$preset" "$work_directory" 2>&1)
empty_status=$?
set -e
case $empty_status:$empty_output in
    0:*) report empty_manifest_rejected rejected ;;
    *:*names\ no\ executable*) report empty_manifest_rejected accepted ;;
    *) report empty_manifest_rejected rejected
       printf '%s\n' "$empty_output" >&2 ;;
esac
write_manifest

# A first promotion retains nothing, because there was no target before it, and
# saying so beats rolling back to a link that was never set.
set +e
"$promoter" --rollback "$work_directory" >/dev/null 2>&1
first_rollback_status=$?
set -e
if [ "$first_rollback_status" -eq 1 ]; then
    report rollback_without_retained_target_refused accepted
else
    report rollback_without_retained_target_refused rejected
fi

# A second preset makes the retained target distinct from the current one, which
# is the case rollback exists for.
second_preset=fixture-preset-second
second_build_directory=$work_directory/build-$second_preset
mkdir -p "$second_build_directory/bin"
cp "$build_directory/bin/llama-server" "$second_build_directory/bin/llama-server"
cp "$build_directory/bin/llama-cli" "$second_build_directory/bin/llama-cli"
cp "$build_directory/bin/llama-mtmd-cli" \
    "$second_build_directory/bin/llama-mtmd-cli"
printf 'fixture backend, second arm\n' >"$second_build_directory/bin/libggml-cuda.so"
{
    printf 'preset\t%s\n' "$second_preset"
    printf 'commit\t0000000000000000000000000000000000000000\n'
    printf 'worktree\tclean\n'
    for object_name in llama-server llama-cli llama-mtmd-cli \
        libggml-cuda.so; do
        object_path=$second_build_directory/bin/$object_name
        object_role=loadable
        case $object_name in llama-*) object_role=executable ;; esac
        printf '%s\t%s\t%s\t%s\n' "$object_role" "$object_name" \
            "$(stat -c %s "$object_path")" \
            "$(sha256sum "$object_path" | cut -d ' ' -f 1)"
    done
} >"$second_build_directory/artifact-manifest.tsv"

set +e
"$promoter" "$second_preset" "$work_directory" >/dev/null 2>&1
second_status=$?
set -e
if [ "$second_status" -eq 0 ] &&
   [ "$(readlink "$work_directory/build-appliance-current")" = "$second_build_directory" ]; then
    report second_promotion_switches accepted
else
    report second_promotion_switches rejected
fi

set +e
rollback_output=$("$promoter" --rollback "$work_directory" 2>&1)
rollback_status=$?
set -e
if [ "$rollback_status" -eq 0 ] &&
   [ "$(readlink "$work_directory/build-appliance-current")" = "$build_directory" ]; then
    report rollback_restores accepted
else
    report rollback_restores rejected
    printf '%s\n' "$rollback_output" >&2
fi

# A preset that produced llama-server and no llama-mtmd-cli must refuse
# promotion. The vision profile is served by the same tree, so a promotion that
# accepted the absence would move a build into service whose projector path this
# gate never exercised.
mv "$build_directory/bin/llama-mtmd-cli" "$build_directory/bin/llama-mtmd-cli.moved"
set +e
multimodal_absent_output=$("$promoter" "$preset" "$work_directory" 2>&1)
multimodal_absent_status=$?
set -e
mv "$build_directory/bin/llama-mtmd-cli.moved" "$build_directory/bin/llama-mtmd-cli"
case $multimodal_absent_status:$multimodal_absent_output in
    0:*) report multimodal_cli_required rejected ;;
    *:*no\ executable\ llama-mtmd-cli*) report multimodal_cli_required accepted ;;
    *) report multimodal_cli_required rejected
       printf '%s\n' "$multimodal_absent_output" >&2 ;;
esac

set +e
"$promoter" >/dev/null 2>&1
usage_status=$?
"$promoter" no-such-preset "$work_directory" >/dev/null 2>&1
absent_status=$?
set -e
[ "$usage_status" -eq 2 ] && report usage_exit accepted || report usage_exit rejected
[ "$absent_status" -eq 1 ] && report absent_preset accepted || report absent_preset rejected

if [ "$failures" -eq 0 ]; then
    printf 'promote_llama_build=accepted\n'
    exit 0
fi
printf 'promote_llama_build=rejected failures=%s\n' "$failures" >&2
exit 1
