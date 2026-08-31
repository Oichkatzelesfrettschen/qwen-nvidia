#!/bin/sh
set -eu

# Constrain the qwen-coder principal's network reach to loopback. The
# nftables output hook matches on the socket's owning uid, so the rule
# binds the account rather than a process tree a double fork could leave:
# traffic from qwen-coder to 127.0.0.0/8 and ::1 passes, and everything
# else from that uid is dropped, which is the `loopback access only to
# llama-server` containment the coding profiles state. The table is its
# own namespace, so ufw's rules and the desktop's traffic stay untouched,
# and `remove` deletes exactly this table.
#
# Root privilege comes from the caller (sudo sh scripts/setup-coding-egress.sh).

usage() {
    printf 'usage: %s apply|remove|status\n' "$0" >&2
    exit 2
}
[ "$#" -eq 1 ] || usage

table=qwen-coder-egress

case $1 in
apply)
    [ "$(id -u)" -eq 0 ] || {
        printf 'root is required; run under sudo\n' >&2
        exit 1
    }
    nft -f - <<'EOF'
table inet qwen-coder-egress
delete table inet qwen-coder-egress
table inet qwen-coder-egress {
    chain output {
        type filter hook output priority filter; policy accept;
        meta skuid "qwen-coder" ip daddr 127.0.0.0/8 accept
        meta skuid "qwen-coder" ip6 daddr ::1 accept
        meta skuid "qwen-coder" counter drop
    }
}
EOF
    printf 'coding_egress=applied table=%s\n' "$table"
    ;;
remove)
    [ "$(id -u)" -eq 0 ] || {
        printf 'root is required; run under sudo\n' >&2
        exit 1
    }
    nft delete table inet "$table" 2>/dev/null || :
    printf 'coding_egress=removed table=%s\n' "$table"
    ;;
status)
    if nft list table inet "$table" >/dev/null 2>&1; then
        printf 'coding_egress=applied table=%s\n' "$table"
    else
        printf 'coding_egress=absent table=%s\n' "$table"
        exit 1
    fi
    ;;
*)
    usage
    ;;
esac
