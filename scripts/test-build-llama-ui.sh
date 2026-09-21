#!/bin/sh
set -eu

# Admit scripts/build-llama-ui.sh without Node: a fixture front end and a fake
# npm on PATH exercise the install, and the refusals a source tree without a
# package.json, a build that writes no dist/index.html, an absent toolchain and
# a destination holding something other than a previous install each earn. The
# fixture source tree is read afterwards to show the build left the pinned
# checkout alone, and the script text is read to show the install reaches no
# second machine.

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
builder=$script_directory/build-llama-ui.sh
work_directory=$(mktemp -d "${TMPDIR:-/tmp}/build-llama-ui.XXXXXX")
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

# The arms run against a PATH holding only the fakes and the utilities the
# builder calls by name, so the absent-toolchain arm removes node rather than
# relying on the host not having it.
system_bin=$work_directory/system-bin
fake_bin=$work_directory/fake-bin
mkdir -p "$system_bin" "$fake_bin"
for utility in mktemp tar rm mkdir mv cp dirname; do
    path=$(command -v "$utility")
    ln -s "$path" "$system_bin/$utility"
done

cat >"$fake_bin/node" <<'NODE'
#!/bin/sh
exit 0
NODE
cat >"$fake_bin/npm" <<'NPM'
#!/bin/sh
case ${1:-} in
    ci) exit 0 ;;
    run)
        [ "${FAKE_NPM_EMPTY_BUILD:-0}" = 1 ] && exit 0
        mkdir -p dist
        printf '<!doctype html><title>llama-ui</title>\n' >dist/index.html
        cp package.json dist/built-from.json
        exit 0
        ;;
esac
exit 0
NPM
chmod +x "$fake_bin/node" "$fake_bin/npm"

source_directory=$work_directory/ui-source
mkdir -p "$source_directory/src"
printf '{"name":"llama-ui","scripts":{"build":"vite build"}}\n' \
    >"$source_directory/package.json"
printf '{}\n' >"$source_directory/package-lock.json"

run_builder() {
    target=$1
    shift
    env -i \
        PATH="$fake_bin:$system_bin" \
        HOME="$work_directory" \
        QWEN_UI_SOURCE="$source_directory" \
        "$@" \
        /bin/sh "$builder" "$target"
}

destination=$work_directory/webui-llama-ui
if run_builder "$destination" >"$work_directory/out" 2>"$work_directory/err"; then
    check builder_exits_zero pass
else
    check builder_exits_zero fail "$(cat "$work_directory/err")"
fi
if [ -f "$destination/index.html" ] && [ -f "$destination/built-from.json" ]; then
    check install_carries_build pass
else
    check install_carries_build fail "$(find "$destination" -mindepth 1 -maxdepth 1 2>&1 | tr '\n' ' ')"
fi
if [ ! -e "$source_directory/node_modules" ] && [ ! -e "$source_directory/dist" ]; then
    check pinned_checkout_untouched pass
else
    check pinned_checkout_untouched fail "$(find "$source_directory" -mindepth 1 -maxdepth 1 | tr '\n' ' ')"
fi

if grep -qE '\bssh\b|\brsync\b' "$builder"; then
    check install_reaches_one_host fail "$(grep -nE '\bssh\b|\brsync\b' "$builder" | tr '\n' ' ')"
else
    check install_reaches_one_host pass
fi

# A second install replaces the first, which is what makes the destination
# guard below the only thing standing between the script and a foreign tree.
if [ -d "$destination" ]; then
    printf 'stale\n' >"$destination/stale.txt"
fi
run_builder "$destination" >/dev/null 2>&1 || true
if [ -f "$destination/index.html" ] && [ ! -e "$destination/stale.txt" ]; then
    check reinstall_replaces_tree pass
else
    check reinstall_replaces_tree fail "$(find "$destination" -mindepth 1 -maxdepth 1 | tr '\n' ' ')"
fi

if run_builder "$work_directory/absent-source" \
    QWEN_UI_SOURCE="$work_directory/not-a-tree" >/dev/null 2>"$work_directory/err"; then
    check missing_sources_refused fail "accepted"
elif grep -q 'no front end sources at' "$work_directory/err"; then
    check missing_sources_refused pass
else
    check missing_sources_refused fail "$(cat "$work_directory/err")"
fi

# The failing build runs against the populated destination, because the swap
# order is what keeps llama-server's --path valid across a failed rebuild.
if run_builder "$destination" FAKE_NPM_EMPTY_BUILD=1 \
    >/dev/null 2>"$work_directory/err"; then
    check empty_build_refused fail "accepted"
elif grep -q 'produced no dist/index.html' "$work_directory/err"; then
    check empty_build_refused pass
else
    check empty_build_refused fail "$(cat "$work_directory/err")"
fi
if [ -f "$destination/index.html" ]; then
    check failed_build_keeps_install pass
else
    check failed_build_keeps_install fail "destination lost its index.html"
fi

rm "$fake_bin/node"
if run_builder "$work_directory/no-node" >/dev/null 2>"$work_directory/err"; then
    check absent_toolchain_refused fail "accepted"
elif grep -q 'needs node on this host' "$work_directory/err"; then
    check absent_toolchain_refused pass
else
    check absent_toolchain_refused fail "$(cat "$work_directory/err")"
fi
printf '#!/bin/sh\nexit 0\n' >"$fake_bin/node"
chmod +x "$fake_bin/node"

foreign=$work_directory/foreign
mkdir -p "$foreign"
printf 'not a front end\n' >"$foreign/notes.txt"
if run_builder "$foreign" >/dev/null 2>"$work_directory/err"; then
    check foreign_destination_refused fail "accepted"
elif grep -q 'it holds no index.html' "$work_directory/err" \
    && [ -f "$foreign/notes.txt" ]; then
    check foreign_destination_refused pass
else
    check foreign_destination_refused fail "$(cat "$work_directory/err")"
fi

printf 'checks_total=%s checks_failed=%s\n' "$checks_total" "$checks_failed"
[ "$checks_failed" -eq 0 ]
