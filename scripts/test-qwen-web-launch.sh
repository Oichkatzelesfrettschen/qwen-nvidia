#!/bin/sh
set -eu

# Tests scripts/qwen-web-launch.sh and the unvalidated-depth marker that
# scripts/qwen-capacity-policy.sh reads from a web preset file.
#
# The launch arms replace qwen-launch.sh with a recorder, so each one measures
# the environment the wrapper hands the launcher rather than starting a server.
# The policy arms drive the real qwen-capacity-policy.sh with the fake
# llama-server, which is where the loopback restriction is enforced.

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
policy=$script_directory/qwen-capacity-policy.sh
fake_server=$script_directory/test-fixtures/fake-llama-server.sh
failures=0

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

report() {
    printf '%s=%s\n' "$1" "$2"
    [ "$2" = ok ] || failures=$((failures + 1))
}

# The wrapper runs from a directory holding a recorder in place of
# qwen-launch.sh, so the arms read the forwarded environment out of a file.
harness=$work/harness
mkdir -p "$harness"
cp "$script_directory/qwen-web-launch.sh" "$harness/qwen-web-launch.sh"
cat >"$harness/qwen-launch.sh" <<'EOF'
#!/bin/sh
set -eu
{
    printf 'profile=%s\n' "${1:-unset}"
    printf 'QWEN_ROUTER=%s\n' "${QWEN_ROUTER:-unset}"
    printf 'QWEN_ROUTER_PRESETS=%s\n' "${QWEN_ROUTER_PRESETS:-unset}"
    printf 'QWEN_ROUTER_MAX=%s\n' "${QWEN_ROUTER_MAX:-unset}"
    printf 'QWEN_BIND_HOST=%s\n' "${QWEN_BIND_HOST:-unset}"
    printf 'QWEN_WEB_BROKER=%s\n' "${QWEN_WEB_BROKER:-unset}"
    printf 'QWEN_WEB_BROKER_PORT=%s\n' "${QWEN_WEB_BROKER_PORT:-unset}"
    printf 'QWEN_WEB_STATE_DIR=%s\n' "${QWEN_WEB_STATE_DIR:-unset}"
    printf 'QWEN_WEB_TOKEN_KEY_FILE=%s\n' "${QWEN_WEB_TOKEN_KEY_FILE:-unset}"
    printf 'QWEN_WEB_PROFILE=%s\n' "${QWEN_WEB_PROFILE:-unset}"
    printf 'QWEN_WEB_PROVIDER=%s\n' "${QWEN_WEB_PROVIDER:-unset}"
    printf 'QWEN_WEB_PROFILES=%s\n' "${QWEN_WEB_PROFILES:-unset}"
    printf 'QWEN_STATIC_PATH=%s\n' "${QWEN_STATIC_PATH:-unset}"
    printf 'QWEN_REQUIRE_API_KEY=%s\n' "${QWEN_REQUIRE_API_KEY:-unset}"
} >"$QWEN_WEB_LAUNCH_RECORD"
EOF
chmod +x "$harness/qwen-launch.sh"
launcher=$harness/qwen-web-launch.sh
# The wrapper serves the fallback page beside its own directory, so the
# harness carries a page holding the two route shapes the wrapper reads for.
mkdir -p "$work/webui"
# shellcheck disable=SC2016
printf '%s\n' 'fetch(`./tools?model=${encodeURIComponent(selectedModel)}&autoload=true`)' \
    'JSON.stringify({ model, tool: toolName, params, stream: false })' \
    >"$work/webui/index.html"

# The control process crosses a separate tmux server before the session starts.
# A fake tmux records the new-session command and proves the API-key requirement
# and authorizer-readiness decision survive that boundary.
control_harness=$work/control-harness
control_bin=$work/control-bin
mkdir -p "$control_harness" "$control_bin"
cp "$script_directory/qwen-webui-control.sh" \
    "$control_harness/qwen-webui-control.sh"
cat >"$control_bin/tmux" <<'EOF'
#!/bin/sh
set -eu
case " $* " in
    *" has-session "*) exit 1 ;;
    *" new-session "*)
        for tmux_argument in "$@"; do
            session_command=$tmux_argument
        done
        printf '%s\n' "$session_command" >"$QWEN_TMUX_RECORD"
        sh -c "$session_command"
        ;;
    *) exit 2 ;;
esac
EOF
chmod +x "$control_bin/tmux"
cat >"$control_harness/qwen-webui-session.sh" <<'EOF'
#!/bin/sh
set -eu
{
    printf 'state_directory=%s\n' "$7"
    printf 'server=%s\n' "$1"
    printf 'model=%s\n' "$2"
    printf 'broker_program=%s\n' "${QWEN_WEB_BROKER_PROGRAM:-unset}"
    printf 'broker_state=%s\n' "${QWEN_WEB_STATE_DIR:-unset}"
    printf 'token_key=%s\n' "${QWEN_WEB_TOKEN_KEY_FILE:-unset}"
    printf 'broker_origin=%s\n' "${QWEN_WEB_BROKER_ORIGIN:-unset}"
    printf 'api_key=%s\n' "${QWEN_REQUIRE_API_KEY:-unset}"
    printf 'authorizer=%s\n' "${QWEN_WEB_AUTHORIZER_READY:-unset}"
} >"$QWEN_CONTROL_SESSION_RECORD"
EOF
chmod +x "$control_harness/qwen-webui-session.sh"
control_record=$work/control-tmux.record
control_session_record=$work/control-session.record
if PATH="$control_bin:$PATH" QWEN_TMUX_RECORD=$control_record \
    QWEN_CONTROL_SESSION_RECORD=$control_session_record \
    QWEN_WEBUI_STATE_DIRECTORY="$work/control state" \
    QWEN_LLAMA_SERVER="$work/fake server" QWEN_MODEL_PATH="$work/fake model" \
    QWEN_WEB_BROKER_PROGRAM="$work/broker program.py" \
    QWEN_WEB_STATE_DIR="$work/broker state" \
    QWEN_WEB_TOKEN_KEY_FILE="$work/token key" \
    QWEN_WEB_BROKER_ORIGIN=http://127.0.0.1:18080 \
    QWEN_REQUIRE_API_KEY=1 QWEN_WEB_AUTHORIZER_READY=1 \
    "$control_harness/qwen-webui-control.sh" start custom \
    >"$work/control.log" 2>"$work/control.err"; then
    outcome=ok
    grep -qx 'api_key=1' "$control_session_record" ||
        outcome=api_key_requirement_dropped
    grep -qx 'authorizer=1' "$control_session_record" ||
        outcome=authorizer_readiness_dropped
    grep -Fqx "state_directory=$work/control state" "$control_session_record" ||
        outcome=state_directory_split
    grep -Fqx "server=$work/fake server" "$control_session_record" ||
        outcome=server_path_split
    grep -Fqx "model=$work/fake model" "$control_session_record" ||
        outcome=model_path_split
    grep -Fqx "broker_program=$work/broker program.py" "$control_session_record" ||
        outcome=broker_program_split
    grep -Fqx "broker_state=$work/broker state" "$control_session_record" ||
        outcome=broker_state_split
    grep -Fqx "token_key=$work/token key" "$control_session_record" ||
        outcome=token_key_split
    grep -qx 'broker_origin=http://127.0.0.1:18080' "$control_session_record" ||
        outcome=broker_origin_dropped
    report control_forwards_web_authority "$outcome"
