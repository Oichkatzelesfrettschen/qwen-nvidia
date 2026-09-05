#!/bin/sh
set -eu

if [ "$#" -lt 3 ] || [ "$#" -gt 6 ]; then
    printf 'usage: %s LLAMA_SERVER MODEL_PATH CONTEXT_SIZE [PORT [STATIC_PATH [API_KEY_FILE]]]\n' "$0" >&2
    exit 2
fi

llama_server=$1
model_path=$2
context_size=$3
server_port=${4:-8080}
static_path=${5:-}
api_key_file=${6:-}
router_enabled=${QWEN_ROUTER:-0}
case $router_enabled in
    0 | 1) ;;
    *)
        printf 'QWEN_ROUTER must be 0 or 1: %s\n' "$router_enabled" >&2
        exit 2
        ;;
esac

# server-models.cpp ends its per-child preset assembly with
# preset.merge(base_preset), and common_preset::merge overwrites, so any
# speculation argument on the router parent's own command line replaces that
# key in every model section. QWEN_SPEC_TYPE=draft-mtp set globally forced
# multi-token prediction onto checkpoints carrying no MTP layers, and each one
# refused to load with "context type MTP requested but model doesn't contain
# MTP layers". scripts/models.tsv now carries mtp_layers and
# speculation_profile per row, and build-router-presets.sh emits the
# speculation keys into each section, so router mode refuses the four
# environment variables outright rather than building an argv that would
# overwrite the registry's own per-checkpoint choice. Single-model mode leaves
# them untouched below, where they remain the experimental path.
if [ "$router_enabled" = 1 ]; then
    router_speculation_override_names=''
    for router_speculation_variable in QWEN_SPEC_TYPE QWEN_SPEC_DRAFT_N_MAX \
        QWEN_SPEC_DRAFT_P_MIN QWEN_SPEC_BACKEND_SAMPLING; do
        eval "router_speculation_value=\${$router_speculation_variable:-}"
        if [ -n "$router_speculation_value" ]; then
            router_speculation_override_names="$router_speculation_override_names $router_speculation_variable"
        fi
    done
    if [ -n "$router_speculation_override_names" ]; then
        printf 'router speculation is registry-owned:%s must stay unset in router mode\n' \
            "$router_speculation_override_names" >&2
        exit 2
    fi
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
bind_host=${QWEN_BIND_HOST:-127.0.0.1}
cors_origins=${QWEN_CORS_ORIGINS:-localhost}

