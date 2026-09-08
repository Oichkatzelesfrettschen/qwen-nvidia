#!/bin/sh
set -eu

# Stop the Web UI and prove nothing survived. The exit status reports the
# machine's state rather than the attempt: a surviving process, tmux session,
# or listener fails the script so a caller cannot mistake a partial stop for a
# clean one.

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
state_directory=${QWEN_WEBUI_STATE_DIRECTORY:-"${HOME:?}/qwen-webui-state"}
server_port=${QWEN_SERVER_PORT:-8080}
status_file=$state_directory/session.status

# The session script rewrites session.status to state=stopped as it exits,
# which drops the guard PIDs, so read them before asking it to stop.
guard_identities=''
server_pid=''
server_start_time=''
broker_pid=''
broker_secret_file=''
if [ -r "$status_file" ]; then
    server_pid=$(sed -n '1p' "$status_file" | tr ' ' '\n' |
        sed -n 's/^server_pid=//p')
    server_start_time=$(sed -n '1p' "$status_file" | tr ' ' '\n' |
        sed -n 's/^server_start_time=//p')
    for guard_name in monitor latency_watchdog kernel_hazard_watchdog; do
        guard_pid=$(sed -n '1p' "$status_file" | tr ' ' '\n' | sed -n "s/^${guard_name}_pid=//p")
        guard_start=$(sed -n '1p' "$status_file" | tr ' ' '\n' | sed -n "s/^${guard_name}_start_time=//p")
        case $guard_pid:$guard_start in
            *[!0-9:]* | :* | *: | *::* ) ;;
            *) guard_identities="$guard_identities $guard_pid:$guard_start:$guard_name" ;;
        esac
    done
    # The broker is read a second time on its own, because its absence proof
    # covers a file as well as a process: it unlinks its per-launch session
    # secret while unwinding from SIGTERM, and a secret surviving the teardown
    # authorizes a page against the next launch. A session that ran no broker
    # records no field here, so an ordinary teardown proves nothing about a
    # secret file a manual broker run left behind.
    broker_pid=$(sed -n '1p' "$status_file" | tr ' ' '\n' |
        sed -n 's/^broker_pid=//p')
    # The session records the secret's path whole on its own line, so the proof
    # reads the file the broker actually wrote: QWEN_WEB_STATE_DIR reaches that
    # session alone, and re-deriving the default here would prove the absence
    # of a file a configured launch placed elsewhere.
    broker_secret_file=$(sed -n 's/^broker secret_file=//p' "$status_file")
    # The recorded start time binds the PID to the process /health identified
    # at launch. A PID is reused once its process exits, so a number alone
    # would signal whatever now holds it.
    broker_start_time=$(sed -n 's/^broker_identity .*start_time=\([0-9]*\).*/\1/p' \
        "$status_file")
    # The image service owns the Vulkan workload lease, the control socket, and
    # any partial artifact, so its pid is read here for the reason the broker's
    # is: `tmux kill-session` ends the session script without running its EXIT
    # trap, and a surviving service holds the lease against the next launch.
    image_service_pid=$(sed -n '1p' "$status_file" | tr ' ' '\n' |
        sed -n 's/^image_service_pid=//p')
    image_service_start_time=$(sed -n \
        's/^image_service_identity .*start_time=\([0-9]*\).*/\1/p' \
        "$status_file")
fi
broker_start_time=${broker_start_time:-}
image_service_pid=${image_service_pid:-}
image_service_start_time=${image_service_start_time:-}
# The two sidecar services are read the same way: the pid off the first line
# and the start time off the lane's own identity line.
physics_service_pid=$(sed -n '1p' "$status_file" 2>/dev/null | tr ' ' '\n' | sed -n 's/^physics_service_pid=//p')
physics_service_start_time=$(sed -n 's/^physics_service_identity .*start_time=\([0-9]*\).*/\1/p' "$status_file" 2>/dev/null | sed -n '1p')
geometry_service_pid=$(sed -n '1p' "$status_file" 2>/dev/null | tr ' ' '\n' | sed -n 's/^geometry_service_pid=//p')
geometry_service_start_time=$(sed -n 's/^geometry_service_identity .*start_time=\([0-9]*\).*/\1/p' "$status_file" 2>/dev/null | sed -n '1p')
physics_service_pid=${physics_service_pid:-}
geometry_service_pid=${geometry_service_pid:-}