else
    report control_forwards_web_authority failed
    cat "$work/control.err" >&2
fi

cat >"$control_bin/ssh" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$@" >"$QWEN_SSH_RECORD"
EOF
chmod +x "$control_bin/ssh"
ssh_record=$work/connect-ssh.record
if PATH="$control_bin:$PATH" QWEN_SSH_RECORD=$ssh_record \
    "$script_directory/connect-qwen-webui.sh" fixture-host 18080 8080 \
    >"$work/connect.log" 2>"$work/connect.err"; then
    outcome=ok
    grep -Fqx '127.0.0.1:18080:127.0.0.1:8080' "$ssh_record" ||
        outcome=server_tunnel_absent
    grep -Fqx '127.0.0.1:8571:127.0.0.1:8571' "$ssh_record" ||
        outcome=broker_tunnel_absent
    grep -Fq 'QWEN_WEB_BROKER_ORIGIN=http://127.0.0.1:18080' \
        "$work/connect.log" || outcome=browser_origin_unreported
    report connect_forwards_server_and_broker "$outcome"
else
    report connect_forwards_server_and_broker failed
    cat "$work/connect.err" >&2
fi

# Every launch below carries a usable signing key, because the wrapper requires
# one before it forwards anything; the arms that test the key rules override
# this path with their own.
token_key_file=$work/token.key
printf 'fixture-signing-key\n' >"$token_key_file"
chmod 600 "$token_key_file"
QWEN_WEB_TOKEN_KEY_FILE=$token_key_file
export QWEN_WEB_TOKEN_KEY_FILE
QWEN_WEB_AUTHORIZER_READY=1
export QWEN_WEB_AUTHORIZER_READY

state_directory=$work/state
mkdir -p "$state_directory/web-mcp-configs"
mcp_config=$state_directory/web-mcp-configs/web-fixture.json
printf '{}\n' >"$mcp_config"

web_profiles=$work/web-profiles.tsv
write_web_profiles() {
    printf '# profile_id\tmodel_id\tweb_mode\tcontext\tvalidated_filled_depth\tmax_results\tmax_fetches\tmax_chars_per_fetch\tmulti_source\tvision_allowed\ttool_selection\texecution_policy\tprovider\tprimary_category\tfallback_category\tminimum_results\tsearxng_url\n' \
        >"$2"
    printf 'web-fixture\tfixture-production\tvalidator-gated\t8192\t16384\t5\t2\t12000\tyes\tno\t9/10\t%s\texa\t-\t-\t-\t-\n' \
        "$1" >>"$2"
}
write_web_profiles validator-gated "$web_profiles"

write_web_preset() {
    web_preset_path=$1
    web_preset_marker=$2
    web_preset_provider=${3:-exa}
    {
        printf '# Generated by scripts/build-web-presets.sh from scripts/web-profiles.tsv.\n'
        printf '# qwen_web_presets=1\n'
        printf '# qwen_web_profiles_path=%s\n' "$web_profiles"
        printf '# qwen_web_profiles_sha256=%s\n' \
            "$(sha256sum "$web_profiles" | cut -d' ' -f1)"
        printf '# qwen_web_provider=%s\n' "$web_preset_provider"
        if [ "$web_preset_marker" = marked ]; then
            printf '# qwen-web-presets: unvalidated-depth-override\n'
        fi
        printf '\n'
        printf '[web-fixture]\n'
        printf 'LLAMA_ARG_MODEL = %s\n' "$policy_model_root/Fixture-GGUF/production.gguf"
        printf 'LLAMA_ARG_ALIAS = web-fixture\n'
        printf 'LLAMA_ARG_CTX_SIZE = 8192\n'
        printf 'LLAMA_ARG_CACHE_TYPE_K = q8_0\n'
        printf 'LLAMA_ARG_CACHE_TYPE_V = q4_0\n'
        printf 'LLAMA_ARG_FLASH_ATTN = on\n'
        printf 'LLAMA_ARG_BATCH = 128\n'
        printf 'LLAMA_ARG_UBATCH = 32\n'
        printf 'LLAMA_ARG_MCP_SERVERS_CONFIG = %s\n' "$mcp_config"
        printf 'LLAMA_ARG_TAGS = web-research,validator-gated\n'
        printf '\n'
    } >"$web_preset_path"
}

policy_model_root=$work/model-root
mkdir -p "$policy_model_root/Fixture-GGUF"
: >"$policy_model_root/Fixture-GGUF/production.gguf"

web_presets=$state_directory/web-presets.ini
write_web_preset "$web_presets" unmarked

record=$work/launch.record

# The wrapper sets router mode, the web preset file, a single resident model,
# and the loopback listener.
if QWEN_WEBUI_STATE_DIRECTORY=$state_directory \
    QWEN_WEB_LAUNCH_RECORD=$record \
    env -u QWEN_BIND_HOST "$launcher" no-graphs \
    >"$work/launch.log" 2>"$work/launch.err"; then
    outcome=ok
    grep -qx 'QWEN_ROUTER=1' "$record" || outcome=router_unset
    grep -qx "QWEN_ROUTER_PRESETS=$web_presets" "$record" || outcome=wrong_presets
    grep -qx 'QWEN_ROUTER_MAX=1' "$record" || outcome=wrong_models_max
    grep -qx 'QWEN_BIND_HOST=127.0.0.1' "$record" || outcome=wrong_bind_host
    grep -qx 'profile=no-graphs' "$record" || outcome=profile_dropped
    grep -qx "QWEN_STATIC_PATH=$harness/../webui" "$record" || outcome=static_path_dropped
    grep -qx 'QWEN_REQUIRE_API_KEY=1' "$record" || outcome=api_key_not_required
    report wrapper_forwards_web_router_environment "$outcome"
    broker_outcome=ok
    grep -qx 'QWEN_WEB_BROKER=1' "$record" || broker_outcome=marker_unset
    grep -qx 'QWEN_WEB_BROKER_PORT=8571' "$record" ||
        broker_outcome=wrong_broker_port
    grep -qx "QWEN_WEB_STATE_DIR=$state_directory/web-mcp" "$record" ||
        broker_outcome=wrong_broker_state_dir
    report wrapper_exports_broker_marker "$broker_outcome"
