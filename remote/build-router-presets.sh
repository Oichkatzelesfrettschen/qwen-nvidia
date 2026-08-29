#!/bin/sh
set -eu

# Generate the router preset file and the tier directories from the registry.
#
# llama-server in router mode reads an INI whose sections name models and whose
# keys are LLAMA_ARG_* option names. It builds a base preset from its own argv,
# strips the SSL, API key, and models-* keys from it, and cascades the rest onto
# every child it spawns. The guarded argv that qwen-capacity-policy.sh already
# builds therefore reaches each child unchanged, and this file carries only what
# differs per checkpoint: the weights, the projector, the admitted depth, the
# cache triple, and the labels the picker shows.
#
# qwen-capacity-policy.sh refuses ambient LLAMA_ARG_* precisely so the caller's
# environment cannot override the computed argv. An INI the policy generates is
# that computation's output rather than ambient input, so the refusal stands.
#
# The tier field decides both the directory a checkpoint is linked into and the
# tag the picker groups it by. Only production and candidate reach the preset
# file. A row tiered archive or rejected is linked nowhere and named in no
# section, which removes it from the picker while leaving the weights on disk
# and the fetch script that verifies them in the tree. A row tiered quarantine
# is linked into a quarantine directory beside its reason record and reaches the
# preset file only under QWEN_ROUTER_INCLUDE_QUARANTINE=1, which the appliance
# launch never sets.
#
# A profile quarantine removes one tuple rather than a checkpoint, so the preset
# this script emits carries LLAMA_ARG_BATCH and LLAMA_ARG_UBATCH from
# the registry rather than letting them arrive by cascade. That makes each
# section state the full submission geometry it serves at, so a quarantined
# tuple is checkable against one file instead of against a file plus the argv
# that spawned the router.
#
# Directories are linked rather than moved. A checkpoint's projector must sit in
# the checkpoint's own directory for remote/select-projector.sh to pair it, and
# linking the directory preserves that pairing while a file move would break a
# reader holding the model open.

if [ "$#" -gt 1 ]; then
    printf 'usage: %s [OUTPUT_INI]\n' "$0" >&2
    printf 'model root comes from QWEN_MODEL_ROOT, default $HOME/models\n' >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
registry=${QWEN_MODEL_REGISTRY:-$script_directory/models.tsv}
model_root=${QWEN_MODEL_ROOT:-"${HOME:?}/models"}
reason_source=${QWEN_QUARANTINE_REASONS:-$script_directory/../evidence/quarantine}
output_ini=${1:-"${HOME:?}/qwen-webui-state/router-presets.ini"}
include_quarantine=${QWEN_ROUTER_INCLUDE_QUARANTINE:-0}
case $include_quarantine in
    0 | 1) ;;
    *)
        printf 'QWEN_ROUTER_INCLUDE_QUARANTINE must be 0 or 1: %s\n' \
            "$include_quarantine" >&2
        exit 2
        ;;
esac
# The picker offers every servable row and the operator prefers one of them. The
# tag names that preference; llama-server has no default-model option, so this
# labels the section rather than preselecting it.
default_model_id=${QWEN_DEFAULT_MODEL_ID:-qwen38-2b-distill}

if [ ! -r "$registry" ]; then
    printf 'model registry is unreadable: %s\n' "$registry" >&2
    exit 1
fi

mkdir -p "$(dirname -- "$output_ini")"
production_directory=$model_root/production
candidate_directory=$model_root/candidates
quarantine_directory=$model_root/quarantine
reason_directory=$model_root/quarantine-reasons
mkdir -p "$production_directory" "$candidate_directory" \
    "$quarantine_directory" "$reason_directory"

