#!/bin/sh
# Calibrate the crux collector's acceptance rule against known-good and
# known-bad replies.
#
# graft's collectFileCrux (dist/graph/enrich.js) admits a returned record on its
# id alone and recomputes the next attempt from `!results.has(r.id)`, while
# applyFileCrux rejects the same record on `!r.summary.trim()`. A record whose
# id was requested and whose summary is blank therefore retires itself from the
# retry and is then discarded. This harness drives both collectors with a stub
# model so the reply class is the only variable, and it needs no GPU: the model
# under test is the collector, not the checkpoint.
#
# Each mode states what the two collectors must do. A mode whose measured
# requests or ready count departs from the expectation fails the run, so the
# harness reports a collector that stops behaving as measured rather than
# silently agreeing with it.
#
#   good                every requested id, summarized   both accept in one request
#   blank               every requested id, no summary   stock accepts, corrected re-asks
#   mixed               the first requested id summarized  corrected recovers one record
#   foreign             the bare name, no summary        neither collector matches an id
#   foreign-summarized  the bare name, summarized        neither collector matches an id
#
# A foreign reply never populates the map under either rule, so both collectors
# re-ask and both discard the result. That is the class the acceptance rule
# cannot reach.
#
#   usage: admit-crux-collector-acceptance.sh OUTPUT_DIRECTORY
#
#   QWEN_CRUX_GRAFT_STOCK  cli.js of the installed graft
#   QWEN_CRUX_GRAFT_FIXED  cli.js of a prepared corrected copy; unset builds one
#   QWEN_CRUX_STUB_PORT    loopback port the stub model binds
set -eu

PYTHON=${PYTHON:-python3}
OUT=${1:?usage: admit-crux-collector-acceptance.sh OUTPUT_DIRECTORY}
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

STOCK=${QWEN_CRUX_GRAFT_STOCK:-/usr/lib/node_modules/@nanonets/graft/dist/cli.js}
FIXED=${QWEN_CRUX_GRAFT_FIXED:-}
PORT=${QWEN_CRUX_STUB_PORT:-18734}
PATCHED_PREDICATE="r.summary.trim() && !results.has(r.id)"

if [ ! -r "$STOCK" ]; then
    printf 'not run: graft is absent at %s\n' "$STOCK" >&2
    exit 0
fi
if ! command -v node >/dev/null 2>&1; then
    printf 'not run: node is absent\n' >&2
    exit 0
fi

WORK=$(mktemp -d)
STUB_PID=
failures=0

cleanup() {
    [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null
    [ -d "$WORK" ] && find "$WORK" -mindepth 1 -delete 2>/dev/null
    [ -d "$WORK" ] && rmdir "$WORK" 2>/dev/null
    return 0
}
trap cleanup EXIT INT TERM

mkdir -p "$OUT"

# The corrected copy is built here rather than referenced, so a run rests on
# the installed graft and nothing outside the tree. The predicate is read back
# from the copy: an edit that landed at the wrong offset, or not at all, must
# not present itself as the corrected collector.
if [ -z "$FIXED" ]; then
    package=$(dirname -- "$(dirname -- "$STOCK")")
    cp -a "$package" "$WORK/graft-fixed"
    FIXED=$WORK/graft-fixed/dist/cli.js
    "$PYTHON" "$HERE/crux-collector-acceptance-patch.py" \
        "$WORK/graft-fixed/dist/graph/enrich.js"
    if ! grep -qF "$PATCHED_PREDICATE" "$WORK/graft-fixed/dist/graph/enrich.js"; then
        printf 'the corrected copy does not carry the acceptance predicate\n' >&2
        exit 1
    fi
fi

# Two definitions with a branch apiece, so the generic C tier reports a span and
# the crux request carries more than one target.
mkdir -p "$WORK/tree"
cat >"$WORK/tree/sample.c" <<'CEOF'
#include <stdio.h>

int
alpha_add(int a, int b)
{
	if (a > b)
		return a + b;
	return b - a;
}

int
beta_scale(int v)
{
	int i;

	for (i = 0; i < 4; i++)
		v <<= 1;
	return v;
}
CEOF

# requests and ready are the expectation per collector, in stock:fixed form.
expect_for() {
    case $1 in
        good)               printf '1:1 3:3\n' ;;
        blank)              printf '1:2 0:0\n' ;;
        mixed)              printf '1:2 1:2\n' ;;
        foreign)            printf '2:2 0:0\n' ;;
        foreign-summarized) printf '2:2 0:0\n' ;;
    esac
}

printf 'mode\tcollector\trequests\tready\tpending\texpected_requests\texpected_ready\tverdict\n' \
    >"$OUT/acceptance.tsv"

for mode in good blank mixed foreign foreign-summarized; do
    expect=$(expect_for "$mode")
    want_requests=${expect%% *}
    want_ready=${expect##* }

    for collector in stock fixed; do
        case $collector in
            stock) cli=$STOCK; want_r=${want_requests%%:*}; want_y=${want_ready%%:*} ;;
            fixed) cli=$FIXED; want_r=${want_requests##*:}; want_y=${want_ready##*:} ;;
        esac

        arm=$mode.$collector
        log=$WORK/$arm.requests
        : >"$log"

        QWEN_STUB_MODE=$mode QWEN_STUB_LOG=$log \
            "$PYTHON" "$HERE/crux-collector-stub-model.py" "$PORT" &
        STUB_PID=$!

        # The stub answers on loopback the moment the socket binds; poll it
        # rather than sleeping a guessed interval.
        waited=0
        while ! "$PYTHON" -c "import socket,sys; s=socket.socket(); \
sys.exit(0 if s.connect_ex(('127.0.0.1', int(sys.argv[1]))) == 0 else 1)" \
            "$PORT" 2>/dev/null; do
            waited=$((waited + 1))
            [ "$waited" -gt 100 ] && break
            sleep 0.1
        done

        GRAFT_NO_IGNORE=1 GRAFT_PROVIDER=openai \
            GRAFT_BASE_URL=http://127.0.0.1:$PORT/v1 \
            GRAFT_MODEL=stub GRAFT_API_KEY=stub \
            node "$cli" --dir "$WORK/$arm.graph" build --deep --allow-partial \
            -j 1 "$WORK/tree" >"$OUT/$arm.deep.log" 2>&1 || true

        kill "$STUB_PID" 2>/dev/null || true
        wait "$STUB_PID" 2>/dev/null || true
        STUB_PID=

        requests=$(grep -c record_symbols "$log" || true)
        ready=$(sed -n 's/.*meaning: \([0-9][0-9]*\) computed.*/\1/p' "$OUT/$arm.deep.log")
        pending=$(sed -n 's/.*computed.*, \([0-9][0-9]*\) pending.*/\1/p' "$OUT/$arm.deep.log")
        : "${ready:=0}" "${pending:=0}"

        if [ "$requests" -eq "$want_r" ] && [ "$ready" -eq "$want_y" ]; then
            verdict=accepted
        else
            verdict=departed
            failures=$((failures + 1))
        fi

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$mode" "$collector" "$requests" "$ready" "$pending" \
            "$want_r" "$want_y" "$verdict" >>"$OUT/acceptance.tsv"
    done
done

printf 'acceptance_done\n' >>"$OUT/acceptance.tsv"
[ "$failures" -eq 0 ]