else
    report wrapper_forwards_web_router_environment failed
    cat "$work/launch.err" >&2
fi

if QWEN_WEBUI_STATE_DIRECTORY=$state_directory \
    QWEN_WEB_LAUNCH_RECORD=$record \
    env -u QWEN_BIND_HOST -u QWEN_WEB_AUTHORIZER_READY "$launcher" \
    >"$work/authorizer-absent.log" 2>"$work/authorizer-absent.err"; then
    report validator_gated_launch_requires_authorizer accepted
elif grep -q 'validator-gated web presets require QWEN_WEB_AUTHORIZER_READY=1' \
    "$work/authorizer-absent.err"; then
    report validator_gated_launch_requires_authorizer ok
else
    report validator_gated_launch_requires_authorizer missing_message
fi

# The signing key travels as a path the wrapper reads before the launch, and a
# key file the broker cannot read refuses here rather than at the first
# approval a human has already given.
if QWEN_WEBUI_STATE_DIRECTORY=$state_directory \
    QWEN_WEB_LAUNCH_RECORD=$record \
    QWEN_WEB_TOKEN_KEY_FILE=$work/absent-token.key \
    env -u QWEN_BIND_HOST "$launcher" \
    >"$work/absent-key.log" 2>"$work/absent-key.err"; then
    report unreadable_signing_key_refused accepted
else
    outcome=ok
    grep -q 'grant signing key is not a regular file' "$work/absent-key.err" ||
        outcome=missing_message
    report unreadable_signing_key_refused "$outcome"
fi

if QWEN_WEBUI_STATE_DIRECTORY=$state_directory \
    QWEN_WEB_LAUNCH_RECORD=$record \
    QWEN_WEB_BROKER_PORT=18571 \
    env -u QWEN_BIND_HOST "$launcher" \
    >"$work/key.log" 2>"$work/key.err"; then
    outcome=ok
    grep -qx "QWEN_WEB_TOKEN_KEY_FILE=$token_key_file" "$record" ||
        outcome=key_path_dropped
    grep -qx 'QWEN_WEB_BROKER_PORT=18571' "$record" || outcome=port_override_dropped
    grep -q 'signing_key=configured' "$work/key.log" || outcome=key_state_unreported
    if grep -q 'fixture-signing-key' "$work/key.log" "$work/key.err"; then
        outcome=key_contents_printed
    fi
    grep -qx 'QWEN_WEB_PROFILE=web-fixture' "$record" || outcome=profile_underived
    grep -qx 'QWEN_WEB_PROVIDER=exa' "$record" || outcome=provider_default_dropped
    grep -q 'profile=web-fixture provider=exa' "$work/key.log" ||
        outcome=profile_unreported
    report signing_key_path_forwarded "$outcome"
else
    report signing_key_path_forwarded refused
    cat "$work/key.err" >&2
fi

# The key rules the broker applies at its own startup refuse here first, where
# the message names the rule; the key contents stay out of every line.
signing_key_arm() {
    arm_name=$1
    arm_key=$2
    arm_message=$3
    if QWEN_WEBUI_STATE_DIRECTORY=$state_directory \
        QWEN_WEB_LAUNCH_RECORD=$record \
        QWEN_WEB_TOKEN_KEY_FILE=$arm_key \
        env -u QWEN_BIND_HOST "$launcher" \
        >"$work/$arm_name.log" 2>"$work/$arm_name.err"; then
        report "$arm_name" accepted
    else
        outcome=ok
        grep -q "grant signing key $arm_message" "$work/$arm_name.err" ||
            outcome=missing_message
        report "$arm_name" "$outcome"
    fi
}
if env -u QWEN_WEB_TOKEN_KEY_FILE QWEN_WEBUI_STATE_DIRECTORY=$state_directory \
    QWEN_WEB_LAUNCH_RECORD=$record env -u QWEN_BIND_HOST "$launcher" \
    >"$work/unset-key.log" 2>"$work/unset-key.err"; then
    report unset_signing_key_refused accepted
else
    outcome=ok
    grep -q 'grant signing key is unset' "$work/unset-key.err" || outcome=missing_message
    report unset_signing_key_refused "$outcome"
fi
open_key=$work/open.key
printf 'open-signing-key\n' >"$open_key"
chmod 644 "$open_key"
signing_key_arm group_readable_signing_key_refused "$open_key" 'carries mode 644'
linked_key=$work/linked.key
ln -s "$token_key_file" "$linked_key"
signing_key_arm symlinked_signing_key_refused "$linked_key" 'is a symbolic link'
empty_key=$work/empty.key
: >"$empty_key"
chmod 600 "$empty_key"
signing_key_arm empty_signing_key_refused "$empty_key" 'is empty'

# One broker signs for one profile, so the preset supplies the profile and a
# second section or a contradicting QWEN_WEB_PROFILE refuses the launch.
two_section_presets=$state_directory/web-presets-two.ini
write_web_preset "$two_section_presets" unmarked
sed 's/^\[web-fixture\]$/[web-second]/; s/^LLAMA_ARG_ALIAS = web-fixture$/LLAMA_ARG_ALIAS = web-second/' \
    "$web_presets" | grep -v '^#' >>"$two_section_presets"
if QWEN_WEBUI_STATE_DIRECTORY=$state_directory \
    QWEN_WEB_PRESETS=$two_section_presets QWEN_WEB_LAUNCH_RECORD=$record \
    env -u QWEN_BIND_HOST "$launcher" \
    >"$work/two.log" 2>"$work/two.err"; then
    report two_section_preset_refused accepted
else
    outcome=ok
    grep -q 'carries 2 sections' "$work/two.err" || outcome=missing_message
    report two_section_preset_refused "$outcome"
