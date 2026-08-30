#!/bin/sh
set -eu

# A parallel range fetch assembles a file from parts, so its failure mode is a
# plausible file rather than an error: a part short by one byte concatenates
# into something that loads and answers wrongly. These checks run the fetcher
# against a local server that honours ranges and compare the assembled digest
# with the origin's, across several connection counts including one that does
# not divide the length evenly.

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
temporary_directory=$(mktemp -d)
server_pid=''
cleanup() {
    [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null
    rm -rf "$temporary_directory"
}
trap cleanup EXIT HUP INT TERM
failures=0

report() {
    printf '%s=%s\n' "$1" "$2"
    [ "$2" = accepted ] || failures=$((failures + 1))
}

document_root=$temporary_directory/www
mkdir -p "$document_root" "$temporary_directory/dest"
# A length that no connection count divides evenly, so the final part is short
# by construction and the assembly is exercised at its boundary.
python3 -c '
import sys
with open(sys.argv[1], "wb") as handle:
    handle.write(bytes((index * 7 + 13) % 256 for index in range(1000003)))
' "$document_root/model.gguf"
mkdir -p "$document_root/owner/repo/resolve/revision/nested" \
    "$document_root/api/models/owner/repo/tree"
cp "$document_root/model.gguf" \
    "$document_root/owner/repo/resolve/revision/model.gguf"
cp "$document_root/model.gguf" \
    "$document_root/owner/repo/resolve/revision/nested/model.gguf"
origin_digest=$(sha256sum "$document_root/model.gguf" | awk '{ print $1 }')
origin_bytes=$(wc -c <"$document_root/model.gguf")
printf '[{"type":"file","path":"model.gguf","size":%s,"lfs":{"oid":"%s","size":%s}},{"type":"file","path":"nested/model.gguf","size":%s,"lfs":{"oid":"%s","size":%s}}]\n' \
    "$origin_bytes" "$origin_digest" "$origin_bytes" \
    "$origin_bytes" "$origin_digest" "$origin_bytes" \
    >"$document_root/api/models/owner/repo/tree/revision"

server_script=$temporary_directory/range-server.py
cat >"$server_script" <<'PYTHON'
import http.server
import os
import sys

root, port_file, request_log = sys.argv[1], sys.argv[2], sys.argv[3]


class RangeHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *arguments, **keywords):
        super().__init__(*arguments, directory=root, **keywords)

    def send_head(self):
        requested = self.headers.get("Range")
        path = self.translate_path(self.path)
        if not requested or not os.path.isfile(path):
            self._limit = None
            return super().send_head()
        with open(request_log, "a", encoding="utf-8") as handle:
            handle.write(requested + "\n")
        size = os.path.getsize(path)
        first, _, last = requested.partition("=")[2].partition("-")
        first = int(first)
        last = int(last) if last else size - 1
        handle = open(path, "rb")
        handle.seek(first)
        self._limit = last - first + 1
        self.send_response(206)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(self._limit))
        self.send_header("Content-Range", f"bytes {first}-{last}/{size}")
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        return handle

    def copyfile(self, source, outputfile):
        limit = getattr(self, "_limit", None)
        if limit is None:
            return super().copyfile(source, outputfile)
        outputfile.write(source.read(limit))

    def end_headers(self):
        if not self.headers.get("Range"):
            self.send_header("Accept-Ranges", "bytes")
        super().end_headers()

    def log_message(self, *arguments):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), RangeHandler)
with open(port_file, "w") as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
PYTHON

port_file=$temporary_directory/port
request_log=$temporary_directory/ranges.log
python3 "$server_script" "$document_root" "$port_file" "$request_log" &
server_pid=$!
attempt=0
while [ "$attempt" -lt 100 ]; do
    [ -s "$port_file" ] && break
    attempt=$((attempt + 1))
    sleep 0.1
done
if [ ! -s "$port_file" ]; then
    printf 'the range server did not start\n' >&2
    exit 1
fi
port=$(cat "$port_file")

fetcher=$script_directory/fetch-candidate-artifact.sh
endpoint=http://127.0.0.1:$port

