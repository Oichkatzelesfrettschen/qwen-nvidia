#!/bin/sh
set -eu

# Holds the paged KV residency engine to its transaction contract with a
# mocked driver and no device. The engine is ggml/src/ggml-cuda/paged-kv-residency.h,
# a new file patches/llama-cuda-paged-kv-buffer.patch adds to the pinned
# tree, so the test extracts that file from the patch rather than carrying a
# second copy that could drift from the bytes the closure builds from: a
# new-file hunk is all added lines, and stripping the leading plus yields the
# file verbatim. The C++ driver is g++-15 ahead of g++, the compiler the CUDA
# closure's host side uses. The test prints one line per check and ends on
# residency_transactions=passed|failed.

usage() {
    cat >&2 <<'USAGE'
usage: test-paged-kv-residency-transactions.sh

Extracts the residency engine from patches/llama-cuda-paged-kv-buffer.patch,
compiles scripts/test-paged-kv-residency-transactions.cpp against it, and
runs it. QWEN_HOST_CXX names the compiler; the default is g++-15, then g++.
USAGE
    exit 2
}

[ "$#" -eq 0 ] || usage

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repository_directory=$(CDPATH='' cd -- "$script_directory/.." && pwd)
patch_file=$repository_directory/patches/llama-cuda-paged-kv-buffer.patch
header_path=ggml/src/ggml-cuda/paged-kv-residency.h

host_cxx=${QWEN_HOST_CXX:-}
if [ -z "$host_cxx" ]; then
    if command -v g++-15 >/dev/null 2>&1; then
        host_cxx=g++-15
    elif command -v g++ >/dev/null 2>&1; then
        host_cxx=g++
    else
        printf 'residency_transactions=not_run reason=no_cxx_compiler\n'
        exit 1
    fi
fi

work_directory=$(mktemp -d "${TMPDIR:-/tmp}/paged-kv-residency.XXXXXX")
trap 'rm -rf "$work_directory"' EXIT INT TERM

# The header's hunk runs from its +++ line to the next diff header; every
# body line of a new file starts with a plus, and a line that starts with
# anything else inside that span means the patch modifies an existing file
# rather than adding one, which this extraction cannot serve.
awk -v path="$header_path" '
    $0 == "+++ b/" path { in_file = 1; next }
    in_file && /^diff --git / { in_file = 0 }
    in_file && /^@@ / { next }
    in_file && /^\\ No newline/ { next }
    in_file {
        if (substr($0, 1, 1) != "+") {
            printf "residency_transactions=refused reason=header_hunk_not_new_file line=%s\n", $0 > "/dev/stderr"
            exit 3
        }
        print substr($0, 2)
    }
' "$patch_file" >"$work_directory/paged-kv-residency.h"

[ -s "$work_directory/paged-kv-residency.h" ] || {
    printf 'residency_transactions=refused reason=header_absent_from_patch path=%s\n' "$header_path"
    exit 1
}
grep -q 'class ggml_paged_kv_residency' "$work_directory/paged-kv-residency.h" || {
    printf 'residency_transactions=refused reason=engine_class_absent\n'
    exit 1
}
printf 'residency_engine_sha256=%s\n' "$(sha256sum "$work_directory/paged-kv-residency.h" | cut -c1-64)"

"$host_cxx" -std=c++17 -Wall -Wextra -Werror -I"$work_directory" \
    -o "$work_directory/test" "$script_directory/test-paged-kv-residency-transactions.cpp"

"$work_directory/test"