# A router preset section normally names a registry id. A web preset section
# names a profile_id instead, because several profiles serve one checkpoint at
# depths the profile chooses, so $6 switches the resolution: the section's
# LLAMA_ARG_MODEL path resolves the registry row through the model_file column,
# which is unique across the registry, and LLAMA_ARG_CTX_SIZE is bounded by that
# row's context_ceiling rather than pinned to its context_default, and bounded
# again by that row's validated_filled_depth unless $7 carries the preset's
# unvalidated-depth marker. Every other tuple key, tier rule, and quarantine
# rule stays identical.
validate_router_preset_tuples() {
    printf '%s\n' "$4" | awk -F'\t' -v model_root="$3" \
        -v include_quarantine="$5" -v web_profile_sections="${6:-0}" \
        -v router_max="$router_max" \
        -v web_depth_override="${7:-0}" '
        function reset_tuple() {
            model_count = 0
            context_count = 0
            cache_k_count = 0
            cache_v_count = 0
            flash_count = 0
            batch_count = 0
            ubatch_count = 0
            tags_count = 0
            model_value = ""
            context_value = ""
            cache_k_value = ""
            cache_v_value = ""
            flash_value = ""
            batch_value = ""
            ubatch_value = ""
            tags_value = ""
        }
        function reject_key(key, count) {
            printf "router preset section %s requires exactly one %s, found %d\n", \
                section, key, count > "/dev/stderr"
            rejected = 1
        }
        function reject_value(key, value) {
            printf "router preset section %s carries invalid %s: %s\n", \
                section, key, value > "/dev/stderr"
            rejected = 1
        }
        function reject_registry_value(key, value, expected) {
            printf "router preset section %s carries %s %s, registry admits %s\n", \
                section, key, value, expected > "/dev/stderr"
            rejected = 1
        }
        function finish_section() {
            if (section == "" || section == "*") {
                return
            }
            model_sections++
            if (model_count != 1) reject_key("LLAMA_ARG_MODEL", model_count)
            if (context_count != 1) reject_key("LLAMA_ARG_CTX_SIZE", context_count)
            if (cache_k_count != 1) reject_key("LLAMA_ARG_CACHE_TYPE_K", cache_k_count)
            if (cache_v_count != 1) reject_key("LLAMA_ARG_CACHE_TYPE_V", cache_v_count)
            if (flash_count != 1) reject_key("LLAMA_ARG_FLASH_ATTN", flash_count)
            if (batch_count != 1) reject_key("LLAMA_ARG_BATCH", batch_count)
            if (ubatch_count != 1) reject_key("LLAMA_ARG_UBATCH", ubatch_count)
            if (context_count == 1 && (context_value !~ /^[0-9]+$/ || context_value + 0 < 1)) {
                reject_value("LLAMA_ARG_CTX_SIZE", context_value)
            }
            if (batch_count == 1 && (batch_value !~ /^[0-9]+$/ || batch_value + 0 < 1)) {
                reject_value("LLAMA_ARG_BATCH", batch_value)
            }
            if (ubatch_count == 1 && (ubatch_value !~ /^[0-9]+$/ || ubatch_value + 0 < 1)) {
                reject_value("LLAMA_ARG_UBATCH", ubatch_value)
            }
            if (batch_count == 1 && ubatch_count == 1 &&
                batch_value ~ /^[0-9]+$/ && ubatch_value ~ /^[0-9]+$/ &&
                ubatch_value + 0 > batch_value + 0) {
                reject_value("LLAMA_ARG_UBATCH", ubatch_value)
            }
            if (cache_k_count == 1 && cache_k_value !~ /^(f32|f16|bf16|q8_0|q5_1|q5_0|q4_1|q4_0|iq4_nl)$/) {
                reject_value("LLAMA_ARG_CACHE_TYPE_K", cache_k_value)
            }
            if (cache_v_count == 1 && cache_v_value !~ /^(f32|f16|bf16|q8_0|q5_1|q5_0|q4_1|q4_0|iq4_nl)$/) {
                reject_value("LLAMA_ARG_CACHE_TYPE_V", cache_v_value)
            }
            if (flash_count == 1 && flash_value !~ /^(on|off|auto)$/) {
                reject_value("LLAMA_ARG_FLASH_ATTN", flash_value)
            }
            registry_key = section
            if (web_profile_sections == 1) {
                model_root_prefix = model_root "/"
                if (model_count == 1 &&
                    substr(model_value, 1, length(model_root_prefix)) == model_root_prefix) {
                    registry_key = registry_id_by_model_file[substr(model_value,
                        length(model_root_prefix) + 1)]
                } else {
                    registry_key = ""
                }
                if (registry_key == "") {
                    printf "web preset section %s carries a LLAMA_ARG_MODEL outside the registry: %s\n", \
                        section, model_value > "/dev/stderr"
                    rejected = 1
                    return
                }
                # Resolution by weights file requires the registry to name each
                # file once. Two rows sharing one model_file would resolve to
                # whichever row was read last, which picks a tier and a tuple
                # by file order, so the ambiguity is refused instead.
                section_model_file = substr(model_value, length(model_root_prefix) + 1)
                if (registry_rows_by_model_file[section_model_file] != 1) {
                    printf "web preset section %s resolves to %d registry rows through model file %s\n", \
                        section, registry_rows_by_model_file[section_model_file], \
                        section_model_file > "/dev/stderr"
                    rejected = 1
                    return
                }
            }
            if (registry_count[registry_key] != 1) {
                printf "router preset section %s resolves to %d registry rows\n", \
                    section, registry_count[registry_key] > "/dev/stderr"
                rejected = 1
                return
            }
            if (registry_tier[registry_key] != "production" &&
                registry_tier[registry_key] != "candidate" &&
                registry_tier[registry_key] != "quarantine") {
                printf "router preset section %s has non-servable registry tier %s\n", \
                    section, registry_tier[registry_key] > "/dev/stderr"
                rejected = 1
            }
            if (registry_tier[registry_key] == "quarantine" &&
                (include_quarantine != 1 || !quarantined_models[registry_key])) {
                printf "router preset section %s lacks an admitted model quarantine override\n", \
                    section > "/dev/stderr"
                rejected = 1
            }
            # A preset persists across a registry edit, so switch_policy is
            # enforced against the row as it stands at launch. standalone-only
            # belongs to the standalone path alone, and evict-first requires a
            # roster of one because server-models.cpp gates eviction on a model
            # count rather than on bytes: a second resident beside such a row
            # is the memory peak the field exists to refuse.
            if (registry_switch_policy[registry_key] == "standalone-only") {
                printf "router preset section %s carries switch_policy standalone-only, which the router never serves\n", \
                    section > "/dev/stderr"
                rejected = 1
            }
            if (registry_switch_policy[registry_key] == "evict-first" &&
                router_max + 0 != 1) {
                printf "router preset section %s carries switch_policy evict-first, which requires QWEN_ROUTER_MAX=1, found %s\n", \
                    section, router_max > "/dev/stderr"
                rejected = 1
            }
            expected_model = model_root "/" registry_model[registry_key]
            if (model_count == 1 && model_value != expected_model) {
                reject_registry_value("LLAMA_ARG_MODEL", model_value,
                    expected_model)
            }
            if (context_count == 1) {
                if (web_profile_sections == 1) {
                    if (context_value + 0 > registry_ceiling[registry_key] + 0) {
                        reject_registry_value("LLAMA_ARG_CTX_SIZE", context_value,
                            "at most " registry_ceiling[registry_key])
                    }
                    # A preset persists across a registry edit, so the depth the
                    # generator validated is rechecked against the registry this
                    # launch reads. build-web-presets.sh admits a context above
                    # validated_filled_depth, or against an unmeasured `-`, only
                    # under QWEN_WEB_ALLOW_UNVALIDATED_DEPTH, whose marker forces
                    # the listener to loopback; a registry that later lowers that
                    # field, or sets it to `-`, leaves an unmarked section serving
                    # a depth no run has filled and decoded and reaching the LAN
                    # through a launch outside the web wrapper. `-` is refused by
                    # its literal spelling, since it reads as 0 in a numeric
                    # comparison and would name a nonsense expectation.
                    if (web_depth_override != 1) {
                        if (registry_filled_depth[registry_key] == "-") {
                            printf "web preset section %s serves context %s where the registry records no filled depth for %s\n", \
                                section, context_value, registry_key > "/dev/stderr"
                            rejected = 1
                        } else if (context_value + 0 > \
                            registry_filled_depth[registry_key] + 0) {
                            reject_registry_value("LLAMA_ARG_CTX_SIZE",
                                context_value,
                                "at most validated_filled_depth " \
                                    registry_filled_depth[registry_key])
                        }
                    }
                } else if (context_value != registry_context[registry_key]) {
                    reject_registry_value("LLAMA_ARG_CTX_SIZE", context_value,
                        registry_context[registry_key])
                }
            }
            if (cache_k_count == 1 && cache_k_value != registry_cache_k[registry_key]) {
                reject_registry_value("LLAMA_ARG_CACHE_TYPE_K", cache_k_value,
                    registry_cache_k[registry_key])
            }
            if (cache_v_count == 1 && cache_v_value != registry_cache_v[registry_key]) {
                reject_registry_value("LLAMA_ARG_CACHE_TYPE_V", cache_v_value,
                    registry_cache_v[registry_key])
            }
            if (flash_count == 1 && flash_value != registry_flash[registry_key]) {
                reject_registry_value("LLAMA_ARG_FLASH_ATTN", flash_value,
                    registry_flash[registry_key])
            }
            if (batch_count == 1 && batch_value != registry_batch[registry_key]) {
                reject_registry_value("LLAMA_ARG_BATCH", batch_value,
                    registry_batch[registry_key])
            }
            if (ubatch_count == 1 && ubatch_value != registry_ubatch[registry_key]) {
                reject_registry_value("LLAMA_ARG_UBATCH", ubatch_value,
                    registry_ubatch[registry_key])
            }
            if (include_quarantine != 1 && quarantined_models[registry_key]) {
                printf "router preset section %s is excluded by model quarantine\n", \
                    section > "/dev/stderr"
                rejected = 1
            }
            profile_key = registry_key SUBSEP context_value SUBSEP batch_value SUBSEP \
                ubatch_value SUBSEP cache_k_value SUBSEP cache_v_value SUBSEP \
                flash_value
            quarantined_section = quarantined_models[registry_key] ||
                quarantined_profiles[profile_key] ||
                registry_tier[registry_key] == "quarantine"
            if (include_quarantine == 1 && quarantined_section) {
                if (tags_count != 1) {
                    reject_key("LLAMA_ARG_TAGS", tags_count)
                } else {
                    quarantine_tag = 0
                    default_tag = 0
                    conflicting_tier_tag = 0
                    tag_count = split(tags_value, tags, ",")
                    for (tag_index = 1; tag_index <= tag_count; tag_index++) {
                        if (tags[tag_index] == "quarantine") quarantine_tag = 1
                        if (tags[tag_index] == "default") default_tag = 1
                        if (tags[tag_index] == "production" ||
                            tags[tag_index] == "candidate" ||
                            tags[tag_index] == "archive" ||
                            tags[tag_index] == "rejected") {
                            conflicting_tier_tag = 1
                        }
                    }
                    if (!quarantine_tag || default_tag || conflicting_tier_tag) {
                        printf "router preset section %s carries unsafe quarantine tags: %s\n", \
                            section, tags_value > "/dev/stderr"
                        rejected = 1
                    }
                }
            }
            if (include_quarantine != 1 &&
                quarantined_profiles[profile_key]) {
                printf "router preset section %s is excluded by profile quarantine\n", \
                    section > "/dev/stderr"
                rejected = 1
            }
        }
        BEGIN { reset_tuple() }
        FILENAME == "-" {
            if ($0 == "") next
            if ($2 == "model") {
                quarantined_models[$3] = 1
            } else if ($2 == "profile") {
                profile_key = $3 SUBSEP $5 SUBSEP $6 SUBSEP $7 SUBSEP \
                    $8 SUBSEP $9 SUBSEP $10
                quarantined_profiles[profile_key] = 1
            }
            next
        }
        FILENAME == ARGV[2] {
            if ($0 ~ /^[[:space:]]*($|#)/) next
            registry_count[$1]++
            registry_model[$1] = $3
            registry_context[$1] = $5
            registry_ceiling[$1] = $6
            registry_id_by_model_file[$3] = $1
            registry_rows_by_model_file[$3]++
            registry_cache_k[$1] = $8
            registry_cache_v[$1] = $9
            registry_flash[$1] = $10
            registry_tier[$1] = $16
            registry_batch[$1] = $17
            registry_ubatch[$1] = $18
            registry_filled_depth[$1] = $19
            registry_switch_policy[$1] = $26
            next
        }
        /^[[:space:]]*($|[#;])/ { next }
        /^[[:space:]]*\[/ {
            finish_section()
            section = $0
            if (section !~ /^[[:space:]]*\[[^]]+\][[:space:]]*$/) {
                printf "router preset carries malformed section header: %s\n", \
                    section > "/dev/stderr"
                rejected = 1
                section = ""
                reset_tuple()
                next
            }
            sub(/^[[:space:]]*\[/, "", section)
            sub(/\][[:space:]]*$/, "", section)
            if (section != "*" && seen_sections[section]++) {
                printf "router preset repeats section: %s\n", section > "/dev/stderr"
                rejected = 1
            }
            reset_tuple()
            next
        }
        {
            if (section == "" || section == "*") next
            separator = index($0, "=")
            if (separator == 0) next
            key = substr($0, 1, separator - 1)
            value = substr($0, separator + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            if (key == "LLAMA_ARG_MODEL") {
                model_count++
                model_value = value
            } else if (key == "LLAMA_ARG_CTX_SIZE") {
                context_count++
                context_value = value
            } else if (key == "LLAMA_ARG_CACHE_TYPE_K") {
                cache_k_count++
                cache_k_value = value
            } else if (key == "LLAMA_ARG_CACHE_TYPE_V") {
                cache_v_count++
                cache_v_value = value
            } else if (key == "LLAMA_ARG_FLASH_ATTN") {
                flash_count++
                flash_value = value
            } else if (key == "LLAMA_ARG_BATCH") {
                batch_count++
                batch_value = value
            } else if (key == "LLAMA_ARG_UBATCH") {
                ubatch_count++
                ubatch_value = value
            } else if (key == "LLAMA_ARG_TAGS") {
                tags_count++
                tags_value = value
            }
        }
        END {
            finish_section()
            if (model_sections == 0) {
                print "router preset carries no model section" > "/dev/stderr"
                rejected = 1
            }
            exit rejected
        }
    ' - "$1" "$2"
}

case $bind_host in
    127.0.0.1 | localhost | 0.0.0.0) ;;
    *[!0-9.]* | '')
        printf 'bind host must be 127.0.0.1, localhost, 0.0.0.0, or an IPv4 address: %s\n' \
            "$bind_host" >&2
        exit 2
        ;;
esac

# The API key is optional at every bind address. A key authenticates callers on
# a shared network; it grants no capability the model itself withholds, so a
# trusted network serves without one and reaches the page directly.
if [ -n "$api_key_file" ] && [ -z "$static_path" ]; then
    printf 'an API key file requires a static path\n' >&2
    exit 2
fi

if [ ! -x "$llama_server" ]; then
    printf 'llama-server is not executable: %s\n' "$llama_server" >&2
    exit 2
fi

if [ ! -f "$model_path" ]; then
    printf 'model is not a regular file: %s\n' "$model_path" >&2
    exit 2
fi

case $context_size in
    '' | *[!0-9]*)
        printf 'context size must be a positive integer\n' >&2
        exit 2
        ;;
esac

if [ "$context_size" -eq 0 ]; then
    printf 'context size must be a positive integer\n' >&2
    exit 2
fi

# Router children take their complete tuple from the preset file. The model path
# supplied to this process is only the largest installed preflight subject, so
# applying that one row's context ceiling to the router-wide listener rejects a
# valid preset whose sections each carry their own admitted depth.
if [ "$router_enabled" != 1 ]; then
# The admitted depth is a property of the checkpoint rather than of the
# appliance: KV cost scales with full-attention layer count and key-value head
# width, so the 9B pays more per token of context than the 2B at the same
# depth. scripts/models.tsv carries one ceiling per row and this gate reads it.
# A checkpoint outside the registry keeps the depth that the 24K allocation of
# 2,974 MiB was measured against.
registry_ceiling=$("$script_directory/model-registry.sh" path "$model_path" \
    context_ceiling 2>/dev/null) || registry_ceiling=''
case $registry_ceiling in
    '' | *[!0-9]*) registry_ceiling=24576 ;;
esac

# Cache representation, Flash Attention, and context depth form one admission
# tuple. A registry ceiling belongs only to the tuple stored in that row. An
# experiment that changes any member supplies its own positive conservative
# ceiling explicitly; silently reusing the registered ceiling would present an
# unvalidated allocation as admitted policy.
registry_cache_type_k=$("$script_directory/model-registry.sh" path "$model_path" \
    cache_type_k 2>/dev/null) || registry_cache_type_k=''
registry_cache_type_v=$("$script_directory/model-registry.sh" path "$model_path" \
    cache_type_v 2>/dev/null) || registry_cache_type_v=''
registry_flash_attention=$("$script_directory/model-registry.sh" path "$model_path" \
    flash_attention 2>/dev/null) || registry_flash_attention=''
[ -n "$registry_cache_type_k" ] || registry_cache_type_k=q8_0
[ -n "$registry_cache_type_v" ] || registry_cache_type_v=q4_0
[ -n "$registry_flash_attention" ] || registry_flash_attention=on

cache_type_k=${QWEN_CACHE_TYPE_K:-$registry_cache_type_k}
cache_type_v=${QWEN_CACHE_TYPE_V:-$registry_cache_type_v}
flash_attention=${QWEN_FLASH_ATTN:-$registry_flash_attention}
for cache_type in "$cache_type_k" "$cache_type_v"; do
    if ! "$script_directory/model-registry.sh" validate-cache-type "$cache_type"; then
        printf 'cache type is outside the set llama-server accepts: %s\n' \
            "$cache_type" >&2
        exit 2
    fi
done
case $flash_attention in
    on | off | auto) ;;
    *)
        printf 'flash attention must be on, off, or auto: %s\n' \
            "$flash_attention" >&2
        exit 2
        ;;
