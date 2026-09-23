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
# leaves every node pending. An auto-choice control must select record_graph;
# Graft's named-function choice must override that same prompt with record_probe.
#
# The key file's contents stay off argv and out of this script's output: the
# emitted line reads the file at eval time, so `eval "$(graft-consumer-env.sh)"`
# places the key in the caller's environment alone.
#
#   QWEN_SERVER_PORT           the served listener, default 8080
#   QWEN_WEBUI_STATE_DIRECTORY the state directory holding api.key
#   QWEN_GRAFT_MODEL           the served alias, default qwen-nvidia
#   QWEN_PROBE_MAX_TOKENS      positive decimal reply cap, default 1024

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

server_port=${QWEN_SERVER_PORT:-8080}
state_directory=${QWEN_WEBUI_STATE_DIRECTORY:-"${HOME:?}/qwen-webui-state"}
api_key_file=$state_directory/api.key
served_model=${QWEN_GRAFT_MODEL:-qwen-nvidia}
probe_max_tokens=${QWEN_PROBE_MAX_TOKENS:-1024}

case $server_port in
    '' | *[!0-9]* | 0*)
        printf 'QWEN_SERVER_PORT must be an integer from 1 to 65535: %s\n' \
            "$server_port" >&2
        exit 2
        ;;
esac
if [ "${#server_port}" -gt 5 ] || [ "$server_port" -gt 65535 ]; then
    printf 'QWEN_SERVER_PORT must be an integer from 1 to 65535: %s\n' "$server_port" >&2
    exit 2
fi
case $probe_max_tokens in
    '' | *[!0-9]* | 0*)
        printf 'QWEN_PROBE_MAX_TOKENS must be a positive decimal integer: %s\n' \
            "$probe_max_tokens" >&2
        exit 2
        ;;
esac
base_url=http://127.0.0.1:$server_port/v1

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

if ! curl --user-agent 'Mozilla/5.0' --silent --fail --max-time 5 "http://127.0.0.1:$server_port/health" \
    >/dev/null 2>&1; then
    printf 'no served appliance answers on 127.0.0.1:%s\n' "$server_port" >&2
    exit 1
fi

# The probe carries the key through a header file rather than argv, so the
# secret stays out of the process table.
header_file=$(mktemp "${TMPDIR:-/tmp}/graft-consumer-env.XXXXXX")
probe_answer_file=
trap 'rm -f "$header_file"; if [ -n "$probe_answer_file" ]; then rm -f "$probe_answer_file"; fi' EXIT INT TERM
printf 'Authorization: Bearer %s\n' "$(tr -d '\n' <"$api_key_file")" \
    >"$header_file"

