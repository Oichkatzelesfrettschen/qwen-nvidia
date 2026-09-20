#!/bin/sh
# gpu-ownership: delegated to the serving chain.
# Measure graft's summarize request against named registry rows, through
# qwen-launch.sh, so a model is chosen for the deep pass by what it returns
# rather than by its size. The request is graft's own: its system prompt,
# the first 24000 characters of the file (a character count, the slice
# graft takes, so a multibyte file is cut at a character boundary),
# temperature 0, one request per file for the probe files in rising size,
# after the forced tool-call probe scripts/graft-consumer-env.sh records
# through.
#
#   usage: admit-summarize-roster.sh OUTPUT_TSV
#   QWEN_SUMMARIZE_SOURCE        the tree the probe files are read from
#   QWEN_ROSTER_IDS              space-separated row ids to measure; unset
#                                measures every admitted row; a set value
#                                names at least one row, each an admitted row
#                                with a ceiling of 16384 or more, none twice,
#                                or nothing launches
#   QWEN_ROSTER_FILES            space-separated probe files, default the
#                                three DiscoBSD files
#   QWEN_ROSTER_MAX_TOKENS       the reply cap, default 32768, the value the
#                                installed graft sends
#   QWEN_CHAT_REASONING_BUDGET   the thought budget each launch binds, default
#                                8192
#   QWEN_ROSTER_REQUEST_TIMEOUT  seconds curl waits for one answer, default 660
#   QWEN_SERVER_PORT             the served listener, default 8080
#   QWEN_WEBUI_STATE_DIRECTORY   holds api.key, default $HOME/qwen-webui-state
#
# Rows whose context_ceiling is below graft's 16384-token floor are skipped.
# Every request body and every full answer is retained beside OUTPUT_TSV as
# OUTPUT_TSV.<id>.<file>.request.json and .json, so a column here is
# re-derivable from them. Three observations stay separate in the columns:
# response validity (outcome http, body, transport_*, launch_failed),
# termination (finish, and context_boundary=yes when prompt plus completion
# reach the context size, a diagnostic beside the finish reason rather than
# a replacement for it), and usability (outcome blank when a stopped answer
# holds no non-whitespace content). A thinking model spends the reply cap
# on its thought block first, and a small model that has finished thinking
# may run on until the cap: both read finish=length, outcome capped.
# The server the roster launched is torn down on every exit path once a
# selection is accepted; a refused selection launches nothing and tears
# nothing down.
set -eu
Q=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
D=${QWEN_SUMMARIZE_SOURCE:?QWEN_SUMMARIZE_SOURCE names the source tree the probe files are read from}
OUT=$1
cap=${QWEN_ROSTER_MAX_TOKENS:-32768}
# The thought budget the launch binds, 8192 where the caller names none, so a
# replay of the first roster keeps its setting and a screen can bound it.
reasoning_budget=${QWEN_CHAT_REASONING_BUDGET:-8192}
request_timeout=${QWEN_ROSTER_REQUEST_TIMEOUT:-660}
server_port=${QWEN_SERVER_PORT:-8080}
state_directory=${QWEN_WEBUI_STATE_DIRECTORY:-"${HOME:?}/qwen-webui-state"}
files=${QWEN_ROSTER_FILES:-"sys/arch/rp2040/dev/flash_swap.c bin/cat/cat.c sys/arch/rp2040/dev/usb.c"}
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
    # shellcheck disable=SC2086
    set -- $QWEN_ROSTER_IDS
    [ "$#" -gt 0 ] || { printf 'QWEN_ROSTER_IDS is set and names no row; unset it to measure every row\n' >&2; exit 2; }
    selected=''
    seen=' '
    for id in "$@"; do
        case "$seen" in *" $id "*) printf 'QWEN_ROSTER_IDS names %s twice\n' "$id" >&2; exit 2 ;; esac
        seen="$seen$id "
        row=$(printf '%s\n' "$eligible" | awk -F'\t' -v id="$id" '$1==id') || true
        [ -n "$row" ] || { printf 'QWEN_ROSTER_IDS names %s, which is no admitted row with a ceiling of 16384 or more\n' "$id" >&2; exit 2; }
        selected="$selected$row
"
    done
    eligible=$selected
fi
for f in $files; do
    [ -r "$D/$f" ] || { printf 'probe file is unreadable: %s\n' "$D/$f" >&2; exit 2; }
