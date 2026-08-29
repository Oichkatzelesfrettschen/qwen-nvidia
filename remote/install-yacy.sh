#!/bin/sh
set -eu

# Installs YaCy natively under $HOME/opt/yacy from a pinned upstream tag and
# writes the loopback, on-demand overrides remote/yacy-control.sh and
# remote/searxng-settings.yml's yacy engine both depend on.
#
# YaCy ships no published SHA-256 for its release tarballs on github.com or
# docs.searxng.org, the two hosts this task's network allowance names, and a
# GitHub-generated /archive/refs/tags/*.tar.gz is not a stable byte stream to
# pin against. This script pins the tag's own commit instead -- a git SHA-1
# read with `git ls-remote --tags`, the same identity class the install
# proves clean and exact against with `git status --porcelain` and
# `git rev-parse HEAD`, matching remote/install-searxng.sh's discipline -- and
# builds from that pinned source with `ant clean all`, the path
# yacy_search_server's own README documents. A published tarball SHA-256
# stays an unconfirmed input; evidence/searxng-provenance.md names it "-" and
# lists it under what this script could not confirm rather than inventing one.

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

install_directory=${1:-"${HOME:?}/opt/yacy"}

# Read with `git ls-remote --tags --sort=-v:refname
# https://github.com/yacy/yacy_search_server.git` on 2026-08-28: the highest
# version tag is Release_1.941.
pinned_tag=Release_1.941
pinned_commit=f0464e7fbcfcb69127f0325910f92f113ce23677
pin_branch=qwen-yacy-pin
upstream_url=https://github.com/yacy/yacy_search_server.git

required_java_major=17

if ! command -v java >/dev/null 2>&1; then
    printf 'java not found on PATH; YaCy requires Java %s or later\n' \
        "$required_java_major" >&2
    exit 1
fi
# The captured group is the first run of digits after the opening quote,
# whether the version string carries a dot ("17.0.9") or stands alone
# ("21"); a trailing ".*" absorbs whatever text follows either form. Pre-9
# java reports "1.8.0_292" for Java 8, which this captures as "1" rather
# than "8" -- both compare below the required major, so the check still
# refuses that runtime, only under a misleading number in its own message.
java_version_output=$(java -version 2>&1 || true)
java_major=$(printf '%s\n' "$java_version_output" |
    sed -n 's/^[^"]*"\([0-9][0-9]*\).*/\1/p' |
    head -n1)
if [ -z "$java_major" ] || [ "$java_major" -lt "$required_java_major" ]; then
    printf 'java major version %s is below the required %s:\n%s\n' \
        "${java_major:-unknown}" "$required_java_major" \
        "$java_version_output" >&2
    exit 1
fi

if ! command -v ant >/dev/null 2>&1; then
    printf 'ant not found on PATH; required to build YaCy from source\n' >&2
    exit 1
fi

printf 'cloning pinned YaCy tag %s (%s) into %s\n' \
    "$pinned_tag" "$pinned_commit" "$install_directory"
if [ -d "$install_directory/.git" ]; then
    git -C "$install_directory" fetch origin
else
    git clone "$upstream_url" "$install_directory"
fi
git -C "$install_directory" checkout -B "$pin_branch" "$pinned_commit"

clone_status=$(git -C "$install_directory" status --porcelain)
if [ -n "$clone_status" ]; then
    printf 'pinned clone is not clean:\n%s\n' "$clone_status" >&2
    exit 1
fi
clone_head=$(git -C "$install_directory" rev-parse HEAD)
if [ "$clone_head" != "$pinned_commit" ]; then
    printf 'HEAD %s does not match pin %s\n' "$clone_head" "$pinned_commit" >&2
    exit 1
fi

printf 'building: ant clean all (in %s)\n' "$install_directory"
build_log=$(mktemp)
cleanup_build_log() {
    rm -f "$build_log"
}
trap cleanup_build_log EXIT
if ! (cd "$install_directory" && ant clean all) >"$build_log" 2>&1; then
    printf 'ant clean all failed -- see %s\n' "$build_log" >&2
    tail -n 60 "$build_log" >&2
    exit 1
fi
build_log_sha256=$(sha256sum "$build_log" | cut -d' ' -f1)

settings_directory=$install_directory/DATA/SETTINGS
mkdir -p "$settings_directory"
config_file=$settings_directory/yacy.conf

# defaults/yacy.init in the pinned tree carries every key at its shipped
# default; this file names only the keys this instance overrides.
# source/net/yacy/server/serverSwitch.java's constructor loads both files as
# maps and does initProps.putAll(configProps), so a yacy.conf naming a subset
# of keys layers over the full defaults rather than needing every key
# restated. autocrawl already defaults to false in the pinned tree
# (defaults/yacy.init:627); this instance states it explicitly so a later
# upstream default change cannot start a crawl this laptop never asked for.
cat >"$config_file" <<EOF
port = 8090
host = 127.0.0.1
upnp.enabled = false
server.https=false
javastart_Xmx=Xmx600m
javastart_priority=10
autocrawl=false
EOF
config_sha256=$(sha256sum "$config_file" | cut -d' ' -f1)

control_script=$script_directory/yacy-control.sh
if [ ! -x "$control_script" ]; then
    printf 'control script missing or not executable: %s\n' "$control_script" >&2
    exit 1
fi

printf 'starting YaCy through %s\n' "$control_script"
# A cold JVM start on two 2.3 GHz cores takes past the control script's 60 s
# default before the listener opens (measured on the appliance), so the
# install waits up to 300 s unless the caller names a bound.
QWEN_YACY_START_TIMEOUT=${QWEN_YACY_START_TIMEOUT:-300} \
    QWEN_YACY_INSTALL_DIRECTORY=$install_directory "$control_script" start
server_started=1
cleanup_server() {
    if [ "$server_started" -eq 1 ]; then
        QWEN_YACY_INSTALL_DIRECTORY=$install_directory "$control_script" stop || true
        server_started=0
    fi
    cleanup_build_log
}
trap cleanup_server EXIT

# Loopback listener alone: ss reports every listener on 8090, and a public
# bind is a design violation this script refuses to certify rather than warn
# about.
listener_lines=$(ss -ltn 'sport = :8090')
listener_addresses=$(printf '%s\n' "$listener_lines" | awk 'NR>1 {print $4}')
if [ -z "$listener_addresses" ]; then
    printf 'no listener found on port 8090\n' >&2
    exit 1
fi
for listener_address in $listener_addresses; do
    case $listener_address in
        127.0.0.1:8090 | \[::1\]:8090 | \[::ffff:127.0.0.1\]:8090) ;;
        *)
            printf 'refusing non-loopback listener: %s\n' "$listener_address" >&2
            exit 1
            ;;
    esac
done

QWEN_YACY_INSTALL_DIRECTORY=$install_directory "$control_script" stop
server_started=0

printf 'install verified: tag %s commit %s\n' "$pinned_tag" "$pinned_commit"
printf 'yacy.conf sha256: %s\n' "$config_sha256"
printf 'build log sha256: %s\n' "$build_log_sha256"
printf 'This run does not write %s/searxng-provenance.md.\n' \
    "$script_directory/../evidence"
printf 'Copy the values above into its "-" placeholders.\n'