fi
# QWEN_WEB_REVIEW_SECTION admits exactly one more section, the review-only
# vision row qwen-image-launch.sh proved resident. The broker still signs for
# the one language profile, so the review section is subtracted before the
# profile is read and the router holds two children rather than one.
review_presets=$state_directory/web-presets-review.ini
review_projector=$policy_model_root/Fixture-GGUF/review-mmproj.gguf
: >"$review_projector"
write_web_preset "$review_presets" unmarked
{
    printf '[vision-fixture]\n'
    printf 'LLAMA_ARG_MODEL = %s\n' "$policy_model_root/Fixture-GGUF/production.gguf"
    printf 'LLAMA_ARG_ALIAS = vision-fixture\n'
    printf 'LLAMA_ARG_CTX_SIZE = 8192\n'
    printf 'LLAMA_ARG_CACHE_TYPE_K = q8_0\n'
    printf 'LLAMA_ARG_CACHE_TYPE_V = q4_0\n'
    printf 'LLAMA_ARG_FLASH_ATTN = on\n'
    printf 'LLAMA_ARG_BATCH = 128\n'
    printf 'LLAMA_ARG_UBATCH = 32\n'
    printf 'LLAMA_ARG_MMPROJ = %s\n' "$review_projector"
    printf 'LLAMA_ARG_TAGS = vision-review,review-only\n'
    printf '\n'
} >>"$review_presets"
if QWEN_WEBUI_STATE_DIRECTORY=$state_directory \
    QWEN_WEB_PRESETS=$review_presets QWEN_WEB_LAUNCH_RECORD=$record \
    QWEN_WEB_REVIEW_SECTION=vision-fixture \
    env -u QWEN_BIND_HOST "$launcher" \
    >"$work/review.log" 2>"$work/review.err"; then
    outcome=ok
    grep -qx 'QWEN_ROUTER_MAX=2' "$record" || outcome=wrong_models_max
    grep -qx 'QWEN_WEB_PROFILE=web-fixture' "$record" || outcome=wrong_profile
    grep -q 'review_section=vision-fixture models_max=2' "$work/review.log" ||
        outcome=unreported
    report review_section_admits_two_sections "$outcome"
else
    report review_section_admits_two_sections refused
    cat "$work/review.err" >&2
fi

# The marker names a section rather than raising the limit on its own, so one
# that survived a regeneration refuses instead of admitting a second child the
# preset never carries.
if QWEN_WEBUI_STATE_DIRECTORY=$state_directory \
    QWEN_WEB_LAUNCH_RECORD=$record QWEN_WEB_REVIEW_SECTION=vision-absent \
    env -u QWEN_BIND_HOST "$launcher" \
    >"$work/review-absent.log" 2>"$work/review-absent.err"; then
    report absent_review_section_refused accepted
else
    outcome=ok
    grep -q 'QWEN_WEB_REVIEW_SECTION names vision-absent' \
        "$work/review-absent.err" || outcome=missing_message
    report absent_review_section_refused "$outcome"
fi

if QWEN_WEBUI_STATE_DIRECTORY=$state_directory \
    QWEN_WEB_LAUNCH_RECORD=$record QWEN_WEB_PROFILE=web-other \
    env -u QWEN_BIND_HOST "$launcher" \
    >"$work/mismatch.log" 2>"$work/mismatch.err"; then
    report profile_mismatch_refused accepted
else
    outcome=ok
    grep -q 'QWEN_WEB_PROFILE names web-other where the preset serves web-fixture' \
        "$work/mismatch.err" || outcome=missing_message
    report profile_mismatch_refused "$outcome"
fi
if QWEN_WEBUI_STATE_DIRECTORY=$state_directory \
    QWEN_WEB_LAUNCH_RECORD=$record QWEN_WEB_PROVIDER=other \
    env -u QWEN_BIND_HOST "$launcher" \
    >"$work/provider.log" 2>"$work/provider.err"; then
    report unknown_provider_refused accepted
else
    outcome=ok
    grep -q 'QWEN_WEB_PROVIDER names other where the preset serves exa' \
        "$work/provider.err" ||
        outcome=missing_message
    report unknown_provider_refused "$outcome"
fi
# A page without the model-scoped routes is refused before any launch, since
# the pinned llama UI build is what an unset static path would otherwise serve.
other_page=$work/other-ui
mkdir -p "$other_page"
printf '<html>upstream ui</html>\n' >"$other_page/index.html"
if QWEN_WEBUI_STATE_DIRECTORY=$state_directory \
    QWEN_WEB_LAUNCH_RECORD=$record QWEN_STATIC_PATH=$other_page \
    env -u QWEN_BIND_HOST "$launcher" \
    >"$work/static.log" 2>"$work/static.err"; then
    report foreign_page_refused accepted
else
    outcome=ok
    grep -q 'composes no model-scoped /tools request' "$work/static.err" ||
        outcome=missing_message
    report foreign_page_refused "$outcome"
fi
fake_provider_presets=$state_directory/web-presets-fake.ini
write_web_preset "$fake_provider_presets" unmarked fake
if QWEN_WEBUI_STATE_DIRECTORY=$state_directory \
    QWEN_WEB_PRESETS=$fake_provider_presets \
    QWEN_WEB_LAUNCH_RECORD=$record QWEN_WEB_PROFILES=$web_profiles \
    env -u QWEN_BIND_HOST "$launcher" \
    >"$work/ledger.log" 2>"$work/ledger.err"; then
    outcome=ok
    grep -qx "QWEN_WEB_PROFILES=$web_profiles" "$record" || outcome=ledger_dropped
    grep -qx 'QWEN_WEB_PROVIDER=fake' "$record" || outcome=provider_dropped
    report preset_provider_derived_and_forwarded "$outcome"
else
    report preset_provider_derived_and_forwarded refused
    cat "$work/ledger.err" >&2
fi

# The marker state and the authorizer setting are reported before the launch.
if grep -q 'unvalidated_depth_marker=absent' "$work/launch.log" &&
    grep -q 'authorizer_ready=1' "$work/launch.log"; then
    report wrapper_reports_marker_and_authorizer_state ok
else
    report wrapper_reports_marker_and_authorizer_state missing_report
fi