done

now_ms() { python3 -c 'import time; print(time.monotonic_ns() // 1000000)'; }
clip() { python3 -c 'import sys; sys.stdout.write(open(sys.argv[1], encoding="utf-8", errors="replace").read()[:24000])' "$1"; }
# A signal ends the run after the teardown; the handler's own exit is what
# makes it terminal, since a trapped signal alone resumes the script.
trap '"$Q/scripts/qwen-teardown.sh" >/dev/null 2>&1 || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf 'model\tfile\tprompt_tokens\tcompletion_tokens\tfinish\treasoning_chars\tcontent_chars\tcontext_boundary\twall_ms\ttool_call\thttp_status\toutcome\n' >"$OUT"
printf '%s\n' "$eligible" | while IFS="$TAB" read -r id ceil file; do
    [ -n "$id" ] || continue
    ctx=$ceil; [ "$ctx" -gt 32768 ] && ctx=32768
    "$Q/scripts/qwen-teardown.sh" >/dev/null 2>&1 || true
    if ! QWEN_CHAT_TOOLS=on QWEN_CHAT_REASONING_BUDGET=$reasoning_budget QWEN_CONTEXT_SIZE=$ctx \
        QWEN_MODEL_PATH=$HOME/models/$file "$Q/scripts/qwen-launch.sh" default >"$OUT.$id.launch" 2>&1; then
        printf '%s\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\tlaunch_failed\n' "$id" >>"$OUT"; continue
    fi
    if "$Q/scripts/graft-consumer-env.sh" >/dev/null 2>"$OUT.$id.probe"; then tc=yes; else tc=no; fi
    header_file=$(mktemp "${TMPDIR:-/tmp}/summarize-roster.XXXXXX")
    printf 'header = "Authorization: Bearer %s"\n' "$(tr -d '\n' <"$state_directory/api.key")" >"$header_file"
    for f in $files; do
        stem=$OUT.$id.$(basename "$f")
        answer=$stem.json
        clip "$D/$f" >"$stem.clip"
        jq -n --rawfile code "$stem.clip" --arg f "$f" --arg sys "$system_prompt" --argjson cap "$cap" \
            '{model:"qwen-nvidia",temperature:0,max_tokens:$cap,messages:[{role:"system",content:$sys},{role:"user",content:("File: "+$f+"\n\n"+$code)}]}' \
            >"$stem.request.json"
        rm -f "$stem.clip"
        s=$(now_ms)
        if status=$(curl --silent --max-time "$request_timeout" --config "$header_file" --output "$answer" --write-out '%{http_code}' \
            -H 'Content-Type: application/json' --data-binary "@$stem.request.json" "http://127.0.0.1:$server_port/v1/chat/completions"); then
            transport=ok
        else
            transport="curl_$?"; status=${status:--}
        fi
        w=$(( $(now_ms) - s ))
        pt=-; ct=-; finish=-; rc=-; cc=-; boundary=-
        if [ "$transport" != ok ]; then outcome=transport_$transport
        elif [ "$status" != 200 ]; then outcome=http
        elif ! jq -e '(.usage.prompt_tokens | type) == "number" and (.usage.completion_tokens | type) == "number" and (.choices[0].message | type) == "object"' "$answer" >/dev/null 2>&1; then outcome=body
        else
            pt=$(jq -r '.usage.prompt_tokens' "$answer"); ct=$(jq -r '.usage.completion_tokens' "$answer")
            finish=$(jq -r '.choices[0].finish_reason // "none"' "$answer")
            rc=$(jq -j '.choices[0].message.reasoning_content // ""' "$answer" | wc -c)
            cc=$(jq -j '.choices[0].message.content // ""' "$answer" | wc -c)
            if [ $((pt + ct)) -ge "$ctx" ]; then boundary=yes; else boundary=no; fi
            case $finish in
                stop)
                    if [ -n "$(jq -j '.choices[0].message.content // ""' "$answer" | tr -d '[:space:]')" ]; then outcome=stop; else outcome=blank; fi ;;
                length) outcome=capped ;;
                *) outcome=finish_$finish ;;
            esac
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$f" "$pt" "$ct" "$finish" "$rc" "$cc" "$boundary" "$w" "$tc" "$status" "$outcome" >>"$OUT"
    done
    rm -f "$header_file"
done
printf 'roster_done\n' >>"$OUT"
