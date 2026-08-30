#!/bin/sh
set -eu

# Prove that no image generation survives. The exit status reports the
# machine's state rather than an attempt: a live service, a live runtime, a
# partial artifact, or a held Vulkan workload lease each fail the script, so a
# caller cannot mistake a partial stop for a clean one.
#
# Every proof reads process and filesystem state. The artifact listener carries
# a credential this script does not hold, so an HTTP probe would report a
# refusal whether or not the service is running and proves nothing here.

usage() {
    printf 'usage: %s [STATE_DIRECTORY]\n' "$0" >&2
    exit 2
}

if [ "$#" -gt 1 ]; then
    usage
fi

state_directory=${1:-${QWEN_WEBUI_STATE_DIRECTORY:-"${HOME:?}/qwen-webui-state"}}
image_directory=$state_directory/images
artifact_directory=$image_directory/artifacts
pid_file=$image_directory/image-service.pid
socket_file=$image_directory/image-service.sock
lease_file=$state_directory/vulkan-workload.lock

residue=0

# The recorded pid is checked against its own command line rather than
# signalled, because a pid is reused once its process exits and this script
# proves absence rather than causing it.
if [ -r "$pid_file" ]; then
    recorded_pid=$(sed -n '1p' "$pid_file" | tr -d ' ')
    case $recorded_pid in
        '' | *[!0-9]*) recorded_pid='' ;;
    esac
    if [ -n "$recorded_pid" ] && [ -r "/proc/$recorded_pid/cmdline" ] &&
        tr '\0' ' ' <"/proc/$recorded_pid/cmdline" | grep -q 'image-service.py'; then
        printf 'image service still running: pid %s\n' "$recorded_pid" >&2
        residue=1
    else
        printf 'stale pid file removed: %s\n' "$pid_file"
        rm -f -- "$pid_file"
    fi
fi

# A second process may run the service without having written that file, so the
# command line is matched directly as well. The pattern names the script rather
# than a bare word, which keeps this script's own arguments from matching it.
# A pattern is anchored to the executable position of the command line, since
# a harness that names the runtime in an environment assignment (for example
# QWEN_IMAGE_RUNTIME=.../sd-cli) carries the same substring and would count
# itself as residue under a bare substring match.
service_pids=$(pgrep -f '^([^ ]*/)?python3?[^ ]* ([^ ]*/)?image-service\.py( |$)' 2>/dev/null || true)
if [ -n "$service_pids" ]; then
    printf 'image service processes survive: %s\n' \
        "$(printf '%s' "$service_pids" | tr '\n' ' ')" >&2
    residue=1
fi

# The runtimes this tree can spawn are the pinned stable-diffusion.cpp binary
# and the fixture that stands in for it. A deployment that pins another binary
# names it in QWEN_IMAGE_RUNTIME_PATTERN as an extended regular expression.
runtime_pattern=${QWEN_IMAGE_RUNTIME_PATTERN:-'^([^ ]*/)?(sd-cli|fake-image-runtime\.sh)( |$)'}
runtime_pids=$(pgrep -f "$runtime_pattern" 2>/dev/null || true)
if [ -n "$runtime_pids" ]; then
    printf 'image runtime processes survive: %s\n' \
        "$(printf '%s' "$runtime_pids" | tr '\n' ' ')" >&2
    residue=1
fi

# A partial artifact is what an interrupted job leaves in the directory the
# finished ones live in, so its presence states that a generation stopped
# between the runtime write and the digest rename. image-service.py names the
# file `.part.png`: the pinned runtime picks its encoder from the output
# path's own extension and appends `.png` to an extensionless name itself, so
# the partial name keeps a recognized extension. `*.part` is matched too for
# an artifact directory a prior version wrote into.
if [ -d "$artifact_directory" ]; then
    partial_files=$(find "$artifact_directory" -maxdepth 1 \
        \( -name '*.part.png' -o -name '*.part' \) -print)
    if [ -n "$partial_files" ]; then
        printf 'partial artifacts survive:\n%s\n' "$partial_files" >&2
        residue=1
    fi
fi

# The kernel lock is the lease authority, so the proof takes it and releases
# it. flock(1) exits 75 on a lock held elsewhere, which separates a busy lease
# from every other failure of this command.
if [ -e "$lease_file" ]; then
    if flock -n -E 75 "$lease_file" true; then
        printf 'vulkan workload lease is free: %s\n' "$lease_file"
    else
        lease_status=$?
        if [ "$lease_status" -eq 75 ]; then
            printf 'vulkan workload lease is held: %s\n' "$lease_file" >&2
            if [ -r "$state_directory/vulkan-workload.status" ]; then
                sed -n '1p' "$state_directory/vulkan-workload.status" >&2
            fi
        else
            printf 'the lease file is unusable (flock exit %s): %s\n' \
                "$lease_status" "$lease_file" >&2
        fi
        residue=1
    fi
fi

# The socket file outlives a killed service, and the next launch unlinks a
# refused one; a socket that still accepts a connection means a service holds
# it, which the process checks above have already reported.
if [ -S "$socket_file" ]; then
    printf 'control socket file remains: %s\n' "$socket_file"
    rm -f -- "$socket_file"
elif [ -e "$socket_file" ] || [ -L "$socket_file" ]; then
    printf 'the control socket path is not a socket: %s\n' "$socket_file" >&2
    residue=1
fi

if [ "$residue" -eq 0 ]; then
    printf 'image teardown verified: no service, no runtime, no partial artifact, lease free\n'
else
    printf 'image teardown incomplete\n' >&2
fi
exit "$residue"
