#!/bin/sh
set -eu

# A launcher's identity covers 17 KB of argument parsing. The measurement code
# and the kernels live in the shared objects the dynamic linker resolves, so an
# artifact record that names the executable alone leaves the code that produced
# a row unidentified. This walks the closure ldd reports, keeps the entries the
# build tree owns, and emits one TSV row per object.

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    printf 'usage: %s EXECUTABLE [OUTPUT_TSV]\n' "$0" >&2
    exit 2
fi

executable_path=$1
output_path=${2:-}

if [ ! -x "$executable_path" ]; then
    printf 'executable is missing or not executable: %s\n' "$executable_path" >&2
    exit 1
fi

executable_directory=$(CDPATH='' cd -- "$(dirname -- "$executable_path")" && pwd)

emit_row() {
    object_path=$1
    object_role=$2
    object_bytes=$(stat -c %s "$object_path")
    object_sha256=$(sha256sum "$object_path" | cut -d ' ' -f 1)
    printf '%s\t%s\t%s\t%s\n' \
        "$object_role" "$(basename -- "$object_path")" \
        "$object_bytes" "$object_sha256"
}

collect_closure() {
    printf 'role\tobject\tbytes\tsha256\n'
    emit_row "$executable_path" executable

    # ldd prints "soname => path (addr)" for resolved entries and omits the
    # arrow for the loader and for vDSO, so the arrow is the filter that keeps
    # resolvable paths. Objects outside the build directory are the
    # distribution's and carry their own package identity.
    # Space-separated so that the membership test below is a substring match;
    # the sed pattern already rejects a path containing a space.
    linked_paths=$(ldd "$executable_path" 2>/dev/null |
        sed -n 's/^.* => \(\/[^ ]*\).*$/\1/p' | sort -u | tr '\n' ' ')

    for resolved_path in $linked_paths; do
        case $resolved_path in
            "$executable_directory"/*) emit_row "$resolved_path" linked ;;
            *) ;;
        esac
    done

    # ldd reports DT_NEEDED alone. A GGML_BACKEND_DL build loads its backends
    # through dlopen, so the objects whose kernels produced a row are exactly
    # the ones the linked walk misses. Every shared object beside the
    # executable is recorded, and one already named above is skipped.
    for candidate_path in "$executable_directory"/*.so "$executable_directory"/*.so.*; do
        [ -f "$candidate_path" ] || continue
        case " $linked_paths " in
            *" $candidate_path "*) continue ;;
        esac
        emit_row "$candidate_path" loadable
    done
}

if [ -n "$output_path" ]; then
    collect_closure > "$output_path"
    printf 'closure=written path=%s rows=%s\n' \
        "$output_path" "$(($(wc -l < "$output_path") - 1))"
else
    collect_closure
fi
