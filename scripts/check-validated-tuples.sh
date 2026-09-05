#!/bin/sh
set -eu

# Every models.tsv row that claims a numeric validated_filled_depth must own a
# validated row in scripts/validated-tuples.tsv naming the same model, depth,
# geometry, cache policy, and projector state, measured on the backend this
# host serves. A depth filled on one backend states nothing about another: the
# graph, the flash-attention kernels, and the allocator all differ, so a
# Vulkan row measured on the prior host is history rather than validation for
# a CUDA claim. QWEN_SERVING_BACKEND names which rows may validate one and
# takes cuda alone, the backend this host serves; rows carrying another
# backend stay in the ledger as history and validate nothing. models.tsv holds one
# validated_filled_depth tuple per row and the ledger holds every measured arm,
# so the cross-ledger check derives the complete tuple models.tsv already
# claims and requires the ledger to carry the same tuple.

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
model_registry=${QWEN_MODEL_REGISTRY:-$script_directory/models.tsv}
tuple_ledger=${QWEN_VALIDATED_TUPLES:-$script_directory/validated-tuples.tsv}
serving_backend=${QWEN_SERVING_BACKEND:-cuda}

case $serving_backend in
    cuda) ;;
    *)
        printf 'QWEN_SERVING_BACKEND takes cuda: %s\n' "$serving_backend" >&2
        exit 2
        ;;
esac

if [ ! -r "$model_registry" ]; then
    printf 'model registry is unreadable: %s\n' "$model_registry" >&2
    exit 1
fi
if [ ! -r "$tuple_ledger" ]; then
    printf 'validated tuple ledger is unreadable: %s\n' "$tuple_ledger" >&2
    exit 1
fi

awk -F'\t' -v serving_backend="$serving_backend" '
    FILENAME == ARGV[1] {
        if ($0 ~ /^#/ || $0 ~ /^[[:space:]]*$/) { next }
        tuple_rows++
        if (NF != 21) {
            printf "validated tuple row %d holds %d fields, expected 21\n", \
                FNR, NF > "/dev/stderr"
            malformed++
            next
        }
        if ($1 == "" || $2 == "") {
            printf "validated tuple row %d requires tuple_id and model_id\n", \
                FNR > "/dev/stderr"
            malformed++
        }
        for (field_index = 4; field_index <= 6; field_index++) {
            if ($field_index !~ /^[1-9][0-9]*$/) {
                printf "%s: tuple geometry field %d is not a canonical positive integer: %s\n", \
                    $1, field_index, $field_index > "/dev/stderr"
                malformed++
            }
        }
        if ($7 !~ /^(f32|f16|bf16|q8_0|q5_1|q5_0|q4_1|q4_0|iq4_nl)$/ ||
            $8 !~ /^(f32|f16|bf16|q8_0|q5_1|q5_0|q4_1|q4_0|iq4_nl)$/) {
            printf "%s: tuple carries an invalid cache type\n", $1 > "/dev/stderr"
            malformed++
        }
        if ($9 !~ /^(on|off|auto)$/ || $10 !~ /^[1-9][0-9]*$/ ||
            $11 !~ /^[1-9][0-9]*$/ || $12 !~ /^(none|loaded)$/ ||
            $13 !~ /^(cuda|vulkan|cpu|hip)$/ ||
            $14 !~ /^(validated|failed|unverified)$/) {
            printf "%s: tuple carries an invalid policy or status field\n", \
                $1 > "/dev/stderr"
            malformed++
        }
        if ($6 ~ /^[1-9][0-9]*$/ && $5 ~ /^[1-9][0-9]*$/ &&
            $6 + 0 > $5 + 0) {
            printf "%s: tuple ubatch %s exceeds batch %s\n", \
                $1, $6, $5 > "/dev/stderr"
            malformed++
        }
        if ($14 == "validated" && $15 == "-") {
            printf "%s: validated tuple carries no evidence path\n", \
                $1 > "/dev/stderr"
            malformed++
        }
        if ($14 != "validated" || $13 != serving_backend) { next }
        # model_id, context, batch, ubatch, cache_k, cache_v, flash_attention,
        # projector_state
        key = $2 SUBSEP $4 SUBSEP $5 SUBSEP $6 SUBSEP $7 SUBSEP $8 SUBSEP \
            $9 SUBSEP $12
        validated_tuples[key] = 1
        next
    }
    # The column-header comment in the registry states the field count, so a
    # column added there does not make every row read as malformed here. A
    # second header redefines the count for every row below it and a trailing
    # tab inflates it by an empty field, so both are refused at the header.
    $0 ~ /^#[[:space:]]*id\t/ {
        if (model_field_count) {
            printf "the model registry states a second column header at row %d\n", \
                FNR > "/dev/stderr"
            malformed++
            next
        }
        if ($NF == "") {
            printf "the model registry column header ends on an empty field\n" \
                > "/dev/stderr"
            malformed++
            next
        }
        model_field_count = NF - 0
        next
    }
    $0 ~ /^#/ || $0 ~ /^[[:space:]]*$/ { next }
    {
        model_rows++
        if (!model_field_count) {
            printf "the model registry states no column header\n" > "/dev/stderr"
            malformed++
            next
        }
        if (NF != model_field_count) {
            printf "model row %d holds %d fields, expected %d\n", \
                FNR, NF, model_field_count > "/dev/stderr"
            malformed++
            next
        }
        # id, context_default..., batch, ubatch, validated_filled_depth,
        # validation_evidence, cache_type_k, cache_type_v, flash_attention.
        if ($19 == "-") { next }
        if ($19 !~ /^[1-9][0-9]*$/) {
            printf "%s: validated_filled_depth is malformed: %s\n", \
                $1, $19 > "/dev/stderr"
            malformed++
            next
        }
        expected_projector_state = ($11 == "required" ? "loaded" : "none")
        checked++
        key = $1 SUBSEP $19 SUBSEP $17 SUBSEP $18 SUBSEP $8 SUBSEP $9 SUBSEP \
            $10 SUBSEP expected_projector_state
        if (!(key in validated_tuples)) {
            printf "%s: models.tsv claims validated_filled_depth %s at batch %s, ubatch %s, cache %s/%s, flash attention %s, projector state %s, and no validated %s row in %s matches\n", \
                $1, $19, $17, $18, $8, $9, $10, \
                expected_projector_state, serving_backend, "'"$tuple_ledger"'" > "/dev/stderr"
            gaps++
        }
    }
    END {
        if (!model_rows) {
            printf "check_validated_tuples=rejected empty_registry=1 tuple_rows=%d model_rows=%d\n", \
                tuple_rows, model_rows > "/dev/stderr"
            exit 1
        }
        # An empty ledger beside a registry that claims no validated depth is
        # the state a host reaches before its first depth campaign, and it is
        # consistent: `checked` counts the claims that needed a matching row,
        # so zero claims and zero rows leave nothing unbacked. A registry row
        # carrying a numeric validated_filled_depth against an empty ledger
        # still fails, because that claim reaches the gaps counter above.
        if (!tuple_rows && checked) {
            printf "check_validated_tuples=rejected empty_ledger=1 claims=%d\n", \
                checked > "/dev/stderr"
            exit 1
        }
        if (gaps + malformed > 0) {
            printf "check_validated_tuples=rejected gaps=%d malformed=%d checked=%d\n", \
                gaps, malformed, checked > "/dev/stderr"
            exit 1
        }
        printf "check_validated_tuples=accepted backend=%s checked=%d\n", \
            serving_backend, checked
    }
' "$tuple_ledger" "$model_registry"
