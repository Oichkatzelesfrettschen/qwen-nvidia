#!/bin/sh
set -eu

# Installs SearXNG natively on the laptop from a pinned upstream commit and
# proves the loopback instance the checked-in settings file describes. The
# native installer is utils/searxng.sh from the pinned tree; its own "install
# all" is interactive (wait_key, ask_yn) and composes three stages this
# repository refuses: searxng.install.valkey.db (no Valkey, per repository
# doctrine), searxng.install.uwsgi (installs a systemd unit, and this
# repository starts and stops a service through its own launch and teardown
# scripts alone), and searxng.install.http.site (nginx/apache in front of a
# loopback, one-human instance). This script runs the granular subcommands
# "install all" itself composes -- packages, user, searxng-src, pyenv -- and
# skips those three plus "install settings" (which reruns install_template
# interactively), installing the checked-in settings file in its place so a
# generated secret_key never reaches Git.

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

if [ "$#" -ne 1 ]; then
    printf 'usage: %s INSTALL_ROOT\n' "$0" >&2
    printf '  INSTALL_ROOT: directory to hold the pinned SearXNG source tree\n' >&2
    exit 2
fi
install_root=$1

# Read from `git ls-remote https://github.com/searxng/searxng.git HEAD` and
# cross-checked against the GitHub API on 2026-08-28. searxng/searxng carries
# no tags at that date (`git ls-remote --tags` is empty), so the pin is the
# master commit read that day rather than a release tag.
pinned_commit=a30b2d47492ab46ae82ce25ee62a31626565cf67
pin_branch=qwen-search-pin
upstream_url=https://github.com/searxng/searxng.git

service_user=searxng
service_group=searxng
settings_path=/etc/searxng/settings.yml
bind_address=127.0.0.1
server_port=8888

settings_source=$script_directory/searxng-settings.yml
if [ ! -f "$settings_source" ]; then
    printf 'checked-in settings file missing: %s\n' "$settings_source" >&2
    exit 2
fi

evidence_directory=$script_directory/../evidence
provenance_record=$evidence_directory/searxng-provenance.md

# Every install stage below runs under sudo, and this repository's rule is
# that a human runs `sudo -v` once and the password never reaches a command
# line, a script argument, or a log. A cached credential is required before
# this script does anything, and its absence is a plain instruction rather
# than a prompt this script issues on the human's behalf.
if ! sudo -n true 2>/dev/null; then
    printf 'sudo credential not cached: run "sudo -v" first, then re-run %s\n' \
        "$0" >&2
    exit 2
fi

# utils/searxng.sh's searxng-src stage clones this tree as the service user
# (git_clone runs under `sudo -u searxng`) and its line 424 check refuses a
# source the user cannot read, so the install root must sit under directories
# that user can traverse; a home directory at mode 0750 is refused here with
# the cause named rather than four stages later by the upstream installer.
install_parent=$(dirname "$install_root")
if id "$service_user" >/dev/null 2>&1 &&
        ! sudo -n -u "$service_user" test -x "$install_parent" 2>/dev/null; then
    printf 'user %s cannot traverse %s; choose an install root the service user can read, such as /opt/searxng-qwen-apu\n' \
        "$service_user" "$install_parent" >&2
    exit 2
fi
# utils/brand.sh reads server.* settings through a bare `python`, so the
# stages fail with empty SEARXNG_PORT when only python3 is on PATH.
if ! command -v python >/dev/null 2>&1; then
    printf 'python not found on PATH (utils/brand.sh calls it); install python-is-python3\n' >&2
    exit 2
fi

printf 'cloning pinned SearXNG commit %s into %s\n' "$pinned_commit" "$install_root"
if [ -d "$install_root/.git" ]; then
    git -C "$install_root" fetch origin
else
    git clone "$upstream_url" "$install_root"
fi
git -C "$install_root" checkout -B "$pin_branch" "$pinned_commit"
# brand.sh derives GIT_URL from this branch's own remote-tracking config
# (`git config branch.<name>.remote`), and utils/searxng.sh's install stages
# read GIT_URL back into the installed clone's origin. A branch created by
# `checkout -B <name> <sha>` alone carries no tracking config, so the
# installed clone would point at an empty URL; the explicit
# --set-upstream-to gives it one without changing which commit is installed.
git -C "$install_root" branch --set-upstream-to=origin/master "$pin_branch" \
    2>/dev/null || true

