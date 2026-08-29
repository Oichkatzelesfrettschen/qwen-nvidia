#!/bin/sh
set -eu

# Explicit process control for the on-demand YaCy peer. No unit file,
# crontab entry, or login hook starts this service: start and stop run only
# through this script, so a reboot leaves the laptop with nothing listening
# on 8090. YaCy is on demand rather than resident -- SearXNG's yacy engine
# ships disabled: true in remote/searxng-settings.yml, so an ordinary search
# never depends on this process running.
#
# Every path is an environment override so remote/test-search-control.sh can
# drive this script against a fake python3 listener with no YaCy install.
# QWEN_YACY_LAUNCH_COMMAND and QWEN_YACY_STOP_COMMAND replace the real
# startYACY.sh/stopYACY.sh invocations whole for that purpose; the pid-file
# and listener proof below runs the same way in both cases, because a fake
# listener that does not close the port on stop should fail the check the
# same way a real one would.

if [ "$#" -ne 1 ]; then
    printf 'usage: %s start|stop|status\n' "$0" >&2
    exit 2
fi
action=$1

install_directory=${QWEN_YACY_INSTALL_DIRECTORY:-"${HOME:?}/opt/yacy"}
server_port=${QWEN_YACY_PORT:-8090}
bind_address=${QWEN_YACY_BIND_ADDRESS:-127.0.0.1}
start_timeout_seconds=${QWEN_YACY_START_TIMEOUT:-60}
stop_timeout_seconds=${QWEN_YACY_STOP_TIMEOUT:-30}

# startYACY.sh -l writes its own PID to yacy.pid in the directory it runs
# from before exec replaces it with the java process, and stopYACY.sh reads
# DATA/SETTINGS/yacy.conf from the same directory to find the admin API.
pid_file=${QWEN_YACY_PID_FILE:-"$install_directory/yacy.pid"}
log_file=${QWEN_YACY_LOG_FILE:-"$install_directory/yacy.log"}

# -f runs startYACY.sh's java invocation in the foreground: `exec` inside the
# script replaces the shell with the java process, so it receives SIGTERM
# directly at the PID this control script records and signals below, the
# same property searxng-control.sh relies on for its own launch command.
launch_command=${QWEN_YACY_LAUNCH_COMMAND:-"'$install_directory/startYACY.sh' -f"}
stop_command=${QWEN_YACY_STOP_COMMAND:-"'$install_directory/stopYACY.sh'"}

pid_is_alive() {
    [ -d "/proc/$1" ]
}

# The JVM opens a dual-stack socket and ss reports the IPv4 loopback in its
# mapped form, `[::ffff:127.0.0.1]:8090` (observed on the appliance under
# Java 21), so that spelling is the same loopback listener as the plain one.
listener_present() {
    ss -ltn "sport = :$server_port" 2>/dev/null |
        awk 'NR>1 {print $4}' |
        grep -qxF -e "$bind_address:$server_port" -e "[::1]:$server_port" \
            -e "[::ffff:$bind_address]:$server_port"
}

read_pid() {
    if [ -f "$pid_file" ]; then
        cat "$pid_file"
    fi
}

case $action in
    start)
        existing_pid=$(read_pid || true)
        if [ -n "${existing_pid:-}" ] && pid_is_alive "$existing_pid"; then
            printf 'already running: pid=%s\n' "$existing_pid" >&2
            exit 2
        fi
        rm -f "$pid_file"
        # The launched shell writes its own PID before exec replaces it with
        # the server process, so the PID in the file is the server's own for
        # the rest of its life rather than a forking wrapper's. The redirects
        # bind to this whole `sh -c` command rather than only to the exec
        # statement inside it, and </dev/null joins them, so no fd this
        # script inherited from its own caller -- in particular the write
        # end of a command substitution's pipe, when this script runs as
        # `$(yacy-control.sh start)` -- survives into the long-lived server
        # process; a server left holding that pipe open never lets it reach
        # EOF, so the caller's command substitution waits forever even after
        # this script itself has exited.
        sh -c "echo \$\$ > '$pid_file'; exec $launch_command" \
            >"$log_file" 2>&1 </dev/null &

        waited=0
        while [ "$waited" -lt "$start_timeout_seconds" ]; do
            started_pid=$(read_pid || true)
            if [ -n "${started_pid:-}" ] && pid_is_alive "$started_pid" &&
                listener_present; then
                printf 'started: pid=%s listener=%s:%s\n' \
                    "$started_pid" "$bind_address" "$server_port"
                exit 0
            fi
            sleep 1
            waited=$((waited + 1))
        done
        printf 'server did not reach a listening state within %ss\n' \
            "$start_timeout_seconds" >&2
        [ -f "$log_file" ] && tail -n 40 "$log_file" >&2
        exit 1
        ;;

    stop)
        current_pid=$(read_pid || true)
        if [ -z "${current_pid:-}" ] || ! pid_is_alive "$current_pid"; then
            rm -f "$pid_file"
            if listener_present; then
                printf 'no recorded process but %s:%s is still listening\n' \
                    "$bind_address" "$server_port" >&2
                exit 1
            fi
            printf 'not running\n'
            exit 0
        fi

        sh -c "$stop_command" >/dev/null 2>&1 || true
        waited=0
        while [ "$waited" -lt "$stop_timeout_seconds" ]; do
            if ! pid_is_alive "$current_pid" && ! listener_present; then
                rm -f "$pid_file"
                printf 'stopped: pid=%s\n' "$current_pid"
                exit 0
            fi
            sleep 1
            waited=$((waited + 1))
        done

        kill -TERM "$current_pid" 2>/dev/null || true
        sleep 2
        if pid_is_alive "$current_pid"; then
            kill -KILL "$current_pid" 2>/dev/null || true
            sleep 1
        fi
        if pid_is_alive "$current_pid" || listener_present; then
            printf 'residue after stop: pid_alive=%s listener=%s\n' \
                "$(pid_is_alive "$current_pid" && echo yes || echo no)" \
                "$(listener_present && echo yes || echo no)" >&2
            exit 1
        fi
        rm -f "$pid_file"
        printf 'stopped (forced): pid=%s\n' "$current_pid"
        ;;

    status)
        current_pid=$(read_pid || true)
        if [ -n "${current_pid:-}" ] && pid_is_alive "$current_pid" &&
            listener_present; then
            printf 'state=running pid=%s listener=%s:%s\n' \
                "$current_pid" "$bind_address" "$server_port"
            exit 0
        fi
        printf 'state=stopped\n'
        exit 1
        ;;

    *)
        printf 'usage: %s start|stop|status\n' "$0" >&2
        exit 2
        ;;
esac