control_status=0
"$script_directory/qwen-webui-control.sh" stop || control_status=$?

# Forced tmux termination bypasses the session EXIT trap. Once control has
# stopped the only session that can own these unique snapshots, remove the
# reserved active-session files left by either forced or interrupted startup.
snapshot_residue=0
for router_preset_snapshot in "$state_directory"/.router-presets.active.*; do
    [ -e "$router_preset_snapshot" ] || \
        [ -L "$router_preset_snapshot" ] || continue
    if [ -f "$router_preset_snapshot" ] || [ -L "$router_preset_snapshot" ]; then
        rm -f -- "$router_preset_snapshot"
    else
        printf 'router snapshot path is not a regular file: %s\n' \
            "$router_preset_snapshot" >&2
        snapshot_residue=1
    fi
done

case $server_pid:$server_start_time in
    *[!0-9:]* | :* | *: | *::* ) server_pid='' ;;
esac
attempt=0
while [ -n "$server_pid" ] && [ "$attempt" -lt 300 ] && \
      [ -r "/proc/$server_pid/stat" ] && \
      [ "$(sed 's/^.*) //' "/proc/$server_pid/stat" | awk '{ print $20 }')" = "$server_start_time" ]; do
    attempt=$((attempt + 1))
    sleep 0.1
done

# `tmux kill-session` ends the session script without running its EXIT trap, so
# the guards it launched are orphaned rather than cleaned up: a probe observed
# this way kept submitting to the graphics queue every 16 ms after the server
# had gone. The session recorded each guard's PID, so signal those rather than
# matching command lines: `pgrep -f` also matches any shell whose arguments
# happen to contain the pattern, including the one running this script.
guard_residue=0
for guard_identity in $guard_identities; do
    guard_pid=${guard_identity%%:*}
    guard_remainder=${guard_identity#*:}
    guard_start=${guard_remainder%%:*}
    guard_name=${guard_remainder#*:}
    if [ -r "/proc/$guard_pid/stat" ] &&
       [ "$(sed 's/^.*) //' "/proc/$guard_pid/stat" | awk '{ print $20 }')" = "$guard_start" ]; then
        printf 'stopping guard pid %s (%s)\n' \
            "$guard_pid" "$guard_name"
        kill -TERM "$guard_pid" 2>/dev/null || true
        attempt=0
        while [ "$attempt" -lt 100 ] && [ -r "/proc/$guard_pid/stat" ] &&
              [ "$(sed 's/^.*) //' "/proc/$guard_pid/stat" | awk '{ print $20 }')" = "$guard_start" ]; do
            attempt=$((attempt + 1))
            sleep 0.1
        done
        if [ -r "/proc/$guard_pid/stat" ] &&
           [ "$(sed 's/^.*) //' "/proc/$guard_pid/stat" | awk '{ print $20 }')" = "$guard_start" ]; then
            printf 'owned guard survived: component=%s pid=%s\n' "$guard_name" "$guard_pid" >&2
            guard_residue=1
        fi
    fi
done

# The broker unlinks its session secret in the cleanup that runs after the
# accept loop unwinds, so the file check waits for the process to leave rather
# than reading the directory while it is still writing. A broker that survives
# the signal is residue, and so is a secret file outliving the broker that
# wrote it.
broker_residue=0
case $broker_pid in
    '' | *[!0-9]*) broker_pid='' ;;
esac
if [ -n "$broker_pid" ] && [ -n "$broker_start_time" ] && \
   [ -r "/proc/$broker_pid/stat" ]; then
    # Field 22 of /proc/PID/stat is the start time in clock ticks. The comm
    # field before it may hold spaces, so the fields are counted from the
    # closing parenthesis rather than from the line start.
    live_start_time=$(sed 's/^.*) //' "/proc/$broker_pid/stat" |
        awk '{ print $20 }')
    if [ "$live_start_time" != "$broker_start_time" ]; then
        printf 'pid %s now belongs to another process (start %s recorded, %s live); the broker is gone\n' \
            "$broker_pid" "$broker_start_time" "$live_start_time" >&2
        broker_pid=''
    fi
fi
if [ -n "$broker_pid" ]; then
    # The broker is signalled here rather than with the guards above, after
    # the start-time comparison has bound the number to the process.
    if kill -0 "$broker_pid" 2>/dev/null; then
        printf 'stopping approval broker pid %s\n' "$broker_pid"
        kill -TERM "$broker_pid" 2>/dev/null || true
    fi
    attempt=0
    while [ "$attempt" -lt 100 ] && kill -0 "$broker_pid" 2>/dev/null; do
        attempt=$((attempt + 1))
        sleep 0.1
    done
    if kill -0 "$broker_pid" 2>/dev/null; then
        printf 'approval broker still running: %s\n' "$broker_pid" >&2
        broker_residue=1
    fi
fi
# The secret file is proved absent on its own: a status file whose PID field
# is missing or malformed still names the path, and a surviving secret
# authorizes a page against the next launch whatever became of the process.
if [ -n "$broker_secret_file" ] && \
   { [ -e "$broker_secret_file" ] || [ -L "$broker_secret_file" ]; }; then
    printf 'approval broker session secret survives: %s\n' \
        "$broker_secret_file" >&2
    broker_residue=1
fi

# The image service is signalled after the start-time comparison has bound the
# number to the process, the way the broker is, and its absence is then proved
# by scripts/image-teardown-check.sh, which reads process and filesystem state
# rather than the attempt: a live service, a live runtime, a partial artifact,
# or a held lease each fail it. A session that ran none records no pid, and the
# check runs anyway, because a manual run leaves the same residue.
case $image_service_pid in
    '' | *[!0-9]*) image_service_pid='' ;;
