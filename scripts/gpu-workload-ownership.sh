#!/bin/sh
set -eu

# Decide whether this host's CUDA device is free for one measurement campaign,
# and hold that decision for as long as the campaign runs.
#
# Two authorities answer two different questions and neither substitutes for the
# other. An exclusive flock(2) on one well-known path serializes the campaigns
# this tree launches, because a lock excludes exactly what also takes it. Device
# residency is answered by the driver: nvidia-smi --query-compute-apps lists the
# processes holding a CUDA context, and each pid is resolved through /proc to an
# executable path, a start time, and a cgroup before it is classified. A process
# named llama-server that holds no CUDA context is a name rather than a device
# client, so it is recorded and does not refuse the run; that distinction is the
# whole reason `pgrep -x llama-server` cannot serve as the ownership authority.
#
# Source this file to use gpu_ownership_acquire and gpu_ownership_inspect, or
# run it with `inspect` to read the classification alone.

GPU_OWNERSHIP_LOCK_DEFAULT=/tmp/qwen-ad104-gpu-0.lock

# A project workload is the confound a campaign exists to remove, so its pattern
# refuses. The desktop is a live consumer of the same device on this host and is
# a covariate of every recorded rate, so its pattern records. A browser belongs
# to the second set: its GPU process holds a CUDA context for rasterization and
# video, which is why Microsoft Edge appears in the compute-app list at about
# 98 MiB beside the compositor. Classification is by name because the driver
# reports a name and a byte count rather than an intent, so a desktop client
# whose name is absent from this pattern refuses the run and is added here once
# it is identified rather than being admitted by a wider default.
#
# One entry names a process shape rather than an application. Chromium and every
# Electron embedder built on it spawn their GPU process with `--type=gpu-process`
# in the argv the driver reports, so that flag identifies the rasterization
# client of an application this list has never seen: Discord reached the
# compute-app list at 594 MiB under its own name and nothing else in the
# pattern. Matching the flag classifies the whole family at once, and a project
# workload never carries it.
GPU_OWNERSHIP_PROJECT_PATTERN='llama-server|llama-bench|llama-cli|llama-mtmd-cli|llama-quantize|nsys|ncu|nv-nsight|image-service|coding-agent|qwen-'
GPU_OWNERSHIP_DESKTOP_PATTERN='kwin_wayland|kwin_x11|Xorg|Xwayland|plasmashell|gnome-shell|sway|wayfire|mutter|firefox|chromium|chrome|msedge|brave|vivaldi|opera|electron|obs|--type=gpu-process'

gpu_ownership_nvidia_smi() {
    printf '%s\n' "${QWEN_GPU_OWNERSHIP_NVIDIA_SMI:-nvidia-smi}"
}

gpu_ownership_procfs() {
    printf '%s\n' "${QWEN_GPU_OWNERSHIP_PROCFS:-/proc}"
}

# Hold the campaign lock on descriptor 9 for the caller's whole lifetime. The
# descriptor is deliberately never closed in the harness: the kernel releases it
# when the process exits, which is what keeps the claim over server launch,
# cache fill, needle decode, server stop, and the post-arm health reads.
#
# Every long-lived child the harness launches must close it with `9>&-`. A child
# inherits the open descriptor and therefore the lock, so a server that outlives
# the probe holds the claim against the next campaign; that leak made a second
# probe exit 75 against a device nothing was using.
gpu_ownership_acquire() {
    gpu_ownership_lock_path=${1:-${QWEN_GPU_OWNERSHIP_LOCK:-$GPU_OWNERSHIP_LOCK_DEFAULT}}
    exec 9>"$gpu_ownership_lock_path"
    if ! flock -n 9; then
        printf 'refused: another qwen CUDA campaign owns GPU 0 (lock %s)\n' \
            "$gpu_ownership_lock_path" >&2
        return 75
    fi
    printf 'gpu_ownership_lock=held path=%s\n' "$gpu_ownership_lock_path"
    return 0
}

# Take the claim where no ancestor holds it, and inspect either way. A campaign
# that already acquired the lock exports QWEN_GPU_OWNERSHIP_HELD, because flock
# is per-process: a nested sweep asking for the same path would be refused by the
# very campaign that launched it. The inspection is unconditional, since external
# interference is what each nested stage still has to rule out.
gpu_ownership_require() {
    if [ -z "${QWEN_GPU_OWNERSHIP_HELD:-}" ]; then
        gpu_ownership_acquire "${1:-}" || return $?
        QWEN_GPU_OWNERSHIP_HELD=1
        export QWEN_GPU_OWNERSHIP_HELD
    else
        printf 'gpu_ownership_lock=inherited\n'
    fi
    gpu_ownership_inspect
}

