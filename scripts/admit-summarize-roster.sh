#!/bin/sh
# gpu-ownership: delegated to the serving chain.
# Measure graft's summarize request against named registry rows, through
# qwen-launch.sh, so a model is chosen for the deep pass by what it returns
# rather than by its size. The request is graft's own: its system prompt,
# its 24000-character clip of the file, temperature 0, one request per file
# for three files of rising size, after the forced tool-call probe
# scripts/graft-consumer-env.sh records through. A thinking model spends a
# client's reply cap on the thought block first, and a small model that has
# finished thinking may run on until the cap: both read as finish=length
# here, and prompt plus completion reaching the context size reads as
# outcome=context_exhausted, where a fit model reads finish=stop on every
# file.
#
#   usage: admit-summarize-roster.sh OUTPUT_TSV
#   QWEN_SUMMARIZE_SOURCE   the tree the three probe files are read from
#   QWEN_ROSTER_IDS         space-separated row ids to measure; unset measures
#                           every admitted row, and every named id must be a
#                           row the roster can launch or nothing launches
#   QWEN_ROSTER_MAX_TOKENS  the reply cap, default 32768, the value the
#                           installed graft sends
#
# Rows whose context_ceiling is below graft's 16384-token floor are skipped.
# Every request's full answer is retained beside OUTPUT_TSV as
# OUTPUT_TSV.<id>.<file>.json, so a column here is re-derivable from it.
# Failures are classified apart: launch, transport (curl exit), http
# (status other than 200), and body (no usage or choices in the answer).
# The server the roster launched is torn down on every exit path.
set -eu
Q=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
D=${QWEN_SUMMARIZE_SOURCE:?QWEN_SUMMARIZE_SOURCE names the source tree the three files are read from}
OUT=$1
cap=${QWEN_ROSTER_MAX_TOKENS:-32768}
TAB=$(printf '\t')
system_prompt='You document source code for a team knowledge base. Given one source file, write a compact plain-English summary covering:
1. The purpose of the file - what it exists to do.
2. The key exported functions/classes/types and what each is for.
3. Important dependencies: internal modules it builds on, external libraries or services it talks to.
4. Notable design decisions, constraints, or gotchas evident in the code.

Write 3-8 sentences of flowing prose. Name concrete identifiers (modules, classes, services) so they can become graph entities. No code blocks, no line-by-line narration, no filler.'

eligible=$(grep -v '^#' "$Q/scripts/models.tsv" |
    awk -F'\t' '$16!="archive" && $16!="quarantine" && $6>=16384 {print $1"\t"$6"\t"$3}')
if [ -n "${QWEN_ROSTER_IDS+set}" ]; then
    [ -n "$QWEN_ROSTER_IDS" ] || { printf 'QWEN_ROSTER_IDS is set and empty; unset it to measure every row\n' >&2; exit 2; }
    selected=''
    for id in $QWEN_ROSTER_IDS; do
        row=$(printf '%s\n' "$eligible" | awk -F'\t' -v id="$id" '$1==id') || true
        [ -n "$row" ] || { printf 'QWEN_ROSTER_IDS names %s, which is no admitted row with a ceiling of 16384 or more\n' "$id" >&2; exit 2; }
        selected="$selected$row
"
    done
    eligible=$selected
fi

now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
trap '"$Q/scripts/qwen-teardown.sh" >/dev/null 2>&1 || true' EXIT INT TERM
printf 'model\tfile\tprompt_tokens\tcompletion_tokens\tfinish\treasoning_chars\tcontent_chars\twall_ms\ttool_call\thttp_status\toutcome\n' >"$OUT"
printf '%s' "$eligible" | while IFS="$TAB" read -r id ceil file; do
    [ -n "$id" ] || continue
    ctx=$ceil; [ "$ctx" -gt 32768 ] && ctx=32768
    "$Q/scripts/qwen-teardown.sh" >/dev/null 2>&1 || true
    if ! QWEN_CHAT_TOOLS=on QWEN_CHAT_REASONING_BUDGET=8192 QWEN_CONTEXT_SIZE=$ctx \
        QWEN_MODEL_PATH=$HOME/models/$file "$Q/scripts/qwen-launch.sh" default >"$OUT.$id.launch" 2>&1; then
        printf '%s\t-\t-\t-\t-\t-\t-\t-\t-\t-\tlaunch_failed\n' "$id" >>"$OUT"; continue
    fi
    if "$Q/scripts/graft-consumer-env.sh" >/dev/null 2>"$OUT.$id.probe"; then tc=yes; else tc=no; fi
    header_file=$(mktemp "${TMPDIR:-/tmp}/summarize-roster.XXXXXX")
    printf 'header = "Authorization: Bearer %s"\n' "$(tr -d '\n' <"$HOME/qwen-webui-state/api.key")" >"$header_file"
    for f in sys/arch/rp2040/dev/flash_swap.c bin/cat/cat.c sys/arch/rp2040/dev/usb.c; do
        answer=$OUT.$id.$(basename "$f").json
        body=$(jq -n --arg code "$(head -c 24000 "$D/$f")" --arg f "$f" --arg sys "$system_prompt" --argjson cap "$cap" \
            '{model:"qwen-nvidia",temperature:0,max_tokens:$cap,messages:[{role:"system",content:$sys},{role:"user",content:("File: "+$f+"\n\n"+$code)}]}')
        s=$(now_ms)
        if status=$(curl --silent --max-time 660 --config "$header_file" --output "$answer" --write-out '%{http_code}' \
            -H 'Content-Type: application/json' --data "$body" http://127.0.0.1:8080/v1/chat/completions); then
            transport=ok
        else
            transport="curl_$?"; status=${status:--}
        fi
        w=$(( $(now_ms) - s ))
        if [ "$transport" != ok ]; then outcome=transport_$transport
        elif [ "$status" != 200 ]; then outcome=http
        elif ! jq -e '.usage.prompt_tokens and .choices[0]' "$answer" >/dev/null 2>&1; then outcome=body
        else
            pt=$(jq -r '.usage.prompt_tokens' "$answer"); ct=$(jq -r '.usage.completion_tokens' "$answer")
            if [ $((pt + ct)) -ge "$ctx" ]; then outcome=context_exhausted
            elif [ "$(jq -r '.choices[0].finish_reason' "$answer")" = stop ]; then outcome=stop
            else outcome=capped; fi
        fi
        if [ "$outcome" = stop ] || [ "$outcome" = capped ] || [ "$outcome" = context_exhausted ]; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$f" "$pt" "$ct" \
                "$(jq -r '.choices[0].finish_reason // "none"' "$answer")" \
                "$(jq -r '.choices[0].message.reasoning_content // ""' "$answer" | wc -c)" \
                "$(jq -r '.choices[0].message.content // ""' "$answer" | wc -c)" "$w" "$tc" "$status" "$outcome" >>"$OUT"
        else
            printf '%s\t%s\t-\t-\t-\t-\t-\t%s\t%s\t%s\t%s\n' "$id" "$f" "$w" "$tc" "$status" "$outcome" >>"$OUT"
        fi
    done
    rm -f "$header_file"
done
printf 'roster_done\n' >>"$OUT"