esac
# The signal goes to a pid whose identity this teardown proved. A recorded
# number with no recorded start time identifies nothing, and the service holds
# the Vulkan workload lease, so an unproven pid is left alone and
# image-teardown-check.sh reports whatever survives rather than a signal
# reaching whichever process now holds that number.
if [ -n "$image_service_pid" ]; then
    if [ -z "$image_service_start_time" ] || \
       [ ! -r "/proc/$image_service_pid/stat" ]; then
        printf 'pid %s carries no recorded start time, so the image service is left to the residue proof\n' \
            "$image_service_pid" >&2
        image_service_pid=''
    else
        live_image_start_time=$(sed 's/^.*) //' "/proc/$image_service_pid/stat" |
            awk '{ print $20 }')
        if [ "$live_image_start_time" != "$image_service_start_time" ]; then
            printf 'pid %s now belongs to another process (start %s recorded, %s live); the image service is gone\n' \
                "$image_service_pid" "$image_service_start_time" \
                "$live_image_start_time" >&2
            image_service_pid=''
        fi
    fi
fi
if [ -n "$image_service_pid" ] && kill -0 "$image_service_pid" 2>/dev/null; then
    printf 'stopping image service pid %s\n' "$image_service_pid"
    kill -TERM "$image_service_pid" 2>/dev/null || true
    attempt=0
    while [ "$attempt" -lt 200 ] && kill -0 "$image_service_pid" 2>/dev/null; do
        attempt=$((attempt + 1))
        sleep 0.1
    done
fi
image_residue=0
image_residue_prover=$script_directory/image-teardown-check.sh
if [ ! -x "$image_residue_prover" ]; then
    # An absent proof is not a proof of absence, so this counts as residue and
    # names the file rather than reaching the caller as a bare 127 from the
    # command substitution below. `rsync -a scripts/` deploys the directory
    # whole, so a missing sibling states that the copy is partial.
    printf 'the image residue proof is absent or not executable: %s\n' \
        "$image_residue_prover" >&2
    image_residue=1
elif ! "$image_residue_prover" "$state_directory"; then
    image_residue=1
fi