marked_presets=$state_directory/web-presets-marked.ini
write_web_preset "$marked_presets" marked
if QWEN_WEBUI_STATE_DIRECTORY=$state_directory \
    QWEN_WEB_PRESETS=$marked_presets QWEN_WEB_LAUNCH_RECORD=$record \
    QWEN_WEB_AUTHORIZER_READY=1 \
    env -u QWEN_BIND_HOST "$launcher" \
    >"$work/marked.log" 2>"$work/marked.err"; then
    outcome=ok
    grep -q 'unvalidated_depth_marker=present' "$work/marked.log" ||
        outcome=marker_unreported
    grep -q 'authorizer_ready=1' "$work/marked.log" ||
        outcome=authorizer_unreported
    report wrapper_reports_present_marker "$outcome"
else
    report wrapper_reports_present_marker failed
    cat "$work/marked.err" >&2
fi

# A caller asking for a LAN listener is refused rather than served on the
# loopback while believing the LAN listens.
for lan_bind_host in 0.0.0.0 192.168.1.10; do
    if QWEN_WEBUI_STATE_DIRECTORY=$state_directory \
        QWEN_WEB_LAUNCH_RECORD=$record QWEN_BIND_HOST=$lan_bind_host \
        "$launcher" >"$work/lan.log" 2>"$work/lan.err"; then
        report "lan_bind_refused_$lan_bind_host" accepted
    else
        outcome=ok
        grep -q 'serves the loopback alone' "$work/lan.err" ||
            outcome=missing_message
        report "lan_bind_refused_$lan_bind_host" "$outcome"
    fi
done

# An explicit loopback request is honoured rather than refused.
if QWEN_WEBUI_STATE_DIRECTORY=$state_directory \
    QWEN_WEB_LAUNCH_RECORD=$record QWEN_BIND_HOST=127.0.0.1 \
    "$launcher" >"$work/loopback.log" 2>"$work/loopback.err"; then
    report explicit_loopback_admitted ok
else
    report explicit_loopback_admitted refused
    cat "$work/loopback.err" >&2
fi

# A section naming an MCP configuration the launch cannot read refuses before
# the listener comes up, where llama-server would report a child startup fault.
absent_mcp_presets=$state_directory/web-presets-absent-mcp.ini
write_web_preset "$absent_mcp_presets" unmarked
sed -i 's|^LLAMA_ARG_MCP_SERVERS_CONFIG = .*|LLAMA_ARG_MCP_SERVERS_CONFIG = /nonexistent/web-mcp.json|' \
    "$absent_mcp_presets"
if QWEN_WEBUI_STATE_DIRECTORY=$state_directory \
    QWEN_WEB_PRESETS=$absent_mcp_presets QWEN_WEB_LAUNCH_RECORD=$record \
    env -u QWEN_BIND_HOST "$launcher" \
    >"$work/absent-mcp.log" 2>"$work/absent-mcp.err"; then
    report absent_mcp_config_refused accepted
else
    outcome=ok
    grep -q 'unreadable MCP configuration' "$work/absent-mcp.err" ||
        outcome=missing_message
    report absent_mcp_config_refused "$outcome"
fi

# A vision section names its projector in LLAMA_ARG_MMPROJ, which router mode
# reads when the request selects that child. A preset persists across the
# generation that resolved the file, so a projector deleted or moved since then
# refuses the launch rather than leaving the listener ready and the image
# request answered from nothing.
projector_path=$policy_model_root/Fixture-GGUF/mmproj-F16.gguf
: >"$projector_path"
present_projector_presets=$state_directory/web-presets-projector.ini
write_web_preset "$present_projector_presets" unmarked
printf 'LLAMA_ARG_MMPROJ = %s\n' "$projector_path" >>"$present_projector_presets"
if QWEN_WEBUI_STATE_DIRECTORY=$state_directory \
    QWEN_WEB_PRESETS=$present_projector_presets QWEN_WEB_LAUNCH_RECORD=$record \
    env -u QWEN_BIND_HOST "$launcher" \
    >"$work/projector-present.log" 2>"$work/projector-present.err"; then
    report present_projector_admitted ok
else
    report present_projector_admitted refused
    cat "$work/projector-present.err" >&2
fi

absent_projector_presets=$state_directory/web-presets-absent-projector.ini
write_web_preset "$absent_projector_presets" unmarked
printf 'LLAMA_ARG_MMPROJ = %s\n' "$policy_model_root/Fixture-GGUF/absent-mmproj.gguf" \
    >>"$absent_projector_presets"
if QWEN_WEBUI_STATE_DIRECTORY=$state_directory \
    QWEN_WEB_PRESETS=$absent_projector_presets QWEN_WEB_LAUNCH_RECORD=$record \
    env -u QWEN_BIND_HOST "$launcher" \
    >"$work/absent-projector.log" 2>"$work/absent-projector.err"; then
    report absent_projector_refused accepted
else
    outcome=ok
    grep -q 'projector that is not a regular file' \
        "$work/absent-projector.err" || outcome=missing_message
    report absent_projector_refused "$outcome"
fi

# A projector path holding a space reaches the check whole, the way the MCP
# configuration path does.
mkdir -p "$policy_model_root/Fixture Vision GGUF"
spaced_projector_path="$policy_model_root/Fixture Vision GGUF/mmproj-F16.gguf"
: >"$spaced_projector_path"
spaced_projector_presets=$state_directory/web-presets-spaced-projector.ini
write_web_preset "$spaced_projector_presets" unmarked
printf 'LLAMA_ARG_MMPROJ = %s\n' "$spaced_projector_path" \
    >>"$spaced_projector_presets"
if QWEN_WEBUI_STATE_DIRECTORY=$state_directory \
    QWEN_WEB_PRESETS=$spaced_projector_presets QWEN_WEB_LAUNCH_RECORD=$record \
    env -u QWEN_BIND_HOST "$launcher" \
    >"$work/spaced-projector.log" 2>"$work/spaced-projector.err"; then
    report spaced_projector_path_admitted ok
else
    report spaced_projector_path_admitted refused
    cat "$work/spaced-projector.err" >&2
fi

# A preset file carrying no web provenance marker refuses, since the policy
# would resolve its sections as registry ids.
plain_presets=$state_directory/plain-presets.ini
sed '/^# qwen_web_presets=1$/d' "$web_presets" >"$plain_presets"
if QWEN_WEBUI_STATE_DIRECTORY=$state_directory \
    QWEN_WEB_PRESETS=$plain_presets QWEN_WEB_LAUNCH_RECORD=$record \
    env -u QWEN_BIND_HOST "$launcher" \
    >"$work/plain.log" 2>"$work/plain.err"; then
    report unmarked_preset_refused accepted
else
    report unmarked_preset_refused ok
fi