# Resolve one pid's durable identity. An exe that cannot be read leaves the
# field `unreadable` rather than absent, because a compute client this harness
# cannot name is the case that must refuse rather than pass silently.
gpu_ownership_identity() {
    gpu_ownership_identity_pid=$1
    gpu_ownership_identity_root=$(gpu_ownership_procfs)/$gpu_ownership_identity_pid
    if [ ! -d "$gpu_ownership_identity_root" ]; then
        printf 'exe=gone start_time=gone cgroup=gone\n'
        return 0
    fi
    gpu_ownership_identity_exe=$(readlink "$gpu_ownership_identity_root/exe" \
        2>/dev/null || printf 'unreadable')
    gpu_ownership_identity_start=$(awk '{ print $22 }' \
        "$gpu_ownership_identity_root/stat" 2>/dev/null || printf 'unreadable')
    [ -n "$gpu_ownership_identity_start" ] ||
        gpu_ownership_identity_start=unreadable
    gpu_ownership_identity_cgroup=$(head -1 \
        "$gpu_ownership_identity_root/cgroup" 2>/dev/null || printf 'unreadable')
    [ -n "$gpu_ownership_identity_cgroup" ] ||
        gpu_ownership_identity_cgroup=unreadable
    printf 'exe=%s start_time=%s cgroup=%s\n' \
        "$gpu_ownership_identity_exe" "$gpu_ownership_identity_start" \
        "$gpu_ownership_identity_cgroup"
}

# Classify every CUDA client and decide the run. QWEN_GPU_OWNERSHIP_SELF_PIDS
# carries the pids this campaign launched itself, which are accepted because the
# harness is asking about interference rather than about its own children.
#
# Every classification line is printed on stdout, so the caller retains the
# desktop occupancy as the covariate it is. A refusal names the client that
# caused it on stderr and returns 1.
gpu_ownership_inspect() {
    gpu_ownership_self_pids=" ${QWEN_GPU_OWNERSHIP_SELF_PIDS:-} "
    gpu_ownership_rows=$("$(gpu_ownership_nvidia_smi)" \
        --query-compute-apps=pid,process_name,used_memory \
        --format=csv,noheader 2>/dev/null || :)
    gpu_ownership_refusals=0

    if [ -n "$gpu_ownership_rows" ]; then
        printf '%s\n' "$gpu_ownership_rows" | while IFS= read -r gpu_ownership_row
        do
            [ -n "$gpu_ownership_row" ] || continue
            gpu_ownership_pid=$(printf '%s' "$gpu_ownership_row" |
                cut -d, -f1 | tr -d ' ')
            gpu_ownership_name=$(printf '%s' "$gpu_ownership_row" |
                cut -d, -f2 | sed 's/^ *//; s/ *$//')
            gpu_ownership_memory=$(printf '%s' "$gpu_ownership_row" |
                cut -d, -f3 | sed 's/^ *//; s/ *$//')
            gpu_ownership_facts=$(gpu_ownership_identity "$gpu_ownership_pid")
            case " $gpu_ownership_self_pids " in
                *" $gpu_ownership_pid "*)
                    gpu_ownership_verdict=accept-self ;;
                *)
                    if printf '%s %s' "$gpu_ownership_name" \
                        "$gpu_ownership_facts" |
                        grep -Eq "$GPU_OWNERSHIP_PROJECT_PATTERN"; then
                        gpu_ownership_verdict=refuse-project
                    elif printf '%s %s' "$gpu_ownership_name" \
                        "$gpu_ownership_facts" |
                        grep -Eq "$GPU_OWNERSHIP_DESKTOP_PATTERN"; then
                        gpu_ownership_verdict=record-desktop
                    else
                        gpu_ownership_verdict=refuse-unknown
                    fi
                    ;;
            esac
            printf 'cuda_client pid=%s name=%s used=%s %s verdict=%s\n' \
                "$gpu_ownership_pid" "$gpu_ownership_name" \
                "$gpu_ownership_memory" "$gpu_ownership_facts" \
                "$gpu_ownership_verdict"
        done > "${TMPDIR:-/tmp}/gpu-ownership-classification.$$"
        cat "${TMPDIR:-/tmp}/gpu-ownership-classification.$$"
        gpu_ownership_refusals=$(grep -c 'verdict=refuse-' \
            "${TMPDIR:-/tmp}/gpu-ownership-classification.$$" || :)
        gpu_ownership_refusal_lines=$(grep 'verdict=refuse-' \
            "${TMPDIR:-/tmp}/gpu-ownership-classification.$$" || :)
        rm -f "${TMPDIR:-/tmp}/gpu-ownership-classification.$$"
    else
        gpu_ownership_refusal_lines=''
        printf 'cuda_clients=none\n'
    fi

    # A process named like a served binary that holds no CUDA context is a name
    # rather than device ownership, so pgrep answers as diagnostic output beside
    # the driver's own list and never as the ownership authority.
    gpu_ownership_named=$(pgrep -x llama-server 2>/dev/null | tr '\n' ' ' || :)
    printf 'named_llama_server_pids=%s\n' "${gpu_ownership_named:--}"

    case $gpu_ownership_refusals in
        '' | 0) return 0 ;;
    esac
    printf 'refused: a foreign CUDA client holds GPU 0\n%s\n' \
        "$gpu_ownership_refusal_lines" >&2
    return 1
}

# Standalone use runs both authorities in the order a campaign takes them.
case ${0##*/} in
    gpu-workload-ownership.sh)
        case ${1:-} in
            inspect) gpu_ownership_inspect ;;
            acquire) gpu_ownership_acquire "${2:-}" && gpu_ownership_inspect ;;
            *)
                printf 'usage: %s inspect|acquire [LOCK_PATH]\n' "$0" >&2
                exit 2
                ;;
        esac
        ;;
esac