# Graft's OpenAI adapter sends the named-function object. A conflicting prompt
# and an auto-choice control distinguish honoring that choice from a model
# independently choosing record_probe after the server downgraded it to auto.
#
# The cap covers a reasoning preamble, because a model that thinks before it
# calls spends the budget on tokens the call never reaches. At 128 this probe
# cut off lfm25-8b-a1b and klear-agentforge-8b and recorded both as unable to
# call a tool; both complete record_probe(ok=true) at 512
# (evidence/ada/agent-model-roster/tool-format-probe/). One forced call costs a
# few dozen tokens, so a model that answers at once spends nothing extra here.
probe_body=$(jq -cn --arg model "$served_model" --arg max_tokens "$probe_max_tokens" '
    {model: $model, temperature: 0, max_tokens: ($max_tokens | tonumber),
     tools: [
        {type: "function", function: {name: "record_graph",
         description: "Record a graph.", parameters: {type: "object",
         properties: {ok: {type: "boolean"}}, required: ["ok"]}}},
        {type: "function", function: {name: "record_probe",
         description: "Record the probe.", parameters: {type: "object",
         properties: {ok: {type: "boolean"}}, required: ["ok"]}}}],
     tool_choice: {type: "function", function: {name: "record_probe"}},
     messages: [{role: "user", content: "Call record_graph with ok set to true. Do not call record_probe."}]}')

probe_answer_file=$(mktemp "${TMPDIR:-/tmp}/graft-consumer-env.XXXXXX")
for probe_mode in auto named; do
    if [ "$probe_mode" = auto ]; then
        expected_function=record_graph
        request_body=$(printf '%s' "$probe_body" | jq -c '.tool_choice = "auto"')
    else
        expected_function=record_probe
        request_body=$probe_body
    fi
    probe_status=$(curl --user-agent 'Mozilla/5.0' --silent --max-time 120 --header "@$header_file" \
        --header 'Content-Type: application/json' --output "$probe_answer_file" \
        --write-out '%{http_code}' \
        --data "$request_body" "$base_url/chat/completions") || {
        printf 'the %s tool-call probe reached no answer on %s\n' "$probe_mode" "$base_url" >&2
        exit 1
    }
    if [ "$probe_status" != 200 ]; then
        printf 'the tool-call probe answered HTTP %s on %s: %s\n' "$probe_status" \
            "$base_url" "$(head -c 300 "$probe_answer_file")" >&2
        exit 1
    fi

    # The answer counts when it is one completed call to the expected function whose
    # arguments parse as JSON and carry ok=true. A body that merely mentions
    # tool_calls -- a null member, an empty array, another function, prose that
    # quotes the field, a truncated reply -- records nothing graft can use, so
    # each of those is refused with the shape it had.
    probe_verdict=$(jq -r --arg expected_function "$expected_function" '
        if (.choices | type) != "array" or (.choices | length) == 0 then "no_choices"
        elif .choices[0].finish_reason != "stop" and .choices[0].finish_reason != "tool_calls" then
            "finish_" + ((.choices[0].finish_reason // "none") | tostring)
        elif (.choices[0].message.tool_calls | type) != "array" then "no_tool_calls"
        elif (.choices[0].message.tool_calls | length) != 1 then
            "tool_calls_" + (.choices[0].message.tool_calls | length | tostring)
        elif .choices[0].message.tool_calls[0].function.name != $expected_function then
            "function_" + ((.choices[0].message.tool_calls[0].function.name // "none") | tostring)
        else
            (.choices[0].message.tool_calls[0].function.arguments
                | try (fromjson | if .ok == true then "ok" else "arguments_ok_" + (.ok | tostring) end)
                  catch "arguments_unparsed")
        end' "$probe_answer_file" 2>/dev/null) || probe_verdict=body_unparsed
    case $probe_verdict in
        ok) ;;
        no_tool_calls)
            printf 'the served llama-server answered the %s tool choice without tool_calls; require named-function tool_choice support, QWEN_CHAT_TOOLS=on, and a model that completes %s(ok=true)\n' \
                "$probe_mode" "$expected_function" >&2
            exit 1
            ;;
        finish_length)
            # A reply the cap cut off says nothing about whether the model can
            # record a call, so the refusal names the cap rather than the model.
            printf 'the %s tool-call probe reached max_tokens %s before completing %s(ok=true); raise QWEN_PROBE_MAX_TOKENS, because a reply cut off mid-call is no evidence the model cannot make one\n' \
                "$probe_mode" "$probe_max_tokens" "$expected_function" >&2
            exit 1
            ;;
        *)
            printf 'the %s tool-call probe did not complete %s(ok=true): %s\n' \
                "$probe_mode" "$expected_function" "$probe_verdict" >&2
            exit 1
            ;;
    esac
done

printf 'export GRAFT_PROVIDER=openai\n'
shell_quote() {
    printf "'"
    printf '%s' "$1" | sed "s/'/'\\\\''/g"
    printf "'"
}
printf 'export GRAFT_BASE_URL=%s\n' "$(shell_quote "$base_url")"
printf 'export GRAFT_MODEL=%s\n' "$(shell_quote "$served_model")"
printf 'export GRAFT_API_KEY=$(cat %s)\n' "$(shell_quote "$api_key_file")"
