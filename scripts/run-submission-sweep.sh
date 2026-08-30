#!/bin/sh
set -eu

# Sweep Vulkan submission settings against a chat-shaped request, driven from a
# client machine so the laptop carries only the server and its guards. Each
# configuration gets its own model load, one request, and a teardown, so the
# graphics-latency samples belong to exactly one configuration.

if [ "$#" -lt 2 ]; then
    printf 'usage: %s SSH_TARGET OUTPUT_DIRECTORY [DECODE_TOKENS]\n' "$0" >&2
    exit 2
fi

ssh_target=$1
output_directory=$2
decode_tokens=${3:-128}
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
remote_root=${QWEN_REMOTE_ROOT:-'$HOME/qwen-laptop-setup'}
base_url=${QWEN_BASE_URL:-http://qwen-laptop:8080}

mkdir -p "$output_directory"
summary=$output_directory/sweep-summary.tsv
printf 'label\tserialize\tnodes\tgraphics_queue\tttft_s\tdecode_tok_s\tprefill_tok_s\tprobe_mean_us\tprobe_p90_us\tprobe_p99_us\tframe_ok_pct\tbreaches\n' \
    >"$summary"

# label:serialize:nodes:allow_graphics_queue
configurations=${QWEN_SWEEP_CONFIGURATIONS:-'
serialized-32:1:32:0
serialized-128:1:128:0
serialized-512:1:512:0
async-16:0:16:0
async-128:0:128:0
serialized-128-gfx:1:128:1
'}

for configuration in $configurations; do
    label=$(printf '%s' "$configuration" | cut -d: -f1)
    serialize=$(printf '%s' "$configuration" | cut -d: -f2)
    nodes=$(printf '%s' "$configuration" | cut -d: -f3)
    graphics_queue=$(printf '%s' "$configuration" | cut -d: -f4)

    printf 'run_start label=%s serialize=%s nodes=%s graphics_queue=%s\n' \
        "$label" "$serialize" "$nodes" "$graphics_queue"

    # The profile name only selects the guard policy; the submission settings
    # are supplied directly so each arm differs by one dimension at a time.
    environment="QWEN_BIND_HOST=0.0.0.0 QWEN_LATENCY_MODE=observe"
    environment="$environment GGML_VK_MAX_NODES_PER_SUBMIT=$nodes"
    [ "$serialize" = 1 ] && environment="$environment GGML_VK_SERIALIZE_SUBMISSIONS=1"
    [ "$graphics_queue" = 1 ] && environment="$environment GGML_VK_ALLOW_GRAPHICS_QUEUE=1"

    if ! ssh -o BatchMode=yes "$ssh_target" \
        "cd $remote_root && env $environment QWEN_SWEEP_DIRECT=1 sh scripts/qwen-launch.sh custom" \
        >"$output_directory/$label.launch" 2>&1; then
        printf 'launch failed label=%s\n' "$label" >&2
        sed -n '1,20p' "$output_directory/$label.launch" >&2
        ssh -o BatchMode=yes "$ssh_target" "cd $remote_root && sh scripts/qwen-teardown.sh" >/dev/null 2>&1 || true
        continue
    fi

    if ! "$script_directory/chat-latency-probe.py" "$base_url" \
        --decode-tokens "$decode_tokens" \
        >"$output_directory/$label.chat" 2>"$output_directory/$label.chat.err"; then
        printf 'request failed label=%s\n' "$label" >&2
        cat "$output_directory/$label.chat.err" >&2
    fi

    ssh -o BatchMode=yes "$ssh_target" \
        "cd $remote_root && sh scripts/summarize-probe.sh" \
        >"$output_directory/$label.probe" 2>&1 || true

    ssh -o BatchMode=yes "$ssh_target" \
        "cd $remote_root && sh scripts/qwen-teardown.sh" \
        >"$output_directory/$label.teardown" 2>&1 || true

    ttft=$(sed -n 's/.*"time_to_first_token_s": *\([0-9.]*\).*/\1/p' "$output_directory/$label.chat" 2>/dev/null || true)
    decode=$(sed -n 's/.*"server_predicted_per_second": *\([0-9.]*\).*/\1/p' "$output_directory/$label.chat" 2>/dev/null || true)
    prefill=$(sed -n 's/.*"server_prompt_per_second": *\([0-9.]*\).*/\1/p' "$output_directory/$label.chat" 2>/dev/null || true)
    mean=$(sed -n 's/^mean=//p' "$output_directory/$label.probe" 2>/dev/null || true)
    p90=$(sed -n 's/^p90=//p' "$output_directory/$label.probe" 2>/dev/null || true)
    p99=$(sed -n 's/^p99=//p' "$output_directory/$label.probe" 2>/dev/null || true)
    frame=$(sed -n 's/^frame_ok_pct=//p' "$output_directory/$label.probe" 2>/dev/null || true)
    breaches=$(sed -n 's/^breaches=//p' "$output_directory/$label.probe" 2>/dev/null || true)

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$label" "$serialize" "$nodes" "$graphics_queue" \
        "${ttft:-n/a}" "${decode:-n/a}" "${prefill:-n/a}" \
        "${mean:-n/a}" "${p90:-n/a}" "${p99:-n/a}" \
        "${frame:-n/a}" "${breaches:-n/a}" >>"$summary"
    printf 'run_stop label=%s ttft=%s decode=%s p90=%s\n' \
        "$label" "${ttft:-n/a}" "${decode:-n/a}" "${p90:-n/a}"
done

printf '\n'
cat "$summary"
