#!/bin/sh
# gpu-ownership: delegated to the serving chain.
# Measure graft's summarize request shape against every admitted text-capable
# registry row, through qwen-launch.sh, so a model is chosen for the deep
# pass by what it returns rather than by its size. A thinking model spends a
# client's reply cap on the thought block first, and a small model that has
# finished thinking may run on until the cap: both read as one row here,
# finish=length with tens of thousands of content characters, where a fit
# model reads finish=stop on every file. Three files of rising size, one
# request each at a 32768 reply cap and an 8192 thought budget, plus the
# forced tool-call probe graft records through.
#
#   usage: admit-summarize-roster.sh OUTPUT_TSV
#   QWEN_SUMMARIZE_SOURCE   the tree the three probe files are read from
#
# Rows whose context_ceiling is below graft's 16384-token floor are skipped.
set -eu
Q=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
D=${QWEN_SUMMARIZE_SOURCE:?QWEN_SUMMARIZE_SOURCE names the source tree the three files are read from}
OUT=$1
printf 'model\tfile\tprompt_tokens\tcompletion_tokens\tfinish\treasoning_chars\tcontent_chars\twall_s\ttool_call\n' >"$OUT"
grep -v '^#' "$Q/scripts/models.tsv" | awk -F'\t' '$16!="archive" && $16!="quarantine" && $6>=16384 {print $1"\t"$6"\t"$3}' |
while IFS="$(printf '\t')" read -r id ceil file; do
    ctx=$ceil; [ "$ctx" -gt 32768 ] && ctx=32768
    "$Q/scripts/qwen-teardown.sh" >/dev/null 2>&1
    if ! QWEN_CHAT_TOOLS=on QWEN_CHAT_REASONING_BUDGET=8192 QWEN_CONTEXT_SIZE=$ctx \
        QWEN_MODEL_PATH=$HOME/models/$file "$Q/scripts/qwen-launch.sh" default >"$OUT.$id.launch" 2>&1; then
        printf '%s\tLAUNCH_FAILED\t-\t-\t-\t-\t-\t-\t-\n' "$id" >>"$OUT"; continue
    fi
    if "$Q/scripts/graft-consumer-env.sh" >/dev/null 2>&1; then tc=yes; else tc=no; fi
    K=$(cat "$HOME/qwen-webui-state/api.key")
    for f in sys/arch/rp2040/dev/flash_swap.c bin/cat/cat.c sys/arch/rp2040/dev/usb.c; do
        body=$(jq -n --arg code "$(cat "$D/$f")" --arg f "$f" '{model:"qwen-nvidia",temperature:0,max_tokens:32768,messages:[{role:"system",content:"Summarize the file in plain English: 1. What it does overall. 2. The key exported functions and what each is for."},{role:"user",content:("File: "+$f+"\n\n"+$code)}]}')
        s=$(date +%s)
        r=$(timeout 700 curl -s -m 660 http://127.0.0.1:8080/v1/chat/completions -H "Authorization: Bearer $K" -H 'Content-Type: application/json' -d "$body")
        w=$(( $(date +%s) - s ))
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$f" \
            "$(printf '%s' "$r" | jq -r '.usage.prompt_tokens // "-"')" \
            "$(printf '%s' "$r" | jq -r '.usage.completion_tokens // "-"')" \
            "$(printf '%s' "$r" | jq -r '.choices[0].finish_reason // "none"')" \
            "$(printf '%s' "$r" | jq -r '.choices[0].message.reasoning_content // ""' | wc -c)" \
            "$(printf '%s' "$r" | jq -r '.choices[0].message.content // ""' | wc -c)" "$w" "$tc" >>"$OUT"
        printf '%s' "$r" | jq -r '.choices[0].message.content // ""' | head -c 1200 >"$OUT.$id.$(basename "$f").txt"
    done
done
"$Q/scripts/qwen-teardown.sh" >/dev/null 2>&1
printf 'roster_done\n' >>"$OUT"
