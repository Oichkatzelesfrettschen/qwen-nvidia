#!/bin/sh
set -eu

# admit-summarize-roster.sh against a fake serving chain: a launch stub, a
# teardown stub that leaves a marker, a probe stub, and an HTTP fixture that
# answers by the probe file's name. Each answer shape the harness classifies
# has a file: stop.c (a summary), blank.c (finish stop, whitespace content),
# length.c (finish length), nousage.c (no completion_tokens), wide.c (30000
# two-byte characters, so the clip is proven a character count), hang.c
# (no answer inside the request timeout). The selection checks prove a
# refused selection launches nothing and tears nothing down, and that an
# unset selection reaches the last eligible row.

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/summarize-roster-test.XXXXXX")
server_pid=
cleanup() {
    if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; fi
    wait 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT INT TERM

checks_total=0
checks_failed=0
check() {
    checks_total=$((checks_total + 1))
    if [ "$2" = pass ]; then
        printf 'check=%s outcome=pass\n' "$1"
    else
        checks_failed=$((checks_failed + 1))
        printf 'check=%s outcome=FAIL detail=%s\n' "$1" "${3:-}" >&2
    fi
}

T=$work/tree
mkdir -p "$T/scripts" "$work/state" "$work/source" "$work/out"
cp "$script_directory/admit-summarize-roster.sh" "$T/scripts/"
marker=$work/teardown.marker
cat >"$T/scripts/qwen-teardown.sh" <<EOF
#!/bin/sh
printf 'teardown\n' >>'$marker'
EOF
cat >"$T/scripts/qwen-launch.sh" <<'EOF'
#!/bin/sh
case ${QWEN_MODEL_PATH:-} in *broken*) exit 1 ;; esac
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' >"$T/scripts/graft-consumer-env.sh"
chmod 755 "$T"/scripts/*.sh
printf 'test-key\n' >"$work/state/api.key"

# A registry of four rows: two eligible, one below the floor, one whose
# launch fails. Twenty-six fields, the switch policy last.
row() { printf '%s\t%s\t%s\tdl.sh\t16384\t%s\t32768\tq8_0\tq4_0\ton\tnone\t-\t-\t-\tuntested\tcandidate\t2048\t512\t-\t-\tunmeasured\trefused\t0\toff\t-\tlru\n' "$1" role "$2" "$3"; }
{
    printf '# header\n'
    row a A/a.gguf 32768
    row c C/c.gguf 8192
    row broken B/broken.gguf 32768
    row b B/b.gguf 32768
} >"$T/scripts/models.tsv"

printf 'int stop;\n' >"$work/source/stop.c"
printf 'int blank;\n' >"$work/source/blank.c"
printf 'int length;\n' >"$work/source/length.c"
printf 'int nousage;\n' >"$work/source/nousage.c"
printf 'int hang;\n' >"$work/source/hang.c"
python3 -c 'import sys; sys.stdout.write("é" * 30000)' >"$work/source/wide.c"

port=$(python3 -c 'import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
cat >"$work/server.py" <<'EOF'
import http.server, json, re, sys, time

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        return

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        name = re.match(r"File: (\S+)", request["messages"][1]["content"]).group(1)
        usage = {"prompt_tokens": 100, "completion_tokens": 20}
        finish, content = "stop", "A summary of the file."
        if name == "blank.c":
            content = "  \n"
        elif name == "length.c":
            finish, usage = "length", {"prompt_tokens": 100, "completion_tokens": 32668}
        elif name == "nousage.c":
            usage = {"prompt_tokens": 100}
        elif name == "hang.c":
            time.sleep(4)
        body = json.dumps({"usage": usage, "choices": [{"finish_reason": finish,
                           "message": {"role": "assistant", "content": content}}]}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
EOF
PYTHONDONTWRITEBYTECODE=1 python3 "$work/server.py" "$port" &
server_pid=$!
sleep 0.5

run() {
    QWEN_SUMMARIZE_SOURCE=$work/source QWEN_SERVER_PORT=$port QWEN_WEBUI_STATE_DIRECTORY=$work/state \
        QWEN_ROSTER_REQUEST_TIMEOUT=1 "$T/scripts/admit-summarize-roster.sh" "$@" >"$work/stdout" 2>"$work/stderr" \
        && printf 0 || printf '%s' "$?"
}

# A refused selection exits 2 before any teardown.
for case in whitespace:'  ' duplicate:'a a' unknown:'a nosuch'; do
    rm -f "$marker"
    status=$(QWEN_ROSTER_IDS="${case#*:}" run "$work/out/refused.tsv")
    if [ "$status" = 2 ] && [ ! -e "$marker" ] && [ ! -e "$work/out/refused.tsv" ]; then
        check "${case%%:*}_selection_refused" pass
    else
        check "${case%%:*}_selection_refused" fail "status=$status marker=$([ -e "$marker" ] && echo yes || echo no) stderr=$(cat "$work/stderr")"
    fi
done

# An unset selection measures every eligible row, the last one included, and
# skips the row below the floor.
rm -f "$marker"
status=$(QWEN_ROSTER_FILES=stop.c run "$work/out/all.tsv")
measured=$(cut -f1 "$work/out/all.tsv" | grep -v '^model$' | grep -v '^roster_done$' | tr '\n' ' ')
if [ "$status" = 0 ] && [ "$measured" = "a broken b " ] \
    && grep -q "^broken	-	-	-	-	-	-	-	-	-	-	launch_failed$" "$work/out/all.tsv" \
    && [ "$(grep -c . "$marker")" -ge 3 ]; then
    check unset_selection_reaches_last_row pass
else
    check unset_selection_reaches_last_row fail "status=$status measured='$measured' stderr=$(cat "$work/stderr")"
fi

# One row against every answer shape: the outcome column separates them, the
# request body is retained with a character-counted clip, and the teardown
# runs after the transport failure ends the run.
rm -f "$marker"
status=$(QWEN_ROSTER_IDS=a QWEN_ROSTER_FILES='stop.c blank.c length.c nousage.c wide.c hang.c' run "$work/out/shapes.tsv")
outcomes=$(awk -F'\t' 'NR>1 && $1=="a" {print $2"="$12}' "$work/out/shapes.tsv" | tr '\n' ' ')
expected='stop.c=stop blank.c=blank length.c=capped nousage.c=body wide.c=stop hang.c=transport_curl_28 '
if [ "$status" = 0 ] && [ "$outcomes" = "$expected" ] && [ -e "$marker" ]; then
    check answer_shapes_classified pass
else
    check answer_shapes_classified fail "status=$status outcomes='$outcomes' marker=$([ -e "$marker" ] && echo yes || echo no) stderr=$(cat "$work/stderr")"
fi
blank_chars=$(awk -F'\t' '$1=="a" && $2=="blank.c" {print $7}' "$work/out/shapes.tsv")
length_boundary=$(awk -F'\t' '$1=="a" && $2=="length.c" {print $8}' "$work/out/shapes.tsv")
if [ "$blank_chars" = 3 ] && [ "$length_boundary" = yes ]; then
    check content_bytes_and_boundary pass
else
    check content_bytes_and_boundary fail "blank_chars=$blank_chars length_boundary=$length_boundary"
fi
clip_chars=$(python3 -c 'import json, sys
body = json.load(open(sys.argv[1]))
print(len(body["messages"][1]["content"]) - len("File: wide.c\n\n"))' "$work/out/shapes.tsv.a.wide.c.request.json")
if [ "$clip_chars" = 24000 ] && [ -s "$work/out/shapes.tsv.a.stop.c.json" ]; then
    check clip_is_a_character_count pass
else
    check clip_is_a_character_count fail "clip_chars=$clip_chars"
fi

printf 'checks_total=%s checks_failed=%s\n' "$checks_total" "$checks_failed"
[ "$checks_failed" -eq 0 ]
