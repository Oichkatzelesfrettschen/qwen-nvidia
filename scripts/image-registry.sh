#!/bin/sh
set -eu

# Read the image lane's four authorities: scripts/image-artifacts.tsv names the
# files a publisher offers, scripts/image-models.tsv binds a set of them into
# one loadable bundle, scripts/image-profiles.tsv serves a bundle at one
# placement arm and one bounded geometry, and scripts/image-quarantine.tsv
# removes a bundle or a shape from every generation path.
#
# Every query validates all four files whole and answers from the rows that
# validation returned, so a caller reading one profile cannot act on a ledger a
# sibling row has made unsafe to read, and a file replaced between validation
# and the answer cannot separate the two. That is the discipline
# model-registry.sh applies to the quarantine authority, and the reason is the
# same: these files decide what reaches the device.
#
# Ledger text never becomes shell source. AWK establishes the row shape, and
# the shell tests each retained evidence path as one quoted word with its
# pathname primitive, so quotes, semicolons, and command substitutions in a
# ledger stay outside executable input.

usage() {
    printf 'usage: %s artifacts | models | profiles\n' "$0" >&2
    printf '       %s bundle MODEL_ID\n' "$0" >&2
    printf '       %s profile PROFILE_ID [FIELD]\n' "$0" >&2
    printf 'artifacts, models, and profiles print the validated data rows verbatim.\n' >&2
    printf 'bundle prints one component line per resolved artifact:\n' >&2
    printf '  component_type artifact_id repository filename fetch_script\n' >&2
    printf 'profile prints the row as key=value lines, or one named field.\n' >&2
    printf 'fields: profile_id model_id placement width height steps sampler cfg\n' >&2
    printf '        max_steps max_dimension timeout_s execution_policy\n' >&2
    printf '        validated_evidence review_model\n' >&2
    exit 2
}

if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
    usage
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH='' cd -- "$script_directory/.." && pwd)
artifact_registry=${QWEN_IMAGE_ARTIFACTS:-$script_directory/image-artifacts.tsv}
model_registry=${QWEN_IMAGE_MODELS:-$script_directory/image-models.tsv}
profile_registry=${QWEN_IMAGE_PROFILES:-$script_directory/image-profiles.tsv}
quarantine_registry=${QWEN_IMAGE_QUARANTINE:-$script_directory/image-quarantine.tsv}

# A file is required readable and non-empty. AWK discriminates the four inputs
# by the order they are read, and a zero-length file is skipped entirely rather
# than opened, which would shift every later file into the wrong schema.
for image_registry_file in \
    "$artifact_registry" "$model_registry" \
    "$profile_registry" "$quarantine_registry"; do
    if [ ! -r "$image_registry_file" ]; then
        printf 'image registry is unreadable: %s\n' "$image_registry_file" >&2
        exit 1
    fi
    if [ ! -s "$image_registry_file" ]; then
        printf 'image registry is empty: %s\n' "$image_registry_file" >&2
        exit 1
    fi
done

