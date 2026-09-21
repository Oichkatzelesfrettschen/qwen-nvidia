#!/bin/sh
# Calibrate the crux collector against the reply classes it must survive.
#
# A crux record reaches the graph only when its id matches a requested target
# and its summary is non-blank, and collectFileCrux (dist/graph/enrich.js)
# enforces neither rule the way enrich reads it: it admits a record on its id
# alone and computes the next attempt from that map, while applyFileCrux rejects
# the same record on `!r.summary.trim()`. Two corrections follow, and this
# measures both against a stub model so the reply is the only variable. No GPU
# is involved: the subject is the collector, not a checkpoint.
#
#   stock     the installed collector
#   accepted  admits a record only when it carries a summary
#   resolved  resolves an echoed target line back to the id it names
#
# Each mode states what the three collectors must do, and a departure fails the
# run, so a collector that stops behaving as measured is reported rather than
# agreed with.
#
#   good                every requested id, summarized
#   blank               every requested id, no summary
#   mixed               the first requested id summarized
#   foreign             the bare symbol name, no summary
#   foreign-summarized  the bare symbol name, summarized
#   echoed              the whole target line as the id, summarized
#
# A foreign reply names no target under any rule, so every collector re-asks and
# discards it: that is the class no acceptance rule reaches. An echoed reply
# names its target in the leading field, and only `resolved` recovers it.
#
#   usage: admit-crux-collector-acceptance.sh OUTPUT_DIRECTORY
#
#   QWEN_CRUX_GRAFT_STOCK  cli.js of the installed graft
#   QWEN_CRUX_STUB_PORT    loopback port the stub model binds
set -eu

PYTHON=${PYTHON:-python3}
OUT=${1:?usage: admit-crux-collector-acceptance.sh OUTPUT_DIRECTORY}
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

STOCK=${QWEN_CRUX_GRAFT_STOCK:-/usr/lib/node_modules/@nanonets/graft/dist/cli.js}
PORT=${QWEN_CRUX_STUB_PORT:-18734}

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

# Each corrected collector is built here from the installed graft and read back
# by the marker its patch introduces, so an edit that landed at the wrong offset
# cannot present itself as the correction it names.
PACKAGE=$(dirname -- "$(dirname -- "$STOCK")")
build_collector() {
    name=$1
    patch=$2
    marker=$3
    cp -a "$PACKAGE" "$WORK/$name"
    "$PYTHON" "$HERE/$patch" "$WORK/$name/dist/graph/enrich.js"
    if ! grep -q "$marker" "$WORK/$name/dist/graph/enrich.js"; then
        printf 'the %s collector does not carry its correction\n' "$name" >&2
        exit 1
    fi
}
build_collector accepted crux-collector-acceptance-patch.py 'r.summary.trim() && !results.has'
build_collector resolved crux-collector-identity-patch.py resolveId

# Two definitions with a branch apiece, so the generic C tier reports a span and
# the crux request carries more than one target. graft sends the file's own node
# as a target too, so the fixture has three.
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

# Requests and ready per collector, in stock:accepted:resolved order.
expect_for() {
    case $1 in
        good)               printf '1:1:1 3:3:3\n' ;;
        blank)              printf '1:2:1 0:0:0\n' ;;
        mixed)              printf '1:2:1 1:2:1\n' ;;
        foreign)            printf '2:2:2 0:0:0\n' ;;
        foreign-summarized) printf '2:2:2 0:0:0\n' ;;
        echoed)             printf '2:2:1 0:0:3\n' ;;
    esac
}

field_of() {
    # field_of LIST INDEX, over a colon-separated triple.
    printf '%s\n' "$1" | cut -d: -f"$2"
}

printf 'mode\tcollector\trequests\tready\tpending\texpected_requests\texpected_ready\tverdict\n' \
    >"$OUT/acceptance.tsv"

for mode in good blank mixed foreign foreign-summarized echoed; do
    expect=$(expect_for "$mode")
    want_requests=${expect%% *}
    want_ready=${expect##* }
    index=0

    for collector in stock accepted resolved; do
        index=$((index + 1))
        case $collector in
            stock) cli=$STOCK ;;
            *)     cli=$WORK/$collector/dist/cli.js ;;
        esac
        want_r=$(field_of "$want_requests" "$index")
        want_y=$(field_of "$want_ready" "$index")

        arm=$mode.$collector
        log=$WORK/$arm.requests
        : >"$log"

        QWEN_STUB_MODE=$mode QWEN_STUB_LOG=$log \
            "$PYTHON" "$HERE/crux-collector-stub-model.py" "$PORT" &
        STUB_PID=$!

        # The stub answers the moment its socket binds; poll rather than sleep a
        # guessed interval.
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
