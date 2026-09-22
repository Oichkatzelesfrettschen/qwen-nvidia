#!/bin/sh
set -eu

# Build the llama.cpp front end and install it as the static directory
# llama-server serves through --path.
#
# The front end is a Vite project inside the pinned llama.cpp checkout, which
# this repository does not vendor, so the build reads it through
# QWEN_UI_SOURCE and produces plain files. npm and its dependency set stay in
# a temporary build tree that the exit trap removes, and the build runs on a
# copy so the pinned checkout keeps the contents the promotion gate recorded.
# The installed directory holds the built output alone;
# scripts/qwen-webui-control.sh selects it over webui/ by its index.html.

if [ "$#" -gt 1 ]; then
    printf 'usage: %s [DESTINATION]\n' "$0" >&2
    exit 2
fi

CDPATH='' cd -- "$(dirname -- "$0")/.."
repository_root=$(pwd)

llama_source=${QWEN_LLAMA_SOURCE:-"${HOME:?}/src/llama.cpp-qwen-nvidia"}
source_directory=${QWEN_UI_SOURCE:-"$llama_source/tools/ui"}
destination=${1:-"$repository_root/webui-llama-ui"}

for required in node npm tar patch; do
    command -v "$required" >/dev/null 2>&1 || {
        printf 'the front end build needs %s on this host\n' "$required" >&2
        exit 1
    }
done

if [ ! -f "$source_directory/package.json" ]; then
    printf 'no front end sources at %s; set QWEN_UI_SOURCE\n' \
        "$source_directory" >&2
    exit 1
fi

# An install replaces the destination wholesale, so a directory that carries no
# index.html is something other than a previous install and is left alone.
if [ -e "$destination" ] && [ ! -f "$destination/index.html" ]; then
    printf 'refusing to replace %s: it holds no index.html\n' "$destination" >&2
    exit 1
fi

mkdir -p "$repository_root/.local-artifacts"
work_directory=$(mktemp -d "${TMPDIR:-$repository_root/.local-artifacts}/build-llama-ui.XXXXXX")
staging=$work_directory/install
cleanup() {
    rm -rf "$work_directory"
}
trap cleanup EXIT HUP INT TERM

printf 'copying front end sources from %s\n' "$source_directory"
mkdir -p "$work_directory/source"
( cd "$source_directory" && tar -cf - --exclude=node_modules --exclude=dist . ) |
    ( cd "$work_directory/source" && tar -xf - )

printf 'applying the native Graft approval hook\n'
patch --batch --forward --fuzz=0 --strip=1 --directory="$work_directory/source" \
    <"$repository_root/patches/llama-ui-graft-approval.patch"
mkdir -p "$work_directory/source/src/lib/services"
cp "$repository_root/scripts/llama-ui/qwen-graft-grant.js" \
    "$work_directory/source/src/lib/services/qwen-graft-grant.js"

printf 'installing dependencies\n'
( cd "$work_directory/source" && npm ci --no-audit --no-fund >/dev/null )

printf 'building\n'
( cd "$work_directory/source" && npm run build >/dev/null )

if [ ! -f "$work_directory/source/dist/index.html" ]; then
    printf 'the build produced no dist/index.html\n' >&2
    exit 1
fi

# The swap happens after the build succeeds, so a failed build leaves the
# serving directory as it was and llama-server keeps its --path valid.
printf 'installing into %s\n' "$destination"
mkdir -p "$staging"
( cd "$work_directory/source/dist" && tar -cf - . ) |
    ( cd "$staging" && tar -xf - )
if [ -d "$destination" ]; then
    mv "$destination" "$work_directory/replaced"
fi
mkdir -p "$(dirname -- "$destination")"
mv "$staging" "$destination"

printf 'installed; restart the session to serve it\n'
