#!/bin/sh
set -eu

# The image registries decide which bytes reach the device and which shape a
# generation may take, so a malformed row reaches the appliance either as a
# failed launch or as an admitted request the machine cannot bound. These
# checks read the seeded files whole and then drive each refusal against a
# temporary copy, because a gate that only ever sees correct rows passes on
# their correctness rather than on its own.

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
reader=$script_directory/image-registry.sh
failures=0
work_directory=$(mktemp -d)
trap 'rm -rf "$work_directory"' EXIT INT TERM

report() {
    printf '%s=%s\n' "$1" "$2"
    [ "$2" = accepted ] || failures=$((failures + 1))
}

# Every refusal case starts from a fresh copy of the four seeded files, so one
# mutation is the single changed dimension of the run that follows.
seed_copies() {
    cp "$script_directory/image-artifacts.tsv" "$work_directory/artifacts.tsv"
    cp "$script_directory/image-models.tsv" "$work_directory/models.tsv"
    cp "$script_directory/image-profiles.tsv" "$work_directory/profiles.tsv"
    cp "$script_directory/image-quarantine.tsv" "$work_directory/quarantine.tsv"
}

run_reader() {
    set +e
    QWEN_IMAGE_ARTIFACTS=$work_directory/artifacts.tsv \
    QWEN_IMAGE_MODELS=$work_directory/models.tsv \
    QWEN_IMAGE_PROFILES=$work_directory/profiles.tsv \
    QWEN_IMAGE_QUARANTINE=$work_directory/quarantine.tsv \
        "$reader" "$@" >"$work_directory/reader.out" 2>"$work_directory/reader.err"
    reader_status=$?
    set -e
}

# A refusal is a nonzero exit with the copies in place. The query is `profiles`
# in every case, because validation covers all four files before any query
# answers and a mutation anywhere must stop the same read.
expect_refusal() {
    refusal_label=$1
    run_reader profiles
    if [ "$reader_status" -ne 0 ]; then
        report "$refusal_label" accepted
    else
        report "$refusal_label" rejected
        printf '%s: the reader answered a mutated ledger\n' "$refusal_label" >&2
    fi
}

expect_acceptance() {
    acceptance_label=$1
    run_reader profiles
    if [ "$reader_status" -eq 0 ]; then
        report "$acceptance_label" accepted
    else
        report "$acceptance_label" rejected
        cat "$work_directory/reader.err" >&2
    fi
}

append_row() {
    append_target=$1
    shift
    printf '%b\n' "$1" >>"$append_target"
}

# The seeded files answer every query, which is the control each refusal below
# is read against.
seed_copies
expect_acceptance seeded_ledger

run_reader artifacts
if [ "$reader_status" -eq 0 ] &&
   [ "$(wc -l <"$work_directory/reader.out")" -eq 7 ]; then
    report artifact_listing accepted
else
    report artifact_listing rejected
fi

run_reader models
if [ "$reader_status" -eq 0 ] &&
   [ "$(wc -l <"$work_directory/reader.out")" -eq 4 ]; then
    report model_listing accepted
else
    report model_listing rejected
fi

# A bundle resolves every component slot it names. sd15-lcm-v1 is the row that
# exercises all three tokens at once: a separate VAE, a packaged text encoder
# reported against the diffusion artifact that carries it, and a LoRA.
run_reader bundle sd15-lcm-v1
bundle_expected=$(printf '%s\n' \
    'diffusion	sd15-diffusion	stable-diffusion-v1-5/stable-diffusion-v1-5	v1-5-pruned-emaonly.safetensors	download-sd15-base.sh' \
    'vae	sd15-vae-ft-mse	stabilityai/sd-vae-ft-mse-original	vae-ft-mse-840000-ema-pruned.safetensors	download-sd15-vae.sh' \
    'text_encoder	sd15-diffusion	stable-diffusion-v1-5/stable-diffusion-v1-5	v1-5-pruned-emaonly.safetensors	download-sd15-base.sh' \
    'lora	sd15-lcm-lora	latent-consistency/lcm-lora-sdv1-5	pytorch_lora_weights.safetensors	download-lcm-lora-sd15.sh')