validate_image_registries() {
    awk -F'\t' '
        function reject(message) {
            printf "%s\n", message > "/dev/stderr"
            bad++
        }
        function canonical_integer(value) {
            return value ~ /^[1-9][0-9]*$/
        }
        function identifier(value) {
            return value ~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/
        }
        function sampler(value) {
            return value ~ /^(euler|euler_a|heun|dpm2|dpm\+\+2s_a|dpm\+\+2m|dpm\+\+2mv2|ipndm|ipndm_v|lcm|ddim_trailing|tcd)$/
        }
        function component_slot(value, wanted, subject, slot,    ok) {
            # wanted is a pipe-separated alternation over component_type, so the
            # vae slot can name either a full vae decoder or a tae Tiny
            # AutoEncoder decoder without a second slot column: both reach the
            # runtime decode stage, and which flag carries the file is a
            # runtime-argv concern rather than a bundle-composition one.
            if (value == "packaged" || value == "-") { return 1 }
            if (!(value in artifact_type)) {
                reject(sprintf("%s: %s component %s names no artifact", \
                    subject, slot, value))
                return 0
            }
            if (artifact_type[value] !~ ("^(" wanted ")$")) {
                reject(sprintf("%s: %s component %s is component_type %s, expected %s", \
                    subject, slot, value, artifact_type[value], wanted))
                return 0
            }
            return 1
        }
        FNR == 1 { file_index++ }
        $0 ~ /^#/ || $0 ~ /^[[:space:]]*$/ { next }

        file_index == 1 {
            artifact_rows++
            if (NF != 9) {
                reject(sprintf("artifact row %d holds %d fields, expected 9", FNR, NF))
                next
            }
            if (!identifier($1)) {
                reject(sprintf("artifact row %d carries a malformed artifact_id: %s", FNR, $1))
                next
            }
            if (seen_artifact[$1]++) {
                reject(sprintf("duplicate artifact_id %s at row %d", $1, FNR))
            }
            if ($2 == "" || $2 == "-") {
                reject(sprintf("%s: repository is unnamed", $1))
            }
            if ($4 == "" || $4 == "-") {
                reject(sprintf("%s: filename is unnamed", $1))
            }
            # The pin is one claim in three fields. A digest without the
            # revision it was read at names no source, and a revision without a
            # digest verifies nothing, so the pin lane sets all three together.
            pinned = ($3 != "-") + ($5 != "-") + ($6 != "-")
            if (pinned != 0 && pinned != 3) {
                reject(sprintf("%s: revision, sha256, and bytes are a partial pin: %s %s %s", \
                    $1, $3, $5, $6))
            } else if (pinned == 3) {
                if ($5 !~ /^[0-9a-f]{64}$/) {
                    reject(sprintf("%s: sha256 is not 64 lowercase hex digits: %s", $1, $5))
                }
                if (!canonical_integer($6)) {
                    reject(sprintf("%s: bytes is not a canonical positive integer: %s", $1, $6))
                }
            }
            if ($7 == "" || $7 == "-") {
                reject(sprintf("%s: license is unnamed", $1))
            }
            if ($8 !~ /^(diffusion|vae|tae|text_encoder|lora|runtime)$/) {
                reject(sprintf("%s: component_type %s is outside the vocabulary", $1, $8))
            }
            if ($9 !~ /^(download|derive)-[a-z0-9][a-z0-9.-]*\.sh$/) {
                reject(sprintf("%s: fetch_script %s is not a download or derive script name", $1, $9))
            }
            artifact_type[$1] = $8
            output[++output_rows] = "artifact\t" $0
            next
        }

        file_index == 2 {
            model_rows++
            if (NF != 12) {
                reject(sprintf("model row %d holds %d fields, expected 12", FNR, NF))
                next
            }
            if (!identifier($1)) {
                reject(sprintf("model row %d carries a malformed model_id: %s", FNR, $1))
                next
            }
            if (seen_model[$1]++) {
                reject(sprintf("duplicate model_id %s at row %d", $1, FNR))
            }
            if ($2 !~ /^[a-z0-9][a-z0-9._-]*$/) {
                reject(sprintf("%s: architecture %s is malformed", $1, $2))
            }
            # The denoising trunk is the one component no checkpoint packages
            # inside another, so its slot always resolves to a file.
            if ($3 == "packaged" || $3 == "-") {
                reject(sprintf("%s: diffusion_artifact names no file: %s", $1, $3))
            } else {
                component_slot($3, "diffusion", $1, "diffusion")
            }
            component_slot($4, "vae|tae", $1, "vae")
            component_slot($5, "text_encoder", $1, "text_encoder")
            component_slot($6, "lora", $1, "lora")
            if ($6 == "packaged") {
                reject(sprintf("%s: lora_artifact reads packaged, which names no delta", $1))
            }
            if (!canonical_integer($7) || !canonical_integer($8)) {
                reject(sprintf("%s: native resolution %sx%s is not canonical positive integers", \
                    $1, $7, $8))
            }
            if (!canonical_integer($9)) {
                reject(sprintf("%s: default_steps %s is not a canonical positive integer", $1, $9))
            }
            if (!sampler($10)) {
                reject(sprintf("%s: default_sampler %s is outside the runtime vocabulary", $1, $10))
            }
            if ($11 !~ /^[0-9]+(\.[0-9]+)?$/) {
                reject(sprintf("%s: default_cfg %s is not a decimal number", $1, $11))
            }
            if ($12 !~ /^(production|candidate|quarantine|archive|rejected)$/) {
                reject(sprintf("%s: tier %s is outside the vocabulary", $1, $12))
            }
            model_vae[$1] = $4
            model_text_encoder[$1] = $5
            output[++output_rows] = "model\t" $0
            next
        }

        file_index == 3 {
            profile_rows++
            if (NF != 14) {
                reject(sprintf("profile row %d holds %d fields, expected 14", FNR, NF))
                next
            }
            if (!identifier($1)) {
                reject(sprintf("profile row %d carries a malformed profile_id: %s", FNR, $1))
                next
            }
            if (seen_profile[$1]++) {
                reject(sprintf("duplicate profile_id %s at row %d", $1, FNR))
            }
            if (!($2 in seen_model)) {
                reject(sprintf("%s: model_id %s is absent from the image model registry", $1, $2))
            }
            if ($3 !~ /^[ABC]$/) {
                reject(sprintf("%s: placement %s is not A, B, or C", $1, $3))
            }
            geometry_ok = 1
            split("width height steps", geometry_names, " ")
            for (field_index = 4; field_index <= 6; field_index++) {
                if (!canonical_integer($field_index)) {
                    reject(sprintf("%s: %s is not a canonical positive integer: %s", \
                        $1, geometry_names[field_index - 3], $field_index))
                    geometry_ok = 0
                }
            }
            split("max_steps max_dimension timeout_s", bound_names, " ")
            for (field_index = 9; field_index <= 11; field_index++) {
                if (!canonical_integer($field_index)) {
                    reject(sprintf("%s: %s is not a canonical positive integer: %s", \
                        $1, bound_names[field_index - 8], $field_index))
                    geometry_ok = 0
                }
            }
            # A profile admits what it requests. The bound is what an
            # authorization grant is checked against, so a request above it is
            # refused here rather than at the runtime argv.
            if (geometry_ok) {
                if ($4 + 0 > $10 + 0) {
                    reject(sprintf("%s: width %s exceeds max_dimension %s", $1, $4, $10))
                }
                if ($5 + 0 > $10 + 0) {
                    reject(sprintf("%s: height %s exceeds max_dimension %s", $1, $5, $10))
                }
                if ($6 + 0 > $9 + 0) {
                    reject(sprintf("%s: steps %s exceeds max_steps %s", $1, $6, $9))
                }
            }
            if (!sampler($7)) {
                reject(sprintf("%s: sampler %s is outside the runtime vocabulary", $1, $7))
            }
            if ($8 !~ /^[0-9]+(\.[0-9]+)?$/) {
                reject(sprintf("%s: cfg %s is not a decimal number", $1, $8))
            }
            # An arm places a component, so the bundle it serves names one. Arm
            # B moves the text encoder to the CPU and arm C moves the VAE with
            # it, and a bundle that omits either has no arm to place it on.
            if (($3 == "B" || $3 == "C") && model_text_encoder[$2] == "-") {
                reject(sprintf("%s: placement %s runs the text encoder on the CPU and %s names none", \
                    $1, $3, $2))
            }
            if ($3 == "C" && model_vae[$2] == "-") {
                reject(sprintf("%s: placement C runs the VAE on the CPU and %s names none", $1, $2))
            }
            if ($12 !~ /^(refused|validator-gated)$/) {
                reject(sprintf("%s: execution_policy %s is not refused or validator-gated", $1, $12))
            }
            if ($12 == "validator-gated" && $13 == "-") {
                reject(sprintf("%s: validator-gated carries no validated_evidence", $1))
            }
            # review_model pairs one vision checkpoint with this image shape, so
            # the reviewer travels with the profile that produced the artifact.
            # `-` states that the profile offers no review. A named value is a
            # scripts/models.tsv model_id, which the preset generator joins
            # against that registry and requires to carry a projector; this
            # ledger validates the spelling alone, because the language registry
            # is the authority for what the id means.
            if ($14 != "-" && !identifier($14)) {
                reject(sprintf("%s: review_model %s is not a model id", $1, $14))
            }
            output[++output_rows] = "profile\t" $0
            next
        }

        file_index == 4 {
            quarantine_rows++
            if (NF != 11) {
                reject(sprintf("quarantine row %d holds %d fields, expected 11", FNR, NF))
                next
            }
            if (!identifier($1)) {
                reject(sprintf("quarantine row %d carries a malformed id: %s", FNR, $1))
                next
            }
            if (seen_quarantine[$1]++) {
                reject(sprintf("duplicate quarantine id %s at row %d", $1, FNR))
            }
            if ($2 == "model") {
                if (!($3 in seen_model)) {
                    reject(sprintf("%s: model-scope subject %s is absent from the image model registry", \
                        $1, $3))
                }
                for (field_index = 5; field_index <= 8; field_index++) {
                    if ($field_index != "-") {
                        reject(sprintf("%s: model-scope row carries shape field %d: %s", \
                            $1, field_index, $field_index))
                    }
                }
            } else if ($2 == "profile") {
                if (!($3 in seen_profile)) {
                    reject(sprintf("%s: profile-scope subject %s is absent from the image profile registry", \
                        $1, $3))
                }
                for (field_index = 5; field_index <= 7; field_index++) {
                    if (!canonical_integer($field_index)) {
                        reject(sprintf("%s: shape field %d is not a canonical positive integer: %s", \
                            $1, field_index, $field_index))
                    }
                }
                if ($8 !~ /^[ABC]$/) {
                    reject(sprintf("%s: placement %s is not A, B, or C", $1, $8))
                }
            } else {
                reject(sprintf("%s: scope %s is not model or profile", $1, $2))
            }
            if ($4 !~ /^(ring-timeout-only|gfxhub-page-fault|vm-protection-fault|device-lost|post-reset-control-failure|no-validated-safe-tuple|runtime-timeout|output-validation-failure)$/) {
                reject(sprintf("%s: failure_class %s is outside the vocabulary", $1, $4))
            }
            if ($11 == "-" || $11 == "") {
                reject(sprintf("%s: quarantine carries no reason record", $1))
            }
            output[++output_rows] = "quarantine\t" $0
            next
        }

        END {
            if (file_index != 4) {
                printf "expected four image registry files, read %d\n", \
                    file_index > "/dev/stderr"
                bad++
            }
            if (!artifact_rows) { reject("the artifact registry holds no rows") }
            if (!model_rows) { reject("the image model registry holds no rows") }
            if (!profile_rows) { reject("the image profile registry holds no rows") }
            if (bad) { exit 1 }
            for (output_index = 1; output_index <= output_rows; output_index++) {
                print output[output_index]
            }
        }
    ' "$artifact_registry" "$model_registry" \
      "$profile_registry" "$quarantine_registry"
}