esac

maximum_context_size=$registry_ceiling
if [ "$cache_type_k" != "$registry_cache_type_k" ] ||
   [ "$cache_type_v" != "$registry_cache_type_v" ] ||
   [ "$flash_attention" != "$registry_flash_attention" ]; then
    override_ceiling=${QWEN_CACHE_OVERRIDE_CONTEXT_CEILING:-}
    case $override_ceiling in
        '' | *[!0-9]* | 0)
            printf 'cache-policy overrides require a positive QWEN_CACHE_OVERRIDE_CONTEXT_CEILING\n' >&2
            exit 2
            ;;
    esac
    if [ "$override_ceiling" -gt "$registry_ceiling" ]; then
        printf 'cache override ceiling must not exceed the registered ceiling: %s > %s\n' \
            "$override_ceiling" "$registry_ceiling" >&2
        exit 2
    fi
    maximum_context_size=$override_ceiling
fi
if [ "$context_size" -gt "$maximum_context_size" ]; then
    printf 'context size exceeds the admitted ceiling for this cache policy: %s > %s\n' \
        "$context_size" "$maximum_context_size" >&2
    exit 2
fi

# Submission geometry comes from the row rather than from a constant, because
# the ceiling and the geometry are one claim. At 16384 the same checkpoint,
# cache triple, Flash Attention state, and device wedged the compute ring
# at 2048/512 and completed twice at 128/32, so a depth is admitted under a
# geometry and reading the ceiling without it reads half the measurement.
registry_batch=$("$script_directory/model-registry.sh" path "$model_path" \
    batch 2>/dev/null) || registry_batch=''
