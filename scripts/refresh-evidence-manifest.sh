#!/bin/sh
set -eu

# ARTIFACTS.md names evidence/SHA256SUMS as the replay authority for every raw
# evidence surface, which holds only while the manifest covers the tree. It
# drifted to 154 of 216 files because each new measurement was committed without
# it, so this script regenerates the whole manifest from the tracked tree and
# `--check` reports the drift without writing.
#
# The manifest covers the sanitized Git copies. evidence/PRE_SANITIZATION_SHA256SUMS
# and the per-directory copies of it record the originals before the identifier
# pass, so they are the one class the manifest excludes: hashing a manifest into
# a manifest makes each refresh rewrite the other.

if [ "$#" -gt 1 ]; then
    printf 'usage: %s [--check]\n' "$0" >&2
    exit 2
fi

mode=${1:-write}
case $mode in
    write | --check) ;;
    *)
        printf 'usage: %s [--check]\n' "$0" >&2
        exit 2
        ;;
esac

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH='' cd -- "$script_directory/.." && pwd)
manifest=$repository_root/evidence/SHA256SUMS
temporary_manifest=$manifest.new

cd "$repository_root"

# Tracked files alone, so an untracked scratch file under evidence/ never enters
# the manifest and a manifest entry always names something a clone receives.
# LC_ALL=C makes the order bytes rather than collation. A bare sort takes the
# caller's locale, and en_US.UTF-8 ignores the hyphen at its first level where C
# compares 0x2D directly, so qwen-kernel-baseline.log and qwen35-4b-c4k-smoke.log
# swap between two machines that hash the same tree to the same digests. The
# manifest is committed, so a locale-dependent order makes it drift on the next
# refresh from a different machine and the gate reports that as staleness.
git -c core.fsmonitor=false ls-files benchmarks evidence |
    grep -v -e '/PRE_SANITIZATION_SHA256SUMS$' -e '^evidence/PRE_SANITIZATION_SHA256SUMS$' \
            -e '^evidence/SHA256SUMS$' |
    LC_ALL=C sort >"$temporary_manifest.paths"

xargs -r sha256sum <"$temporary_manifest.paths" >"$temporary_manifest"
rm -f "$temporary_manifest.paths"

if [ "$mode" = --check ]; then
    if cmp -s "$manifest" "$temporary_manifest"; then
        rm -f "$temporary_manifest"
        printf 'evidence_manifest=current entries=%s\n' "$(wc -l <"$manifest")"
        exit 0
    fi
    printf 'evidence_manifest=stale\n' >&2
    diff -u "$manifest" "$temporary_manifest" >&2 || true
    rm -f "$temporary_manifest"
    exit 1
fi

mv "$temporary_manifest" "$manifest"
printf 'evidence_manifest=written entries=%s\n' "$(wc -l <"$manifest")"
