#!/bin/sh
set -eu

# Verify the qwen-coder principal holds the locked shape the coding lane
# assumes: nologin shell, locked password, no supplementary groups, a
# mode-0700 home with the mirror and worktree roots, no credential state,
# and no write path into the authoritative checkout. The check reads the
# account databases and the filesystem alone, so it runs without root; a
# missing account is a plain rejection naming the setup script.

principal=qwen-coder
principal_home=/var/lib/qwen-coder
repository_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

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

entry=$(getent passwd "$principal" || :)
[ -n "$entry" ] || {
    printf 'principal %s is absent; run sudo sh scripts/setup-coding-principal.sh\n' \
        "$principal" >&2
    exit 1
}

shell=$(printf '%s' "$entry" | cut -d: -f7)
case $shell in
    */nologin) check shell_nologin pass ;;
    *) check shell_nologin fail "$shell" ;;
esac

home_field=$(printf '%s' "$entry" | cut -d: -f6)
[ "$home_field" = "$principal_home" ] && check home_path pass ||
    check home_path fail "$home_field"

password_state=$(passwd -S "$principal" 2>/dev/null | awk '{ print $2 }' || :)
case $password_state in
    L | LK) check password_locked pass ;;
    '') check password_locked pass ;;
    *) check password_locked fail "$password_state" ;;
esac

supplementary=$(id -Gn "$principal" | tr ' ' '\n' |
    grep -v "^$principal$" || :)
[ -z "$supplementary" ] && check no_supplementary_groups pass ||
    check no_supplementary_groups fail "$supplementary"

if [ -d "$principal_home" ]; then
    home_stat=$(stat -c '%a %U' "$principal_home")
    [ "$home_stat" = "700 $principal" ] && check home_mode_owner pass ||
        check home_mode_owner fail "$home_stat"
    # The 0700 home blocks traversal for an unprivileged caller, so the
    # interior checks read through a cached sudo where one is available and
    # report not-run otherwise rather than misreading denial as absence.
    for subdirectory in repos worktrees tmp; do
        if [ -d "$principal_home/$subdirectory" ] ||
            sudo -n test -d "$principal_home/$subdirectory" 2>/dev/null; then
            check "home_${subdirectory}_exists" pass
        elif sudo -n true 2>/dev/null; then
            check "home_${subdirectory}_exists" fail absent
        else
            printf 'check=home_%s_exists outcome=not-run detail=home is 0700 and sudo is uncached\n' \
                "$subdirectory"
        fi
    done
else
    check home_mode_owner fail absent
fi

# An unreadable home would make [ ! -e ] read denial as absence, so the
# credential checks require a positive read of the home interior.
for credential_path in .ssh .config/gh .config/gcloud .aws .mozilla \
    .config/chromium; do
    check_name="no_$(printf '%s' "$credential_path" | tr /. __)"
    if sudo -n true 2>/dev/null; then
        sudo -n test -e "$principal_home/$credential_path" 2>/dev/null &&
            check "$check_name" fail present ||
            check "$check_name" pass
    elif [ -r "$principal_home" ] && [ -x "$principal_home" ]; then
        [ ! -e "$principal_home/$credential_path" ] &&
            check "$check_name" pass || check "$check_name" fail present
    else
        printf 'check=%s outcome=not-run detail=home is 0700 and sudo is uncached\n' \
            "$check_name"
    fi
done

# The principal must hold no write path into the authoritative checkout:
# neither the working tree nor .git is group- or world-writable, and
# qwen-coder owns neither.
repo_write=$(find "$repository_root/.git" "$repository_root/scripts" \
    -maxdepth 0 \( -user "$principal" -o -perm -o+w \) -print || :)
[ -z "$repo_write" ] && check no_repo_write_path pass ||
    check no_repo_write_path fail "$repo_write"

if [ "$checks_failed" -eq 0 ]; then
    printf 'coding_principal=accepted checks=%s\n' "$checks_total"
    exit 0
fi
printf 'coding_principal=rejected failed=%s of=%s\n' \
    "$checks_failed" "$checks_total" >&2
exit 1
