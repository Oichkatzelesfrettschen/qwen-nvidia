#!/bin/sh
set -eu

# Verify an installed Qwen Code runtime against the registry pin: the
# candidate symlink resolves inside the install root to the pinned version
# directory, the executable answers --version with the pinned version, and
# the checked-in settings disable the runtime's own auto-update so the
# repository keeps the upgrade decision.

usage() {
    printf 'usage: %s [INSTALL_ROOT]\n' "$0" >&2
    exit 2
}

[ "$#" -le 1 ] || usage
install_root=${1:-"${HOME:?}/tools/qwen-code"}

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
registry=$script_directory/coding-runtimes.tsv
settings_template=$script_directory/qwen-code-settings.json

runtime_row=$(awk -F'\t' '!/^#/ && $1 == "qwen-code"' "$registry")
[ -n "$runtime_row" ] || {
    printf 'coding-runtimes.tsv holds no qwen-code row\n' >&2
    exit 1
}
pinned_version=$(printf '%s' "$runtime_row" | cut -f2)
version_directory=$(printf '%s' "$runtime_row" | cut -f8)
executable_relative=$(printf '%s' "$runtime_row" | cut -f9)

candidate_link=$install_root/candidate
[ -L "$candidate_link" ] || {
    printf 'verify=rejected reason=candidate_symlink_absent path=%s\n' \
        "$candidate_link" >&2
    exit 1
}
candidate_target=$(readlink "$candidate_link")
[ "$candidate_target" = "$version_directory" ] || {
    printf 'verify=rejected reason=candidate_points_elsewhere target=%s pinned=%s\n' \
        "$candidate_target" "$version_directory" >&2
    exit 1
}

qwen_executable=$install_root/candidate/$executable_relative
[ -x "$qwen_executable" ] || {
    printf 'verify=rejected reason=executable_absent path=%s\n' \
        "$qwen_executable" >&2
    exit 1
}
reported_version=$("$qwen_executable" --version 2>&1 | tr -d '[:space:]')
case $reported_version in
    *"$pinned_version"*) : ;;
    *)
        printf 'verify=rejected reason=version_mismatch reported=%s pinned=%s\n' \
            "$reported_version" "$pinned_version" >&2
        exit 1
        ;;
esac

python3 - "$settings_template" <<'EOF' || exit 1
import json, sys
settings = json.load(open(sys.argv[1]))
if settings.get("general", {}).get("enableAutoUpdate") is not False:
    print("verify=rejected reason=auto_update_enabled", file=sys.stderr)
    raise SystemExit(1)
for provider in settings.get("modelProviders", {}).values():
    for entry in provider:
        url = entry.get("baseUrl", "")
        if not (url.startswith("http://127.0.0.1")
                or url.startswith("http://localhost")
                or url.startswith("http://[::1]")):
            print("verify=rejected reason=non_loopback_base_url url=%s" % url,
                  file=sys.stderr)
            raise SystemExit(1)
        if "apiKey" in entry or "api_key" in entry:
            print("verify=rejected reason=credential_in_settings",
                  file=sys.stderr)
            raise SystemExit(1)
EOF

printf 'verify=accepted version=%s candidate=%s auto_update=disabled\n' \
    "$pinned_version" "$candidate_link"