image_registry_rows=$(validate_image_registries) || exit 1

# A retained path is checked after AWK has established the row shape, so the
# path is one shell word and the pathname primitive is what tests it.
check_retained_path() {
    retained_subject=$1
    retained_field=$2
    retained_path=$3
    case $retained_path in
        - ) return 0 ;;
        '' | /* | ../* | */../* | */.. )
            printf '%s: %s is not a repository-relative path: %s\n' \
                "$retained_subject" "$retained_field" "$retained_path" >&2
            return 1
            ;;
    esac
    if [ ! -e "$repository_root/$retained_path" ]; then
        printf '%s: %s is absent from the tree: %s\n' \
            "$retained_subject" "$retained_field" "$retained_path" >&2
        return 1
    fi
    return 0
}

image_registry_tab=$(printf '\t')
retained_path_failures=0
while IFS="$image_registry_tab" read -r row_kind row_field_1 _row_field_2 \
    _row_field_3 _row_field_4 _row_field_5 _row_field_6 _row_field_7 \
    _row_field_8 row_field_9 row_field_10 row_field_11 _row_field_12 \
    row_field_13 _row_field_14; do
    case $row_kind in
        profile)
            check_retained_path "$row_field_1" validated_evidence \
                "$row_field_13" || retained_path_failures=$((retained_path_failures + 1))
            ;;
        quarantine)
            for retained_quarantine_field in first_evidence latest_evidence \
                reason_record; do
                case $retained_quarantine_field in
                    first_evidence) retained_quarantine_path=$row_field_9 ;;
                    latest_evidence) retained_quarantine_path=$row_field_10 ;;
                    *) retained_quarantine_path=$row_field_11 ;;
                esac
                check_retained_path "$row_field_1" \
                    "$retained_quarantine_field" "$retained_quarantine_path" ||
                    retained_path_failures=$((retained_path_failures + 1))
            done
            ;;
    esac
