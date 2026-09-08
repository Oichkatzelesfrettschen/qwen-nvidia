#!/bin/sh
set -eu

usage() {
    printf 'usage: %s PID START_TIME SERVER_LOG\n' "$0" >&2
    exit 2
}

[ "$#" -eq 3 ] || usage
server_pid=$1
server_start_time=$2
server_log=$3
escalation_ms=${QWEN_DRAIN_ESCALATION_MS:-10000}

case $server_pid:$server_start_time:$escalation_ms in
    *[!0-9:]* | :* | *: | *::* ) usage ;;
esac

process_identity_matches() {
    [ -r "/proc/$server_pid/stat" ] || return 1
    live_start_time=$(sed 's/^.*) //' "/proc/$server_pid/stat" 2>/dev/null | awk '{ print $20 }')
    [ "$live_start_time" = "$server_start_time" ]
}

process_has_terminated() {
    process_identity_matches || return 0
    process_state=$(sed 's/^.*) //' "/proc/$server_pid/stat" 2>/dev/null | awk '{ print $1 }')
    [ "$process_state" = Z ] || [ "$process_state" = X ]
}

owned_processes=
capture_tree() {
    capture_parent=$1
    for task_children in "/proc/$capture_parent"/task/*/children; do
        [ -r "$task_children" ] || continue
        for capture_child in $(cat "$task_children"); do
            case " $owned_processes " in *" $capture_child:"*) continue ;; esac
            [ -r "/proc/$capture_child/stat" ] || continue
            capture_start=$(sed 's/^.*) //' "/proc/$capture_child/stat" 2>/dev/null | awk '{ print $20 }')
            [ -n "$capture_start" ] || continue
            owned_processes="$owned_processes $capture_child:$capture_start"
            capture_tree "$capture_child"
        done
    done
}

owned_process_alive() {
    owned_identity=$1
    owned_pid=${owned_identity%%:*}
    owned_start=${owned_identity#*:}
    [ -r "/proc/$owned_pid/stat" ] || return 1
    [ "$(sed 's/^.*) //' "/proc/$owned_pid/stat" 2>/dev/null | awk '{ print $20 }')" = "$owned_start" ] || return 1
    owned_state=$(sed 's/^.*) //' "/proc/$owned_pid/stat" 2>/dev/null | awk '{ print $1 }')
    [ "$owned_state" != Z ] && [ "$owned_state" != X ]
}

if ! process_identity_matches; then
    printf 'server_retirement=refused reason=identity_mismatch pid=%s\n' "$server_pid" >&2
    exit 1
fi
server_session_id=$(sed 's/^.*) //' "/proc/$server_pid/stat" | awk '{ print $4 }')
if [ "$server_session_id" != "$server_pid" ]; then
    printf 'server_retirement=refused reason=session_boundary_mismatch pid=%s session_id=%s\n' \
        "$server_pid" "$server_session_id" >&2
    exit 1
fi

serving_session_members() {
    for member_stat in /proc/[0-9]*/stat; do
        [ -r "$member_stat" ] || continue
        member_fields=$(sed 's/^.*) //' "$member_stat" 2>/dev/null) || continue
        [ "$(printf '%s\n' "$member_fields" | awk '{ print $4 }')" = "$server_session_id" ] || continue
        member_pid=${member_stat#/proc/}
        member_pid=${member_pid%/stat}
        member_start=$(printf '%s\n' "$member_fields" | awk '{ print $20 }')
        member_state=$(printf '%s\n' "$member_fields" | awk '{ print $1 }')
        [ "$member_state" = Z ] || [ "$member_state" = X ] ||
            printf '%s:%s\n' "$member_pid" "$member_start"
    done
}

log_size=0
log_identity=absent
router_generations=
router_inventory=
if [ -f "$server_log" ]; then
    log_size=$(stat -c '%s' "$server_log")
    log_identity=$(stat -c '%d:%i' "$server_log")
    if [ "${QWEN_ROUTER:-0}" = 1 ]; then
        router_inventory=$(sed -n '/router_child_inventory complete=yes active=[0-9][0-9]*$/p' "$server_log" | tail -n 1)
        router_generations=$(awk '
            /router_child_generation / {
                key = ""; record = ""
                for (field = 1; field <= NF; field++) {
                    if ($field ~ /^(model|generation_port|pid|start_time)=/) {
                        record = record (record ? " " : "") $field
                    }
                    if ($field ~ /^model=/) key = $field
                    if ($field ~ /^generation_port=/) key = key " " $field
                }
                live[key] = record
            }
            /router_child_retirement / {
                key = ""
                for (field = 1; field <= NF; field++) {
                    if ($field ~ /^model=/) key = $field
                    if ($field ~ /^generation_port=/) key = key " " $field
                }
                delete live[key]
            }
            END { for (key in live) print live[key] }
        ' "$server_log")
    fi
fi
capture_tree "$server_pid"


kill -TERM "$server_pid" 2>/dev/null || true
waited_ms=0
while ! process_has_terminated && [ "$waited_ms" -lt "$escalation_ms" ]; do
    sleep 0.05
    waited_ms=$((waited_ms + 50))
done

survivors=
process_has_terminated || survivors="$survivors $server_pid:$server_start_time"
for owned_identity in $owned_processes; do
    owned_process_alive "$owned_identity" && survivors="$survivors $owned_identity"
done
for owned_identity in $(serving_session_members); do
    case " $survivors " in *" $owned_identity "*) ;; *) survivors="$survivors $owned_identity" ;; esac
