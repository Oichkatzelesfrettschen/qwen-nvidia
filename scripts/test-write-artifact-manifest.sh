#!/bin/sh
set -eu

# Admit scripts/write-artifact-manifest.sh without a build: a fixture build
# directory carries a build-configuration.tsv, three executables, and shared
# objects under both their unversioned and versioned names, so the checks read
# the header the promotion gate parses, one row per object that the gate
# rehashes, the versioned and the dlopened objects under `loadable`, and the
# refusals a misnamed directory and a missing configuration earn.

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
writer=$script_directory/write-artifact-manifest.sh
work_directory=$(mktemp -d "${TMPDIR:-/tmp}/write-artifact-manifest.XXXXXX")
trap 'rm -rf "$work_directory"' EXIT INT TERM

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

build=$work_directory/build-qwen-cuda-0123456789ab
mkdir -p "$build/bin"
printf 'configuration_schema\t2\nactual_commit\tabc123\nsource_diff_sha256\tdeadbeef\nvulkan\tOFF\n' \
    >"$build/build-configuration.tsv"
for executable in llama-server llama-cli llama-mtmd-cli; do
    printf '#!/bin/sh\nexit 0\n' >"$build/bin/$executable"
    chmod +x "$build/bin/$executable"
done
printf 'ggml' >"$build/bin/libggml.so.0.21.0"
ln -s libggml.so.0.21.0 "$build/bin/libggml.so.0"
ln -s libggml.so.0.21.0 "$build/bin/libggml.so"
printf 'server-impl' >"$build/bin/libllama-server-impl.so"

if output=$("$writer" "$build" 2>"$work_directory/stderr"); then
    check writer_exits_zero pass
else
    check writer_exits_zero fail "$(cat "$work_directory/stderr")"
fi
manifest=$build/artifact-manifest.tsv
if [ "$(sed -n '1,5p' "$manifest" | tr '\n' ' ')" = \
   "preset	qwen-cuda-0123456789ab commit	abc123 worktree	dirty serving_backend	CUDA0 fallback_backend	none " ]; then
    check header_rows pass
else
    check header_rows fail "$(sed -n '1,5p' "$manifest" | tr '\n' ' ')"
fi
server_digest=$(sha256sum "$build/bin/llama-server" | cut -d ' ' -f 1)
if grep -q "^executable	llama-server	$(stat -c %s "$build/bin/llama-server")	$server_digest\$" "$manifest" \
    && [ "$(grep -c '^executable	' "$manifest")" = 3 ]; then
    check executable_rows pass
else
    check executable_rows fail "$(grep '^executable' "$manifest" | tr '\n' ' ')"
fi
impl_digest=$(sha256sum "$build/bin/libllama-server-impl.so" | cut -d ' ' -f 1)
if grep -q "^loadable	libllama-server-impl.so	11	$impl_digest\$" "$manifest" \
    && grep -q '^loadable	libggml.so.0.21.0	4	' "$manifest" \
    && grep -q '^loadable	libggml.so	' "$manifest" \
    && ! grep -q '^loadable	libggml.so.0	' "$manifest"; then
    check loadable_rows pass
else
    check loadable_rows fail "$(grep '^loadable' "$manifest" | tr '\n' ' ')"
fi
case $output in
    *'objects=6'*) check object_count pass ;;
    *) check object_count fail "$output" ;;
esac

# A clean tree is read from the empty-tree digest.
sed -i 's/^source_diff_sha256\t.*/source_diff_sha256\te3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855/' \
    "$build/build-configuration.tsv"
"$writer" "$build" >/dev/null
if grep -q '^worktree	clean$' "$manifest"; then
    check clean_worktree_read pass
else
    check clean_worktree_read fail "$(grep '^worktree' "$manifest")"
fi

misnamed=$work_directory/candidate
mkdir -p "$misnamed/bin"
if "$writer" "$misnamed" >/dev/null 2>"$work_directory/stderr"; then
    check misnamed_directory_refused fail "accepted"
elif grep -q 'not named build-PRESET' "$work_directory/stderr"; then
    check misnamed_directory_refused pass
else
    check misnamed_directory_refused fail "$(cat "$work_directory/stderr")"
fi

rm "$build/build-configuration.tsv"
if "$writer" "$build" >/dev/null 2>"$work_directory/stderr"; then
    check missing_configuration_refused fail "accepted"
elif grep -q 'no build-configuration.tsv' "$work_directory/stderr"; then
    check missing_configuration_refused pass
else
    check missing_configuration_refused fail "$(cat "$work_directory/stderr")"
fi

printf 'checks_total=%s checks_failed=%s\n' "$checks_total" "$checks_failed"
[ "$checks_failed" -eq 0 ]
