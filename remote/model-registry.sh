#!/bin/sh
set -eu

# Read one field of one row of remote/models.tsv. A checkpoint is identified
# either by its registry id or by the path it is served from, so the launch
# path resolves a row from QWEN_MODEL_PATH without the caller naming an id.

validate_cache_type() {
    case $1 in
        f32 | f16 | bf16 | q8_0 | q5_1 | q5_0 | q4_1 | q4_0 | iq4_nl)
            return 0
            ;;
        *) return 1 ;;
    esac
}

# The tier vocabulary is closed because each value carries a different claim and
# a typo would otherwise create a sixth tier that no reader handles. production
# is a serving tuple measured safe and useful; candidate leaves quality or
# performance unqualified with no device failure under its admitted tuple;
# quarantine names a device failure or the absence of any validated safe tuple;
# archive is a valid artifact displaced or too slow to serve; rejected lost
# admission on measurement without being dangerous.
validate_tier() {
    case $1 in
        production | candidate | quarantine | archive | rejected) return 0 ;;
        *) return 1 ;;
    esac
}

if [ "$#" -eq 2 ] && [ "$1" = validate-cache-type ]; then
    validate_cache_type "$2"
    exit $?
fi

if [ "$#" -eq 2 ] && [ "$1" = validate-tier ]; then
    validate_tier "$2"
    exit $?
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
quarantine_registry=${QWEN_QUARANTINE_REGISTRY:-$script_directory/quarantine.tsv}

# The quarantine queries read a second file rather than the tier field alone,
# because a quarantine has two scopes and the model registry has one row per
# checkpoint. A scope `model` row removes a checkpoint entirely; a scope
# `profile` row removes one tuple of a checkpoint that otherwise serves. An
# optional runtime mode returns rows that apply to that path, including `any`.
if [ "$#" -ge 1 ] && [ "$#" -le 2 ]; then
    quarantine_query=$1
    quarantine_runtime_mode=${2:-}
    case $quarantine_query in
        quarantine-subjects | quarantine-profiles | quarantine-rows) ;;
        *) quarantine_query='' ;;
    esac
    if [ -n "$quarantine_query" ]; then
        case $quarantine_runtime_mode in
            '' | router-child | standalone) ;;
            *)
                printf 'quarantine runtime mode must be router-child or standalone: %s\n' \
                    "$quarantine_runtime_mode" >&2
                exit 2
                ;;
        esac
        if [ ! -r "$quarantine_registry" ]; then
            printf 'quarantine registry is unreadable: %s\n' \
                "$quarantine_registry" >&2
            exit 1
        fi
        awk -F'\t' -v mode="$quarantine_runtime_mode" \
            -v query="$quarantine_query" '
            function validate_quarantine_row(row_number, field_index) {
                row_invalid = 0
                if (NF != 14) {
                    printf "quarantine row %d holds %d fields, expected 14\n", \
                        row_number, NF > "/dev/stderr"
                    invalid = 1
                    return 1
                }
                if ($1 == "" || $3 == "") {
                    printf "quarantine row %d requires non-empty id and subject\n", \
                        row_number > "/dev/stderr"
                    invalid = row_invalid = 1
                }
                if ($2 != "model" && $2 != "profile") {
                    printf "quarantine row %d carries invalid scope %s\n", \
                        row_number, $2 > "/dev/stderr"
                    invalid = row_invalid = 1
                }
                if ($14 != "any" && $14 != "router-child" &&
                    $14 != "standalone") {
                    printf "quarantine row %d carries invalid runtime mode %s\n", \
                        row_number, $14 > "/dev/stderr"
                    invalid = row_invalid = 1
                }
                if ($2 == "model") {
                    for (field_index = 5; field_index <= 10; field_index++) {
                        if ($field_index != "-") {
                            printf "model quarantine row %d carries tuple field %d: %s\n", \
                                row_number, field_index, $field_index > "/dev/stderr"
                            invalid = row_invalid = 1
                        }
                    }
                }
                if ($2 == "profile") {
                    if ($5 !~ /^[1-9][0-9]*$/ ||
                        $6 !~ /^[1-9][0-9]*$/ ||
                        $7 !~ /^[1-9][0-9]*$/) {
                        printf "profile quarantine row %d carries invalid depth or geometry\n", \
                            row_number > "/dev/stderr"
                        invalid = row_invalid = 1
                    } else if ($7 + 0 > $6 + 0) {
                        printf "profile quarantine row %d carries ubatch above batch\n", \
                            row_number > "/dev/stderr"
                        invalid = row_invalid = 1
                    }
                    if ($8 !~ /^(f32|f16|bf16|q8_0|q5_1|q5_0|q4_1|q4_0|iq4_nl)$/ ||
                        $9 !~ /^(f32|f16|bf16|q8_0|q5_1|q5_0|q4_1|q4_0|iq4_nl)$/) {
                        printf "profile quarantine row %d carries invalid cache type\n", \
                            row_number > "/dev/stderr"
                        invalid = row_invalid = 1
                    }
                    if ($10 !~ /^(on|off|auto)$/) {
                        printf "profile quarantine row %d carries invalid flash attention\n", \
                            row_number > "/dev/stderr"
                        invalid = row_invalid = 1
                    }
                }
                return row_invalid
            }
            $0 ~ /^#/ || $0 ~ /^[[:space:]]*$/ { next }
            { row_invalid = validate_quarantine_row(NR) }
            row_invalid { next }
            mode != "" && $14 != "any" && $14 != mode { next }
            query == "quarantine-subjects" && $2 == "model" {
                query_rows[++query_row_count] = $3
                next
            }
            query == "quarantine-profiles" && $2 == "profile" {
                query_rows[++query_row_count] = sprintf("%s\t%s\t%s\t%s\t%s\t%s\t%s", \
                    $3, $5, $6, $7, $8, $9, $10)
                next
            }
            query == "quarantine-rows" { query_rows[++query_row_count] = $0 }
            END {
                if (invalid) { exit 1 }
                for (query_row_index = 1;
                     query_row_index <= query_row_count;
                     query_row_index++) {
                    print query_rows[query_row_index]
                }
            }
        ' "$quarantine_registry"
        exit 0
    fi
