#!/bin/sh
set -eu

# Fetch the photographic vision fixture and prove it byte for byte.
#
# scripts/generate-quality-images.py draws flat-colour line art, which exercises
# the projector on synthetic statistics alone: hard edges, a handful of exact
# RGB values, no sensor noise, no depth of field, and no resampling artefacts.
# A photograph carries all of those, so a projector that reads drawn charts and
# fails on a camera image is a failure this suite could not otherwise see.
#
# The file is committed, so the suite runs without the network. This script is
# the replay authority: it names the upstream object, the byte count, and the
# SHA-256, verifies a copy already on disk, and fetches only when that copy is
# absent. That is the same discipline the checkpoint fetch scripts carry, for
# the same reason -- a fixture whose provenance is a URL alone can be replaced
# upstream without anything in this tree noticing.
#
# The subject is one plains zebra standing in profile, facing left, in dry
# golden grass with leafless scrub behind it. Those are the facts the `photo`
# rows in scripts/quality-suite.tsv grade against, and they are read off this
# exact file rather than off the upstream description.

usage() {
    printf 'usage: %s [OUTPUT_PATH]\n' "$0" >&2
    printf '  verifies an existing file or fetches the pinned bytes when absent\n' >&2
    exit 2
}

[ "$#" -le 1 ] || usage

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
output_path=${1:-$script_directory/quality-images/zebra.jpg}

# Wikimedia Commons, File:Zebra (24694097565).jpg
#   licence  CC0 1.0 Universal Public Domain Dedication
#   author   Mussi Katz, via Flickr
#   subject  Equus quagga, Tanzania, 2015-09-28
#   original 3760x2507, 1432788 bytes
# The API reports AttributionRequired false. Provenance is recorded because a
# fixture with no source is a fixture nobody can re-derive, not because CC0
# asks for it.
photo_url='https://upload.wikimedia.org/wikipedia/commons/thumb/1/17/Zebra_%2824694097565%29.jpg/960px-Zebra_%2824694097565%29.jpg'
photo_bytes=273028
photo_sha256=d1ba1b26171856c6e6ad953aab5625d86c94196bc64e92de47c2c50710e0c0bc

# upload.wikimedia.org answers 429 to a bare browser user agent and 400 to a
# thumbnail width outside its published bucket list, so the width above is one
# of those buckets and the agent carries a descriptive token beside the Mozilla
# prefix. No personal identifier goes in the header.
user_agent='Mozilla/5.0 (X11; Linux x86_64) qwen-apu-vision-fixture/1.0'

verify() {
    [ -f "$1" ] || return 1
    actual_bytes=$(stat -c %s "$1")
    actual_sha256=$(sha256sum "$1" | cut -d ' ' -f 1)
    [ "$actual_bytes" = "$photo_bytes" ] && [ "$actual_sha256" = "$photo_sha256" ]
}

if verify "$output_path"; then
    printf 'quality_photo=verified path=%s bytes=%s sha256=%s\n' \
        "$output_path" "$photo_bytes" "$photo_sha256"
    exit 0
fi

if [ -f "$output_path" ]; then
    printf 'existing file does not match the pinned revision: %s\n' "$output_path" >&2
    printf 'expected %s bytes sha256 %s\n' "$photo_bytes" "$photo_sha256" >&2
    printf 'found    %s bytes sha256 %s\n' \
        "$(stat -c %s "$output_path")" \
        "$(sha256sum "$output_path" | cut -d ' ' -f 1)" >&2
    exit 1
fi

command -v wget >/dev/null 2>&1 || {
    printf 'wget is absent\n' >&2
    exit 1
}

mkdir -p "$(dirname -- "$output_path")"
temporary_path=$output_path.partial
rm -f "$temporary_path"
wget -nv --user-agent="$user_agent" \
    --header='Accept: image/jpeg,image/*,*/*;q=0.8' \
    --referer='https://commons.wikimedia.org/wiki/File:Zebra_(24694097565).jpg' \
    --tries=4 --waitretry=25 --retry-on-http-error=429,503 \
    -O "$temporary_path" "$photo_url" || {
        rm -f "$temporary_path"
        printf 'fetch failed: %s\n' "$photo_url" >&2
        exit 1
    }

if ! verify "$temporary_path"; then
    printf 'fetched file does not match the pinned revision\n' >&2
    printf 'expected %s bytes sha256 %s\n' "$photo_bytes" "$photo_sha256" >&2
    printf 'found    %s bytes sha256 %s\n' \
        "$(stat -c %s "$temporary_path")" \
        "$(sha256sum "$temporary_path" | cut -d ' ' -f 1)" >&2
    rm -f "$temporary_path"
    exit 1
fi

mv "$temporary_path" "$output_path"
printf 'quality_photo=fetched path=%s bytes=%s sha256=%s\n' \
    "$output_path" "$photo_bytes" "$photo_sha256"
