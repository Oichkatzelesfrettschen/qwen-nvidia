#!/bin/sh
# gpu-ownership: delegated to the serving chain.
# Put named registry rows against the six contract questions of the DiscoBSD
# invariant map (docs/research/invariant-map.md), one bounded source package
# per question, and grade what comes back on three mechanical checks that a
# reader can rerun: whether the answer names the enforcing symbol, whether it
# makes the entry's discriminating distinction, and whether every identifier
# it names resolves in the package it was given.
#
# The third check is the one the broad screen could not make. A summary that
# invents `usb_usb_usb` or `sys/configure_desktop.h` is wrong in a way no
# stopping, token count or wall time reveals, and graft ingests it the same
# as a true one. Grading it needs the package, not the repository: an
# identifier the model could not have read is an invention whether or not it
# exists somewhere else in the tree.
#
# A pass on all three is not a true answer. It states that the answer names
# the right code, draws the distinction the entry turns on, and invents
# nothing. Whether the prose around that is correct stays a reading.
#
#   usage: admit-contract-questions.sh OUTPUT_DIRECTORY
#   QWEN_CONTRACT_IDS       space-separated registry rows, default the two
#                           screen finalists and the incumbent control
#   QWEN_CONTRACT_SOURCE    the DiscoBSD tree, default $HOME/Github/discobsd-2040-unofficial
#   QWEN_CONTRACT_MAX_TOKENS  reply cap, default 1024
#   QWEN_CONTRACT_TIMEOUT   seconds per request, default 120
set -eu
: "${PYTHON:?Select the intended Python interpreter}"
Q=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
OUT=${1:?usage: admit-contract-questions.sh OUTPUT_DIRECTORY}
D=${QWEN_CONTRACT_SOURCE:-"${HOME:?}/Github/discobsd-2040-unofficial"}
IDS=${QWEN_CONTRACT_IDS:-"lfm25-350m-qad qwen3-4b-instruct-2507 qwen38-4b-distill"}
CAP=${QWEN_CONTRACT_MAX_TOKENS:-1024}
TIMEOUT=${QWEN_CONTRACT_TIMEOUT:-120}
PORT=${QWEN_SERVER_PORT:-8080}
STATE=${QWEN_WEBUI_STATE_DIRECTORY:-"${HOME:?}/qwen-webui-state"}
mkdir -p "$OUT"

# Each contract names its package files, the symbols an answer must name, and
# the two sides of its distinction: the term that marks the correct reading
# and the term that marks the conflation the entry warns about.
contract_files() {
    case $1 in
    swap-append) echo "sys/arch/rp2040/dev/flash_swap.c sys/arch/rp2040/dev/flash_swap.h" ;;
    exec-preflight) echo "sys/arch/rp2040/rp2040/exec_hsaout.c" ;;
    usb-ownership) echo "sys/arch/rp2040/dev/usb.c" ;;
    signal-frame) echo "sys/arch/rp2040/rp2040/sig_machdep.c" ;;
    heap-refusal) echo "sys/kern/kern_mman.c lib/libc/arm/sys/sbrk.c" ;;
    swapram-exclusion) echo "sys/kern/vm_swap.c" ;;
    esac
}
contract_question() {
    case $1 in
    swap-append) cat <<'EOF'
In this source, what does flash_swap_append itself check before it erases or
programs, and what must its callers guarantee that the function does not
check? Answer in plain prose. Name only identifiers that appear in the source
above.
EOF
;;
    exec-preflight) cat <<'EOF'
In this source, in what order does exec_hsaout_check verify the executable and
commit the process, and what happens to the process if the second expansion
disagrees with the header? Answer in plain prose. Name only identifiers that
appear in the source above.
EOF
;;
    usb-ownership) cat <<'EOF'
In this source, which bit decides whether the USB controller or the processor
owns a bulk endpoint buffer, and what does the driver do when a bulk OUT
buffer is found with that bit clear? Answer in plain prose. Name only
identifiers that appear in the source above.
EOF
;;
    signal-frame) cat <<'EOF'