fi

emit_servable_rows() {
    servable_output_field=$1
    servable_registry=${QWEN_MODEL_REGISTRY:-$script_directory/models.tsv}
    if [ ! -r "$servable_registry" ]; then
        printf 'model registry is unreadable: %s\n' "$servable_registry" >&2
        return 1
    fi
    if [ ! -r "$quarantine_registry" ]; then
        printf 'quarantine registry is unreadable: %s\n' \
            "$quarantine_registry" >&2
        return 1
    fi
    # Read the quarantine authority first, then admit only registry rows whose
    # router-child tuple survives both exclusion scopes. The field selector is
    # fixed by the caller; it is not user-provided AWK source.
    awk -F'\t' -v output_field="$servable_output_field" '
        function validate_quarantine_row(row_number, field_index) {
            row_invalid = 0
            if (NF != 14) {
                printf "quarantine row %d holds %d fields, expected 14\n", \
                    row_number, NF > "/dev/stderr"
                invalid = 1
                return 1
            }
            if ($1 == "" || $3 == "") {
                printf "quarantine row %d requires non-empty id and subject\n", \
                    row_number > "/dev/stderr"
                invalid = row_invalid = 1
            }
            if ($2 != "model" && $2 != "profile") {
                printf "quarantine row %d carries invalid scope %s\n", \
                    row_number, $2 > "/dev/stderr"
                invalid = row_invalid = 1
            }
            if ($14 != "any" && $14 != "router-child" &&
                $14 != "standalone") {
                printf "quarantine row %d carries invalid runtime mode %s\n", \
                    row_number, $14 > "/dev/stderr"
                invalid = row_invalid = 1
            }
            if ($2 == "model") {
                for (field_index = 5; field_index <= 10; field_index++) {
                    if ($field_index != "-") {
                        printf "model quarantine row %d carries tuple field %d: %s\n", \
                            row_number, field_index, $field_index > "/dev/stderr"
                        invalid = row_invalid = 1
                    }
                }
            }
            if ($2 == "profile") {
                if ($5 !~ /^[1-9][0-9]*$/ ||
                    $6 !~ /^[1-9][0-9]*$/ ||
                    $7 !~ /^[1-9][0-9]*$/) {
                    printf "profile quarantine row %d carries invalid depth or geometry\n", \
                        row_number > "/dev/stderr"
                    invalid = row_invalid = 1
                } else if ($7 + 0 > $6 + 0) {
                    printf "profile quarantine row %d carries ubatch above batch\n", \
                        row_number > "/dev/stderr"
                    invalid = row_invalid = 1
                }
                if ($8 !~ /^(f32|f16|bf16|q8_0|q5_1|q5_0|q4_1|q4_0|iq4_nl)$/ ||
                    $9 !~ /^(f32|f16|bf16|q8_0|q5_1|q5_0|q4_1|q4_0|iq4_nl)$/) {
                    printf "profile quarantine row %d carries invalid cache type\n", \
                        row_number > "/dev/stderr"
                    invalid = row_invalid = 1
                }
                if ($10 !~ /^(on|off|auto)$/) {
                    printf "profile quarantine row %d carries invalid flash attention\n", \
                        row_number > "/dev/stderr"
                    invalid = row_invalid = 1
                }
            }
            return row_invalid
        }
        FILENAME == ARGV[1] {
            if ($0 ~ /^#/ || $0 ~ /^[[:space:]]*$/) { next }
            row_invalid = validate_quarantine_row(FNR)
            if (row_invalid) { next }
            if ($14 == "standalone") { next }
            if ($2 == "model") {
                quarantined_models[$3] = 1
            } else if ($2 == "profile") {
                profile_key = $3 SUBSEP $5 SUBSEP $6 SUBSEP $7 SUBSEP \
                    $8 SUBSEP $9 SUBSEP $10
                quarantined_profiles[profile_key] = 1
            }
            next
        }
        $0 ~ /^#/ || $0 ~ /^[[:space:]]*$/ { next }
        invalid { next }
        NF != 22 {
            printf "model row %d holds %d fields, expected 22\n", FNR, NF \
                > "/dev/stderr"
            invalid = 1
            next
        }
        $16 == "production" || $16 == "candidate" {
            profile_key = $1 SUBSEP $5 SUBSEP $17 SUBSEP $18 SUBSEP \
                $8 SUBSEP $9 SUBSEP $10
            if (!quarantined_models[$1] && !quarantined_profiles[profile_key]) {
                print $output_field
            }
        }
        END { exit invalid ? 1 : 0 }
    ' "$quarantine_registry" "$servable_registry"
}

# The rows the router can load on demand. Router mode serves any of them behind
# one listener, so a caller sizing the machine reads this list rather than the
# one checkpoint it happened to name.
if [ "$#" -eq 1 ] && [ "$1" = servable-files ]; then
    emit_servable_rows 3
    exit 0
fi

# The ids of those same rows. The router routes on an id and answers 400 for one
# it does not hold, so a caller grading every served checkpoint enumerates ids
# here rather than reading the live endpoint, which would also list a
# quarantined row exposed by QWEN_ROUTER_INCLUDE_QUARANTINE.
if [ "$#" -eq 1 ] && [ "$1" = servable-ids ]; then
    emit_servable_rows 1
    exit 0
fi

# The tuple ledger carries every measured (context, batch, ubatch, cache,
# Flash Attention) arm rather than the single validated_filled_depth field
# models.tsv holds per row, because the served checkpoint fills and decodes
# 16384 tokens at batch 128 and wedges the ring at the harness-default 2048,
# and one scalar per model cannot carry both arms. Both subcommands validate
# the whole ledger before reading it, the same discipline emit_servable_rows
# applies to the quarantine authority, because a caller reading one row must
# not trust a ledger a sibling row has made unsafe to read.
validate_tuple_ledger() {
    tuple_ledger_registry=${QWEN_VALIDATED_TUPLES:-$script_directory/validated-tuples.tsv}
    tuple_model_registry=${QWEN_MODEL_REGISTRY:-$script_directory/models.tsv}
    if [ ! -r "$tuple_ledger_registry" ]; then
        printf 'validated tuple ledger is unreadable: %s\n' \
            "$tuple_ledger_registry" >&2
        return 1
    fi
    if [ ! -r "$tuple_model_registry" ]; then
        printf 'model registry is unreadable: %s\n' "$tuple_model_registry" >&2
        return 1
    fi
    tuple_ledger_rows=$(awk -F'\t' '
        FILENAME == ARGV[1] {
            if ($0 ~ /^#/ || $0 ~ /^[[:space:]]*$/) { next }
            if (NF >= 1) { known_model_ids[$1] = 1 }
            next
        }
        $0 ~ /^#/ || $0 ~ /^[[:space:]]*$/ { next }
        {
            rows++
            if (NF != 21) {
                printf "tuple row %d holds %d fields, expected 21\n", FNR, NF \
                    > "/dev/stderr"
                bad++
                next
            }
            if ($1 == "") {
                printf "tuple row %d carries an empty tuple_id\n", FNR \
                    > "/dev/stderr"
                bad++
                next
            }
            if (seen_id[$1]++) {
                printf "duplicate tuple_id %s at row %d\n", $1, FNR \
                    > "/dev/stderr"
                bad++
            }
            if (!($2 in known_model_ids)) {
                printf "%s: model_id %s is absent from the model registry\n", \
                    $1, $2 > "/dev/stderr"
                bad++
            }
            if ($3 != "standalone" && $3 != "router-child") {
                printf "%s: runtime_mode %s is not standalone or router-child\n", \
                    $1, $3 > "/dev/stderr"
                bad++
            }
            split("context batch ubatch", geometry_names, " ")
            for (i = 4; i <= 6; i++) {
                if ($i !~ /^[1-9][0-9]*$/) {
                    printf "%s: %s is not a canonical positive integer: %s\n", \
                        $1, geometry_names[i - 3], $i > "/dev/stderr"
                    bad++
                }
            }
            if ($5 ~ /^[1-9][0-9]*$/ && $6 ~ /^[1-9][0-9]*$/ &&
                $6 + 0 > $5 + 0) {
                printf "%s: ubatch %s exceeds batch %s\n", $1, $6, $5 \
                    > "/dev/stderr"
                bad++
            }
            if ($7 !~ /^(f32|f16|bf16|q8_0|q5_1|q5_0|q4_1|q4_0|iq4_nl)$/) {
                printf "%s: cache_k %s is outside the runtime vocabulary\n", \
                    $1, $7 > "/dev/stderr"
                bad++
            }
            if ($8 !~ /^(f32|f16|bf16|q8_0|q5_1|q5_0|q4_1|q4_0|iq4_nl)$/) {
                printf "%s: cache_v %s is outside the runtime vocabulary\n", \
                    $1, $8 > "/dev/stderr"
                bad++
            }
            if ($9 != "on" && $9 != "off" && $9 != "auto") {
                printf "%s: flash_attention %s is not on, off, or auto\n", \
                    $1, $9 > "/dev/stderr"
                bad++
            }
            if ($10 !~ /^[1-9][0-9]*$/) {
                printf "%s: threads %s is not a canonical positive integer\n", \
                    $1, $10 > "/dev/stderr"
                bad++
            }
            if ($11 !~ /^[1-9][0-9]*$/) {
                printf "%s: parallel %s is not a canonical positive integer\n", \
                    $1, $11 > "/dev/stderr"
                bad++
            }
            if ($12 != "none" && $12 != "loaded") {
                printf "%s: projector_state %s is not none or loaded\n", \
                    $1, $12 > "/dev/stderr"
                bad++
            }
            if ($13 != "vulkan" && $13 != "cpu" && $13 != "hip") {
                printf "%s: backend %s is not vulkan, cpu, or hip\n", \
                    $1, $13 > "/dev/stderr"
                bad++
            }
            if ($14 != "validated" && $14 != "failed" && $14 != "unverified") {
                printf "%s: status %s is not validated, failed, or unverified\n", \
                    $1, $14 > "/dev/stderr"
                bad++
            }
            if ($14 == "validated") {
                if ($15 == "-") {
                    printf "%s: validated status carries no evidence path\n", \
                        $1 > "/dev/stderr"
                    bad++
                }
            }
            if ($21 != "-" && $21 !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/) {
                printf "%s: measured_at %s is not an ISO date or -\n", \
                    $1, $21 > "/dev/stderr"
                bad++
            }
            print $0
        }
        END {
            if (!rows) { print "tuple ledger holds no rows" > "/dev/stderr"; bad++ }
            exit bad ? 1 : 0
        }
    ' "$tuple_model_registry" "$tuple_ledger_registry") || return 1

    # Ledger text never becomes shell source. Validate each retained evidence
    # path as one shell word after AWK has established the 21-field row shape,
    # then test the quoted path with the shell's pathname primitive. The shell
    # pathname test keeps quotes, semicolons, and command substitutions in a
    # ledger outside executable input.
    tuple_tab=$(printf '\t')
    tuple_evidence_failures=0
    while IFS="$tuple_tab" read -r tuple_id _model_id _runtime_mode \
        _context _batch _ubatch _cache_k _cache_v _flash_attention \
        _threads _parallel _projector_state _backend tuple_status \
        tuple_evidence _llama_commit _runner_sha256 _kernel _mesa _amdgpu \
        _measured_at; do
        [ "$tuple_status" = validated ] || continue
        case $tuple_evidence in
            '' | - | /* | ../* | */../* | */..)
                printf '%s: validation evidence is not a repository-relative path: %s\n' \
                    "$tuple_id" "$tuple_evidence" >&2
                tuple_evidence_failures=$((tuple_evidence_failures + 1))
                continue
                ;;
        esac
        if [ ! -e "$script_directory/../$tuple_evidence" ]; then
            printf '%s: validation evidence is absent from the tree: %s\n' \
                "$tuple_id" "$tuple_evidence" >&2
            tuple_evidence_failures=$((tuple_evidence_failures + 1))
        fi
    done <<EOF
$tuple_ledger_rows
EOF
    [ "$tuple_evidence_failures" -eq 0 ] || return 1
    printf '%s\n' "$tuple_ledger_rows"
}

# All validated and failed arms measured for one model, in ledger order. A
# caller choosing a serving geometry reads every row rather than the single
# field models.tsv carries, because two geometries at the same depth can
# disagree.
if [ "$#" -eq 2 ] && [ "$1" = tuples ]; then
    tuples_model_id=$2
    validated_tuples_rows=$(validate_tuple_ledger) || exit 1
    printf '%s\n' "$validated_tuples_rows" | awk -F'\t' -v model_id="$tuples_model_id" \
        '$2 == model_id { print; matched = 1 } END { exit matched ? 0 : 1 }'
    exit $?
fi

# One tuple row by its id, either the whole row as key=value lines or a single
# named field, the same interface the id and path selectors give the model
# registry.
if [ "$#" -eq 2 ] && [ "$1" = tuple ]; then
    tuple_selector=$2
    validated_tuples_rows=$(validate_tuple_ledger) || exit 1
    printf '%s\n' "$validated_tuples_rows" | awk -F'\t' -v selector="$tuple_selector" '
        $1 == selector {
            split("tuple_id model_id runtime_mode context batch ubatch cache_k " \
                  "cache_v flash_attention threads parallel projector_state " \
                  "backend status evidence llama_commit runner_sha256 kernel " \
                  "mesa amdgpu measured_at", names, " ")
            for (i = 1; i <= 21; i++) { printf "%s=%s\n", names[i], $i }
            matched = 1
            next
        }
        END { exit matched ? 0 : 3 }
    '
    exit $?
fi

if [ "$#" -eq 3 ] && [ "$1" = tuple ]; then
    tuple_selector=$2
    tuple_field=$3
    validated_tuples_rows=$(validate_tuple_ledger) || exit 1
    printf '%s\n' "$validated_tuples_rows" | awk -F'\t' \
        -v selector="$tuple_selector" -v field="$tuple_field" '
        $1 == selector {
            split("tuple_id model_id runtime_mode context batch ubatch cache_k " \
                  "cache_v flash_attention threads parallel projector_state " \
                  "backend status evidence llama_commit runner_sha256 kernel " \
                  "mesa amdgpu measured_at", names, " ")
            for (i = 1; i <= 21; i++) {
                if (names[i] == field) { printf "%s\n", $i; found = 1 }
            }
            matched = 1
            next
        }
        END { exit matched && found ? 0 : 3 }
    '
    exit $?
fi

if [ "$#" -ne 2 ] && [ "$#" -ne 3 ]; then
    printf 'usage: %s id|path SELECTOR [FIELD]\n' "$0" >&2
    printf '       %s validate-cache-type TYPE\n' "$0" >&2
    printf '       %s validate-tier TIER\n' "$0" >&2
    printf '       %s quarantine-subjects|quarantine-profiles|quarantine-rows [RUNTIME_MODE]\n' "$0" >&2
    printf '       %s servable-files | servable-ids\n' "$0" >&2
    printf '       %s tuples MODEL_ID\n' "$0" >&2
    printf '       %s tuple TUPLE_ID [FIELD]\n' "$0" >&2
    printf 'fields: id role model_file fetch_script context_default context_ceiling\n' >&2
    printf '        context_target cache_type_k cache_type_v flash_attention\n' >&2
    printf '        projector projector_fetch_script decode_tok_s prefill_tok_s\n' >&2
    printf '        quality tier batch\n' >&2
    printf '        ubatch validated_filled_depth validation_evidence\n' >&2
    printf '        raw_tool_selection guarded_tool_execution\n' >&2
    printf 'omit FIELD to print the whole row as key=value lines\n' >&2
    exit 2
fi

selector_kind=$1
selector=$2
field=${3:-}
registry=${QWEN_MODEL_REGISTRY:-$script_directory/models.tsv}

case $selector_kind in
    id | path) ;;
    *)
        printf 'selector kind must be id, path, validate-cache-type, validate-tier, or a quarantine query: %s\n' \
            "$selector_kind" >&2
        exit 2
        ;;
