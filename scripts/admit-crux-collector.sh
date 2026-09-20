#!/bin/sh
# gpu-ownership: delegated to the serving chain.
# Measure graft's crux retry policy against the checkpoints it penalizes.
#
# dist/graph/enrich.js collects a returned record on its id alone,
# `if (!results.has(r.id)) results.set(r.id, r)`, and computes the next
# attempt as `refs.filter((r) => !results.has(r.id))`. applyFileCrux then
# rejects the same record on `!r.summary.trim()` and leaves the node pending.
# An id returned with a blank summary is therefore present enough to retire
# itself from the retry and unusable enough to be discarded afterwards, so one
# of the two attempts is spent on nothing. A checkpoint that produces that
# reply shape more often loses more records to the policy than to its own
# answers, which is a client property being read as a model property.
#
# The arms cross two checkpoints with two collectors over one fixed input. The
# corrected collector accepts a record only when it carries the summary enrich
# requires, so the retry set is the ids that still have none:
#
#     retry targets = requested ids - ids with accepted records
#
# QWEN_CRUX_GRAFT_FIXED names a graft whose enrich.js carries that change;
# QWEN_CRUX_GRAFT_STOCK names the installed one. Both arms run the same tree,
# the same served closure and the same geometry, and each takes its own graft
# directory, so no arm reads another's cache.
#
# Request counts come from the server's own task lines rather than from graft,
# because the retry is the property under test and graft reports only its
# outcome. A reply cut short by the memory guard voids its arm: the telemetry
# is sliced per arm and an abort line there makes the row `void`.
#
#   usage: admit-crux-collector.sh OUTPUT_DIRECTORY
#   QWEN_CRUX_IDS          space-separated registry rows
#   QWEN_CRUX_TREE         the two-file tree both collectors index
#   QWEN_CRUX_GRAFT_STOCK  cli.js of the installed graft
#   QWEN_CRUX_GRAFT_FIXED  cli.js of the collector-corrected copy
set -eu
PYTHON=${PYTHON:-python3}
Q=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
OUT=${1:?usage: admit-crux-collector.sh OUTPUT_DIRECTORY}
IDS=${QWEN_CRUX_IDS:-"qwen38-4b-distill qwen3-4b-instruct-2507"}
TREE=${QWEN_CRUX_TREE:?QWEN_CRUX_TREE names the tree both collectors index}
STOCK=${QWEN_CRUX_GRAFT_STOCK:-/usr/lib/node_modules/@nanonets/graft/dist/cli.js}
FIXED=${QWEN_CRUX_GRAFT_FIXED:?QWEN_CRUX_GRAFT_FIXED names the corrected cli.js}
CONTEXT=${QWEN_CRUX_CONTEXT:-16384}
BUDGET=${QWEN_CRUX_REASONING_BUDGET:-512}
STATE=${QWEN_WEBUI_STATE_DIRECTORY:-"${HOME:?}/qwen-webui-state"}
WORK=${QWEN_CRUX_WORK:-"$OUT/graphs"}
mkdir -p "$OUT" "$WORK"

OUT_ABSOLUTE=$(CDPATH='' cd -- "$OUT" && pwd)
TREE_ABSOLUTE=$(CDPATH='' cd -- "$TREE" && pwd)
# graft echoes its --dir and its tree into the log it writes. The longer roots
# are replaced first, so a path under the home directory resolves to its own
# name rather than to the home one.
scrub_home() {
    sed -e "s|$OUT_ABSOLUTE|\$OUTPUT_DIRECTORY|g" -e "s|$TREE_ABSOLUTE|\$TREE|g" \
        -e "s|${HOME:?}|\$HOME|g"
}
scrub_to() {
    if [ -r "$1" ]; then scrub_home <"$1" >"$2"; else : >"$2"; fi
}
# The launch truncates the appliance logs in place, so an offset taken before
# it addresses the middle of what the next arm writes. The file moves aside
# instead and the arm's log is the whole of what it wrote.
retire_log() {
    [ -e "$1" ] || return 0
    mv -- "$1" "$2"
}
now_ms() { "$PYTHON" -c 'import time; print(time.monotonic_ns()//1000000)'; }

