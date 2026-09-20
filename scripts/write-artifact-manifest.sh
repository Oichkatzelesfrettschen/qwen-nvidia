#!/bin/sh
set -eu

# gpu-ownership: non-gpu-helper; executes no device binary.

# Write the artifact manifest promote-llama-build.sh reads: the preset the
# build directory was configured as, the commit and worktree state the
# build-configuration.tsv records, the serving and fallback backends the
# configuration names, then one `role<TAB>object<TAB>bytes<TAB>sha256` row per
# object. `executable` names the three launchers, `linked` the shared objects
# the dynamic linker resolves for llama-server as hash-load-closure.sh walks
# them, and `loadable` every shared object under bin/ by its unversioned and
# its fully versioned name, which covers the `*-impl.so` libraries a launcher
# dlopens. The promotion gate rehashes every row against bin/, so a rebuilt
# dependency under a promoted tree is refused there rather than served as a
# difference nobody attributes. The builder once wrote this file and stopped;
# every closure built since carried none, and the gate refused each by name.
# The row order reproduces the promoted closure's own manifest byte for byte.
#
#   usage: write-artifact-manifest.sh BUILD_DIRECTORY [OUTPUT]
#
# OUTPUT defaults to BUILD_DIRECTORY/artifact-manifest.tsv. The preset is the
# build directory's basename past `build-`.

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    printf 'usage: %s BUILD_DIRECTORY [OUTPUT]\n' "$0" >&2
    exit 2
fi
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
build_directory=$(CDPATH='' cd -- "$1" && pwd)
output_path=${2:-$build_directory/artifact-manifest.tsv}
configuration_path=$build_directory/build-configuration.tsv
hasher=$script_directory/hash-load-closure.sh

case ${build_directory##*/} in
    build-*) preset=${build_directory##*/build-} ;;
    *)
        printf 'build directory is not named build-PRESET: %s\n' \
            "$build_directory" >&2
        exit 2
        ;;
esac
if [ ! -r "$configuration_path" ]; then
    printf 'build directory carries no build-configuration.tsv: %s\n' \
        "$build_directory" >&2
    exit 1
fi
configuration_field() {
    awk -F'\t' -v key="$1" '$1 == key { print $2; exit }' "$configuration_path"
}
commit=$(configuration_field actual_commit)
source_diff=$(configuration_field source_diff_sha256)
[ -n "$commit" ] || { printf 'build-configuration.tsv names no actual_commit\n' >&2; exit 1; }
# The empty tree's diff hashes to e3b0c442..., so any other digest records
# a worktree that differed from the commit when the build ran.
case $source_diff in
    e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855) worktree=clean ;;
    *) worktree=dirty ;;
esac
# This tree configures GGML_VULKAN=OFF and LLAMA_NO_CPU_FALLBACK, so a
# served artifact has one backend and nothing to fall back to. The field
# stays in the manifest as the statement that there is none.
fallback_backend=none

temporary_manifest=$(mktemp "${TMPDIR:-/tmp}/artifact-manifest.XXXXXX")
trap 'rm -f "$temporary_manifest"' EXIT INT TERM
{
    printf 'preset\t%s\n' "$preset"
    printf 'commit\t%s\n' "$commit"
    printf 'worktree\t%s\n' "$worktree"
    printf 'serving_backend\tCUDA0\n'
    printf 'fallback_backend\t%s\n' "$fallback_backend"
    for executable in llama-server llama-cli llama-mtmd-cli; do
        executable_path=$build_directory/bin/$executable
        [ -x "$executable_path" ] || {
            printf 'build directory carries no executable %s\n' "$executable" >&2
            exit 1
        }
        printf 'executable\t%s\t%s\t%s\n' "$executable" \
            "$(stat -c %s "$executable_path")" \
            "$(sha256sum "$executable_path" | cut -d ' ' -f 1)"
    done
    "$hasher" "$build_directory/bin/llama-server" |
        awk -F'\t' '$1 == "linked" && $2 !~ /-impl\.so/'
    for pattern in '*.so' '*.so.[0-9]*.[0-9]*.[0-9]*'; do
        find "$build_directory/bin" -maxdepth 1 -name "$pattern" -print | sort |
            while IFS= read -r object_path; do
                printf 'loadable\t%s\t%s\t%s\n' "${object_path##*/}" \
                    "$(stat -c %s "$object_path")" \
                    "$(sha256sum "$object_path" | cut -d ' ' -f 1)"
            done
    done
} >"$temporary_manifest"
object_count=$(awk -F'\t' '$1 == "executable" || $1 == "linked" || $1 == "loadable"' \
    "$temporary_manifest" | wc -l)
[ "$object_count" -gt 0 ] || {
    printf 'the closure names no hashable object\n' >&2
    exit 1
}
mv -f "$temporary_manifest" "$output_path"
trap - EXIT INT TERM
printf 'artifact_manifest=written path=%s objects=%s\n' "$output_path" "$object_count"