# A stale link outlives the row that created it, so the tier directories are
# emptied of links before they are rebuilt. A real directory found where a link
# belongs is refused rather than skipped: reconciliation would leave the
# checkpoint inside it in a tier no row claims, and a quarantined model sitting
# in a real production/ directory is exactly the state the tiers exist to
# prevent.
for tier_directory in "$production_directory" "$candidate_directory" \
    "$quarantine_directory"; do
    for existing in "$tier_directory"/*; do
        [ -e "$existing" ] || [ -L "$existing" ] || continue
        if [ -L "$existing" ]; then
            rm -f "$existing"
            continue
        fi
        printf 'tier directory holds a real entry where a symlink belongs: %s\n' \
            "$existing" >&2
        printf 'move it out of the tier tree; reconciliation refuses to touch it\n' >&2
        exit 1
    done
done
for existing in "$reason_directory"/*; do
    [ -f "$existing" ] || continue
    rm -f "$existing"
done

emitted=0
skipped_unlisted=0
skipped_absent=0
quarantined=0
quarantine_rows=$("$script_directory/model-registry.sh" quarantine-rows router-child)

deploy_quarantine_reason() {
    quarantine_reason_id=$1
    if [ ! -f "$reason_source/$quarantine_reason_id.md" ]; then
        printf 'quarantine %s carries no reason record at %s\n' \
            "$quarantine_reason_id" "$reason_source/$quarantine_reason_id.md" >&2
        return 1
    fi
    cp -- "$reason_source/$quarantine_reason_id.md" \
        "$reason_directory/$quarantine_reason_id.md"
}

{
    printf '# Generated by remote/build-router-presets.sh from the model registry.\n'
    printf '# Edit remote/models.tsv and regenerate; edits here are overwritten.\n'
    printf '# qwen_router_include_quarantine=%s\n' "$include_quarantine"
    printf '\n'
} >"$output_ini"

while IFS='	' read -r id role model_file _fetch_script context_default \
    _context_ceiling _context_target cache_type_k cache_type_v flash_attention \
    projector _projector_fetch_script _decode_tok_s _prefill_tok_s _quality tier batch ubatch \
    _validated_filled_depth _validation_evidence; do
    case $id in
        '#'* | '') continue ;;
    esac
    [ -n "${tier:-}" ] || continue

    if ! "$script_directory/model-registry.sh" validate-tier "$tier"; then
        printf 'row %s carries tier %s, which is outside the vocabulary\n' \
            "$id" "$tier" >&2
        exit 1
    fi

    # Archive and rejected rows stay outside every preset even when a retained
    # model-scope quarantine record also names them. The research override
    # exposes quarantined serving candidates; it never reverses archival.
    case $tier in
        archive | rejected)
            skipped_unlisted=$((skipped_unlisted + 1))
            continue
            ;;
    esac

    model_quarantine_row=$(printf '%s\n' "$quarantine_rows" |
        awk -F'\t' -v subject="$id" '$2 == "model" && $3 == subject { print; exit }')
    profile_quarantine_row=$(printf '%s\n' "$quarantine_rows" |
        awk -F'\t' -v subject="$id" -v depth="$context_default" \
            -v row_batch="$batch" -v row_ubatch="$ubatch" \
            -v cache_k="$cache_type_k" -v cache_v="$cache_type_v" \
            -v flash="$flash_attention" '
            $2 == "profile" && $3 == subject && $5 == depth &&
            $6 == row_batch && $7 == row_ubatch && $8 == cache_k &&
            $9 == cache_v && $10 == flash { print; exit }')

    if [ "$tier" = quarantine ] && [ -z "$model_quarantine_row" ]; then
        printf 'row %s is tiered quarantine without a router-child quarantine record\n' \
            "$id" >&2
        exit 1
    fi

    effective_tier=$tier
    preset_tier=$tier
    quarantine_row=''
    if [ -n "$model_quarantine_row" ]; then
        effective_tier=quarantine
        preset_tier=quarantine
        quarantine_row=$model_quarantine_row
    elif [ -n "$profile_quarantine_row" ]; then
        preset_tier=quarantine
        quarantine_row=$profile_quarantine_row
    fi

    model_path=$model_root/$model_file
    if [ ! -f "$model_path" ]; then
        printf 'preset_skipped id=%s reason=weights_absent path=%s\n' \
            "$id" "$model_path" >&2
        skipped_absent=$((skipped_absent + 1))
        continue
    fi

    case $effective_tier in
        production) tier_directory=$production_directory ;;
        quarantine) tier_directory=$quarantine_directory ;;
        *) tier_directory=$candidate_directory ;;
    esac
    model_directory=$(dirname -- "$model_path")
    ln -sfn "$model_directory" "$tier_directory/$(basename -- "$model_directory")"

    # The quarantine registry is the exclusion authority. A model-scope row
    # overrides a stale production or candidate tier, while a profile-scope row
    # removes only the exact section tuple. The research override exposes either
    # on a preset marked for loopback enforcement by qwen-capacity-policy.sh.
    if [ -n "$quarantine_row" ]; then
        quarantined=$((quarantined + 1))
        quarantine_reason_id=$(printf '%s\n' "$quarantine_row" | awk -F'\t' '{ print $1 }')
        deploy_quarantine_reason "$quarantine_reason_id"
        if [ "$include_quarantine" != 1 ]; then
            continue
        fi
        printf 'quarantine_exposed id=%s reason=%s\n' \
            "$id" "$reason_directory/$quarantine_reason_id.md" >&2
    fi

    {
        printf '[%s]\n' "$id"
        printf 'LLAMA_ARG_MODEL = %s\n' "$model_path"
        printf 'LLAMA_ARG_ALIAS = %s\n' "$id"
        if [ "$id" = "$default_model_id" ] &&
            [ "$preset_tier" != quarantine ]; then
            printf 'LLAMA_ARG_TAGS = %s,%s,default\n' "$preset_tier" "$role"
        else
            printf 'LLAMA_ARG_TAGS = %s,%s\n' "$preset_tier" "$role"
        fi
        printf 'LLAMA_ARG_CTX_SIZE = %s\n' "$context_default"
        printf 'LLAMA_ARG_CACHE_TYPE_K = %s\n' "$cache_type_k"
        printf 'LLAMA_ARG_CACHE_TYPE_V = %s\n' "$cache_type_v"
        printf 'LLAMA_ARG_FLASH_ATTN = %s\n' "$flash_attention"
        printf 'LLAMA_ARG_BATCH = %s\n' "$batch"
        printf 'LLAMA_ARG_UBATCH = %s\n' "$ubatch"
    } >>"$output_ini"

    if [ "$projector" = required ]; then
        projector_path=$("$script_directory/select-projector.sh" "$model_path" \
            2>/dev/null) || projector_path=''
        if [ -n "$projector_path" ]; then
            printf 'LLAMA_ARG_MMPROJ = %s\n' "$projector_path" >>"$output_ini"
        else
            printf 'preset_warning id=%s reason=projector_unresolved\n' "$id" >&2
        fi
    fi
    printf '\n' >>"$output_ini"
    emitted=$((emitted + 1))
done <"$registry"

printf 'router_presets=written path=%s models=%s unlisted=%s quarantined=%s absent=%s\n' \
    "$output_ini" "$emitted" "$skipped_unlisted" "$quarantined" "$skipped_absent"
printf 'tier_directories production=%s candidates=%s quarantine=%s reasons=%s\n' \
    "$production_directory" "$candidate_directory" "$quarantine_directory" \
    "$reason_directory"
if [ "$include_quarantine" = 1 ]; then
    printf 'quarantine_override=on models_exposed=%s\n' "$quarantined"
fi