if [ "$reader_status" -eq 0 ] &&
   [ "$(cat "$work_directory/reader.out")" = "$bundle_expected" ]; then
    report bundle_resolution accepted
else
    report bundle_resolution rejected
    cat "$work_directory/reader.out" >&2
fi

# A bundle that omits a component reports the slots it names and stays silent
# about the one it does not, so a caller reads composition rather than a fixed
# four-line shape.
run_reader bundle sd15-base
if [ "$reader_status" -eq 0 ] &&
   [ "$(wc -l <"$work_directory/reader.out")" -eq 3 ]; then
    report bundle_omitted_component accepted
else
    report bundle_omitted_component rejected
fi

run_reader profile image-sdxs-512-b placement
if [ "$reader_status" -eq 0 ] && [ "$(cat "$work_directory/reader.out")" = B ]; then
    report profile_field accepted
else
    report profile_field rejected
fi

run_reader profile image-sdxs-512-a
if [ "$reader_status" -eq 0 ] &&
   [ "$(wc -l <"$work_directory/reader.out")" -eq 14 ]; then
    report profile_row accepted
else
    report profile_row rejected
fi

# An absent row and an absent field carry different exit codes for the reason
# model-registry.sh separates them: a caller that asked for the wrong field of a
# real row and a caller that asked about a row nothing holds need different
# repairs.
run_reader profile no-such-profile
if [ "$reader_status" -eq 1 ]; then
    report absent_profile accepted
else
    report absent_profile rejected
fi

run_reader profile image-sdxs-512-a no-such-field
if [ "$reader_status" -eq 3 ]; then
    report absent_field accepted
else
    report absent_field rejected
fi

run_reader bundle no-such-model
if [ "$reader_status" -eq 1 ]; then
    report absent_bundle accepted
else
    report absent_bundle rejected
fi

set +e
"$reader" >/dev/null 2>&1
usage_status=$?
"$reader" no-such-query >/dev/null 2>&1
unknown_query_status=$?
set -e
if [ "$usage_status" -eq 2 ] && [ "$unknown_query_status" -eq 2 ]; then
    report usage_exit accepted
else
    report usage_exit rejected
fi

# An unreadable or empty authority stops the query rather than reading as an
# empty set, which would admit every row the missing file excludes.
seed_copies
rm -f "$work_directory/quarantine.tsv"
expect_refusal absent_quarantine_authority

seed_copies
: >"$work_directory/quarantine.tsv"
expect_refusal empty_quarantine_authority

# Column count. A row short one field shifts every later value into the wrong
# column, so the shape is checked before any value is read.
seed_copies
append_row "$work_directory/artifacts.tsv" \
    'short-row\thf/repo\t-\tfile.safetensors\t-\t-\tmit\tdiffusion'
expect_refusal artifact_field_count

seed_copies
append_row "$work_directory/models.tsv" \
    'short-model\tsd1.x\tsd15-diffusion\tpackaged\tpackaged\t-\t512\t512\t4\tlcm\t1.5'
expect_refusal model_field_count

seed_copies
append_row "$work_directory/profiles.tsv" \
    'short-profile\tsd15-base\tA\t512\t512\t4\teuler\t7.0\t8\t512\t300\trefused'
expect_refusal profile_field_count

seed_copies
append_row "$work_directory/quarantine.tsv" \
    'short-quarantine\tmodel\tsd15-base\tdevice-lost\t-\t-\t-\t-\t-\t-'
expect_refusal quarantine_field_count

# Duplicate ids. The runtime keys on the id string, so two rows sharing one id
# make which row was acted on unreadable.
seed_copies
append_row "$work_directory/artifacts.tsv" \
    'sd15-diffusion\thf/other\t-\tother.safetensors\t-\t-\tmit\tdiffusion\tdownload-other.sh'
expect_refusal duplicate_artifact_id

seed_copies
append_row "$work_directory/profiles.tsv" \
    'image-sd15-base-a\tsd15-base\tA\t512\t512\t20\teuler_a\t7.0\t30\t512\t300\trefused\t-'
expect_refusal duplicate_profile_id