# The policy enforces the same loopback from the file itself. A marked preset
# launched at 0.0.0.0 reaches llama-server bound to 127.0.0.1.
model_registry=$work/models.tsv
{
    printf '# id\trole\tmodel_file\tfetch_script\tcontext_default\tcontext_ceiling\tcontext_target\tcache_type_k\tcache_type_v\tflash_attention\tprojector\tprojector_fetch_script\tdecode_tok_s\tprefill_tok_s\tquality\ttier\tbatch\tubatch\tvalidated_filled_depth\tvalidation_evidence\traw_tool_selection\tguarded_tool_execution\tmtp_layers\tspeculation_profile\n'
    printf 'fixture-production\tfixture-role\tFixture-GGUF/production.gguf\tdownload-fixture.sh\t8192\t16384\t32768\tq8_0\tq4_0\ton\tnone\t-\t1.00\t1.00\tuntested\tproduction\t128\t32\t16384\tevidence/fixture.md\t9/10\trefused\t0\toff\t-\n'
} >"$model_registry"

quarantine_registry=$work/quarantine.tsv
printf '# reason_id\tscope\tsubject\tconsumers\tdepth\tbatch\tubatch\tcache_type_k\tcache_type_v\tflash_attention\n' \
    >"$quarantine_registry"

# Every policy arm uses the ledger identity written into the fixture preset.

fake_icd=$work/radeon_icd.x86_64.json
: >"$fake_icd"
policy_output=$work/policy.out

run_policy() {
    QWEN_MODEL_REGISTRY=$model_registry QWEN_MODEL_ROOT=$policy_model_root \
    QWEN_QUARANTINE_REGISTRY=$quarantine_registry QWEN_VULKAN_ICD=$fake_icd \
    QWEN_WEB_PROFILES=${QWEN_WEB_PROFILES:-$web_profiles} \
    QWEN_POLICY_TEST_OUTPUT=$policy_output QWEN_ROUTER=1 \
    QWEN_ROUTER_PRESETS=$1 QWEN_ROUTER_MAX=1 QWEN_BIND_HOST=$2 \
        "$policy" "$fake_server" \
        "$policy_model_root/Fixture-GGUF/production.gguf" 8192 18080
}

policy_host_argument() {
    sed -n 's/^argument=//p' "$policy_output" |
        awk '/^--host$/ { getline; print; exit }'
}

if run_policy "$marked_presets" 0.0.0.0 \
    >"$work/policy-marked.log" 2>"$work/policy-marked.err"; then
    if [ "$(policy_host_argument)" = 127.0.0.1 ]; then
        report policy_forces_loopback_on_marked_preset ok
    else
        report policy_forces_loopback_on_marked_preset "$(policy_host_argument)"
    fi
else
    report policy_forces_loopback_on_marked_preset failed
    cat "$work/policy-marked.err" >&2
fi

# An unmarked web preset leaves the requested listener in place, so the arm
# above measures the marker rather than router mode.
if run_policy "$web_presets" 0.0.0.0 \
    >"$work/policy-unmarked.log" 2>"$work/policy-unmarked.err"; then
    if [ "$(policy_host_argument)" = 0.0.0.0 ]; then
        report policy_keeps_listener_without_marker ok
    else
        report policy_keeps_listener_without_marker "$(policy_host_argument)"
    fi
else
    report policy_keeps_listener_without_marker failed
    cat "$work/policy-unmarked.err" >&2
fi

if QWEN_WEB_AUTHORIZER_READY=0 run_policy "$web_presets" 127.0.0.1 \
    >"$work/policy-authorizer-absent.log" \
    2>"$work/policy-authorizer-absent.err"; then
    report policy_requires_authorizer_for_validator_gated accepted
elif grep -q 'web preset section web-fixture requires QWEN_WEB_AUTHORIZER_READY=1' \
    "$work/policy-authorizer-absent.err"; then
    report policy_requires_authorizer_for_validator_gated ok
else
    report policy_requires_authorizer_for_validator_gated missing_message
fi

# The policy reads every tuple key out of a web section, so an absent
# LLAMA_ARG_UBATCH and a diverging cache V type each refuse the launch.
missing_ubatch_presets=$state_directory/web-presets-missing-ubatch.ini
sed '/^LLAMA_ARG_UBATCH =/d' "$web_presets" >"$missing_ubatch_presets"
if run_policy "$missing_ubatch_presets" 127.0.0.1 \
    >"$work/missing-ubatch.log" 2>"$work/missing-ubatch.err"; then
    report policy_refuses_missing_ubatch accepted
else
    report policy_refuses_missing_ubatch ok
fi

wrong_cache_v_presets=$state_directory/web-presets-wrong-cache-v.ini
sed 's/^LLAMA_ARG_CACHE_TYPE_V = .*/LLAMA_ARG_CACHE_TYPE_V = q8_0/' \
    "$web_presets" >"$wrong_cache_v_presets"
if run_policy "$wrong_cache_v_presets" 127.0.0.1 \
    >"$work/wrong-cache-v.log" 2>"$work/wrong-cache-v.err"; then
    report policy_refuses_diverging_cache_v accepted
else
    report policy_refuses_diverging_cache_v ok
fi

absent_cache_v_presets=$state_directory/web-presets-absent-cache-v.ini
sed '/^LLAMA_ARG_CACHE_TYPE_V =/d' "$web_presets" >"$absent_cache_v_presets"
if run_policy "$absent_cache_v_presets" 127.0.0.1 \
    >"$work/absent-cache-v.log" 2>"$work/absent-cache-v.err"; then
    report policy_refuses_absent_cache_v accepted
else
    report policy_refuses_absent_cache_v ok
fi

# A web section requesting a depth above its row's context_ceiling refuses,
# which is the bound that replaces the context_default equality a router
# section carries.
over_ceiling_presets=$state_directory/web-presets-over-ceiling.ini
sed 's/^LLAMA_ARG_CTX_SIZE = .*/LLAMA_ARG_CTX_SIZE = 32768/' \
    "$web_presets" >"$over_ceiling_presets"
if run_policy "$over_ceiling_presets" 127.0.0.1 \
    >"$work/over-ceiling.log" 2>"$work/over-ceiling.err"; then
    report policy_refuses_context_above_ceiling accepted
else
    report policy_refuses_context_above_ceiling ok
fi

# A depth inside the ceiling and above context_default is admitted, which is the
# depth freedom a profile exists to express.
inside_ceiling_presets=$state_directory/web-presets-inside-ceiling.ini
sed 's/^LLAMA_ARG_CTX_SIZE = .*/LLAMA_ARG_CTX_SIZE = 16384/' \
    "$web_presets" >"$inside_ceiling_presets"
