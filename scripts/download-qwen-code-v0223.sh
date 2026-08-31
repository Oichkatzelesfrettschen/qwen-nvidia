#!/bin/sh
set -eu

# Fetch and install the pinned Qwen Code release. The registry row in
# scripts/coding-runtimes.tsv carries the pin; this script downloads the
# release asset and the publisher's SHA256SUMS artifact, requires the byte
# count and the digest to match both authorities, refuses any archive member
# that is a link or escapes the archive root, extracts into a versioned
# directory, proves the executable answers --version with the pinned
# version, and atomically points the `candidate` symlink at it. A prior
# version keeps its own directory, so rollback is a symlink move. The
# repository owns the upgrade decision: the generated settings in
# scripts/qwen-code-settings.json disable the runtime's own auto-update.

usage() {
    printf 'usage: %s [INSTALL_ROOT]\n' "$0" >&2
    printf '  INSTALL_ROOT defaults to ~/tools/qwen-code\n' >&2
    exit 2
}

[ "$#" -le 1 ] || usage
install_root=${1:-"${HOME:?}/tools/qwen-code"}

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
registry=$script_directory/coding-runtimes.tsv

runtime_row=$(awk -F'\t' '!/^#/ && $1 == "qwen-code" && $2 == "0.22.3"' \
    "$registry")
[ -n "$runtime_row" ] || {
    printf 'coding-runtimes.tsv holds no qwen-code 0.22.3 row\n' >&2
    exit 1
}
upstream_repository=$(printf '%s' "$runtime_row" | cut -f3)
release_tag=$(printf '%s' "$runtime_row" | cut -f4)
asset_name=$(printf '%s' "$runtime_row" | cut -f5)
expected_bytes=$(printf '%s' "$runtime_row" | cut -f6)
expected_sha256=$(printf '%s' "$runtime_row" | cut -f7)
version_directory=$(printf '%s' "$runtime_row" | cut -f8)
executable_relative=$(printf '%s' "$runtime_row" | cut -f9)

release_base=https://github.com/$upstream_repository/releases/download/$release_tag
target_directory=$install_root/$version_directory
candidate_link=$install_root/candidate

mkdir -p "$install_root"
work_directory=$(mktemp -d "$install_root/.fetch-XXXXXX")
trap 'rm -rf "$work_directory"' EXIT INT TERM

archive=$work_directory/$asset_name
digest_file=$work_directory/SHA256SUMS

curl --silent --show-error --location --fail --retry 3 \
    --output "$archive" "$release_base/$asset_name"
curl --silent --show-error --location --fail --retry 3 \
    --output "$digest_file" "$release_base/SHA256SUMS"

# The publisher's digest artifact is the outer authority and the registry pin
# is the inner one; the fetched bytes must satisfy both.
publisher_sha256=$(awk -v asset="$asset_name" '$2 == asset { print $1 }' \
    "$digest_file")
[ -n "$publisher_sha256" ] || {
    printf 'publisher SHA256SUMS names no %s\n' "$asset_name" >&2
    exit 1
}
[ "$publisher_sha256" = "$expected_sha256" ] || {
    printf 'publisher digest %s disagrees with the registry pin %s\n' \
        "$publisher_sha256" "$expected_sha256" >&2
    exit 1
}
actual_bytes=$(wc -c <"$archive" | tr -d ' ')
[ "$actual_bytes" = "$expected_bytes" ] || {
    printf 'fetched %s bytes, registry pins %s\n' \
        "$actual_bytes" "$expected_bytes" >&2
    exit 1
}
actual_sha256=$(sha256sum "$archive" | cut -d ' ' -f 1)
[ "$actual_sha256" = "$expected_sha256" ] || {
    printf 'fetched digest %s, registry pins %s\n' \
        "$actual_sha256" "$expected_sha256" >&2
    exit 1
}

# Every member must be a regular file or directory under the archive root:
# a link member or a path reaching outside the extraction directory writes
# where the archive names rather than where the installer chose.
unsafe_members=$(tar -tzvf "$archive" | awk '
    substr($1, 1, 1) != "-" && substr($1, 1, 1) != "d" { print; next }' || :)
[ -z "$unsafe_members" ] || {
    printf 'archive carries non-regular members:\n%s\n' "$unsafe_members" >&2
    exit 1
}
escaping_paths=$(tar -tzf "$archive" | awk '
    /^\// || /^\.\.\// || /\/\.\.\// || /\/\.\.$/ { print }' || :)
[ -z "$escaping_paths" ] || {
    printf 'archive carries escaping paths:\n%s\n' "$escaping_paths" >&2
    exit 1
}

extract_directory=$work_directory/extract
mkdir "$extract_directory"
tar -xzf "$archive" -C "$extract_directory"

staged_executable=$extract_directory/$executable_relative
[ -x "$staged_executable" ] || {
    printf 'extracted archive holds no executable at %s\n' \
        "$executable_relative" >&2
    exit 1
}
reported_version=$("$staged_executable" --version 2>&1 | tr -d '[:space:]')
case $reported_version in
    *0.22.3*) : ;;
    *)
        printf 'executable reports version %s, registry pins 0.22.3\n' \
            "$reported_version" >&2
        exit 1
        ;;
esac

if [ -e "$target_directory" ]; then
    printf 'install_status=already_installed directory=%s\n' \
        "$target_directory"
else
    mv "$extract_directory" "$target_directory"
    printf 'install_status=installed directory=%s\n' "$target_directory"
fi

# The symlink swap is one rename, so a reader of `candidate` sees the prior
# version or this one and never a partial state.
ln -s "$version_directory" "$work_directory/candidate.next"
mv -T "$work_directory/candidate.next" "$candidate_link"

printf 'qwen_code=pinned version=0.22.3 bytes=%s verified_sha256=%s candidate=%s\n' \
    "$expected_bytes" "$expected_sha256" "$candidate_link"