clone_status=$(git -C "$install_root" status --porcelain)
if [ -n "$clone_status" ]; then
    printf 'pinned clone is not clean:\n%s\n' "$clone_status" >&2
    exit 1
fi
clone_head=$(git -C "$install_root" rev-parse HEAD)
if [ "$clone_head" != "$pinned_commit" ]; then
    printf 'HEAD %s does not match pin %s\n' "$clone_head" "$pinned_commit" >&2
    exit 1
fi

installer=$install_root/utils/searxng.sh
if [ ! -x "$installer" ]; then
    printf 'installer script missing or not executable: %s\n' "$installer" >&2
    exit 1
fi

installer_log=$(mktemp)
cleanup_temp_files() {
    rm -f "$installer_log"
}
trap cleanup_temp_files EXIT

run_install_stage() {
    stage=$1
    printf 'running: %s install %s\n' "$installer" "$stage"
    # The redirect runs in this script's own shell, at this user's
    # privilege, before sudo starts the installer; only the installer's
    # write to /etc/searxng and its own user/package operations need root.
    # searxng.install.pyenv calls wait_key with no argument, which reads one
    # key from stdin with no timeout unless utils/lib.sh's FORCE_TIMEOUT is
    # set. `sudo env FORCE_TIMEOUT=1 installer` sets it inside the root
    # process env itself rather than relying on sudo to forward it from this
    # shell, which a default sudoers env_reset policy would otherwise strip;
    # </dev/null backs the read with an immediate EOF too, so a read that
    # somehow ignored FORCE_TIMEOUT would fail closed rather than block this
    # script on a terminal no automated run has.
    # shellcheck disable=SC2024
    if ! sudo -H env FORCE_TIMEOUT=1 "$installer" install "$stage" \
            </dev/null >>"$installer_log" 2>&1; then
        printf 'install stage failed: %s -- see %s\n' "$stage" "$installer_log" >&2
        tail -n 40 "$installer_log" >&2
        exit 1
    fi
}

run_install_stage packages
run_install_stage user
run_install_stage searxng-src
run_install_stage pyenv

# The installer's own "install settings" stage runs install_template
# interactively against an existing file and then seds a fresh
# ultrasecretkey in place with openssl rand. This script installs the
# checked-in file whole instead, so the same qwen-named categories reach the
# laptop that a reviewer reads in Git, and performs the same substitution by
# hand so the placeholder never survives into the running instance.
printf 'installing settings file: %s\n' "$settings_path"
sudo -H mkdir -p "$(dirname "$settings_path")"
sudo -H install -m 0640 -o "$service_user" -g "$service_group" \
    "$settings_source" "$settings_path"
sudo -H sed -i -e "s/ultrasecretkey/$(openssl rand -hex 16)/g" "$settings_path"
if sudo -H grep -q ultrasecretkey "$settings_path"; then
    printf 'installed settings file still carries the placeholder secret_key\n' >&2
    exit 1
fi

settings_sha256=$(sha256sum "$settings_source" | cut -d' ' -f1)

control_script=$script_directory/searxng-control.sh
if [ ! -x "$control_script" ]; then
    printf 'control script missing or not executable: %s\n' "$control_script" >&2
    exit 1
fi

printf 'starting SearXNG through %s\n' "$control_script"
"$control_script" start
server_started=1
cleanup_server_and_temp_files() {
    if [ "$server_started" -eq 1 ]; then
        "$control_script" stop || true
        server_started=0
    fi
    cleanup_temp_files
}
trap cleanup_server_and_temp_files EXIT

# Loopback listener alone: ss reports every listener on the port, and a
# public bind is a design violation this script refuses to certify rather
# than warn about.
listener_lines=$(ss -ltn "sport = :$server_port")
listener_addresses=$(printf '%s\n' "$listener_lines" | awk 'NR>1 {print $4}')
if [ -z "$listener_addresses" ]; then
    printf 'no listener found on port %s\n' "$server_port" >&2
    exit 1
