#!/bin/sh
# gpu-ownership: delegated to the serving chain.
# Put a checkpoint against graft's own --deep pass on a bounded tree, so the
# question a roster screen leaves open -- whether a checkpoint produces a
# context graph a reader can use -- is decided by the client that consumes it
# rather than by a replica of one of its requests.
#
# The crux pass is the request that decides it. dist/ai/crux.js sends ONE file
# under 1-based line numbers clipped at 18000 characters, lists every target
# definition by id with its own line range, sets responseFormat
# {kind:"tool", name:"record_symbols"}, and caps the reply at 8192 tokens; the
# OpenAI adapter turns that response format into the named-function tool_choice
# object. The served closure 192d0663a533 carries
# llama-server-tool-choice-object.patch and resolves that object to the named
# tool under "required". Every closure before it read the object through
# json_value(body, "tool_choice", std::string("auto")) and answered a request
# nothing forced. graft conceals that downgrade: argsFromResponse falls back to
# recoverToolArgsFromContent, so a model that writes the payload as prose still
# fills the graph, and the loss surfaces only as the warning
# warnToolChoiceIgnored prints, which this harness counts.
#
# Both arms read the same bytes. Each id takes its own detached worktree of the
# source tree, sparse-checked-out to the same paths at the same commit, and its
# own graft directory outside that worktree, so no arm replays another's
# summaries out of graft/.cache and `git worktree remove` retires each one
# without --force.
#
# The knobs are equal where they apply and named where they do not.
# qwen-capacity-policy.sh serves --parallel 1, so a concurrency above 1 queues
# at the one slot and inflates per-request latency while wall time stands
# still; the pass runs at 1 and the wall time is a sum of request latencies.
# The reasoning budget bounds the thought block of a thinking template. The
# distill row carries one and spends an unbounded budget before its content
# reaches the call; the 2507 instruct row has no thought block, so the same
# value costs it nothing, and leaving the budget unset would measure the two
# templates rather than the two models.
#
# What the graph holds is not what the model said. buildCrux clamps a returned
# span into the node's own range before storing it, so a crux read back from
# wiring.json is inside its symbol whatever the model answered.
# graft-deep-evidence.py therefore reports completion and coverage, which the
# graph does carry, and admit-record-symbols.sh measures span fidelity on the
# unclamped wire.
#
# A terminated server is not a model result. monitor-qwen-runtime.sh ends a
# server that reads more than 64 MiB of swap in one sample while mem_available
# sits under its headroom, and this host swaps to zram, so a desktop page-in
# storm reaches that rate while the server holds none of it. The client reports
# the SIGKILL as a transport error and a reader takes it for a model that
# cannot answer. Each arm therefore slices the guard's own telemetry and an arm
# the guard ended carries the verdict void. QWEN_SWAPIN_HEADROOM_KIB passes
# through unchanged; minimum_mem_available_kib stays where it is and ends a
# server on its own, so moving the headroom narrows the band this rate watches
# without removing the reserve underneath it.
#
#   usage: admit-graft-deep.sh OUTPUT_DIRECTORY
#   QWEN_GRAFT_IDS       space-separated registry rows, in run order
#   QWEN_GRAFT_SOURCE    the source checkout the arms sparse-check out
#   QWEN_GRAFT_PATHS     cone paths the sparse checkout keeps
#   QWEN_GRAFT_TREES     directory the per-arm worktrees live under
#   QWEN_GRAFT_CONTEXT   served depth, equal across arms
#   QWEN_GRAFT_REASONING_BUDGET  thought-block bound, equal across arms
#   QWEN_GRAFT_JOBS      graft --deep concurrency, 1 for the served geometry
#   QWEN_SWAPIN_HEADROOM_KIB  passed to the runtime guard unchanged
set -eu

PYTHON=${PYTHON:-python3}
Q=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
OUT=${1:?usage: admit-graft-deep.sh OUTPUT_DIRECTORY}
IDS=${QWEN_GRAFT_IDS:-"qwen38-4b-distill qwen3-4b-instruct-2507"}
SOURCE=${QWEN_GRAFT_SOURCE:-"${HOME:?}/Github/discobsd-2040-unofficial"}
CONE=${QWEN_GRAFT_PATHS:-"sys/arch/rp2040/dev sys/arch/rp2040/rp2040"}
TREES=${QWEN_GRAFT_TREES:-"${HOME:?}/worktrees/discobsd-2040-unofficial"}
CONTEXT=${QWEN_GRAFT_CONTEXT:-16384}
BUDGET=${QWEN_GRAFT_REASONING_BUDGET:-512}
JOBS=${QWEN_GRAFT_JOBS:-1}
STATE=${QWEN_WEBUI_STATE_DIRECTORY:-"${HOME:?}/qwen-webui-state"}
EMPTY='-	-	-	-	-	-	-	-	-	-	-	-'