for connections in 1 2 4 7; do
    rm -rf "$temporary_directory/dest"
    mkdir -p "$temporary_directory/dest"
    line=$(QWEN_HUGGINGFACE_ENDPOINT=$endpoint QWEN_FETCH_CONNECTIONS=$connections \
        "$fetcher" owner/repo revision \
        model.gguf "$temporary_directory/dest" 2>&1) || {
            report "connections_$connections" rejected
            printf '%s\n' "$line" >&2
            continue
        }
    assembled=$(sha256sum "$temporary_directory/dest/model.gguf" | awk '{ print $1 }')
    mode=$(printf '%s' "$line" | sed -n 's/.*mode=\([a-z]*\).*/\1/p')
    if ! printf '%s' "$line" | grep -q 'verified_sha256='; then
        report "digest_state_$connections" rejected
        printf 'the local LFS tree did not verify its published digest: %s\n' \
            "$line" >&2
    fi
    expected_mode=parallel
    [ "$connections" = 1 ] && expected_mode=single
    if [ "$assembled" = "$origin_digest" ] && [ "$mode" = "$expected_mode" ]; then
        report "connections_$connections" accepted
    else
        report "connections_$connections" rejected
        printf 'digest %s against origin %s, mode %s expected %s\n' \
            "$assembled" "$origin_digest" "$mode" "$expected_mode" >&2
    fi
done

# One-stream mode must keep a prior partial and ask the origin only for the
# remaining suffix. The range log distinguishes a resumed transfer from a
# byte-zero restart that happens to produce the same final digest.
rm -rf "$temporary_directory/dest"
mkdir -p "$temporary_directory/dest"
head -c 12345 "$document_root/model.gguf" \
    >"$temporary_directory/dest/model.gguf.part"
: >"$request_log"
line=$(QWEN_HUGGINGFACE_ENDPOINT=$endpoint QWEN_FETCH_CONNECTIONS=1 \
    "$fetcher" owner/repo revision model.gguf \
    "$temporary_directory/dest" 2>&1) || {
        report single_stream_resume rejected
        printf '%s\n' "$line" >&2
        line=''
    }
resumed_digest=$(sha256sum "$temporary_directory/dest/model.gguf" | awk '{ print $1 }')
if [ "$resumed_digest" = "$origin_digest" ] && \
   grep -Fx 'bytes=12345-' "$request_log" >/dev/null; then
    report single_stream_resume accepted
else
    report single_stream_resume rejected
fi

# Artifact names retain their repository-relative path. The fetcher creates the
# nested parent before curl opens either its partial or final output.
nested_destination=$temporary_directory/nested-dest
line=$(QWEN_HUGGINGFACE_ENDPOINT=$endpoint QWEN_FETCH_CONNECTIONS=1 \
    "$fetcher" owner/repo revision nested/model.gguf \
    "$nested_destination" 2>&1) || {
        report nested_artifact_parent rejected
        printf '%s\n' "$line" >&2
        line=''
    }
nested_digest=$(sha256sum "$nested_destination/nested/model.gguf" | awk '{ print $1 }')
if [ "$nested_digest" = "$origin_digest" ] && \
   printf '%s' "$line" | grep -q 'verified_sha256='; then
    report nested_artifact_parent accepted
else
    report nested_artifact_parent rejected
fi

# A retained artifact is re-observed rather than refetched, and a file that has
# changed under a recorded digest is refused rather than served.
line=$(QWEN_HUGGINGFACE_ENDPOINT=$endpoint QWEN_FETCH_CONNECTIONS=4 \
    "$fetcher" owner/repo revision model.gguf \
    "$temporary_directory/dest" 2>&1)
case $line in
    *artifact_status=retained*) report retained_artifact_reobserved accepted ;;
    *) report retained_artifact_reobserved rejected ;;
esac

printf 'tampered\n' >>"$temporary_directory/dest/model.gguf"
if QWEN_HUGGINGFACE_ENDPOINT=$endpoint QWEN_FETCH_CONNECTIONS=4 \
        "$fetcher" owner/repo revision model.gguf \
        "$temporary_directory/dest" >/dev/null 2>&1; then
    report tampered_artifact_refused rejected
else
    report tampered_artifact_refused accepted
fi

if [ "$failures" -eq 0 ]; then
    printf 'fetch_candidate_artifact=accepted\n'
    exit 0
fi
printf 'fetch_candidate_artifact=rejected failures=%s\n' "$failures" >&2
exit 1