# stop_sidecar LANE PID START_TIME: signal a sidecar whose identity the
# recorded start time proves, wait for it, then run the lane's own residue
# proof over the lane's state directory; an unproven pid is left to the proof.
sidecar_residue=0
stop_sidecar() {
    sidecar_lane=$1
    sidecar_pid=$2
    sidecar_start_time=$3
    case $sidecar_pid in '' | *[!0-9]*) sidecar_pid='' ;; esac
    if [ -n "$sidecar_pid" ]; then
        if [ -z "$sidecar_start_time" ] || [ ! -r "/proc/$sidecar_pid/stat" ]; then
            printf 'pid %s carries no recorded start time, so the %s service is left to the residue proof\n' \
                "$sidecar_pid" "$sidecar_lane" >&2
            sidecar_pid=''
        else
            live_sidecar_start_time=$(sed 's/^.*) //' "/proc/$sidecar_pid/stat" | awk '{ print $20 }')
            if [ "$live_sidecar_start_time" != "$sidecar_start_time" ]; then
                printf 'pid %s now belongs to another process; the %s service is gone\n' \
                    "$sidecar_pid" "$sidecar_lane" >&2
                sidecar_pid=''
            fi
        fi
    fi
    if [ -n "$sidecar_pid" ] && kill -0 "$sidecar_pid" 2>/dev/null; then
        printf 'stopping %s service pid %s\n' "$sidecar_lane" "$sidecar_pid"
        kill -TERM "$sidecar_pid" 2>/dev/null || true
        attempt=0
        while [ "$attempt" -lt 200 ] && kill -0 "$sidecar_pid" 2>/dev/null; do
            attempt=$((attempt + 1))
            sleep 0.1
        done
        if kill -0 "$sidecar_pid" 2>/dev/null; then
            printf '%s service pid %s survived SIGTERM for 20 s; sending SIGKILL\n' "$sidecar_lane" "$sidecar_pid" >&2
            kill -KILL "$sidecar_pid" 2>/dev/null || true
        fi
    fi
    # A lane that never ran under this state directory leaves no directory
    # and no pid, and its proof has nothing to read; a lane that ran is proven
    # by its own check, whose absence then counts as residue.
    sidecar_prover=$script_directory/$sidecar_lane-teardown-check.sh
    if [ -z "$sidecar_pid" ] && [ ! -d "$state_directory/$sidecar_lane" ]; then
        :
    elif [ ! -x "$sidecar_prover" ]; then
        printf 'the %s residue proof is absent or not executable: %s\n' "$sidecar_lane" "$sidecar_prover" >&2
        sidecar_residue=1
    elif ! "$sidecar_prover" "$state_directory/$sidecar_lane"; then
        sidecar_residue=1
    fi
}
stop_sidecar physics "$physics_service_pid" "$physics_service_start_time"
stop_sidecar geometry "$geometry_service_pid" "$geometry_service_start_time"

residue=$snapshot_residue
if [ "$control_status" -ne 0 ]; then
    printf 'session control stop failed: status=%s\n' "$control_status" >&2
    residue=1
fi
if [ "$guard_residue" -ne 0 ]; then
    residue=1
fi
if [ "$broker_residue" -ne 0 ]; then
    residue=1
fi
if [ "$image_residue" -ne 0 ]; then
    residue=1
fi
if [ "$sidecar_residue" -ne 0 ]; then
    residue=1
fi
if [ -n "$server_pid" ] && [ -r "/proc/$server_pid/stat" ] && \
   [ "$(sed 's/^.*) //' "/proc/$server_pid/stat" | awk '{ print $20 }')" = "$server_start_time" ]; then
    printf 'owned llama-server still running: %s\n' "$server_pid" >&2
    residue=1
fi
if tmux -L qwen-runtime has-session -t qwen-webui 2>/dev/null; then
    printf 'tmux session qwen-webui still present\n' >&2
    residue=1
fi
if command -v ss >/dev/null 2>&1 && \
   ss -ltn "sport = :$server_port" 2>/dev/null | grep -q ":$server_port"; then
    printf 'port %s still has a listener\n' "$server_port" >&2
    residue=1
fi

rm -f "$state_directory/server.pid"
if [ "$residue" -eq 0 ]; then
    printf 'torn down: no server, tmux session, probe, approval broker, image, physics, or geometry service, or router snapshot; port %s free\n' \
        "$server_port"
else
    printf 'teardown incomplete\n' >&2
fi
exit "$residue"