# Canonical integers. The service builds exact string keys from these fields, so
# a leading zero or a unit suffix is a different key for the same shape.
seed_copies
append_row "$work_directory/profiles.tsv" \
    'leading-zero\tsd15-base\tA\t0512\t512\t20\teuler_a\t7.0\t30\t512\t300\trefused\t-'
expect_refusal profile_noncanonical_integer

seed_copies
append_row "$work_directory/models.tsv" \
    'zero-steps\tsd1.x\tsd15-diffusion\tpackaged\tpackaged\t-\t512\t512\t0\tlcm\t1.5\tcandidate'
expect_refusal model_noncanonical_integer

# The pin is one claim in three fields, so a digest without its revision and
# byte count is refused rather than half trusted.
seed_copies
append_row "$work_directory/artifacts.tsv" \
    'partial-pin\thf/repo\t-\tfile.safetensors\t0000000000000000000000000000000000000000000000000000000000000000\t-\tmit\tdiffusion\tdownload-partial.sh'
expect_refusal artifact_partial_pin

# Bundle resolution. A component that names no artifact and a component of the
# wrong type are two different mistakes and both stop the read: the second is
# the one a loader would otherwise accept, since a VAE file loads cleanly in a
# slot that expects one.
seed_copies
append_row "$work_directory/models.tsv" \
    'absent-component\tsd1.x\tno-such-artifact\tpackaged\tpackaged\t-\t512\t512\t4\tlcm\t1.5\tcandidate'
expect_refusal bundle_component_absent

seed_copies
append_row "$work_directory/models.tsv" \
    'wrong-type\tsd1.x\tsd15-vae-ft-mse\tpackaged\tpackaged\t-\t512\t512\t4\tlcm\t1.5\tcandidate'
expect_refusal bundle_component_wrong_type

seed_copies
append_row "$work_directory/models.tsv" \
    'lora-in-vae-slot\tsd1.x\tsd15-diffusion\tsd15-lcm-lora\tpackaged\t-\t512\t512\t4\tlcm\t1.5\tcandidate'
expect_refusal bundle_vae_slot_wrong_type

seed_copies
append_row "$work_directory/profiles.tsv" \
    'orphan-profile\tno-such-model\tA\t512\t512\t4\tlcm\t1.5\t8\t512\t300\trefused\t-'
expect_refusal profile_model_absent

# The bounds admit the request. A profile above its own ceiling would hand an
# authorization grant a shape the ledger denies.
seed_copies
append_row "$work_directory/profiles.tsv" \
    'over-dimension\tsd15-base\tA\t768\t512\t20\teuler_a\t7.0\t30\t512\t300\trefused\t-'
expect_refusal profile_width_over_max_dimension

seed_copies
append_row "$work_directory/profiles.tsv" \
    'over-height\tsd15-base\tA\t512\t768\t20\teuler_a\t7.0\t30\t512\t300\trefused\t-'
expect_refusal profile_height_over_max_dimension

seed_copies
append_row "$work_directory/profiles.tsv" \
    'over-steps\tsd15-base\tA\t512\t512\t40\teuler_a\t7.0\t30\t512\t300\trefused\t-'
expect_refusal profile_steps_over_max_steps

# The placement vocabulary is closed, so a fourth arm cannot enter by typo.
seed_copies
append_row "$work_directory/profiles.tsv" \
    'bad-arm\tsd15-base\tD\t512\t512\t20\teuler_a\t7.0\t30\t512\t300\trefused\t-'
expect_refusal profile_placement_arm

# An arm places a component the bundle must name. A bundle omitting its text
# encoder has no arm B, and one omitting its VAE has no arm C.
seed_copies
append_row "$work_directory/models.tsv" \
    'no-text-encoder\tsd1.x\tsd15-diffusion\tpackaged\t-\t-\t512\t512\t4\tlcm\t1.5\tcandidate'
append_row "$work_directory/profiles.tsv" \
    'arm-b-no-encoder\tno-text-encoder\tB\t512\t512\t4\tlcm\t1.5\t8\t512\t300\trefused\t-\t-'
expect_refusal placement_b_requires_text_encoder

seed_copies
append_row "$work_directory/models.tsv" \
    'no-vae\tsd1.x\tsd15-diffusion\t-\tpackaged\t-\t512\t512\t4\tlcm\t1.5\tcandidate'