fi
for listener_address in $listener_addresses; do
    case $listener_address in
        127.0.0.1:"$server_port" | \[::1\]:"$server_port") ;;
        *)
            printf 'refusing non-loopback listener: %s\n' "$listener_address" >&2
            exit 1
            ;;
    esac
done

json_response=$(mktemp)
json_status=$(curl -s -o "$json_response" -w '%{http_code}' \
    "http://$bind_address:$server_port/search?q=test&format=json")
if [ "$json_status" != 200 ]; then
    printf 'GET /search?format=json returned %s\n' "$json_status" >&2
    cat "$json_response" >&2
    rm -f "$json_response"
    exit 1
fi
if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$json_response" \
        >/dev/null 2>&1; then
    printf 'GET /search?format=json did not return parseable JSON\n' >&2
    rm -f "$json_response"
    exit 1
fi
rm -f "$json_response"

config_response=$(mktemp)
config_status=$(curl -s -o "$config_response" -w '%{http_code}' \
    "http://$bind_address:$server_port/config")
if [ "$config_status" != 200 ]; then
    printf 'GET /config returned %s\n' "$config_status" >&2
    cat "$config_response" >&2
    rm -f "$config_response"
    exit 1
fi

# /config's "categories" key lists every category name any enabled engine
# carries, and each engine's own "categories" list is the membership this
# instance means by qwen-open, qwen-broad, qwen-academic, qwen-news, and
# qwen-yacy. The check reads membership rather than set equality: an engine
# also keeps its upstream category (general, web, science, news), so the
# category name alone would overcount an engine this instance never touched.
verified_engine_list=$(mktemp)
config_check_status=0
python3 - "$config_response" >"$verified_engine_list" <<'PYEOF' || config_check_status=$?
import json
import sys

with open(sys.argv[1]) as handle:
    config = json.load(handle)

qwen_categories = {
    "qwen-open": {"mwmbl", "wiby", "wikipedia", "wikidata"},
    "qwen-broad": {"google", "bing", "brave", "duckduckgo", "startpage", "qwant", "mojeek"},
    "qwen-academic": {"crossref", "arxiv", "pubmed", "wikipedia"},
    "qwen-news": {"reuters", "google news", "bing news", "brave.news"},
    "qwen-yacy": {"yacy"},
}

categories = set(config["categories"])
engines_by_name = {engine["name"]: engine for engine in config["engines"]}

missing_categories = sorted(c for c in qwen_categories if c not in categories)
if missing_categories:
    print("missing categories: %s" % missing_categories, file=sys.stderr)
    sys.exit(1)

failures = []
for category, expected_names in qwen_categories.items():
    for name in expected_names:
        engine = engines_by_name.get(name)
        if engine is None:
            failures.append("engine not present in /config: %s" % name)
            continue
        if category not in engine["categories"]:
            failures.append(
                "engine %s missing category %s (has %s)"
                % (name, category, engine["categories"])
            )
        if name != "yacy" and not engine["enabled"]:
            failures.append("engine %s is disabled" % name)
        print("%s\t%s\tenabled=%s" % (category, name, engine["enabled"]))

if failures:
    for failure in failures:
        print(failure, file=sys.stderr)
    sys.exit(1)
PYEOF
rm -f "$config_response"
if [ "$config_check_status" -ne 0 ]; then
    rm -f "$verified_engine_list"
    exit 1
fi

installer_log_sha256=$(sha256sum "$installer_log" | cut -d' ' -f1)

"$control_script" stop
server_started=0

verified_engine_table=$(cat "$verified_engine_list")
rm -f "$verified_engine_list"

printf 'install verified: commit %s, settings sha256 %s\n' \
    "$pinned_commit" "$settings_sha256"
printf 'installer log sha256: %s\n' "$installer_log_sha256"
printf 'verified engines:\n%s\n' "$verified_engine_table"
printf '\n'
printf 'This run does not write %s.\n' "$provenance_record"
printf 'Copy the values above into its "-" placeholders.\n'
