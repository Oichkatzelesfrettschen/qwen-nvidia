#!/bin/sh
# Record what each checkpoint returns for a crux request, by id.
#
# A crux record reaches the graph only when its id matches a requested target
# and its summary is non-blank. The deep log reports neither: it prints one miss
# class per file, drawn from a field the summarizer overwrites on every call,
# and no reply body is retained anywhere. This runs one traced graft per
# checkpoint over one tree and writes the ids requested, parsed, matched and
# summarized for every attempt, so a lost record is attributed rather than
# inferred.
#
# The instrumentation observes and changes no acceptance rule, so a traced run
# takes the path an untraced run takes. QWEN_CRUX_COLLECTOR selects which
# collector is traced: stock, or resolved, which resolves an echoed target line
# back to the id it names.
#
#   usage: admit-crux-identity.sh OUTPUT_DIRECTORY
#
#   QWEN_CRUX_IDS          checkpoints to cross, default the two 4B rows
#   QWEN_CRUX_TREE         the tree the traced graft indexes
#   QWEN_CRUX_COLLECTOR    stock or resolved, default stock
#   QWEN_CRUX_CONTEXT      served depth, default 16384
set -eu

PYTHON=${PYTHON:-python3}
Q=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

OUT=${1:?usage: admit-crux-identity.sh OUTPUT_DIRECTORY}
IDS=${QWEN_CRUX_IDS:-"qwen38-4b-distill qwen3-4b-instruct-2507"}
TREE=${QWEN_CRUX_TREE:?QWEN_CRUX_TREE names the tree the traced graft indexes}
STOCK=${QWEN_CRUX_GRAFT_STOCK:-/usr/lib/node_modules/@nanonets/graft/dist/cli.js}
COLLECTOR=${QWEN_CRUX_COLLECTOR:-stock}
CONTEXT=${QWEN_CRUX_CONTEXT:-16384}
BUDGET=${QWEN_CRUX_REASONING_BUDGET:-512}
STATE=${QWEN_WEBUI_STATE_DIRECTORY:-"${HOME:?}/qwen-webui-state"}
WORK=${QWEN_CRUX_WORK:-"$OUT/graphs"}
mkdir -p "$OUT" "$WORK"

OUT_ABSOLUTE=$(CDPATH='' cd -- "$OUT" && pwd)
TREE_ABSOLUTE=$(CDPATH='' cd -- "$TREE" && pwd)
scrub_home() {
    sed -e "s|$OUT_ABSOLUTE|\$OUTPUT_DIRECTORY|g" -e "s|$TREE_ABSOLUTE|\$TREE|g" \
        -e "s|${HOME:?}|\$HOME|g"
}
scrub_to() {
    if [ -r "$1" ]; then scrub_home <"$1" >"$2"; else : >"$2"; fi
}
retire_log() {
    [ -e "$1" ] || return 0
    mv -- "$1" "$2"
}
now_ms() { "$PYTHON" -c 'import time; print(time.monotonic_ns()//1000000)'; }

# The instrumented copy is built from the installed graft and read back by the
# markers its patches introduce, so a run cannot report a trace the collector
# never wrote, nor a correction that failed to apply. The correction goes on
# first: the trace anchors on lines it leaves alone.
TRACED=$WORK/graft-traced-$COLLECTOR
if [ ! -d "$TRACED" ]; then
    cp -a "$(dirname -- "$(dirname -- "$STOCK")")" "$TRACED"
    if [ "$COLLECTOR" = resolved ]; then
        "$PYTHON" "$Q/scripts/crux-collector-identity-patch.py" \
            "$TRACED/dist/graph/enrich.js"
    fi
    "$PYTHON" "$Q/scripts/crux-collector-trace-patch.py" \
        "$TRACED/dist/graph/enrich.js"
fi
if ! grep -q traceCruxAttempt "$TRACED/dist/graph/enrich.js"; then
    printf 'the traced copy carries no attempt trace\n' >&2
    exit 1
fi
if [ "$COLLECTOR" = resolved ] && ! grep -q resolveId "$TRACED/dist/graph/enrich.js"; then
    printf 'the traced copy carries no id resolution\n' >&2
    exit 1
fi

printf 'model\tcollector\tdeep_status\twall_ms\tattempts\tidentity\trecovered\tblank\tcomplete\tverdict\n' \
    >"$OUT/identity.tsv"
