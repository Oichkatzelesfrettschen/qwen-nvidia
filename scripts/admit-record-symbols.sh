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
# list. graft takes its targets from the tree-sitter extraction; this takes
# them from graft itself, so the ids are the ones the graph uses.
for f in $FILES; do
    stem=$OUT/$(printf '%s' "$f" | tr / _)
    ( cd "$D" && graft skeleton "$f" 2>/dev/null ) | sed -n 's/^- L\([0-9]*\)-L\([0-9]*\)  \([a-z]*\) \([A-Za-z_][A-Za-z0-9_]*\).*/\4\t\3\t\1\t\2/p' >"$stem.targets"
    [ -s "$stem.targets" ] || { printf 'no targets for %s\n' "$f" >&2; continue; }
    python3 - "$D/$f" "$f" "$stem.targets" "$stem.request.json" "$CAP" <<'PY'
import json, sys
source_path, rel, targets_path, out_path, cap = sys.argv[1:6]
src = open(source_path, encoding='utf-8', errors='replace').read()
if len(src) > 18000:
    src = src[:18000] + "\n… (truncated)"
numbered = "\n".join(f"{i+1}\t{l}" for i, l in enumerate(src.split("\n")))
rows = [l.split("\t") for l in open(targets_path).read().split("\n") if l.strip()]
targets = "\n".join(f"- id={r[0]} | {r[1]} | lines L{r[2]}-L{r[3]}" for r in rows)
n = len(rows)
system = ("You produce definitions for a code graph that helps engineers navigate a codebase.\n\n"
          "You are given ONE source file with 1-based line numbers, and a list of TARGET "
          "definitions in it. Describe EVERY target via the record_symbols tool.\n\n"
          "Rules:\n"
          "- Return EXACTLY ONE entry for EVERY target id, using that id verbatim. The number "
          "of entries you return MUST equal the number of targets.\n"
          "- summary: ONE sentence about what the symbol is FOR, not a restatement of its signature.\n"
          "- crux_start / crux_end: FILE line numbers, inside that symbol's own line range, at "
          "most about 8 lines, never the whole function. Where there is no single focal span, "
          "use crux_start 0 and crux_end 0.")
user = f"FILE: {rel}\n\n{numbered}\n\nTARGETS ({n} — return all {n}, one entry per id):\n{targets}"
schema = {"type": "object", "properties": {"symbols": {"type": "array", "items": {"type": "object",
          "properties": {"id": {"type": "string"}, "summary": {"type": "string"},
                         "crux_start": {"type": "number"}, "crux_end": {"type": "number"}},
          "required": ["id", "summary", "crux_start", "crux_end"]}}}, "required": ["symbols"]}
body = {"model": "qwen-nvidia", "temperature": 0, "max_tokens": int(cap),
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
        "tools": [{"type": "function", "function": {"name": "record_symbols",
                   "description": "Record one entry per target definition.", "parameters": schema}}],
        "tool_choice": "required"}
json.dump(body, open(out_path, "w"))
PY
done

printf 'model\tfile\ttargets\twall_ms\tcalled\tentries\tid_exact\tid_missing\tid_invented\tcrux_in_range\tcrux_zero\tcrux_bad\toutcome\n' >"$OUT/symbols.tsv"
trap '"$Q/scripts/qwen-teardown.sh" >/dev/null 2>&1 || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for id in $IDS; do
    row=$("$Q/scripts/model-registry.sh" id "$id")
    file=$(printf '%s\n' "$row" | sed -n 's/^model_file=//p')
    "$Q/scripts/qwen-teardown.sh" >/dev/null 2>&1 || true
    if ! QWEN_CHAT_TOOLS=on QWEN_CHAT_REASONING_BUDGET=512 QWEN_CONTEXT_SIZE=16384 \
        QWEN_MODEL_PATH=$HOME/models/$file "$Q/scripts/qwen-launch.sh" default \
        >"$OUT/$id.launch" 2>&1; then
        for f in $FILES; do
            printf '%s\t%s\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\tlaunch_failed\n' "$id" "$f" >>"$OUT/symbols.tsv"
        done
        continue
    fi
    header=$(mktemp "${TMPDIR:-/tmp}/symbols.XXXXXX")
    printf 'header = "Authorization: Bearer %s"\n' "$(tr -d '\n' <"$STATE/api.key")" >"$header"
    for f in $FILES; do
        stem=$OUT/$(printf '%s' "$f" | tr / _)
        [ -s "$stem.request.json" ] || continue
        answer=$OUT/$id.$(basename "$f").symbols.json
        s=$(python3 -c 'import time; print(time.monotonic_ns()//1000000)')
        status=$(curl --silent --max-time "$TIMEOUT" --config "$header" --output "$answer" \
            --write-out '%{http_code}' -H 'Content-Type: application/json' \
            --data-binary "@$stem.request.json" \
            "http://127.0.0.1:$PORT/v1/chat/completions") || status=transport
        w=$(( $(python3 -c 'import time; print(time.monotonic_ns()//1000000)') - s ))
        python3 - "$answer" "$stem.targets" "$id" "$f" "$w" "$status" >>"$OUT/symbols.tsv" <<'PY'
import json, sys
answer, targets_path, model, rel, wall, status = sys.argv[1:7]
rows = [l.split("\t") for l in open(targets_path).read().split("\n") if l.strip()]
want = {r[0]: (int(r[2]), int(r[3])) for r in rows}
def emit(*f):
    print("\t".join(str(x) for x in (model, rel, len(want), wall) + f))
try:
    d = json.load(open(answer))
    msg = d["choices"][0]["message"]
except Exception:
    emit("-", "-", "-", "-", "-", "-", "-", "-", f"http_{status}"); raise SystemExit
calls = msg.get("tool_calls") or []
if not calls:
    emit("no", 0, 0, len(want), 0, 0, 0, 0, "no_call"); raise SystemExit
try:
    args = json.loads(calls[0]["function"]["arguments"])
    syms = args["symbols"]
    assert isinstance(syms, list)
except Exception:
    emit("yes", "-", "-", "-", "-", "-", "-", "-", "arguments_unparsed"); raise SystemExit
seen = [s.get("id") for s in syms if isinstance(s, dict)]
exact = sum(1 for i in seen if i in want)
invented = sorted({i for i in seen if i not in want})
missing = sorted(set(want) - set(seen))
in_range = zero = bad = 0
for s in syms:
    if not isinstance(s, dict) or s.get("id") not in want:
        continue
    lo, hi = want[s["id"]]
    a, b = s.get("crux_start"), s.get("crux_end")
    if not isinstance(a, (int, float)) or not isinstance(b, (int, float)):
        bad += 1
    elif int(a) == 0 and int(b) == 0:
        zero += 1
    elif lo <= int(a) <= int(b) <= hi:
        in_range += 1
    else:
        bad += 1
ok = (not missing) and (not invented) and bad == 0 and len(syms) == len(want)
emit("yes", len(syms), exact, len(missing), len(invented), in_range, zero, bad,
     "pass" if ok else "fail")
PY
    done
    rm -f "$header"
done
printf 'symbols_done\n' >>"$OUT/symbols.tsv"
