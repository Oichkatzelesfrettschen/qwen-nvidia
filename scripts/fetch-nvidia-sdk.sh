#!/bin/sh
set -eu

# Fetch one archive named in scripts/nvidia-sdk-artifacts.tsv into a directory
# and verify it against the vendor-published digest the ledger pins. The
# ledger is the authority: a row's source_url is where the bytes come from and
# its sha256 is what they have to hash to, so a changed upstream file is a
# refusal here rather than an installed surprise. An archive already present
# at the expected digest is left alone. Installation is not this script's job;
# the PKGBUILD the row names does that with the same digest.

usage() {
    printf 'usage: %s ARTIFACT_ID DESTINATION_DIRECTORY\n' "$0" >&2
    exit 2
}
[ "$#" -eq 2 ] || usage
artifact_id=$1
destination=$2

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ledger=$script_directory/nvidia-sdk-artifacts.tsv

row=$(awk -F '\t' -v id="$artifact_id" '!/^#/ && NF > 1 && $1 == id { print; found++ }
    END { if (found != 1) exit 1 }' "$ledger") || {
    printf 'nvidia-sdk-artifacts.tsv names no single row for %s\n' "$artifact_id" >&2
    exit 2
}
artifact_name=$(printf '%s\n' "$row" | cut -f 7)
source_url=$(printf '%s\n' "$row" | cut -f 8)
expected_sha256=$(printf '%s\n' "$row" | cut -f 9)
status=$(printf '%s\n' "$row" | cut -f 12)
case $expected_sha256 in
    *[!0-9a-f]* | '') printf 'row %s carries no hex digest\n' "$artifact_id" >&2; exit 2 ;;
esac
[ "${#expected_sha256}" -eq 64 ] || { printf 'row %s digest is not 64 hex\n' "$artifact_id" >&2; exit 2; }
[ "$status" = pinned ] || { printf 'row %s is %s rather than pinned\n' "$artifact_id" "$status" >&2; exit 2; }

mkdir -p "$destination"
target=$destination/$artifact_name
if [ -f "$target" ]; then
    observed=$(sha256sum "$target" | cut -d ' ' -f 1)
    if [ "$observed" = "$expected_sha256" ]; then
        printf 'nvidia_sdk_fetch=present artifact=%s sha256=%s\n' "$artifact_id" "$observed"
        exit 0
    fi
    printf 'an archive at %s hashes to %s rather than %s; remove it to refetch\n' \
        "$target" "$observed" "$expected_sha256" >&2
    exit 1
fi
# The download lands under a temporary name and is renamed only after it
# hashes, so a partial or altered transfer never sits at the pinned name.
partial=$target.partial
curl --silent --show-error --fail --location --output "$partial" "$source_url"
observed=$(sha256sum "$partial" | cut -d ' ' -f 1)
if [ "$observed" != "$expected_sha256" ]; then
    rm -f "$partial"
    printf 'fetched %s hashes to %s rather than the pinned %s\n' \
        "$artifact_id" "$observed" "$expected_sha256" >&2
    exit 1
fi
mv "$partial" "$target"
printf 'nvidia_sdk_fetch=verified artifact=%s sha256=%s bytes=%s\n' \
    "$artifact_id" "$observed" "$(stat -c %s "$target")"