registry_ubatch=$("$script_directory/model-registry.sh" path "$model_path" \
    ubatch 2>/dev/null) || registry_ubatch=''
case $registry_batch in '' | *[!0-9]*) registry_batch=128 ;; esac
case $registry_ubatch in '' | *[!0-9]*) registry_ubatch=32 ;; esac
batch_size=${QWEN_BATCH_SIZE:-$registry_batch}
ubatch_size=${QWEN_UBATCH_SIZE:-$registry_ubatch}
for submission_value in "$batch_size" "$ubatch_size"; do
    case $submission_value in
        '' | *[!0-9]* | 0)
            printf 'batch and ubatch must be positive integers: %s\n' \
                "$submission_value" >&2
            exit 2
            ;;
    esac
done
if [ "$ubatch_size" -gt "$batch_size" ]; then
    printf 'ubatch exceeds batch: %s > %s\n' "$ubatch_size" "$batch_size" >&2
    exit 2
fi

# A quarantined profile names a tuple that produced a device failure. The launch
# refuses to construct it rather than warning about it, because the failure it
# reproduces resets the compute ring on a live desktop.
registry_id=$("$script_directory/model-registry.sh" path "$model_path" \
    id 2>/dev/null) || registry_id=''
if [ -n "$registry_id" ]; then
    quarantine_profiles=$("$script_directory/model-registry.sh" \
        quarantine-profiles standalone)
    quarantine_hit=$(awk -F'\t' -v id="$registry_id" \
        -v depth="$context_size" -v batch="$batch_size" \
        -v ubatch="$ubatch_size" -v cache_k="$cache_type_k" \
        -v cache_v="$cache_type_v" -v flash="$flash_attention" '
        $1 == id && $2 == depth && $3 == batch && $4 == ubatch &&
        $5 == cache_k && $6 == cache_v && $7 == flash { print $1; exit }
    ' <<EOF
$quarantine_profiles
EOF
    )
    if [ -n "$quarantine_hit" ]; then
        printf 'this tuple is quarantined: %s at depth %s, batch %s, ubatch %s, K %s, V %s, flash attention %s\n' \
            "$registry_id" "$context_size" "$batch_size" "$ubatch_size" \
            "$cache_type_k" "$cache_type_v" "$flash_attention" >&2
        printf 'the reason record is evidence/quarantine/%s-d%s-b%s-ub%s.md\n' \
            "$registry_id" "$context_size" "$batch_size" "$ubatch_size" >&2
        exit 2
    fi
fi

# The allocation and the validated depth are separate claims and the status line
# carries both, so a served depth above anything measured to fill and decode is
# a visible gap rather than an implied guarantee.
registry_validated_depth=$("$script_directory/model-registry.sh" path \
    "$model_path" validated_filled_depth 2>/dev/null) || registry_validated_depth=''
[ -n "$registry_validated_depth" ] || registry_validated_depth=-
if [ "$registry_validated_depth" = - ]; then
    printf 'depth_validation admitted=%s validated=none geometry=%s/%s\n' \
        "$context_size" "$batch_size" "$ubatch_size" >&2
elif [ "$context_size" -gt "$registry_validated_depth" ]; then
    printf 'depth_validation admitted=%s validated=%s geometry=%s/%s allocation_beyond_validation=yes\n' \
        "$context_size" "$registry_validated_depth" "$batch_size" \
        "$ubatch_size" >&2
else
    printf 'depth_validation admitted=%s validated=%s geometry=%s/%s\n' \
        "$context_size" "$registry_validated_depth" "$batch_size" \
        "$ubatch_size" >&2
fi
fi

case $server_port in
    '' | *[!0-9]*)
        printf 'port must be an integer from 1024 through 65535\n' >&2
        exit 2
        ;;
esac

if [ "$server_port" -lt 1024 ] || [ "$server_port" -gt 65535 ]; then
    printf 'port must be an integer from 1024 through 65535\n' >&2
    exit 2
fi

if [ -n "$static_path" ] && [ ! -f "$static_path/index.html" ]; then
    printf 'static path must contain index.html: %s\n' "$static_path" >&2
    exit 2
fi

if [ -n "$api_key_file" ] && [ ! -s "$api_key_file" ]; then
    printf 'API key file must be a non-empty regular file: %s\n' "$api_key_file" >&2
    exit 2
fi

if env | awk -F= '$1 ~ /^LLAMA_ARG_/ { found = 1 } END { exit !found }'; then
    printf 'LLAMA_ARG_* environment overrides are forbidden by the fixed policy\n' >&2
    exit 2
fi

