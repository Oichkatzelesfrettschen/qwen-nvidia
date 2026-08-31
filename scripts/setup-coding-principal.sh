#!/bin/sh
set -eu

# Create the locked system identity the coding lane runs under. qwen-coder
# is a system account with a nologin shell, an empty supplementary group
# set, and a private home under /var/lib/qwen-coder holding the task mirror
# and worktree roots; it carries no SSH keys, no GitHub or cloud
# credentials, and no browser state because nothing ever writes them there.
# The account holds no write path into the authoritative checkout: a coding
# job operates in an ephemeral worktree of a separate bare mirror, and the
# service exports a patch the human applies. The script is idempotent, so a
# rerun converges the account and directory state rather than failing.
#
# Root privilege comes from the caller (sudo sh scripts/setup-coding-principal.sh);
# the script itself never invokes sudo.

usage() {
    printf 'usage: %s\n' "$0" >&2
    exit 2
}
[ "$#" -eq 0 ] || usage

[ "$(id -u)" -eq 0 ] || {
    printf 'root is required; run under sudo\n' >&2
    exit 1
}

principal=qwen-coder
principal_home=/var/lib/qwen-coder

if ! id "$principal" >/dev/null 2>&1; then
    useradd --system --user-group \
        --home-dir "$principal_home" --create-home \
        --shell /usr/bin/nologin "$principal"
fi

# usermod converges pre-existing accounts onto the locked shape.
usermod --shell /usr/bin/nologin --groups '' "$principal"
passwd -l "$principal" >/dev/null

mkdir -p "$principal_home/repos" "$principal_home/worktrees" \
    "$principal_home/tmp"
chown "$principal:$principal" "$principal_home" \
    "$principal_home/repos" "$principal_home/worktrees" \
    "$principal_home/tmp"
chmod 700 "$principal_home" "$principal_home/repos" \
    "$principal_home/worktrees" "$principal_home/tmp"

supplementary=$(id -Gn "$principal" | tr ' ' '\n' |
    grep -v "^$principal$" || :)
[ -z "$supplementary" ] || {
    printf 'supplementary groups persist: %s\n' "$supplementary" >&2
    exit 1
}

printf 'coding_principal=ready user=%s home=%s shell=%s groups=%s\n' \
    "$principal" "$principal_home" "$(getent passwd $principal | cut -d: -f7)" \
    "$(id -Gn "$principal" | tr ' ' ',')"