In this source, how does sendsig place the signal frame relative to the frame
the exception return writes, and why does it clear a bit of the saved xPSR
before the handler runs? Answer in plain prose. Name only identifiers that
appear in the source above.
EOF
;;
    heap-refusal) cat <<'EOF'
In this source, how many separate conditions can make brk refuse to grow the
data segment, what is each one, and what does sbrk return and leave unchanged
when the kernel refuses? Answer in plain prose. Name only identifiers that
appear in the source above.
EOF
;;
    swapram-exclusion) cat <<'EOF'
In this source, when the RAM tier accepts a swapout, what does the process not
get that a flash swapout would have given it, and what does swapin still read
from outside the pool? Answer in plain prose. Name only identifiers that
appear in the source above.
EOF
;;
    esac
}
# Symbols an answer must name to have found the enforcing code at all.
contract_required() {
    case $1 in
    swap-append) echo "flash_swap_append" ;;
    exec-preflight) echo "exec_hsaout_check" ;;
    usb-ownership) echo "USB_BUF_CTRL_AVAIL" ;;
    signal-frame) echo "sendsig" ;;
    heap-refusal) echo "brk" ;;
    swapram-exclusion) echo "swapram" ;;
    esac
}
# The distinction the entry turns on: correct term, then the conflation.
contract_right() {
    case $1 in
    swap-append) echo "FLASH_PROG_BYTES" ;;
    exec-preflight) echo "EFTYPE" ;;
    usb-ownership) echo "AVAIL" ;;
    signal-frame) echo "STKALIGN|xPSR|psr" ;;
    heap-refusal) echo "p_saddr" ;;
    swapram-exclusion) echo "exec_text_restore" ;;
    esac
}
contract_wrong() {
    case $1 in
    swap-append) echo "ascending|in order|ordering.*validat|validat.*ordering" ;;
    exec-preflight) echo "retr|next format|another format is tried" ;;
    usb-ownership) echo "SRAM|DRAM" ;;
    signal-frame) echo "MPU|MMU" ;;
    heap-refusal) echo "single condition|one condition|only condition" ;;
    swapram-exclusion) echo "never touches flash|no flash|flash is never" ;;
    esac
}

CONTRACTS="swap-append exec-preflight usb-ownership signal-frame heap-refusal swapram-exclusion"

# One package per contract, assembled once so every row reads the same bytes.
for c in $CONTRACTS; do
    : >"$OUT/$c.package"
    for f in $(contract_files "$c"); do
        printf '===== %s =====\n' "$f" >>"$OUT/$c.package"
        cat "$D/$f" >>"$OUT/$c.package"
        printf '\n' >>"$OUT/$c.package"
    done
    # The identifier vocabulary the package licenses: every C identifier and
    # every path-like token in it. An answer naming anything else invented it.
    "$PYTHON" - "$OUT/$c.package" "$OUT/$c.vocab" <<'PY'
import re, sys
text = open(sys.argv[1], encoding='utf-8', errors='replace').read()
words = set(re.findall(r'[A-Za-z_][A-Za-z0-9_]{2,}', text))
words |= set(re.findall(r'[A-Za-z0-9_./-]+\.[ch]\b', text))
open(sys.argv[2], 'w').write('\n'.join(sorted(words)))
PY
done