append_row "$work_directory/profiles.tsv" \
    'arm-c-no-vae\tno-vae\tC\t512\t512\t4\tlcm\t1.5\t8\t512\t300\trefused\t-\t-'
expect_refusal placement_c_requires_vae

# The same bundle at arm A is admitted, so the two refusals above are the arm's
# requirement rather than the bundle's composition.
seed_copies
append_row "$work_directory/models.tsv" \
    'no-vae\tsd1.x\tsd15-diffusion\t-\tpackaged\t-\t512\t512\t4\tlcm\t1.5\tcandidate'
append_row "$work_directory/profiles.tsv" \
    'arm-a-no-vae\tno-vae\tA\t512\t512\t4\tlcm\t1.5\t8\t512\t300\trefused\t-\t-'
expect_acceptance placement_a_admits_omitted_vae

seed_copies
append_row "$work_directory/profiles.tsv" \
    'bad-policy\tsd15-base\tA\t512\t512\t20\teuler_a\t7.0\t30\t512\t300\tunguarded\t-\t-'
expect_refusal profile_execution_policy

seed_copies
append_row "$work_directory/models.tsv" \
    'bad-tier\tsd1.x\tsd15-diffusion\tpackaged\tpackaged\t-\t512\t512\t4\tlcm\t1.5\tpromoted'
expect_refusal model_tier_vocabulary

seed_copies
append_row "$work_directory/profiles.tsv" \
    'bad-sampler\tsd15-base\tA\t512\t512\t20\tkarras_magic\t7.0\t30\t512\t300\trefused\t-'
expect_refusal profile_sampler_vocabulary

seed_copies
append_row "$work_directory/artifacts.tsv" \
    'bad-component\thf/repo\t-\tfile.safetensors\t-\t-\tmit\tcontrolnet\tdownload-bad.sh'
expect_refusal artifact_component_type_vocabulary

seed_copies
append_row "$work_directory/artifacts.tsv" \
    'bad-fetch\thf/repo\t-\tfile.safetensors\t-\t-\tmit\tdiffusion\tfetch_it_somehow'
expect_refusal artifact_fetch_script_name

# tae joins the component_type vocabulary as a second decoder shape: a Tiny
# AutoEncoder reaches sd-cli through --taesd rather than through the vae/
# directory slot a full vae uses, and the vae_artifact column accepts either.
seed_copies
append_row "$work_directory/artifacts.tsv" \
    'standalone-tae\thf/repo\t-\ttae.safetensors\t-\t-\tmit\ttae\tdownload-standalone-tae.sh'
expect_acceptance artifact_component_type_tae

# The seeded sdxs-512 row already resolves its vae_artifact to a tae artifact
# (sdxs-512-vae), so the bundle query is the acceptance proof: a vae slot
# naming a tae component is admitted rather than refused as a type mismatch.
seed_copies
run_reader bundle sdxs-512
if [ "$reader_status" -eq 0 ] &&
   printf '%s\n' "$(cat "$work_directory/reader.out")" | grep -q '^vae	sdxs-512-vae	'; then
    report bundle_vae_slot_resolves_tae accepted
else
    report bundle_vae_slot_resolves_tae rejected
    cat "$work_directory/reader.out" >&2
fi

# A tae component stays confined to the vae slot: naming one in the lora slot
# is still the wrong-type mistake component_slot exists to catch.
seed_copies
append_row "$work_directory/artifacts.tsv" \
    'standalone-tae\thf/repo\t-\ttae.safetensors\t-\t-\tmit\ttae\tdownload-standalone-tae.sh'
append_row "$work_directory/models.tsv" \
    'tae-in-lora-slot\tsd1.x\tsd15-diffusion\tpackaged\tpackaged\tstandalone-tae\t512\t512\t4\tlcm\t1.5\tcandidate'
expect_refusal bundle_lora_slot_rejects_tae

