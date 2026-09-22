#!/bin/sh
# gpu-ownership: delegated to the serving chain.
# Put named registry rows against graft's own record_symbols contract, which
# is the request its symbol pass actually sends and the one shape a row must
# satisfy to produce graph input at all.
#
# The contract is mechanical, which is what the prose screens are not. graft
# numbers the file's lines, lists its target definitions by id with their
# line ranges, forces a call to record_symbols, and requires exactly one
# entry per target id, that id verbatim, a one-sentence summary, and a crux
# span inside that symbol's own range or the literal 0/0 that means the
# symbol has no focal span. Every one of those is checkable against the
# request without reading the prose: an id the file never listed is an
# invention, a missing id is a dropped target, and a crux outside the
# symbol's range points at code the summary does not describe.
#
# Targets come from graft's own graph, which is what makes the count and the
# span reference agree. An earlier revision read them from `graft skeleton`
# and keyed them on the bare symbol name, so a file carrying a prototype and
# its definition requested more rows than it graded and charged the surplus
# to the model; record-symbols-contract.py holds that reasoning and
# test-record-symbols-contract.py calibrates it.
#
# A row that passes here has not said anything true. It has produced a
# well-formed record whose spans point where they claim to. The six
# contract questions remain the semantic gate; this is the gate before it,
# and the broad screen's forced record_probe call is weaker than both,
# since a boolean argument exercises none of this.
#
#   usage: admit-record-symbols.sh OUTPUT_DIRECTORY
#   QWEN_SYMBOLS_IDS     space-separated registry rows
#   QWEN_SYMBOLS_SOURCE  the DiscoBSD tree
#   QWEN_SYMBOLS_FILES   space-separated probe files
set -eu
: "${PYTHON:?Select the intended Python interpreter}"
# Thirteen graded columns sit between the file name and the outcome, which
# record-symbols-contract.py prints as its own header.
EMPTY='	-	-	-	-	-	-	-	-	-	-	-	-	-'
Q=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
OUT=${1:?usage: admit-record-symbols.sh OUTPUT_DIRECTORY}
D=${QWEN_SYMBOLS_SOURCE:-"${HOME:?}/Github/discobsd-2040-unofficial"}
IDS=${QWEN_SYMBOLS_IDS:-"lfm25-350m-qad qwen3-4b-instruct-2507 qwen38-4b-distill"}
FILES=${QWEN_SYMBOLS_FILES:-"sys/arch/rp2040/dev/flash_swap.c sys/kern/kern_mman.c sys/arch/rp2040/rp2040/sig_machdep.c"}
CAP=${QWEN_SYMBOLS_MAX_TOKENS:-2048}
TIMEOUT=${QWEN_SYMBOLS_TIMEOUT:-180}
PORT=${QWEN_SERVER_PORT:-8080}
STATE=${QWEN_WEBUI_STATE_DIRECTORY:-"${HOME:?}/qwen-webui-state"}
mkdir -p "$OUT"

# One request per file, built the way dist/ai/crux.js builds it: the file
# under 1-based line numbers clipped at 18000 characters, then the target
# list. The ids are graft's own node ids, read from the graph the deep pass
# writes, so a name occurring twice in one file stays two targets.
CONTRACT="$Q/scripts/record-symbols-contract.py"
GRAPH=${QWEN_SYMBOLS_GRAPH:-"$D/graft/.graph/wiring.json"}
[ -r "$GRAPH" ] || { printf 'no graph at %s; run graft build first\n' "$GRAPH" >&2; exit 1; }
for f in $FILES; do
    stem=$OUT/$(printf '%s' "$f" | tr / _)
    if [ "$("$PYTHON" "$CONTRACT" targets "$GRAPH" "$f" "$stem.targets")" = 0 ]; then
        printf 'no targets for %s\n' "$f" >&2
        rm -f "$stem.targets"
        continue
    fi
    "$PYTHON" "$CONTRACT" request "$D/$f" "$f" "$stem.targets" "$stem.request.json" "$CAP"
done

"$PYTHON" "$CONTRACT" columns >"$OUT/symbols.tsv"
active_model=''
header=''
cleanup_server() {
    if [ -n "$header" ]; then
        rm -f -- "$header"
        header=''
    fi
    [ -n "$active_model" ] || return 0
    "$Q/scripts/qwen-teardown.sh" >"$OUT/$active_model.teardown" 2>&1
    active_model=''
}
trap cleanup_server EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for id in $IDS; do
    row=$("$Q/scripts/model-registry.sh" id "$id")
    file=$(printf '%s\n' "$row" | sed -n 's/^model_file=//p')
    cleanup_server
    if ! QWEN_REQUIRE_API_KEY=1 QWEN_CHAT_TOOLS=on QWEN_CHAT_REASONING_BUDGET=512 QWEN_CONTEXT_SIZE=16384 \
        QWEN_MODEL_PATH=$HOME/models/$file "$Q/scripts/qwen-launch.sh" default \
        >"$OUT/$id.launch" 2>&1; then
        for f in $FILES; do
            printf '%s\t%s%b\tlaunch_failed\n' "$id" "$f" "$EMPTY" >>"$OUT/symbols.tsv"
        done
        continue
    fi
    active_model=$id
    header=$(mktemp "${TMPDIR:-/tmp}/symbols.XXXXXX")
    printf 'header = "Authorization: Bearer %s"\n' "$(tr -d '\n' <"$STATE/api.key")" >"$header"
    for f in $FILES; do
        stem=$OUT/$(printf '%s' "$f" | tr / _)
        [ -s "$stem.request.json" ] || continue
        answer=$OUT/$id.$(basename "$f").symbols.json
        s=$("$PYTHON" -c 'import time; print(time.monotonic_ns()//1000000)')
        status=$(curl --user-agent 'Mozilla/5.0' --silent --max-time "$TIMEOUT" --config "$header" --output "$answer" \
            --write-out '%{http_code}' -H 'Content-Type: application/json' \
            --data-binary "@$stem.request.json" \
            "http://127.0.0.1:$PORT/v1/chat/completions") || status=transport
        w=$(( $("$PYTHON" -c 'import time; print(time.monotonic_ns()//1000000)') - s ))
        "$PYTHON" "$CONTRACT" check "$answer" "$stem.targets" \
            "$id" "$f" "$w" "$status" >>"$OUT/symbols.tsv"
    done
    rm -f "$header"
done
cleanup_server
printf 'symbols_done\n' >>"$OUT/symbols.tsv"
awk -F '\t' 'NR > 1 && $0 != "symbols_done" { rows++; if ($NF != "pass") failed=1 }
    END { exit (failed || rows == 0) }' "$OUT/symbols.tsv"