if run_policy "$inside_ceiling_presets" 127.0.0.1 \
    >"$work/inside-ceiling.log" 2>"$work/inside-ceiling.err"; then
    report policy_admits_context_inside_ceiling ok
else
    report policy_admits_context_inside_ceiling refused
    cat "$work/inside-ceiling.err" >&2
fi

# A generated tree under a path holding a space names one readable
# configuration, and the launch admits it. Field splitting over command
# substitution would report each fragment of that one path as unreadable.
spaced_state_directory="$work/state with space"
mkdir -p "$spaced_state_directory/web mcp configs"
spaced_mcp_config="$spaced_state_directory/web mcp configs/web-fixture.json"
printf '{}\n' >"$spaced_mcp_config"
spaced_presets="$spaced_state_directory/web-presets.ini"
write_web_preset "$spaced_presets" unmarked
sed -i "s|^LLAMA_ARG_MCP_SERVERS_CONFIG = .*|LLAMA_ARG_MCP_SERVERS_CONFIG = $spaced_mcp_config|" \
    "$spaced_presets"
if QWEN_WEBUI_STATE_DIRECTORY="$spaced_state_directory" \
    QWEN_WEB_PRESETS="$spaced_presets" QWEN_WEB_LAUNCH_RECORD=$record \
    env -u QWEN_BIND_HOST "$launcher" \
    >"$work/spaced.log" 2>"$work/spaced.err"; then
    report spaced_mcp_config_path_admitted ok
else
    report spaced_mcp_config_path_admitted refused
    cat "$work/spaced.err" >&2
fi

# The count of unreadable configurations survives the loop, which a pipeline
# would leave at zero by running the body in a subshell. A preset naming one
# readable and one absent configuration refuses.
mixed_presets=$state_directory/web-presets-mixed-mcp.ini
write_web_preset "$mixed_presets" unmarked
{
    printf '[web-fixture-second]\n'
    printf 'LLAMA_ARG_MODEL = %s\n' "$policy_model_root/Fixture-GGUF/production.gguf"
    printf 'LLAMA_ARG_MCP_SERVERS_CONFIG = /nonexistent/second-web-mcp.json\n'
    printf '\n'
} >>"$mixed_presets"
if QWEN_WEBUI_STATE_DIRECTORY=$state_directory \
    QWEN_WEB_PRESETS=$mixed_presets QWEN_WEB_LAUNCH_RECORD=$record \
    env -u QWEN_BIND_HOST "$launcher" \
    >"$work/mixed-mcp.log" 2>"$work/mixed-mcp.err"; then
    report absent_mcp_config_beside_readable_refused accepted
else
    outcome=ok
    grep -q '/nonexistent/second-web-mcp.json' "$work/mixed-mcp.err" ||
        outcome=missing_message
    report absent_mcp_config_beside_readable_refused "$outcome"
fi

# A preset persists across a registry edit, so the launch rechecks the depth
# against the registry it reads now. build-web-presets.sh admits a context above
# validated_filled_depth only under the marker, and a registry that later lowers
# that field, or sets it to `-`, leaves an unmarked section serving a depth no
# run has filled and decoded.
write_lowered_registry() {
    {
        printf '# id\trole\tmodel_file\tfetch_script\tcontext_default\tcontext_ceiling\tcontext_target\tcache_type_k\tcache_type_v\tflash_attention\tprojector\tprojector_fetch_script\tdecode_tok_s\tprefill_tok_s\tquality\ttier\tbatch\tubatch\tvalidated_filled_depth\tvalidation_evidence\traw_tool_selection\tguarded_tool_execution\tmtp_layers\tspeculation_profile\n'
        printf 'fixture-production\tfixture-role\tFixture-GGUF/production.gguf\tdownload-fixture.sh\t8192\t16384\t32768\tq8_0\tq4_0\ton\tnone\t-\t1.00\t1.00\tuntested\tproduction\t128\t32\t%s\tevidence/fixture.md\t9/10\trefused\t0\toff\t-\n' \
            "$1"
    } >"$2"
}

run_policy_with_registry() {
    QWEN_MODEL_REGISTRY=$1 QWEN_MODEL_ROOT=$policy_model_root \
    QWEN_QUARANTINE_REGISTRY=$quarantine_registry QWEN_VULKAN_ICD=$fake_icd \
    QWEN_WEB_PROFILES=${QWEN_WEB_PROFILES:-$web_profiles} \
    QWEN_POLICY_TEST_OUTPUT=$policy_output QWEN_ROUTER=1 \
    QWEN_ROUTER_PRESETS=$2 QWEN_ROUTER_MAX=1 QWEN_BIND_HOST=127.0.0.1 \
        "$policy" "$fake_server" \
        "$policy_model_root/Fixture-GGUF/production.gguf" 8192 18080
}

depth_presets=$state_directory/web-presets-depth.ini
sed 's/^LLAMA_ARG_CTX_SIZE = .*/LLAMA_ARG_CTX_SIZE = 16384/' \
    "$web_presets" >"$depth_presets"
marked_depth_presets=$state_directory/web-presets-depth-marked.ini
sed 's/^LLAMA_ARG_CTX_SIZE = .*/LLAMA_ARG_CTX_SIZE = 16384/' \
    "$marked_presets" >"$marked_depth_presets"

for lowered_depth in 8192 -; do
    lowered_registry=$work/models-lowered-$lowered_depth.tsv
    write_lowered_registry "$lowered_depth" "$lowered_registry"
    case $lowered_depth in
        -) lowered_case=unmeasured ;;
        *) lowered_case=lowered ;;
    esac
    if run_policy_with_registry "$lowered_registry" "$depth_presets" \
        >"$work/depth-$lowered_case.log" 2>"$work/depth-$lowered_case.err"; then
        report "policy_refuses_${lowered_case}_filled_depth" accepted
    else
        outcome=ok
        grep -q 'web-fixture' "$work/depth-$lowered_case.err" ||
            outcome=missing_section
        report "policy_refuses_${lowered_case}_filled_depth" "$outcome"
    fi

    # The marker is the claim the generator recorded when it admitted an
    # unvalidated depth, so a marked preset still launches and reaches the
    # loopback the marker forces.
    if run_policy_with_registry "$lowered_registry" "$marked_depth_presets" \
        >"$work/depth-marked-$lowered_case.log" \
        2>"$work/depth-marked-$lowered_case.err"; then
        report "policy_admits_marked_${lowered_case}_filled_depth" ok
    else
        report "policy_admits_marked_${lowered_case}_filled_depth" refused
        cat "$work/depth-marked-$lowered_case.err" >&2
    fi