# Eight graded columns sit between the collector name and the verdict.
EMPTY='	-	-	-	-	-	-	-	-'
printf 'model\tcollector\tdeep_status\twall_ms\tfiles\tsymbols\tready\tpending\tcrux_requests\tfile_errors\tverdict\n' \
    >"$OUT/collector.tsv"
trap '"$Q/scripts/qwen-teardown.sh" >/dev/null 2>&1 || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for id in $IDS; do
    row=$("$Q/scripts/model-registry.sh" id "$id")
    model_file=$(printf '%s\n' "$row" | sed -n 's/^model_file=//p')
    for collector in stock fixed; do
        case $collector in
            stock) cli=$STOCK ;;
            fixed) cli=$FIXED ;;
        esac
        arm=$id.$collector
        graph=$WORK/$arm

        "$Q/scripts/qwen-teardown.sh" >/dev/null 2>&1 || true
        retire_log "$STATE/server.log" "$STATE/server.log.previous"
        retire_log "$STATE/telemetry.log" "$STATE/telemetry.log.previous"

        if ! QWEN_CHAT_TOOLS=on QWEN_CHAT_REASONING_BUDGET="$BUDGET" \
            QWEN_CONTEXT_SIZE="$CONTEXT" QWEN_MODEL_PATH=$HOME/models/$model_file \
            "$Q/scripts/qwen-launch.sh" default >"$OUT/$arm.launch" 2>&1; then
            scrub_to "$OUT/$arm.launch" "$OUT/$arm.launch.scrubbed"
            mv "$OUT/$arm.launch.scrubbed" "$OUT/$arm.launch"
            printf '%s\t%s%s\tlaunch_failed\n' "$id" "$collector" "$EMPTY" >>"$OUT/collector.tsv"
            continue
        fi
        scrub_to "$OUT/$arm.launch" "$OUT/$arm.launch.scrubbed"
        mv "$OUT/$arm.launch.scrubbed" "$OUT/$arm.launch"

        eval "$("$Q/scripts/graft-consumer-env.sh")"
        rm -rf "$graph"
        mkdir -p "$graph"
        started=$(now_ms)
        if GRAFT_NO_IGNORE=1 node "$cli" --dir "$graph" build --deep --allow-partial \
            -j 1 "$TREE" >"$OUT/$arm.deep.log" 2>&1; then
            deep_status=0
        else
            deep_status=$?
        fi
        wall=$(( $(now_ms) - started ))
        "$Q/scripts/qwen-teardown.sh" >/dev/null 2>&1 || true

        scrub_to "$OUT/$arm.deep.log" "$OUT/$arm.deep.log.scrubbed"
        mv "$OUT/$arm.deep.log.scrubbed" "$OUT/$arm.deep.log"
        scrub_to "$STATE/server.log" "$OUT/$arm.server.log"
        scrub_to "$STATE/telemetry.log" "$OUT/$arm.telemetry.log"

        # Every request the server admitted prints one `new prompt` line, so
        # the count is the summarize and synthesize calls plus every crux
        # attempt, including the retries this measures.
        crux_requests=$(grep -c 'new prompt' "$OUT/$arm.server.log" 2>/dev/null || true)
        file_errors=$(grep -c 'no usable symbol summaries' "$OUT/$arm.deep.log" 2>/dev/null || true)
        guard_abort=$(sed -n 's/^abort_utc=[^ ]* reason=//p' "$OUT/$arm.telemetry.log" \
            | tr '\n' ',' | sed 's/,$//')

        counts=$("$PYTHON" "$Q/scripts/graft-deep-evidence.py" "$graph")
        printf '%s\n' "$counts" >"$OUT/$arm.graph-evidence.tsv"
        field() { printf '%s\n' "$counts" | sed -n "s/^$1\t//p"; }
        if [ -n "$guard_abort" ]; then
            verdict=void
        else
            verdict=$(field verdict)
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$id" "$collector" "$deep_status" "$wall" "$(field files)" \
            "$(field function_nodes)" "$(field ready)" "$(field pending)" \
            "$crux_requests" "$file_errors" "$verdict" >>"$OUT/collector.tsv"
    done
done
printf 'collector_done\n' >>"$OUT/collector.tsv"