command -v graft >/dev/null 2>&1 || {
    printf 'graft is absent from PATH; the deep pass has no client\n' >&2
    exit 2
}
[ -d "$SOURCE/.git" ] || {
    printf 'the source checkout carries no git directory: %s\n' "$SOURCE" >&2
    exit 2
}
mkdir -p "$OUT"

# graft echoes its --dir back into the log it writes, so an output directory
# outside the home directory still leaves an absolute local path behind. The
# longer root is replaced first, so an output directory under the home
# directory resolves to the output name rather than to the home one.
OUT_ABSOLUTE=$(CDPATH='' cd -- "$OUT" && pwd)
scrub_home() {
    sed -e "s|$OUT_ABSOLUTE|\$OUTPUT_DIRECTORY|g" -e "s|${HOME:?}|\$HOME|g"
}
now_ms() { "$PYTHON" -c 'import time; print(time.monotonic_ns()//1000000)'; }
# The launch truncates the appliance logs in place, so a byte offset taken
# before it addresses the middle of what the next arm writes the moment that
# arm grows past the previous arm's length. Moving the file aside instead
# makes the arm's log the whole file, which is the only form in which a count
# of zero warnings means the arm printed none: a slice that opens mid-line
# carries no evidence about the lines before it.
# The retired copy stays in the state directory under a fixed name, so an arm
# that exits before its teardown leaves no file behind in the evidence tree and
# the next arm overwrites it rather than accumulating one per row.
retire_log() {
    [ -e "$1" ] || return 0
    mv -- "$1" "$2"
}
scrub_to() {
    if [ -r "$1" ]; then
        scrub_home <"$1" >"$2"
    else
        : >"$2"
    fi
}

base=$(git -C "$SOURCE" rev-parse HEAD)
{
    printf 'source_commit\t%s\n' "$base"
    printf 'source_paths\t%s\n' "$CONE"
    printf 'context_size\t%s\n' "$CONTEXT"
    printf 'reasoning_budget\t%s\n' "$BUDGET"
    printf 'graft_jobs\t%s\n' "$JOBS"
    printf 'graft_version\t%s\n' "$(graft --version 2>/dev/null | tr -d '\n')"
    printf 'swapin_headroom_kib\t%s\n' \
        "${QWEN_SWAPIN_HEADROOM_KIB:-monitor-default}"
} >"$OUT/pilot-inputs.tsv"

printf 'model\tdeep_status\twall_ms\tfiles\tready\tpending\tstale\tsummary_empty\tcrux_present\tcrux_null\tcrux_at_node_start\tchoice_warnings\tdowngrade_lines\tfile_errors\tguard_abort\tverdict\n' \
    >"$OUT/pilot.tsv"