done
if [ -n "$survivors" ]; then
    for owned_identity in $survivors; do
        owned_pid=${owned_identity%%:*}
        if [ "$owned_pid" = "$server_pid" ]; then
            process_identity_matches && kill -KILL "$owned_pid" 2>/dev/null || true
        else
            owned_process_alive "$owned_identity" && kill -KILL "$owned_pid" 2>/dev/null || true
        fi
    done
    waited_ms=0
    while [ "$waited_ms" -lt "$escalation_ms" ]; do
        remaining=0
        for owned_identity in $survivors; do
            owned_pid=${owned_identity%%:*}
            if [ "$owned_pid" = "$server_pid" ]; then
                process_has_terminated || remaining=1
            else
                owned_process_alive "$owned_identity" && remaining=1
            fi
        done
        [ "$remaining" -eq 1 ] || break
        sleep 0.05
        waited_ms=$((waited_ms + 50))
    done
    printf 'server_retirement=failed reason=bounded_escalation survivors=%s\n' \
        "$(printf '%s' "$survivors" | sed 's/^ *//; s/ /,/g')" >&2
    exit 1
fi

printf 'server_retirement=completed pid=%s\n' "$server_pid"
if [ -f "$server_log" ] && [ "$(stat -c '%d:%i' "$server_log")" = "$log_identity" ]; then
    retirement_log=$(tail -c "+$((log_size + 1))" "$server_log")
    teardown_observations=$(printf '%s\n' "$retirement_log" |
        sed -n 's/.*teardown: held=\(yes\|no\).*/\1/p')
    teardown_yes=$(printf '%s\n' "$teardown_observations" | awk '$0 == "yes" { count++ } END { print count + 0 }')
    teardown_no=$(printf '%s\n' "$teardown_observations" | awk '$0 == "no" { count++ } END { print count + 0 }')
    router_proof=0
    if [ "${QWEN_ROUTER:-0}" = 1 ]; then
        router_proof=0
        expected_active=$(printf '%s\n' "$router_inventory" | sed -n 's/.* active=\([0-9][0-9]*\)$/\1/p')
        generation_count=$(printf '%s\n' "$router_generations" | awk 'NF { count++ } END { print count + 0 }')
        if [ -n "$expected_active" ] && [ "$expected_active" -gt 0 ] &&
           [ "$generation_count" -eq "$expected_active" ]; then
            router_proof=1
        fi
        while IFS= read -r generation; do
            [ -n "$generation" ] || continue
            model=$(printf '%s\n' "$generation" | tr ' ' '\n' | sed -n 's/^model=//p')
            port=$(printf '%s\n' "$generation" | tr ' ' '\n' | sed -n 's/^generation_port=//p')
            pid=$(printf '%s\n' "$generation" | tr ' ' '\n' | sed -n 's/^pid=//p')
            start=$(printf '%s\n' "$generation" | tr ' ' '\n' | sed -n 's/^start_time=//p')
            matching_retirements=$(printf '%s\n' "$retirement_log" | awk \
                -v model="$model" -v port="$port" -v pid="$pid" -v start="$start" '
                /router_child_retirement / {
                    delete value
                    for (field = 1; field <= NF; field++) {
                        split($field, pair, "="); value[pair[1]] = pair[2]
                    }
                    if (value["model"] == model && value["generation_port"] == port &&
                        value["pid"] == pid && value["start_time"] == start) {
                        count++
                        if (value["exited"] != "yes" || value["exit_status"] != "0" ||
                            value["teardown_exclusion"] != "orderly") bad++
                    }
                }
                END { print count + 0 ":" bad + 0 }')
            if [ "$matching_retirements" != 1:0 ]; then
                router_proof=0
            fi
            if [ -r "/proc/$pid/stat" ] &&
               [ "$(sed 's/^.*) //' "/proc/$pid/stat" 2>/dev/null | awk '{ print $20 }')" = "$start" ]; then
                router_proof=0
            fi
        done <<EOF
$router_generations
EOF
    fi
    if { [ "${QWEN_ROUTER:-0}" = 1 ] && [ "$router_proof" -eq 1 ]; } ||
       { [ "${QWEN_ROUTER:-0}" != 1 ] && [ -z "$owned_processes" ] &&
         [ "$teardown_no" -eq 0 ] && [ "$teardown_yes" -eq 1 ]; }; then
        printf 'teardown: held=yes\n'
    elif [ "$teardown_no" -gt 0 ]; then
        printf 'teardown: held=no\n'
    fi
fi