printf 'model\tcontract\twall_ms\tfinish\tnames_enforcer\tdraws_distinction\tconflates\tinvented\tinvented_list\toutcome\n' >"$OUT/contracts.tsv"
trap '"$Q/scripts/qwen-teardown.sh" >/dev/null 2>&1 || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for id in $IDS; do
    row=$("$Q/scripts/model-registry.sh" id "$id")
    file=$(printf '%s\n' "$row" | sed -n 's/^model_file=//p')
    "$Q/scripts/qwen-teardown.sh" >/dev/null 2>&1 || true
    if ! QWEN_REQUIRE_API_KEY=1 QWEN_CHAT_TOOLS=on QWEN_CHAT_REASONING_BUDGET=512 QWEN_CONTEXT_SIZE=16384 \
        QWEN_MODEL_PATH=$HOME/models/$file "$Q/scripts/qwen-launch.sh" default \
        >"$OUT/$id.launch" 2>&1; then
        for c in $CONTRACTS; do
            printf '%s\t%s\t-\t-\t-\t-\t-\t-\t-\tlaunch_failed\n' "$id" "$c" >>"$OUT/contracts.tsv"
        done
        continue
    fi
    header=$(mktemp "${TMPDIR:-/tmp}/contract.XXXXXX")
    printf 'header = "Authorization: Bearer %s"\n' "$(tr -d '\n' <"$STATE/api.key")" >"$header"
    for c in $CONTRACTS; do
        answer=$OUT/$id.$c.json
        jq -n --rawfile pkg "$OUT/$c.package" --arg q "$(contract_question "$c")" \
            --argjson cap "$CAP" \
            '{model:"qwen-nvidia",temperature:0,max_tokens:$cap,messages:[{role:"user",content:($pkg+"\n\n"+$q)}]}' \
            >"$OUT/$id.$c.request.json"
        s=$("$PYTHON" -c 'import time; print(time.monotonic_ns()//1000000)')
        status=$(curl --user-agent 'Mozilla/5.0' --silent --max-time "$TIMEOUT" --config "$header" --output "$answer" \
            --write-out '%{http_code}' -H 'Content-Type: application/json' \
            --data-binary "@$OUT/$id.$c.request.json" \
            "http://127.0.0.1:$PORT/v1/chat/completions") || status=transport
        w=$(( $("$PYTHON" -c 'import time; print(time.monotonic_ns()//1000000)') - s ))
        if [ "$status" != 200 ] || ! jq -e '.choices[0].message' "$answer" >/dev/null 2>&1; then
            printf '%s\t%s\t%s\t-\t-\t-\t-\t-\t-\thttp_%s\n' "$id" "$c" "$w" "$status" >>"$OUT/contracts.tsv"
            continue
        fi
        jq -j '.choices[0].message.content // ""' "$answer" >"$OUT/$id.$c.txt"
        finish=$(jq -r '.choices[0].finish_reason // "none"' "$answer")
        body=$OUT/$id.$c.txt
        names=no; grep -E -q "$(contract_required "$c")" "$body" && names=yes
        draws=no; grep -E -q "$(contract_right "$c")" "$body" && draws=yes
        conf=no;  grep -E -qi "$(contract_wrong "$c")" "$body" && conf=yes
        # Identifiers the answer names that the package never contained.
        "$PYTHON" - "$body" "$OUT/$c.vocab" >"$OUT/$id.$c.invented" <<'PY'
import re, sys
body = open(sys.argv[1], encoding='utf-8', errors='replace').read()
vocab = set(open(sys.argv[2], encoding='utf-8').read().split())
# A claimed identifier: snake_case, CamelCase with an underscore, an ALL_CAPS
# macro, or a path ending in .c or .h. Ordinary English words carry none of
# those shapes, so prose is not mistaken for an invented symbol.
claims = set()
claims |= set(re.findall(r'\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\b', body))
claims |= set(re.findall(r'\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+\b', body))
claims |= set(re.findall(r'\b[A-Za-z0-9_./-]+\.[ch]\b', body))
print('\n'.join(sorted(c for c in claims if c not in vocab)))
PY
        inv=$(grep -c . "$OUT/$id.$c.invented" || true)
        invlist=$(tr '\n' ',' <"$OUT/$id.$c.invented" | sed 's/,$//')
        [ -n "$invlist" ] || invlist=-
        if [ "$names" = yes ] && [ "$draws" = yes ] && [ "$conf" = no ] && [ "$inv" -eq 0 ]; then
            outcome=pass
        else
            outcome=fail
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$id" "$c" "$w" "$finish" "$names" "$draws" "$conf" "$inv" "$invlist" "$outcome" \
            >>"$OUT/contracts.tsv"
    done
    rm -f "$header"
done
printf 'contracts_done\n' >>"$OUT/contracts.tsv"
