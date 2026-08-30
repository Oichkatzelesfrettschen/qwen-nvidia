#!/bin/sh
set -eu

# Explicit process control for the native SearXNG instance. No unit file,
# crontab entry, or login hook starts this service: start and stop run only
# through this script, so a reboot leaves the laptop with nothing listening
# on 8888.
#
# Every path below is an environment override so scripts/test-search-control.sh
# can drive this script against a fake python3 listener as the invoking user,
# with no SearXNG install and no sudo. QWEN_SEARXNG_SERVICE_USER defaults to
# the real service account (searxng); run_as_service_user only invokes sudo
# when that account differs from the caller, so a test that names its own
# account never needs a privilege it does not have.

if [ "$#" -ne 1 ]; then
    printf 'usage: %s start|stop|status\n' "$0" >&2
    exit 2
fi
action=$1

service_user=${QWEN_SEARXNG_SERVICE_USER:-searxng}
pyenv_python=${QWEN_SEARXNG_PYTHON:-/usr/local/searxng/searx-pyenv/bin/python}
settings_path=${QWEN_SEARXNG_SETTINGS_PATH:-/etc/searxng/settings.yml}
run_directory=${QWEN_SEARXNG_RUN_DIRECTORY:-/usr/local/searxng/run}
python_module=${QWEN_SEARXNG_MODULE:-searx.webapp}
server_port=${QWEN_SEARXNG_PORT:-8888}
bind_address=${QWEN_SEARXNG_BIND_ADDRESS:-127.0.0.1}
start_timeout_seconds=${QWEN_SEARXNG_START_TIMEOUT:-120}
stop_timeout_seconds=${QWEN_SEARXNG_STOP_TIMEOUT:-15}

# QWEN_SEARXNG_LAUNCH_COMMAND replaces the default `python -m searx.webapp`
# invocation whole, which is what lets the fake-listener test substitute a
# python3 http.server one-liner without SearXNG installed anywhere.
launch_command=${QWEN_SEARXNG_LAUNCH_COMMAND:-"env SEARXNG_SETTINGS_PATH='$settings_path' '$pyenv_python' -m $python_module"}

pid_file=$run_directory/server.pid
log_file=$run_directory/server.log

run_as_service_user() {
    if [ "$service_user" = "$(id -un)" ]; then
        sh -c "$1"
    else
        if ! sudo -n true 2>/dev/null; then
            printf 'sudo credential not cached: run "sudo -v" first\n' >&2
            exit 2
        fi
        sudo -H -u "$service_user" sh -c "$1"
    fi
}

pid_is_alive() {
    [ -d "/proc/$1" ]
}

listener_present() {
    ss -ltn "sport = :$server_port" 2>/dev/null |
        awk 'NR>1 {print $4}' |
        grep -qxF -e "$bind_address:$server_port" -e "[::1]:$server_port"
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
        run_as_service_user "mkdir -p '$run_directory' && rm -f '$pid_file'"
        # The redirect and the PID write both run inside the privileged
        # shell rather than this script's own, because run_directory is
        # owned by service_user (mode 0755 from install's own `mkdir -p`)
        # and the invoking human cannot open a file for writing there. The
        # launched shell writes its own PID before exec replaces it with the
        # server process, so the PID in the file is the server's own for the
        # rest of its life rather than a forking wrapper's.
        #
        # The subshell's own stdin, stdout, and stderr are reassigned before
        # it forks anything, rather than only inside the exec'd command, so
        # no fd inherited from this script's caller -- in particular the
        # write end of a command substitution's pipe, when this script runs
        # as `$(searxng-control.sh start)` -- survives into the long-lived
        # server process. A server left holding that pipe open never lets
        # the pipe reach EOF, so the caller's command substitution waits
        # forever even after this script itself has exited.
        (run_as_service_user \
            "echo \$\$ > '$pid_file'; exec $launch_command >'$log_file' 2>&1 </dev/null") \
            >/dev/null 2>&1 </dev/null &

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
        run_as_service_user "[ -f '$log_file' ] && tail -n 40 '$log_file'" >&2 || true
        exit 1
        ;;

    stop)
        current_pid=$(read_pid || true)
        if [ -z "${current_pid:-}" ] || ! pid_is_alive "$current_pid"; then
            run_as_service_user "rm -f '$pid_file'"
            if listener_present; then
                printf 'no recorded process but %s:%s is still listening\n' \
                    "$bind_address" "$server_port" >&2
                exit 1
            fi
            printf 'not running\n'
            exit 0
        fi

        run_as_service_user "kill -TERM $current_pid" 2>/dev/null || true
        waited=0
        while [ "$waited" -lt "$stop_timeout_seconds" ]; do
            if ! pid_is_alive "$current_pid" && ! listener_present; then
                run_as_service_user "rm -f '$pid_file'"
                printf 'stopped: pid=%s\n' "$current_pid"
                exit 0
            fi
            sleep 1
            waited=$((waited + 1))
        done

        run_as_service_user "kill -KILL $current_pid" 2>/dev/null || true
        sleep 1
        if pid_is_alive "$current_pid" || listener_present; then
            printf 'residue after stop: pid_alive=%s listener=%s\n' \
                "$(pid_is_alive "$current_pid" && echo yes || echo no)" \
                "$(listener_present && echo yes || echo no)" >&2
            exit 1
        fi
        run_as_service_user "rm -f '$pid_file'"
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