esac

if [ ! -r "$registry" ]; then
    printf 'model registry is unreadable: %s\n' "$registry" >&2
    exit 1
fi

awk -F'\t' -v kind="$selector_kind" -v selector="$selector" -v field="$field" '
    /^#/ { next }
    NF < 22 { next }
    {
        matched = 0
        if (kind == "id" && $1 == selector) {
            matched = 1
        }
        # A path matches when it ends in the registry file suffix, so the row
        # holds a repository-relative name and the caller holds an absolute one.
        if (kind == "path" && length($3) <= length(selector) &&
            substr(selector, length(selector) - length($3) + 1) == $3) {
            matched = 1
        }
        if (!matched) { next }
        matched_any = 1
        split("id role model_file fetch_script context_default context_ceiling " \
              "context_target cache_type_k cache_type_v flash_attention projector " \
              "projector_fetch_script decode_tok_s prefill_tok_s quality tier batch ubatch " \
              "validated_filled_depth validation_evidence raw_tool_selection " \
              "guarded_tool_execution", names, " ")
        if (field == "") {
            for (i = 1; i <= 22; i++) { printf "%s=%s\n", names[i], $i }
        } else {
            for (i = 1; i <= 22; i++) {
                if (names[i] == field) { printf "%s\n", $i; found = 1 }
            }
            if (!found) { exit 3 }
        }
        exit 0
    }
    END {
        if (!matched_any) {
            printf "no registry row matches %s %s\n", kind, selector > "/dev/stderr"
            exit 1
        }
    }
' "$registry"
