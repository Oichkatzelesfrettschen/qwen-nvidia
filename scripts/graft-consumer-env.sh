#!/bin/sh
set -eu

# gpu-ownership: non-gpu-helper; executes no device binary.

# Emit the environment graft's --deep pass needs to use the served appliance
# as its model, after proving the endpoint answers a forced tool call.
#
# graft speaks the OpenAI wire format and records each summary through a
# forced `tool_choice`; a llama-server launched without --jinja ignores the
# `tools` field and answers in prose, the 2B distill answers a forced call in
# prose even under --jinja while the 4B distill records it, and graft then
# leaves every node pending. The probe below sends the smallest forced tool call and requires a
# `tool_calls` member in the answer, so a launch that lacks QWEN_CHAT_TOOLS=on
# is refused here rather than discovered as an empty graph.
#
# The key file's contents stay off argv and out of this script's output: the
# emitted line reads the file at eval time, so `eval "$(graft-consumer-env.sh)"`
# places the key in the caller's environment alone.
#
#   QWEN_SERVER_PORT           the served listener, default 8080
#   QWEN_WEBUI_STATE_DIRECTORY the state directory holding api.key
#   QWEN_GRAFT_MODEL           the served alias, default qwen-nvidia

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

server_port=${QWEN_SERVER_PORT:-8080}
state_directory=${QWEN_WEBUI_STATE_DIRECTORY:-"${HOME:?}/qwen-webui-state"}
api_key_file=$state_directory/api.key
served_model=${QWEN_GRAFT_MODEL:-qwen-nvidia}
base_url=http://127.0.0.1:$server_port/v1

case $server_port in
    '' | *[!0-9]* | 0)
        printf 'QWEN_SERVER_PORT must be a positive integer: %s\n' \
            "$server_port" >&2
        exit 2
        ;;
esac

if [ ! -f "$api_key_file" ]; then
    printf 'api key file is absent; launch the appliance first: %s\n' \
        "$api_key_file" >&2
    exit 1
fi
key_mode=$(stat -c %a "$api_key_file")
case $key_mode in
    400 | 600) : ;;
    *)
        printf 'api key file %s carries mode %s, required 0400 or 0600\n' \
            "$api_key_file" "$key_mode" >&2
        exit 1
        ;;
esac

if ! curl --silent --fail --max-time 5 "http://127.0.0.1:$server_port/health" \
    >/dev/null 2>&1; then
    printf 'no served appliance answers on 127.0.0.1:%s\n' "$server_port" >&2
    exit 1
fi

# The probe carries the key through a header file rather than argv, so the
# secret stays out of the process table.
header_file=$(mktemp "${TMPDIR:-/tmp}/graft-consumer-env.XXXXXX")
printf 'header = "Authorization: Bearer %s"\n' "$(tr -d '\n' <"$api_key_file")" \
    >"$header_file"

# tool_choice is a string because that is the only shape the server reads.
# tools/server/server-common.cpp takes it through
# json_value(body, "tool_choice", std::string("auto")), which catches the type
# error an object raises and returns "auto"; the OpenAI named-function object
# this probe used to send forced nothing, and every server log of that campaign
# carries `Wrong type supplied for parameter 'tool_choice'`. oxcoder-9b records
# a call under "required" and none under "auto"
# (evidence/ada/agent-model-roster/tool-choice-required/), so the object form
# read a voluntary call as a forced one and a declined one as an inability.
#
# The cap covers a reasoning preamble, because a model that thinks before it
# calls spends the budget on tokens the call never reaches. At 128 this probe
# cut off lfm25-8b-a1b and klear-agentforge-8b and recorded both as unable to
# call a tool; both complete record_probe(ok=true) at 512
# (evidence/ada/agent-model-roster/tool-format-probe/). One forced call costs a
# few dozen tokens, so a model that answers at once spends nothing extra here.
probe_max_tokens=${QWEN_PROBE_MAX_TOKENS:-1024}
case $probe_max_tokens in
    ''|*[!0-9]*)
        printf 'QWEN_PROBE_MAX_TOKENS names a token count: %s\n' \
            "$probe_max_tokens" >&2
        exit 2
        ;;
