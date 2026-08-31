#!/bin/sh
set -eu

# Admit the contained Qwen Code launcher without the runtime: a fake
# executable records the argv and the provider environment it starts with,
# so the checks read what the child actually receives -- the loopback
# refusal, the key-file rules, the mode-to-approval mapping, the ambient
# provider scrub, and the credential travelling through the environment
# alone.

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
work_directory=$(mktemp -d "${TMPDIR:-/tmp}/coding-agent-launch.XXXXXX")
trap 'rm -rf "$work_directory"' EXIT INT TERM

checks_total=0
checks_failed=0
check() {
    checks_total=$((checks_total + 1))
    if [ "$2" = pass ]; then
        printf 'check=%s outcome=pass\n' "$1"
    else
        checks_failed=$((checks_failed + 1))
        printf 'check=%s outcome=FAIL detail=%s\n' "$1" "${3:-}" >&2
    fi
}

launcher=$script_directory/coding-agent-launch.sh

mkdir -p "$work_directory/home" "$work_directory/runtime"
cat >"$work_directory/fake-qwen" <<'EOF'
#!/bin/sh
printf 'argv=%s\n' "$*"
printf 'key=%s\n' "${QWEN_NVIDIA_LOCAL_API_KEY:-unset}"
printf 'openai=%s\n' "${OPENAI_API_KEY:-unset}"
printf 'anthropic=%s\n' "${ANTHROPIC_API_KEY:-unset}"
EOF
chmod 755 "$work_directory/fake-qwen"

printf 'local-test-key\n' >"$work_directory/llama-api.key"
chmod 600 "$work_directory/llama-api.key"
printf '{}\n' >"$work_directory/settings.json"

run_launcher() {
    mode=$1
    shift
    env -i PATH=/usr/bin:/bin HOME="$work_directory/home" \
        OPENAI_API_KEY=ambient-openai ANTHROPIC_API_KEY=ambient-anthropic \
        QWEN_CODING_KEY_FILE="$work_directory/llama-api.key" \
        QWEN_CODING_SETTINGS="$work_directory/settings.json" \
        QWEN_CODING_BASE_URL="${base_url_override:-http://127.0.0.1:8080/v1}" \
        QWEN_CODING_RUNTIME_ROOT="$work_directory/runtime" \
        QWEN_CODING_RUNTIME_EXECUTABLE="$work_directory/fake-qwen" \
        "$@" \
        "$launcher" "$mode" test-model 'change one value'
}

output=$(run_launcher plan 2>&1) || {
    check plan_launch fail "$output"
    exit 1
}
case $output in
*'--approval-mode plan'*) check plan_maps_to_plan_approval pass ;;
*) check plan_maps_to_plan_approval fail "$output" ;;
esac
case $output in
*'key=local-test-key'*) check key_travels_in_environment pass ;;
*) check key_travels_in_environment fail "$output" ;;
esac
case $output in
*'openai=unset'*'anthropic=unset'*) check ambient_providers_scrubbed pass ;;
*) check ambient_providers_scrubbed fail "$output" ;;
esac
argv_line=$(printf '%s\n' "$output" | grep '^argv=')
case $argv_line in
*local-test-key*) check key_stays_out_of_argv fail "$argv_line" ;;
*) check key_stays_out_of_argv pass ;;
esac
case $output in
*'--output-format stream-json'*'--model test-model'* | \
    *'--model test-model'*'--output-format stream-json'*)
    check model_and_stream_json_forced pass ;;
*) check model_and_stream_json_forced fail "$output" ;;
esac
[ -f "$work_directory/home/.qwen/settings.json" ] &&
    check settings_installed_into_home pass ||
    check settings_installed_into_home fail

output=$(run_launcher apply 2>&1)
case $output in
*'--approval-mode yolo'*) check apply_maps_to_automatic_approval pass ;;
*) check apply_maps_to_automatic_approval fail "$output" ;;
esac

if base_url_override='http://192.0.2.1:8080/v1' run_launcher plan \
    >/dev/null 2>&1; then
    check non_loopback_refused fail 'external base URL accepted'
else
    check non_loopback_refused pass
fi

chmod 644 "$work_directory/llama-api.key"
if run_launcher plan >/dev/null 2>&1; then
    check open_key_mode_refused fail 'mode 644 key accepted'
else
    check open_key_mode_refused pass
fi
chmod 400 "$work_directory/llama-api.key"
if run_launcher plan >/dev/null 2>&1; then
    check read_only_key_mode_accepted pass
else
    check read_only_key_mode_accepted fail 'mode 400 key refused'
fi
rm -f "$work_directory/llama-api.key"
if run_launcher plan >/dev/null 2>&1; then
    check missing_key_refused fail 'absent key accepted'
else
    check missing_key_refused pass
fi

if [ "$checks_failed" -eq 0 ]; then
    printf 'coding_agent_launch=accepted checks=%s\n' "$checks_total"
    exit 0
fi
printf 'coding_agent_launch=rejected failed=%s of=%s\n' \
    "$checks_failed" "$checks_total" >&2
exit 1