# Every checked-in row reads refused, so an unconditionally refusing gate would
# pass the suite above. These two rows carry the promotion the gate exists for:
# a validator-gated profile naming a record that exists is admitted, and the
# same row naming an absent record is refused.
seed_copies
append_row "$work_directory/profiles.tsv" \
    'gated-present\tsd15-base\tA\t512\t512\t20\teuler_a\t7.0\t30\t512\t300\tvalidator-gated\tevidence/image-appliance/design.md\t-'
expect_acceptance validator_gated_with_evidence

seed_copies
append_row "$work_directory/profiles.tsv" \
    'gated-absent\tsd15-base\tA\t512\t512\t20\teuler_a\t7.0\t30\t512\t300\tvalidator-gated\tevidence/image-appliance/no-such-record.md\t-'
expect_refusal validator_gated_evidence_absent

seed_copies
append_row "$work_directory/profiles.tsv" \
    'gated-unrecorded\tsd15-base\tA\t512\t512\t20\teuler_a\t7.0\t30\t512\t300\tvalidator-gated\t-'
expect_refusal validator_gated_without_evidence

# A path that escapes the tree is refused before the pathname test runs, so
# ledger text reaches no traversal.
seed_copies
append_row "$work_directory/profiles.tsv" \
    'escaping-evidence\tsd15-base\tA\t512\t512\t20\teuler_a\t7.0\t30\t512\t300\trefused\t../etc/passwd'
expect_refusal profile_evidence_escapes_tree

# Quarantine. A row that names a subject nothing holds, a model-scope row
# carrying a shape, and a reason record absent from the tree are each an
# exclusion no reader can act on.
seed_copies
append_row "$work_directory/quarantine.tsv" \
    'valid-model-row\tmodel\tsd15-base\tdevice-lost\t-\t-\t-\t-\tevidence/image-appliance/design.md\tevidence/image-appliance/design.md\tevidence/image-appliance/design.md'
expect_acceptance quarantine_model_row

seed_copies
append_row "$work_directory/quarantine.tsv" \
    'valid-profile-row\tprofile\timage-sd15-base-a\tring-timeout-only\t512\t512\t20\tA\t-\t-\tevidence/image-appliance/design.md'
expect_acceptance quarantine_profile_row

seed_copies
append_row "$work_directory/quarantine.tsv" \
    'absent-subject\tmodel\tno-such-model\tdevice-lost\t-\t-\t-\t-\t-\t-\tevidence/image-appliance/design.md'
expect_refusal quarantine_subject_absent

seed_copies
append_row "$work_directory/quarantine.tsv" \
    'absent-profile-subject\tprofile\tno-such-profile\tring-timeout-only\t512\t512\t20\tA\t-\t-\tevidence/image-appliance/design.md'
expect_refusal quarantine_profile_subject_absent

seed_copies
append_row "$work_directory/quarantine.tsv" \
    'scoped-shape\tmodel\tsd15-base\tdevice-lost\t512\t512\t20\tA\t-\t-\tevidence/image-appliance/design.md'
expect_refusal quarantine_model_scope_carries_shape

seed_copies
append_row "$work_directory/quarantine.tsv" \
    'bad-scope\tbundle\tsd15-base\tdevice-lost\t-\t-\t-\t-\t-\t-\tevidence/image-appliance/design.md'
expect_refusal quarantine_scope_vocabulary

seed_copies
append_row "$work_directory/quarantine.tsv" \
    'bad-failure-class\tmodel\tsd15-base\tit-broke\t-\t-\t-\t-\t-\t-\tevidence/image-appliance/design.md'
expect_refusal quarantine_failure_class_vocabulary

seed_copies
append_row "$work_directory/quarantine.tsv" \
    'absent-record\tmodel\tsd15-base\tdevice-lost\t-\t-\t-\t-\t-\t-\tevidence/image-appliance/no-such-record.md'
expect_refusal quarantine_reason_record_absent

seed_copies
append_row "$work_directory/quarantine.tsv" \
    'unrecorded\tmodel\tsd15-base\tdevice-lost\t-\t-\t-\t-\t-\t-\t-'
expect_refusal quarantine_without_reason_record

# The seeded files themselves meet every rule, read through the reader's own
# defaults rather than through the copies.
set +e
"$reader" profiles >/dev/null 2>"$work_directory/seeded.err"
seeded_status=$?
set -e
if [ "$seeded_status" -eq 0 ]; then
    report seeded_files_default_paths accepted