done <<EOF
$image_registry_rows
EOF
[ "$retained_path_failures" -eq 0 ] || exit 1

select_rows() {
    printf '%s\n' "$image_registry_rows" |
        awk -F'\t' -v kind="$1" '$1 == kind { sub(/^[^\t]*\t/, ""); print }'
}

case $1 in
    artifacts | models | profiles)
        [ "$#" -eq 1 ] || usage
        case $1 in
            artifacts) select_rows artifact ;;
            models) select_rows model ;;
            profiles) select_rows profile ;;
        esac
        exit 0
        ;;
    bundle)
        [ "$#" -eq 2 ] || usage
        bundle_model_id=$2
        # Resolve every component slot the bundle names against the artifact
        # rows validation returned. A `packaged` slot reports the diffusion
        # artifact that carries it, so a caller placing components on the CPU
        # reads which file supplies each one.
        printf '%s\n' "$image_registry_rows" |
            awk -F'\t' -v model_id="$bundle_model_id" '
                $1 == "artifact" {
                    repository[$2] = $3
                    filename[$2] = $5
                    fetch_script[$2] = $10
                    next
                }
                $1 == "model" && $2 == model_id {
                    matched = 1
                    diffusion = $4
                    split("diffusion vae text_encoder lora", slot_names, " ")
                    for (slot_index = 1; slot_index <= 4; slot_index++) {
                        slot_value = $(slot_index + 3)
                        if (slot_value == "-") { continue }
                        resolved = (slot_value == "packaged") ? diffusion : slot_value
                        printf "%s\t%s\t%s\t%s\t%s\n", slot_names[slot_index], \
                            resolved, repository[resolved], filename[resolved], \
                            fetch_script[resolved]
                    }
                }
                END { exit matched ? 0 : 1 }
            ' || {
                printf 'no image model row matches %s\n' "$bundle_model_id" >&2
                exit 1
            }
        exit 0
        ;;
    profile)
        [ "$#" -eq 2 ] || [ "$#" -eq 3 ] || usage
        profile_selector=$2
        profile_field=${3:-}
        set +e
        printf '%s\n' "$image_registry_rows" |
            awk -F'\t' -v selector="$profile_selector" -v field="$profile_field" '
                $1 == "profile" && $2 == selector {
                    split("profile_id model_id placement width height steps " \
                          "sampler cfg max_steps max_dimension timeout_s " \
                          "execution_policy validated_evidence review_model", \
                          names, " ")
                    matched = 1
                    for (name_index = 1; name_index <= 14; name_index++) {
                        if (field == "") {
                            printf "%s=%s\n", names[name_index], $(name_index + 1)
                        } else if (names[name_index] == field) {
                            printf "%s\n", $(name_index + 1)
                            found = 1
                        }
                    }
                }
                END {
                    if (!matched) { exit 1 }
                    if (field != "" && !found) { exit 3 }
                }
            '
        profile_query_status=$?
        set -e
        if [ "$profile_query_status" -eq 1 ]; then
            printf 'no image profile row matches %s\n' "$profile_selector" >&2
        elif [ "$profile_query_status" -eq 3 ]; then
            printf 'no such profile field: %s\n' "$profile_field" >&2
        fi
        exit "$profile_query_status"
        ;;
    *)
        usage
        ;;
esac