# Router mode serves every admitted checkpoint behind one listener and lets the
# picker choose per chat. llama-server builds a base preset from this argv,
# strips the SSL, API key, and models-* keys from it, and cascades the rest onto
# each child it spawns, so every guard below reaches the child unchanged and the
# preset file supplies only what differs per checkpoint.
#
# models-max is 1 rather than the upstream default of 4. The 4B alone peaks at
# 2029 MiB of a 2048 MiB VRAM carve-out with 2700 MiB more in GTT, so a second
# resident model competes for a pool already saturated by one. Switching models
# unloads the previous one, which costs a reload and buys a device that fits.
router_presets=${QWEN_ROUTER_PRESETS:-"${HOME:?}/qwen-webui-state/router-presets.ini"}
router_registry=${QWEN_MODEL_REGISTRY:-"$script_directory/models.tsv"}
router_quarantine_registry=${QWEN_QUARANTINE_REGISTRY:-$script_directory/quarantine.tsv}
router_model_root=${QWEN_MODEL_ROOT:-"${HOME:?}/models"}
router_web_profiles_environment=${QWEN_WEB_PROFILES:-}
router_web_profiles=$script_directory/web-profiles.tsv
router_web_profiles_guard_path=-
router_web_profiles_guard_sha256=-
router_max=${QWEN_ROUTER_MAX:-1}
router_preset_expected_sha256=${QWEN_ROUTER_PRESET_SHA256:-}
verify_router_preset_identity() {
    if [ -z "$router_preset_expected_sha256" ]; then
        return 0
    fi
    if [ "${#router_preset_expected_sha256}" -ne 64 ]; then
        printf 'router preset SHA-256 must hold 64 lowercase hexadecimal characters\n' >&2
        return 1
    fi
    case $router_preset_expected_sha256 in
        *[!0-9a-f]*)
            printf 'router preset SHA-256 must hold 64 lowercase hexadecimal characters\n' >&2
            return 1
            ;;
    esac
    if ! router_preset_identity=$(sha256sum "$router_presets"); then
        printf 'router preset identity cannot be measured: %s\n' \
            "$router_presets" >&2
        return 1
    fi
    router_preset_actual_sha256=${router_preset_identity%% *}
    if [ "$router_preset_actual_sha256" != "$router_preset_expected_sha256" ]; then
        printf 'router preset identity changed: expected %s, measured %s\n' \
            "$router_preset_expected_sha256" "$router_preset_actual_sha256" >&2
        return 1
    fi
}
measure_router_authority_identity() {
    authority_name=$1
    authority_path=$2
    if ! authority_identity=$(sha256sum "$authority_path"); then
        printf '%s identity cannot be measured: %s\n' \
            "$authority_name" "$authority_path" >&2
        return 1
    fi
    printf '%s\n' "${authority_identity%% *}"
}
# execution_policy is the security boundary the web ledger states, and a preset
# persists across an edit to it. build-web-presets.sh emits a section only for a
# validator-gated or ui-mediated row and writes that word into LLAMA_ARG_TAGS, so
# a row moved to refused, or removed from the ledger, leaves a persisted section
# launching an MCP configuration the ledger no longer authorizes. The launch
# rejoins each section to the current ledger by its profile_id, which is the
# section name build-web-presets.sh writes, and requires the row to exist, to
# carry an emitting policy, and to carry the same policy the section's tags
# claim: a row moved from validator-gated to ui-mediated leaves a persisted
# LLAMA_ARG_MCP_SERVERS_CONFIG in a section the ledger now says reaches no
# network.
#
# validate_current_router_authorities runs this immediately before the exec, so
# the ledger's last read is one link earlier than the preset and the two
# registries, whose digests qwen-router-exec-guard.sh remeasures after the
# Vulkan wrapper configures the environment.
validate_web_preset_execution_policies() {
    awk -F'\t' -v ledger="$1" -v authorizer_ready="$3" '
        function policy_from_tags(tags,   tag_count, tags_parts, tag_index) {
            tag_count = split(tags, tags_parts, ",")
            for (tag_index = 1; tag_index <= tag_count; tag_index++) {
                if (tags_parts[tag_index] == "validator-gated" ||
                    tags_parts[tag_index] == "ui-mediated" ||
                    tags_parts[tag_index] == "refused") {
                    return tags_parts[tag_index]
                }
            }
            return ""
        }
        function finish_section(   ledger_policy, section_policy) {
            if (section == "" || section == "*") return
            # A review-only section names a vision checkpoint rather than a web
            # profile, so the web ledger holds no row for it and the rejoin that
            # guards an execution grant has nothing to rejoin. What makes it
            # safe is that it holds no grant at all: the tuple validator has
            # already bound it to one registry row at that row own geometry,
            # and an MCP configuration reaching it would arm a tool the page
            # never offers a reviewer, so its absence is required here.
            if (tags_value ~ /(^|,)review-only(,|$)/) {
                if (seen_mcp_configuration) {
                    printf "web preset section %s is review-only and carries LLAMA_ARG_MCP_SERVERS_CONFIG\n", \
                        section > "/dev/stderr"
                    rejected = 1
                }
                return
            }
            if (!(section in ledger_execution_policy)) {
                printf "web preset section %s names a profile the ledger %s no longer carries\n", \
                    section, ledger > "/dev/stderr"
                rejected = 1
                return
            }
            ledger_policy = ledger_execution_policy[section]
            if (ledger_policy != "validator-gated" && ledger_policy != "ui-mediated") {
                printf "web preset section %s carries ledger execution_policy %s, which emits no section\n", \
                    section, ledger_policy > "/dev/stderr"
                rejected = 1
                return
            }
            if (ledger_policy == "validator-gated" && authorizer_ready != 1) {
                printf "web preset section %s requires QWEN_WEB_AUTHORIZER_READY=1\n", \
                    section > "/dev/stderr"
                rejected = 1
            }
            section_policy = policy_from_tags(tags_value)
            if (section_policy != ledger_policy) {
                printf "web preset section %s claims execution_policy %s where the ledger carries %s\n", \
                    section, section_policy, ledger_policy > "/dev/stderr"
                rejected = 1
            }
        }
        FILENAME == ledger {
            if ($0 ~ /^[[:space:]]*($|#)/) next
            ledger_execution_policy[$1] = $12
            next
        }
        /^[[:space:]]*($|[#;])/ { next }
        /^[[:space:]]*\[/ {
            finish_section()
            section = $0
            sub(/^[[:space:]]*\[/, "", section)
            sub(/\][[:space:]]*$/, "", section)
            tags_value = ""
            seen_mcp_configuration = 0
            next
        }
        {
            if (section == "" || section == "*") next
            separator = index($0, "=")
            if (separator == 0) next
            key = substr($0, 1, separator - 1)
            value = substr($0, separator + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            if (key == "LLAMA_ARG_TAGS") tags_value = value
            if (key == "LLAMA_ARG_MCP_SERVERS_CONFIG") seen_mcp_configuration = 1
        }
        END {
            finish_section()
            exit rejected
        }
    ' "$1" "$2"
}

verify_web_profiles_identity() {
    if [ "$web_presets_from_preset" != 1 ]; then
        return 0
    fi
    if ! web_profiles_identity=$(sha256sum -- "$router_web_profiles"); then
        printf 'web profile ledger identity cannot be measured: %s\n' \
            "$router_web_profiles" >&2
        return 1
    fi
    web_profiles_actual_sha256=${web_profiles_identity%% *}
    if [ "$web_profiles_actual_sha256" != "$router_web_profiles_guard_sha256" ]; then
        printf 'web profile ledger identity changed: expected %s, measured %s\n' \
            "$router_web_profiles_guard_sha256" \
            "$web_profiles_actual_sha256" >&2
        return 1
    fi
}

validate_current_router_authorities() {
    if ! router_quarantine_rows=$(
        "$script_directory/model-registry.sh" quarantine-rows router-child
    ); then
        printf 'router quarantine authority is unavailable\n' >&2
        return 1
    fi
    if ! validate_router_preset_tuples "$router_registry" "$router_presets" \
        "$router_model_root" "$router_quarantine_rows" \
        "$quarantine_override_from_preset" "$web_presets_from_preset" \
        "$web_depth_override_from_preset"; then
        printf 'router presets do not carry complete admitted tuples: %s\n' \
            "$router_presets" >&2
        return 1
    fi
    if [ "$web_presets_from_preset" = 1 ]; then
        verify_web_profiles_identity || return 1
        if [ ! -r "$router_web_profiles" ]; then
            printf 'web profile ledger is unreadable: %s\n' \
                "$router_web_profiles" >&2
            return 1
        fi
        if ! validate_web_preset_execution_policies "$router_web_profiles" \
            "$router_presets" "$router_web_authorizer_ready"; then
            printf 'web preset sections lost their ledger execution grant: %s\n' \
                "$router_presets" >&2
            printf 'regenerate the preset tree with scripts/build-web-presets.sh\n' >&2
            return 1
        fi
    fi
}
if [ "$router_enabled" = 1 ]; then
    if [ ! -r "$router_presets" ]; then
        printf 'router presets are unreadable: %s\n' "$router_presets" >&2
        printf 'generate them with scripts/build-router-presets.sh\n' >&2
        exit 2
    fi
    verify_router_preset_identity || exit 2
    if [ ! -r "$router_registry" ]; then
        printf 'router model registry is unreadable: %s\n' "$router_registry" >&2
        exit 2
    fi
    if [ ! -r "$router_quarantine_registry" ]; then
        printf 'router quarantine authority is unavailable: %s\n' \
            "$router_quarantine_registry" >&2
        exit 2
    fi
    case $router_max in
        '' | *[!0-9]*)
            printf 'router model limit must be a non-negative integer: %s\n' \
                "$router_max" >&2
            exit 2
            ;;
    esac
    # build-web-presets.sh names its sections for profile ids and chooses a
    # depth inside context_ceiling, so its head marker selects the section
    # resolution the tuple validator applies. The marker is the file's own
    # provenance, which is what makes the resolution survive a preset that
    # persists across a later launch.
    web_presets_from_preset=$(sed -n 's/^# qwen_web_presets=\([01]\)$/\1/p' \
        "$router_presets")
    case $web_presets_from_preset in
        '') web_presets_from_preset=0 ;;
        0 | 1) ;;
        *)
            printf 'router presets carry ambiguous web provenance: %s\n' \
                "$router_presets" >&2
            exit 2
            ;;
    esac
    web_profiles_path_from_preset=$(sed -n \
        's/^# qwen_web_profiles_path=//p' "$router_presets")
    web_profiles_sha256_from_preset=$(sed -n \
        's/^# qwen_web_profiles_sha256=//p' "$router_presets")
    if [ "$web_presets_from_preset" = 1 ]; then
        case $web_profiles_path_from_preset in
            /*) ;;
            *)
                printf 'web presets omit an absolute web profile ledger path: %s\n' \
                    "$router_presets" >&2
                exit 2
                ;;
        esac
        if [ "${#web_profiles_sha256_from_preset}" -ne 64 ]; then
            printf 'web preset ledger SHA-256 must hold 64 lowercase hexadecimal characters\n' >&2
            exit 2
        fi
        case $web_profiles_sha256_from_preset in
            *[!0-9a-f]*)
                printf 'web preset ledger SHA-256 must hold 64 lowercase hexadecimal characters\n' >&2
                exit 2
                ;;
        esac
        if [ -n "$router_web_profiles_environment" ] &&
            [ "$router_web_profiles_environment" != "$web_profiles_path_from_preset" ]; then
            printf 'QWEN_WEB_PROFILES names %s where the preset binds %s\n' \
                "$router_web_profiles_environment" \
                "$web_profiles_path_from_preset" >&2
            exit 2
        fi
        router_web_profiles=$web_profiles_path_from_preset
        router_web_profiles_guard_path=$web_profiles_path_from_preset
        router_web_profiles_guard_sha256=$web_profiles_sha256_from_preset
        router_web_authorizer_ready=${QWEN_WEB_AUTHORIZER_READY:-0}
        case $router_web_authorizer_ready in
            0 | 1) ;;
            *)
                printf 'QWEN_WEB_AUTHORIZER_READY must be 0 or 1: %s\n' \
                    "$router_web_authorizer_ready" >&2
                exit 2
                ;;
        esac
    elif [ -n "$web_profiles_path_from_preset$web_profiles_sha256_from_preset" ]; then
        printf 'non-web router presets carry web profile ledger identity markers: %s\n' \
            "$router_presets" >&2
        exit 2
    fi
    # build-web-presets.sh writes this marker when
    # QWEN_WEB_ALLOW_UNVALIDATED_DEPTH admitted a profile whose context exceeds
    # its row's validated_filled_depth or whose depth reads `-`. The preset file
    # carries the marker, so the restriction follows the file across every later
    # launch the way the quarantine provenance does.
    web_depth_override_from_preset=0
    if grep -qx '# qwen-web-presets: unvalidated-depth-override' \
        "$router_presets"; then
        web_depth_override_from_preset=1
    fi
    quarantine_override_from_preset=$(sed -n \
        's/^# qwen_router_include_quarantine=\([01]\)$/\1/p' \
        "$router_presets")
    if [ "$web_presets_from_preset" = 0 ] &&
        grep -qx '# Generated by scripts/build-router-presets.sh from the model registry.' \
        "$router_presets" && [ -z "$quarantine_override_from_preset" ]; then
        printf 'generated router presets omit quarantine provenance; regenerate %s\n' \
            "$router_presets" >&2
        exit 2
    fi
    case $quarantine_override_from_preset in
        '' | 0 | 1) ;;
        *)
            printf 'router presets carry ambiguous quarantine provenance: %s\n' \
                "$router_presets" >&2
            exit 2
            ;;
    esac
    if [ -n "$router_preset_expected_sha256" ]; then
        router_preset_guard_sha256=$router_preset_expected_sha256
    else
        router_preset_guard_sha256=$(measure_router_authority_identity \
            'router preset' "$router_presets") || exit 2
    fi
    router_registry_guard_sha256=$(measure_router_authority_identity \
        'router model registry' "$router_registry") || exit 2
    router_quarantine_guard_sha256=$(measure_router_authority_identity \
        'router quarantine registry' "$router_quarantine_registry") || exit 2
    validate_current_router_authorities || exit 2
    quarantine_override_from_environment=${QWEN_ROUTER_INCLUDE_QUARANTINE:-0}
    case $quarantine_override_from_environment in
        0 | 1) ;;
        *)
            printf 'QWEN_ROUTER_INCLUDE_QUARANTINE must be 0 or 1: %s\n' \
                "$quarantine_override_from_environment" >&2
            exit 2
            ;;
    esac
    # A quarantined checkpoint reaches the picker only through the research
    # override, and it stays on the loopback while it does. The appliance binds
    # 0.0.0.0 so the laptop serves the LAN, and a warning alone would leave a
    # model with a recorded device failure or no validated safe tuple reachable
    # from every host on that network. The bind host is forced rather than
    # refused, so the override runs the experiment it exists for and the
    # exposure it would create does not follow it.
    if [ "$quarantine_override_from_environment" = 1 ] ||
       [ "$quarantine_override_from_preset" = 1 ]; then
        if [ "$bind_host" != 127.0.0.1 ]; then
            printf 'quarantine override forces the listener to loopback: %s -> 127.0.0.1\n' \
                "$bind_host" >&2
            bind_host=127.0.0.1
        fi
    fi
    # A section admitted past its validated_filled_depth serves a depth no run
    # has filled and decoded, so the same restriction applies for the same
    # reason: the appliance binds 0.0.0.0 and a depth that wedged the compute
    # ring reaches every host on the network from there. The bind host is forced
    # rather than refused, so the experiment the override exists for still runs.
    if [ "$web_depth_override_from_preset" = 1 ]; then
        if [ "$bind_host" != 127.0.0.1 ]; then
            printf 'web preset unvalidated-depth override forces the listener to loopback: %s -> 127.0.0.1\n' \
                "$bind_host" >&2
            bind_host=127.0.0.1
        fi
    fi
    set -- "$llama_server" \
        --models-preset "$router_presets" \
        --models-max "$router_max" \
        --host "$bind_host" \
        --port "$server_port" \
        --cors-origins "$cors_origins"
else
    set -- "$llama_server" \
        --model "$model_path" \
        --host "$bind_host" \
        --port "$server_port" \
        --alias qwen-apu \
        --cors-origins "$cors_origins"
fi

if [ -n "$static_path" ]; then
    set -- "$@" --path "$static_path" --ui
else
    set -- "$@" --no-ui
fi

if [ -n "$api_key_file" ]; then
    set -- "$@" --api-key-file "$api_key_file"
fi

# The projector turns images into embeddings the language model consumes; a
# text GGUF alone never gains vision. It must come from the same checkpoint as
# the language weights, which download-qwen35-4b-mmproj.sh pins to the same
# repository revision. Offloading it to Vulkan costs about 672 MiB of a heap
# with over 12 GiB free, and the alternative is running a vision encoder on two
# CPU cores.
if [ -n "${QWEN_MMPROJ:-}" ] && [ "$router_enabled" != 1 ]; then
    if [ ! -f "$QWEN_MMPROJ" ]; then
        printf 'projector is not a regular file: %s\n' "$QWEN_MMPROJ" >&2
        exit 2
    fi
    set -- "$@" --mmproj "$QWEN_MMPROJ"
    if [ "${QWEN_MMPROJ_OFFLOAD:-1}" = 0 ]; then
        set -- "$@" --no-mmproj-offload
    fi
    if [ -n "${QWEN_IMAGE_MAX_TOKENS:-}" ]; then
        set -- "$@" --image-max-tokens "$QWEN_IMAGE_MAX_TOKENS"
    fi
fi

# Speculation is a policy argument rather than an ambient override, so the four
# variables below are the whole surface and LLAMA_ARG_* stays refused above.
# draft-mtp needs no second checkpoint: common_speculative_init_result takes the
# `else if (spec_mtp)` branch and builds the draft context against the target
# model, and llama_model::create_memory filters the MTP KV cache to
# `il >= hparams.n_layer()`, so the draft cache holds the one appended NextN
# block. The 4B distill carries that block at 37,767,168 bytes, which the
# ordinary load reports as an unused tensor and skips.
spec_type=${QWEN_SPEC_TYPE:-}
if [ -n "$spec_type" ]; then
    case $spec_type in
        draft-mtp | ngram-simple | ngram-map-k | ngram-map-k4v | ngram-mod | ngram-cache) ;;
        *)
            printf 'speculation type must be draft-mtp or an ngram type: %s\n' \
                "$spec_type" >&2
            exit 2
            ;;
    esac
    set -- "$@" --spec-type "$spec_type"

    spec_draft_n_max=${QWEN_SPEC_DRAFT_N_MAX:-}
    if [ -n "$spec_draft_n_max" ]; then
        case $spec_draft_n_max in
            '' | *[!0-9]*)
                printf 'draft length must be a non-negative integer: %s\n' \
                    "$spec_draft_n_max" >&2
                exit 2
                ;;
        esac
        # A draft of N tokens makes the target emit N+1 output positions in one
        # pass, and common_speculative_get_output_limits clamps that count to
        # the batch size. Sixteen keeps the product inside the 128-token batch
        # this policy sets.
        if [ "$spec_draft_n_max" -gt 16 ]; then
            printf 'draft length exceeds operational maximum: %s > 16\n' \
                "$spec_draft_n_max" >&2
            exit 2
        fi
        # Zero aborts the pinned server on the first prompt:
        # common_speculative_get_output_limits sizes the target context for
        # `1 + n_draft` outputs while the speculative decode path still asks for
        # two, and llama-context.cpp:2227 asserts
        # `n_outputs_max <= cparams.n_outputs_max`. common/arg.cpp accepts any
        # value at or above zero, so the gate is here.
        if [ "$spec_draft_n_max" -eq 0 ]; then
            printf 'draft length of zero aborts the pinned server; omit QWEN_SPEC_TYPE to disable speculation\n' >&2
            exit 2
        fi
        set -- "$@" --spec-draft-n-max "$spec_draft_n_max"
    fi

    # p_min gates drafting rather than acceptance: common/speculative.cpp reads
    # llama_get_embeddings_nextn and breaks out of the draft loop when the
    # head's confidence falls below it, so a floor of 1 leaves the MTP block
    # loaded and the draft context built while no draft reaches the target.
    spec_draft_p_min=${QWEN_SPEC_DRAFT_P_MIN:-}
    if [ "$spec_draft_p_min" = 0 ]; then
        spec_draft_p_min=''
    fi
    if [ -n "$spec_draft_p_min" ]; then
        case $spec_draft_p_min in
            *[!0-9.]* | '' | *.*.*)
                printf 'draft probability floor must be a decimal fraction: %s\n' \
                    "$spec_draft_p_min" >&2
                exit 2
                ;;
        esac
        set -- "$@" --spec-draft-p-min "$spec_draft_p_min"
    fi

    if [ "${QWEN_SPEC_BACKEND_SAMPLING:-0}" = 1 ]; then
        set -- "$@" --spec-draft-backend-sampling
    fi
fi

# Backend sampling moves the supported sampler chain onto the device. This
# vocabulary is 248,320 entries wide, so the transfer it removes is the largest
# per-token host copy the server makes. It is experimental in the pinned build,
# which is why it is a variable rather than the default.
if [ "${QWEN_BACKEND_SAMPLING:-0}" = 1 ]; then
    set -- "$@" --backend-sampling
fi

# The device is named rather than left to enumeration order. CUDA0 is the one
# serving device: the promoted closure carries the CUDA backend alone, and the
# retained dual-backend diagnostic closure enumerates Vulkan0 for the same card
# and once placed a router child there because nothing named a device.
# QWEN_SERVING_BACKEND takes cuda; `vulkan` named the retired serving path and
# is refused ahead of the argv, since a Vulkan launch is a diagnostic arm run by
# hand under the diagnostic closure rather than a serving configuration.
case ${QWEN_SERVING_BACKEND:-cuda} in
    cuda) ;;
    *)
        printf 'QWEN_SERVING_BACKEND takes cuda: %s\n' "${QWEN_SERVING_BACKEND:-cuda}" >&2
        printf 'Vulkan serving is retired on this host; the dual-backend diagnostic closure runs by hand\n' >&2
        exit 2
        ;;
esac
serving_device=CUDA0
serving_threads=${QWEN_SERVING_THREADS:-6}
case $serving_threads in
    '' | *[!0-9]* | 0)
        printf 'QWEN_SERVING_THREADS must be a positive integer: %s\n' \
            "$serving_threads" >&2
        exit 2
        ;;
esac

set -- "$@" \
    --log-verbosity 4 \
    --device "$serving_device" \
    --split-mode none \
    --n-gpu-layers all \
    --override-tensor ".*=$serving_device" \
    --fit off \
    --parallel 1 \
    --threads "$serving_threads" \
    --threads-batch "$serving_threads" \
    --ctx-checkpoints 0 \
    --cache-ram 0 \
    --no-context-shift \
    --offline

# The six per-checkpoint flags stay off the router's own argv, because
# server-models.cpp ends its preset assembly with `preset.merge(base_preset)`
# and common_preset::merge overwrites, so a router CLI argument replaces the
# same key in every model preset. Setting --ctx-size here served the vision row
# at 24576 where its section named 16384. Router mode therefore leaves depth,
# cache triple, and submission geometry to the preset file, which
# build-router-presets.sh writes from the registry row for every section, and
# the single-model path sets them from the row it launches.
#
# Every section carrying all six is what makes the omission safe: an absent key
# falls through to the llama.cpp defaults, and those are batch 2048 and ubatch
# 512, which is the quarantined geometry.
if [ "$router_enabled" != 1 ]; then
    set -- "$@" \
        --ctx-size "$context_size" \
        --batch-size "$batch_size" \
        --ubatch-size "$ubatch_size" \
        --flash-attn "$flash_attention" \
        --cache-type-k "$cache_type_k" \
        --cache-type-v "$cache_type_v"
fi

# cuda-runtime-env.sh is the one environment wrapper a served launch runs
# through. It scrubs the ambient GGML_CUDA_* and GGML_VK_* names before it
# exports its own profile, so a named profile means one thing whatever the
# caller's shell carried.
runtime_environment_wrapper=$script_directory/cuda-runtime-env.sh
[ -x "$runtime_environment_wrapper" ] || {
    printf 'runtime environment wrapper is absent: %s\n' \
        "$runtime_environment_wrapper" >&2
    exit 1
}
printf 'runtime_environment backend=%s wrapper=%s profile=%s\n' \
    "${QWEN_SERVING_BACKEND:-cuda}" "$(basename "$runtime_environment_wrapper")" \
    "${QWEN_CUDA_PROFILE:-default}"

# This is the active-compute lease, second in the fixed order below the
# top-level owner lock qwen-webui-session.sh holds for the whole serving
# lifetime. The lease covers active compute alone -- model load, evaluation and
# decode, image load and generation, vision review -- so an idle loaded server
# competes with nothing while every decoding pass excludes a generation.
# scripts/image-service.py takes it across one generation and llama-server holds
# it from the first busy slot to the last idle one.
#
# QWEN_GPU_COMPUTE_LEASE is the name. patches/llama-server-vulkan-workload-lease.patch
# still reads QWEN_VULKAN_WORKLOAD_LOCK, so both are exported over one file for
# this transition release; gpu_ownership_lease_path refuses a configuration whose
# two names resolve to different inodes, which is the split the rename exists to
# prevent. Neither wrapper scrubs either name, so both cross the exec boundary
# untouched. In router mode server-models.cpp snapshots environ into base_env at
# server_models_routes construction and spawns every child with that copy, so the
# child executing the graphs opens the lease; the router parent leaves
# server_context uninitialised and opens nothing.
workload_lease_state_directory=${QWEN_WEBUI_STATE_DIRECTORY:-"${HOME:?}/qwen-webui-state"}
export QWEN_GPU_COMPUTE_LEASE="$workload_lease_state_directory/vulkan-workload.lock"
export QWEN_VULKAN_WORKLOAD_LOCK="$QWEN_GPU_COMPUTE_LEASE"
printf 'gpu_compute_lease path=%s legacy_name=QWEN_VULKAN_WORKLOAD_LOCK\n' "$QWEN_GPU_COMPUTE_LEASE"

# The registry decides what the picker offers, so the roster carries the preset
# and nothing else. server-models.cpp calls load_from_cache() and cascades its
# result into the roster beside the preset sections, which puts any model
# llama-server has ever cached in front of a user regardless of tier: three
# archived 27B rows reached the picker that way. A row larger than the device
# carve-out is killed by the kernel as it loads, and the kill takes the router
# with it, so an unadmitted row is a crash rather than a slow answer. Pointing
# LLAMA_CACHE at a directory this session owns leaves that scan with nothing to
# find. common/common.cpp's fs_get_cache_directory reads the variable ahead of
# XDG_CACHE_HOME and HOME, and neither wrapper scrubs it.
roster_cache_directory=$workload_lease_state_directory/router-model-cache
mkdir -p "$roster_cache_directory" || {
    printf 'router model cache directory is not creatable: %s\n' \
        "$roster_cache_directory" >&2
    exit 1
}
export LLAMA_CACHE="$roster_cache_directory"
printf 'roster_cache path=%s entries=%s\n' "$LLAMA_CACHE" \
    "$(find "$roster_cache_directory" -mindepth 1 -maxdepth 1 | wc -l)"

# The launcher hashes its immutable-per-session snapshot before preflight. The
# exec boundary revalidates both mutable registry authorities and measures the
# preset again, so a quarantine or model-registry replacement invalidates the
# assembled server command before llama-server starts.
if [ "$router_enabled" = 1 ]; then
    verify_router_preset_identity || exit 2
    validate_current_router_authorities || exit 2
    exec "$runtime_environment_wrapper" \
        "$script_directory/qwen-router-exec-guard.sh" \
        "$router_presets" "$router_preset_guard_sha256" \
        "$router_registry" "$router_registry_guard_sha256" \
        "$router_quarantine_registry" "$router_quarantine_guard_sha256" \
        "$router_web_profiles_guard_path" \
        "$router_web_profiles_guard_sha256" \
        "$@"
fi

exec "$runtime_environment_wrapper" "$@"