else
    report seeded_files_default_paths rejected
    cat "$work_directory/seeded.err" >&2
fi

# One checked-in profile emits and the rest admit a shape alone. A section
# carries one `mcpServers` object, so remote/build-web-presets.sh refuses two
# emitting rows; the ledger states that bound directly by holding exactly one
# validator-gated row, and every other row reads refused. Every checked-in
# bundle reads candidate.
checked_in_gated=$("$reader" profiles | awk -F'\t' '$12 == "validator-gated" { print $1 }')
checked_in_other=$("$reader" profiles |
    awk -F'\t' '$12 != "validator-gated" && $12 != "refused"')
if [ "$checked_in_gated" = image-sdxs-512-a ] && [ -z "$checked_in_other" ]; then
    report one_profile_validator_gated accepted
else
    report one_profile_validator_gated rejected
    printf 'validator-gated rows: %s\n' "${checked_in_gated:-<none>}" >&2
fi
if [ -z "$("$reader" models | awk -F'\t' '$12 != "candidate"')" ]; then
    report every_model_candidate accepted
else
    report every_model_candidate rejected
fi

# Each schema header states the column order the reader indexes by, so a header
# that drifts from the reader is the drift a reader cannot detect for itself.
check_header() {
    header_file=$1
    header_expected=$2
    header_actual=$(grep '^# ' "$header_file" | tail -n 1)
    if [ "$header_actual" = "$header_expected" ]; then
        report "$3" accepted
    else
        report "$3" rejected
        printf 'header differs:\n  %s\n  %s\n' "$header_actual" "$header_expected" >&2
    fi
}
# review_model names the vision checkpoint that reviews what a profile
# generates. This ledger validates the spelling and remote/models.tsv is the
# authority for what the id means, so a well-formed id is admitted here whether
# or not this machine holds its weights, and a path or an empty field is not.
seed_copies
append_row "$work_directory/profiles.tsv" \
    'review-named\tsd15-base\tA\t512\t512\t20\teuler_a\t7.0\t30\t512\t300\trefused\t-\tlfm25-vl-16b'
expect_acceptance review_model_named

seed_copies
append_row "$work_directory/profiles.tsv" \
    'review-path\tsd15-base\tA\t512\t512\t20\teuler_a\t7.0\t30\t512\t300\trefused\t-\t../lfm25-vl-16b'
expect_refusal review_model_malformed

# A row spelling thirteen fields predates the column, and the reader would take
# validated_evidence for a reviewer if a short row were admitted.
seed_copies
append_row "$work_directory/profiles.tsv" \
    'review-absent-column\tsd15-base\tA\t512\t512\t20\teuler_a\t7.0\t30\t512\t300\trefused\t-'
expect_refusal review_model_column_required

check_header "$script_directory/image-artifacts.tsv" \
    "$(printf '# artifact_id\trepository\trevision\tfilename\tsha256\tbytes\tlicense\tcomponent_type\tfetch_script')" \
    artifact_schema_header
check_header "$script_directory/image-models.tsv" \
    "$(printf '# model_id\tarchitecture\tdiffusion_artifact\tvae_artifact\ttext_encoder_artifact\tlora_artifact\tnative_width\tnative_height\tdefault_steps\tdefault_sampler\tdefault_cfg\ttier')" \
    model_schema_header
check_header "$script_directory/image-profiles.tsv" \
    "$(printf '# profile_id\tmodel_id\tplacement\twidth\theight\tsteps\tsampler\tcfg\tmax_steps\tmax_dimension\ttimeout_s\texecution_policy\tvalidated_evidence\treview_model')" \
    profile_schema_header
check_header "$script_directory/image-quarantine.tsv" \
    "$(printf '# id\tscope\tsubject\tfailure_class\twidth\theight\tsteps\tplacement\tfirst_evidence\tlatest_evidence\treason_record')" \
    quarantine_schema_header

if [ "$failures" -eq 0 ]; then
    printf 'image_registry_checks=accepted\n'
    exit 0
fi
printf 'image_registry_checks=rejected failures=%d\n' "$failures" >&2
exit 1