esac

probe_body='{"model":"'$served_model'","temperature":0,"max_tokens":'$probe_max_tokens',
"tools":[{"type":"function","function":{"name":"record_probe",
"description":"Record the probe.","parameters":{"type":"object",
"properties":{"ok":{"type":"boolean"}},"required":["ok"]}}}],
"tool_choice":"required",
"messages":[{"role":"user","content":"Record ok as true."}]}'

probe_answer_file=$(mktemp "${TMPDIR:-/tmp}/graft-consumer-env.XXXXXX")
trap 'rm -f "$header_file" "$probe_answer_file"' EXIT INT TERM
probe_status=$(curl --silent --max-time 120 --config "$header_file" \
    --header 'Content-Type: application/json' --output "$probe_answer_file" \
    --write-out '%{http_code}' \
    --data "$probe_body" "$base_url/chat/completions") || {
    printf 'the tool-call probe reached no answer on %s\n' "$base_url" >&2
    exit 1
}
if [ "$probe_status" != 200 ]; then
    printf 'the tool-call probe answered HTTP %s on %s: %s\n' "$probe_status" \
        "$base_url" "$(head -c 300 "$probe_answer_file")" >&2
    exit 1
fi

# The answer counts when it is one completed call to record_probe whose
# arguments parse as JSON and carry ok=true. A body that merely mentions
# tool_calls -- a null member, an empty array, another function, prose that
# quotes the field, a truncated reply -- records nothing graft can use, so
# each of those is refused with the shape it had.
probe_verdict=$(jq -r '
    if (.choices | type) != "array" or (.choices | length) == 0 then "no_choices"
    elif .choices[0].finish_reason != "stop" and .choices[0].finish_reason != "tool_calls" then
        "finish_" + ((.choices[0].finish_reason // "none") | tostring)
    elif (.choices[0].message.tool_calls | type) != "array" then "no_tool_calls"
    elif (.choices[0].message.tool_calls | length) != 1 then
        "tool_calls_" + (.choices[0].message.tool_calls | length | tostring)
    elif .choices[0].message.tool_calls[0].function.name != "record_probe" then
        "function_" + ((.choices[0].message.tool_calls[0].function.name // "none") | tostring)
    else
        (.choices[0].message.tool_calls[0].function.arguments
            | try (fromjson | if .ok == true then "ok" else "arguments_ok_" + (.ok | tostring) end)
              catch "arguments_unparsed")
    end' "$probe_answer_file" 2>/dev/null) || probe_verdict=body_unparsed
case $probe_verdict in
    ok) ;;
    no_tool_calls)
        printf 'the served llama-server answered a forced tool call without tool_calls; launch with QWEN_CHAT_TOOLS=on and a model that records one, such as the 4B distill (the 2B distill answers in prose)\n' >&2
        exit 1
        ;;
    finish_length)
        # A reply the cap cut off says nothing about whether the model can
        # record a call, so the refusal names the cap rather than the model.
        printf 'the tool-call probe reached max_tokens %s before completing record_probe(ok=true); raise QWEN_PROBE_MAX_TOKENS, because a reply cut off mid-call is no evidence the model cannot make one\n' \
            "$probe_max_tokens" >&2
        exit 1
        ;;
    *)
        printf 'the tool-call probe did not complete record_probe(ok=true): %s\n' \
            "$probe_verdict" >&2
        exit 1
        ;;
esac

printf 'export GRAFT_PROVIDER=openai\n'
printf 'export GRAFT_BASE_URL=%s\n' "$base_url"
printf 'export GRAFT_MODEL=%s\n' "$served_model"
printf "export GRAFT_API_KEY=\$(cat '%s')\n" "$api_key_file"