done

# A plain router preset carries no web provenance, and its depth rule stays the
# context_default equality; the fixture row's `-` filled depth leaves it
# admitted, so the new bound reaches web sections alone.
router_presets_plain=$state_directory/router-presets-plain.ini
{
    printf '# Generated by scripts/build-router-presets.sh from the model registry.\n'
    printf '# qwen_router_include_quarantine=0\n'
    printf '\n'
    printf '[fixture-production]\n'
    printf 'LLAMA_ARG_MODEL = %s\n' "$policy_model_root/Fixture-GGUF/production.gguf"
    printf 'LLAMA_ARG_ALIAS = fixture-production\n'
    printf 'LLAMA_ARG_CTX_SIZE = 8192\n'
    printf 'LLAMA_ARG_CACHE_TYPE_K = q8_0\n'
    printf 'LLAMA_ARG_CACHE_TYPE_V = q4_0\n'
    printf 'LLAMA_ARG_FLASH_ATTN = on\n'
    printf 'LLAMA_ARG_BATCH = 128\n'
    printf 'LLAMA_ARG_UBATCH = 32\n'
    printf 'LLAMA_ARG_TAGS = production,fixture-role,default\n'
    printf '\n'
} >"$router_presets_plain"
unmeasured_registry=$work/models-lowered---.tsv
write_lowered_registry - "$unmeasured_registry"
if run_policy_with_registry "$unmeasured_registry" "$router_presets_plain" \
    >"$work/router-plain.log" 2>"$work/router-plain.err"; then
    report router_preset_keeps_context_default_rule ok
else
    report router_preset_keeps_context_default_rule refused
    cat "$work/router-plain.err" >&2
fi


# execution_policy is the security boundary the ledger states and a preset
# persists across an edit to it, so the launch rejoins each section to the
# current ledger. A row moved to refused, removed outright, or moved to another
# emitting policy than the section's tags claim refuses the launch; an
# unreadable ledger refuses it the way an unreadable quarantine authority does.
revoked_profiles=$work/web-profiles-revoked.tsv
write_web_profiles refused "$revoked_profiles"
if QWEN_WEB_PROFILES=$revoked_profiles run_policy "$web_presets" 127.0.0.1 \
    >"$work/revoked.log" 2>"$work/revoked.err"; then
    report policy_refuses_revoked_execution_policy accepted
else
    outcome=ok
    grep -q 'QWEN_WEB_PROFILES names .* where the preset binds' \
        "$work/revoked.err" ||
        outcome=missing_message
    report policy_refuses_revoked_execution_policy "$outcome"
fi

vanished_profiles=$work/web-profiles-vanished.tsv
write_web_profiles validator-gated "$vanished_profiles"
sed -i '/^web-fixture\t/d' "$vanished_profiles"
if QWEN_WEB_PROFILES=$vanished_profiles run_policy "$web_presets" 127.0.0.1 \
    >"$work/vanished.log" 2>"$work/vanished.err"; then
    report policy_refuses_vanished_profile accepted
else
    outcome=ok
    grep -q 'QWEN_WEB_PROFILES names .* where the preset binds' \
        "$work/vanished.err" || outcome=missing_message
    report policy_refuses_vanished_profile "$outcome"
fi

# A row moved between two emitting policies leaves the persisted
# LLAMA_ARG_MCP_SERVERS_CONFIG in a section the ledger now says reaches no
# network, so the section's claimed policy is compared against the ledger's.
moved_profiles=$work/web-profiles-moved.tsv
write_web_profiles ui-mediated "$moved_profiles"
if QWEN_WEB_PROFILES=$moved_profiles run_policy "$web_presets" 127.0.0.1 \
    >"$work/moved.log" 2>"$work/moved.err"; then
    report policy_refuses_moved_execution_policy accepted
else
    outcome=ok
    grep -q 'QWEN_WEB_PROFILES names .* where the preset binds' \
        "$work/moved.err" ||
        outcome=missing_message
    report policy_refuses_moved_execution_policy "$outcome"
fi

if QWEN_WEB_PROFILES=$work/web-profiles-absent.tsv \
    run_policy "$web_presets" 127.0.0.1 \
    >"$work/ledger-absent.log" 2>"$work/ledger-absent.err"; then
    report policy_refuses_unreadable_ledger accepted
else
    outcome=ok
    grep -q 'QWEN_WEB_PROFILES names .* where the preset binds' \
        "$work/ledger-absent.err" ||
        outcome=missing_message
    report policy_refuses_unreadable_ledger "$outcome"
fi

# The unchanged ledger is the control: the same preset launches where the row
# still carries the policy its section claims.
if run_policy "$web_presets" 127.0.0.1 \
    >"$work/ledger-control.log" 2>"$work/ledger-control.err"; then
    report policy_admits_unchanged_ledger ok
else
    report policy_admits_unchanged_ledger refused
    cat "$work/ledger-control.err" >&2
fi

identity_profiles=$work/web-profiles-identity.tsv
write_web_profiles validator-gated "$identity_profiles"
identity_presets=$state_directory/web-presets-identity.ini
original_web_profiles=$web_profiles
web_profiles=$identity_profiles
write_web_preset "$identity_presets" unmarked
web_profiles=$original_web_profiles
printf '# changed after preset generation\n' >>"$identity_profiles"
if QWEN_WEBUI_STATE_DIRECTORY=$state_directory \
    QWEN_WEB_PRESETS=$identity_presets QWEN_WEB_LAUNCH_RECORD=$record \
    env -u QWEN_BIND_HOST -u QWEN_WEB_PROFILES "$launcher" \
    >"$work/ledger-identity.log" 2>"$work/ledger-identity.err"; then
    report wrapper_refuses_changed_ledger_identity accepted
elif grep -q 'web profile ledger identity changed:' \
    "$work/ledger-identity.err"; then
    report wrapper_refuses_changed_ledger_identity ok
else
    report wrapper_refuses_changed_ledger_identity missing_message
fi

if [ "$failures" -ne 0 ]; then
    printf 'test-qwen-web-launch: %d check(s) failed\n' "$failures" >&2
    exit 1
fi
printf 'test-qwen-web-launch: all checks passed\n'