"$Q/scripts/qwen-teardown.sh" >/dev/null 2>&1 || true
trap '"$Q/scripts/qwen-teardown.sh" >/dev/null 2>&1 || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for id in $IDS; do
    if ! row=$("$Q/scripts/model-registry.sh" id "$id" 2>/dev/null); then
        printf '%s\tunregistered\t%s\tnone\trejected\n' "$id" "$EMPTY" \
            >>"$OUT/pilot.tsv"
        continue
    fi
    model_file=$(printf '%s\n' "$row" | sed -n 's/^model_file=//p')
    tree=$TREES/graft-deep-$id
    graph=$OUT/graph-$id

    # The tree is a worktree so its generated bytes end with it, and the graft
    # directory sits outside it so the tree stays clean enough to remove
    # without --force.
    if [ ! -e "$tree" ]; then
        git -C "$SOURCE" worktree add --detach "$tree" "$base" >/dev/null 2>&1
        git -C "$tree" sparse-checkout init --cone >/dev/null 2>&1
        # shellcheck disable=SC2086
        git -C "$tree" sparse-checkout set $CONE >/dev/null 2>&1
    fi
    tree_commit=$(git -C "$tree" rev-parse HEAD)
    [ "$tree_commit" = "$base" ] || {
        printf '%s carries %s, not the source commit %s\n' \
            "$tree" "$tree_commit" "$base" >&2
        exit 1
    }

    "$Q/scripts/qwen-teardown.sh" >/dev/null 2>&1 || true
    retire_log "$STATE/server.log" "$STATE/server.log.previous"
    retire_log "$STATE/telemetry.log" "$STATE/telemetry.log.previous"

    if ! QWEN_CHAT_TOOLS=on QWEN_CHAT_REASONING_BUDGET="$BUDGET" \
        QWEN_CONTEXT_SIZE="$CONTEXT" QWEN_MODEL_PATH=$HOME/models/$model_file \
        "$Q/scripts/qwen-launch.sh" default >"$OUT/$id.launch" 2>&1; then
        scrub_to "$OUT/$id.launch" "$OUT/$id.launch.scrubbed"
        mv "$OUT/$id.launch.scrubbed" "$OUT/$id.launch"
        printf '%s\tlaunch_failed\t%s\tnone\trejected\n' "$id" "$EMPTY" \
            >>"$OUT/pilot.tsv"
        continue
    fi
    scrub_to "$OUT/$id.launch" "$OUT/$id.launch.scrubbed"
    mv "$OUT/$id.launch.scrubbed" "$OUT/$id.launch"

    # The consumer environment refuses a listener that answers a forced tool
    # call without a call, so an arm that reaches the deep pass has already
    # produced one completed record_probe under the served closure.
    if ! consumer_env=$("$Q/scripts/graft-consumer-env.sh" 2>"$OUT/$id.probe"); then
        scrub_to "$OUT/$id.probe" "$OUT/$id.probe.scrubbed"
        mv "$OUT/$id.probe.scrubbed" "$OUT/$id.probe"
        printf '%s\tprobe_refused\t%s\tnone\trejected\n' "$id" "$EMPTY" \
            >>"$OUT/pilot.tsv"
        "$Q/scripts/qwen-teardown.sh" >/dev/null 2>&1 || true
        continue
    fi
    eval "$consumer_env"

    rm -rf "$graph"
    started=$(now_ms)
    if GRAFT_NO_IGNORE=1 graft --dir "$graph" build --deep --allow-partial \
        -j "$JOBS" "$tree" >"$OUT/$id.deep.log" 2>&1; then
        deep_status=0
    else
        deep_status=$?
    fi
    wall_ms=$(( $(now_ms) - started ))
    scrub_to "$OUT/$id.deep.log" "$OUT/$id.deep.log.scrubbed"
    mv "$OUT/$id.deep.log.scrubbed" "$OUT/$id.deep.log"

    "$Q/scripts/qwen-teardown.sh" >/dev/null 2>&1 || true
    scrub_to "$STATE/server.log" "$OUT/$id.server.log"
    scrub_to "$STATE/telemetry.log" "$OUT/$id.telemetry.log"

    # warnToolChoiceIgnored is the only line graft prints when a reply carries
    # neither a tool call nor recoverable content, and the server prints the
    # downgrade line only on a closure that lacks the tool_choice patch. Both
    # counts are zero on a served closure that forces the object.
    choice_warnings=$(grep -c 'did not honor tool_choice\|may ignore forced tool_choice' \
        "$OUT/$id.deep.log" 2>/dev/null || true)
    downgrade_lines=$(grep -c "Wrong type supplied for parameter 'tool_choice'" \
        "$OUT/$id.server.log" 2>/dev/null || true)
    file_errors=$(grep -c 'no usable symbol summaries' "$OUT/$id.deep.log" \
        2>/dev/null || true)

    # The guard writes its reason before it signals, so an arm that ends in a
    # terminated server says so in its row rather than in its counts.
    guard_abort=$(sed -n 's/^abort_utc=[^ ]* reason=//p' "$OUT/$id.telemetry.log" |
        tr '\n' ',' | sed 's/,$//')
    [ -n "$guard_abort" ] || guard_abort=none

    counts=$("$PYTHON" "$Q/scripts/graft-deep-evidence.py" "$graph")
    printf '%s\n' "$counts" >"$OUT/$id.graph-evidence.tsv"
    field() { printf '%s\n' "$counts" | sed -n "s/^$1\t//p"; }
    if [ "$guard_abort" = none ]; then
        verdict=$(field verdict)
    else
        verdict=void
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$id" "$deep_status" "$wall_ms" "$(field files)" "$(field ready)" \
        "$(field pending)" "$(field stale)" "$(field summary_empty)" \
        "$(field crux_present)" "$(field crux_null)" \
        "$(field crux_at_node_start)" "$choice_warnings" "$downgrade_lines" \
        "$file_errors" "$guard_abort" "$verdict" >>"$OUT/pilot.tsv"
done

printf 'graft_deep_done\n' >>"$OUT/pilot.tsv"