trap '"$Q/scripts/qwen-teardown.sh" >/dev/null 2>&1 || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for id in $IDS; do
    row=$("$Q/scripts/model-registry.sh" id "$id")
    model_file=$(printf '%s\n' "$row" | sed -n 's/^model_file=//p')

    "$Q/scripts/qwen-teardown.sh" >/dev/null 2>&1 || true
    retire_log "$STATE/server.log" "$STATE/server.log.previous"
    retire_log "$STATE/telemetry.log" "$STATE/telemetry.log.previous"

    if ! QWEN_CHAT_TOOLS=on QWEN_CHAT_REASONING_BUDGET="$BUDGET" \
        QWEN_CONTEXT_SIZE="$CONTEXT" QWEN_MODEL_PATH=$HOME/models/$model_file \
        "$Q/scripts/qwen-launch.sh" default >"$OUT/$id.$COLLECTOR.launch" 2>&1; then
        scrub_to "$OUT/$id.$COLLECTOR.launch" "$OUT/$id.$COLLECTOR.launch.scrubbed"
        mv "$OUT/$id.$COLLECTOR.launch.scrubbed" "$OUT/$id.$COLLECTOR.launch"
        printf '%s\t%s\t-\t-\t-\t-\t-\t-\t-\tlaunch_failed\n' "$id" "$COLLECTOR" \
            >>"$OUT/identity.tsv"
        continue
    fi
    scrub_to "$OUT/$id.$COLLECTOR.launch" "$OUT/$id.$COLLECTOR.launch.scrubbed"
    mv "$OUT/$id.$COLLECTOR.launch.scrubbed" "$OUT/$id.$COLLECTOR.launch"

    eval "$("$Q/scripts/graft-consumer-env.sh")"
    trace=$OUT/$id.$COLLECTOR.trace.jsonl
    : >"$trace"
    started=$(now_ms)
    if GRAFT_CRUX_TRACE=$trace GRAFT_NO_IGNORE=1 \
        node "$TRACED/dist/cli.js" --dir "$WORK/$id.$COLLECTOR" build --deep \
        --allow-partial -j 1 "$TREE" >"$OUT/$id.$COLLECTOR.deep.log" 2>&1; then
        deep_status=0
    else
        deep_status=$?
    fi
    wall=$(( $(now_ms) - started ))
    "$Q/scripts/qwen-teardown.sh" >/dev/null 2>&1 || true

    scrub_to "$OUT/$id.$COLLECTOR.deep.log" "$OUT/$id.$COLLECTOR.deep.log.scrubbed"
    mv "$OUT/$id.$COLLECTOR.deep.log.scrubbed" "$OUT/$id.$COLLECTOR.deep.log"
    scrub_to "$STATE/server.log" "$OUT/$id.$COLLECTOR.server.log"
    scrub_to "$STATE/telemetry.log" "$OUT/$id.$COLLECTOR.telemetry.log"

    "$PYTHON" "$Q/scripts/crux-identity-evidence.py" "$trace" >"$OUT/$id.$COLLECTOR.identity.tsv"
    count() { sed 1d "$OUT/$id.$COLLECTOR.identity.tsv" | awk -F'\t' -v want="$1" '$11==want' | wc -l; }
    attempts=$(sed 1d "$OUT/$id.$COLLECTOR.identity.tsv" | wc -l)
    identity=$(count identity)
    recovered=$(count recovered)
    blank=$(count blank)
    complete=$(count complete)

    guard_abort=$(sed -n 's/^abort_utc=[^ ]* reason=//p' "$OUT/$id.$COLLECTOR.telemetry.log" \
        | tr '\n' ',' | sed 's/,$//')
    if [ -n "$guard_abort" ]; then
        verdict=void
    elif [ "$identity" -gt 0 ]; then
        verdict=identity_loss
    elif [ "$blank" -gt 0 ]; then
        verdict=blank_summaries
    elif [ "$recovered" -gt 0 ]; then
        verdict=identity_recovered
    elif [ "$attempts" -eq "$complete" ]; then
        verdict=complete
    else
        verdict=mixed
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$id" "$COLLECTOR" "$deep_status" "$wall" "$attempts" "$identity" \
        "$recovered" "$blank" "$complete" "$verdict" >>"$OUT/identity.tsv"
done
printf 'identity_done\n' >>"$OUT/identity.tsv"
