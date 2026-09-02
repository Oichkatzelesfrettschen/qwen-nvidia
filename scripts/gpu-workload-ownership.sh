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

# Four kernel locks order this device and the order is fixed: the top-level owner
# lock this file holds, then the active-compute lease, then a service-local job
# lock, then an artifact or output lock. Each level is acquired while holding the
# levels above it and released before them.
#
# The owner lock is held for the whole lifetime of exactly one top-level
# orchestrator -- one serving session, one measurement campaign, or one
# standalone image, PhysX, or OptiX campaign. The compute lease at
# $QWEN_GPU_COMPUTE_LEASE is inner because it covers work that intentionally
# coexists under one serving session: model load, evaluation and decode, image
# load and generation, vision review, and the PhysX, OptiX, and TensorRT
# execution that follows. It leaves out the broker, the HTTP listener, telemetry,
# the kernel watcher, ordinary file work, an idle resident process, and the
# graphics-latency monitor, none of which run active compute.
#
# The order follows from how each acquire behaves rather than from granularity.
# The lease acquire blocks on a bounded deadline while the owner lock refuses at
# once with status 75, so a blocking acquire taken above a contended non-blocking
# lock converts a refusal into a wait the refusal exists to replace, and the lease
# is taken and released many times inside one owner hold.
#
# gpu_ownership_assert_order enforces the one inversion that can be constructed:
# a process holding the compute lease and then asking for the owner lock. It runs
# on the acquire path and refuses deterministically rather than waiting.
# Inheriting the owner lock and then taking the lease is the sanctioned sequence,
# so the check never fires on the inherited path.

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
# Which children close the descriptor follows from which process is the device
# client, and the two lanes answer oppositely. A measurement harness closes it
# on every long-lived child with `9>&-`, because the harness itself is the
# campaign and a child outliving it holds the claim against the next one. The
# serving chain keeps it open all the way to llama-server, because there the
# server's own residency is the claim and the harness process is gone by then.
#
# Every long-lived child a harness launches must close it with `9>&-`. The
# open descriptor is a transferable capability rather than a record of a past
# decision: a child inherits it, holds the lock through it, and satisfies the
# inherited-descriptor check gpu_ownership_require performs, so a server that
# outlives the probe both holds the claim against the next campaign and carries
# the ownership grant into whatever it launches; that leak made a second probe
# exit 75 against a device nothing was using.

# One resolution of the lock path serves both the acquire path and the
# inherited-descriptor comparison, so an explicit argument or
# QWEN_GPU_OWNERSHIP_LOCK names the same file in each.
gpu_ownership_lock_path() {
    printf '%s\n' "${1:-${QWEN_GPU_OWNERSHIP_LOCK:-$GPU_OWNERSHIP_LOCK_DEFAULT}}"
}

# The active-compute lease path. QWEN_GPU_COMPUTE_LEASE is the name; the lease
# carried QWEN_VULKAN_WORKLOAD_LOCK while Vulkan was the only accelerated path
# this tree had, and that name is accepted for one transition release only where
# both variables resolve to the same file by device and inode. A configuration
# naming two different files is refused rather than silently serialized on one of
# them, because two lease inodes is the split this rename exists to prevent.
gpu_ownership_lease_path() {
    gpu_ownership_lease_new=${QWEN_GPU_COMPUTE_LEASE:-}
    gpu_ownership_lease_legacy=${QWEN_VULKAN_WORKLOAD_LOCK:-}
    if [ -n "$gpu_ownership_lease_new" ] && [ -n "$gpu_ownership_lease_legacy" ]; then
        gpu_ownership_lease_new_id=$(stat -L -c '%d:%i' \
            "$gpu_ownership_lease_new" 2>/dev/null || printf 'absent-new')
        gpu_ownership_lease_legacy_id=$(stat -L -c '%d:%i' \
            "$gpu_ownership_lease_legacy" 2>/dev/null || printf 'absent-legacy')
        if [ "$gpu_ownership_lease_new_id" != "$gpu_ownership_lease_legacy_id" ] &&
            [ "$gpu_ownership_lease_new" != "$gpu_ownership_lease_legacy" ]; then
            printf 'refused: QWEN_GPU_COMPUTE_LEASE and QWEN_VULKAN_WORKLOAD_LOCK name two files: %s (%s) and %s (%s)\n' \
                "$gpu_ownership_lease_new" "$gpu_ownership_lease_new_id" \
                "$gpu_ownership_lease_legacy" "$gpu_ownership_lease_legacy_id" >&2
            return 1
        fi
    fi
    if [ -n "$gpu_ownership_lease_new" ]; then
        printf '%s\n' "$gpu_ownership_lease_new"
        return 0
    fi
    if [ -n "$gpu_ownership_lease_legacy" ]; then
        printf '%s\n' "$gpu_ownership_lease_legacy"
        return 0
    fi
    printf '%s/gpu-compute.lease\n' \
        "${QWEN_WEBUI_STATE_DIRECTORY:-${HOME:-/nonexistent}/qwen-webui-state}"
}

# Refuse the owner lock to a caller already inside the compute lease. Every
# descriptor this process holds is compared against the lease file by device and
# inode, the same identity comparison gpu_ownership_verify_inherited applies to
# the owner lock, so an inherited lease descriptor is caught as well as one this
# process opened. The refusal is immediate, which is what keeps the inversion a
# named error rather than a wait. An absent lease file is no violation, since a
# workstation that has never served has nothing to invert against.
gpu_ownership_assert_order() {
    gpu_ownership_order_lease=$(gpu_ownership_lease_path) || return 1
    [ -e "$gpu_ownership_order_lease" ] || return 0
    gpu_ownership_order_lease_id=$(stat -L -c '%d:%i' \
        "$gpu_ownership_order_lease" 2>/dev/null || printf 'absent')
    [ "$gpu_ownership_order_lease_id" != absent ] || return 0
    for gpu_ownership_order_link in /proc/self/fd/*; do
        [ -e "$gpu_ownership_order_link" ] || continue
        gpu_ownership_order_id=$(stat -L -c '%d:%i' \
            "$gpu_ownership_order_link" 2>/dev/null || printf 'unreadable')
        [ "$gpu_ownership_order_id" = "$gpu_ownership_order_lease_id" ] || continue
        printf 'refused: lock order inversion: descriptor %s already holds the GPU compute lease %s, which is inner to the owner lock\n' \
            "${gpu_ownership_order_link##*/}" "$gpu_ownership_order_lease" >&2
        return 1
    done
    return 0
}

gpu_ownership_acquire() {
    gpu_ownership_lock_path=$(gpu_ownership_lock_path "${1:-}")
    gpu_ownership_assert_order || return 75
    exec 9>"$gpu_ownership_lock_path"
    if ! flock -n 9; then
        printf 'refused: another qwen CUDA campaign owns GPU 0 (lock %s)\n' \
            "$gpu_ownership_lock_path" >&2
        return 75
    fi
    printf 'gpu_ownership_lock=held path=%s\n' "$gpu_ownership_lock_path"
    return 0
}

# Prove that an inherited descriptor is the campaign lock and that the lock is
# held. QWEN_GPU_OWNERSHIP_FD names the descriptor number an ancestor opened on
# the lock path and locked, and each check below establishes one property and
# refuses one forgery:
#
#   shape       the value is a decimal integer, so it reaches /proc/self/fd and
#               the flock argv as a descriptor number rather than as a path
#               fragment or an option.
#   open        /proc/self/fd/N resolves, so the descriptor exists in this
#               process. This refuses the bare marker the boolean was: a caller
#               who exports the variable and opens nothing is rejected here.
#   identity    `stat -L -c %d:%i` of /proc/self/fd/N equals that of the lock
#               path, so the descriptor refers to the lock file itself by device
#               and inode. This refuses a descriptor open on some other file,
#               which is otherwise open, lockable, and meaningless.
#   held        a fresh `flock -n` on a separate open of the lock path fails, so
#               some open file description exclusively holds the lock. This
#               refuses an unlocked open of the right file, and it runs before
#               the next check because `flock -n N` on an unlocked inherited
#               descriptor would acquire the lock and manufacture the very
#               holder this check looks for.
#   ours        `flock -n N` succeeds, so the holder is reachable through this
#               descriptor rather than being a foreign campaign: flock(2) grants
#               a request that the calling open file description already holds
#               and refuses one another description holds. This refuses a second
#               unlocked open of the lock file made while a foreign campaign
#               holds it.
#
# The pair proves that the lock is held and that this descriptor's own
# description holds it; the open file description is compared by its lock
# behavior rather than by an identity the kernel exports. Any failure refuses
# with a named reason and the caller exits 75, and an unset variable takes the
# acquire path instead. The inspection is unconditional, since external
# interference is what each nested stage still has to rule out.
gpu_ownership_verify_inherited() {
    gpu_ownership_verify_path=$1
    gpu_ownership_verify_fd=${QWEN_GPU_OWNERSHIP_FD:-}
    case $gpu_ownership_verify_fd in
        '' | *[!0-9]*)
            printf 'refused: QWEN_GPU_OWNERSHIP_FD is not a descriptor number: %s\n' \
                "$gpu_ownership_verify_fd" >&2
            return 1
            ;;
    esac
    gpu_ownership_verify_link=/proc/self/fd/$gpu_ownership_verify_fd
    if [ ! -e "$gpu_ownership_verify_link" ]; then
        printf 'refused: descriptor %s is closed in this process (%s)\n' \
            "$gpu_ownership_verify_fd" "$gpu_ownership_verify_link" >&2
        return 1
    fi
    gpu_ownership_verify_fd_id=$(stat -L -c '%d:%i' \
        "$gpu_ownership_verify_link" 2>/dev/null || printf 'unreadable')
    gpu_ownership_verify_path_id=$(stat -L -c '%d:%i' \
        "$gpu_ownership_verify_path" 2>/dev/null || printf 'absent')
    if [ "$gpu_ownership_verify_fd_id" != "$gpu_ownership_verify_path_id" ] ||
        [ "$gpu_ownership_verify_fd_id" = unreadable ]; then
        printf 'refused: descriptor %s inode mismatch: fd=%s lock=%s (%s)\n' \
            "$gpu_ownership_verify_fd" "$gpu_ownership_verify_fd_id" \
            "$gpu_ownership_verify_path_id" "$gpu_ownership_verify_path" >&2
        return 1
    fi
    if flock -n -x "$gpu_ownership_verify_path" true 2>/dev/null; then
        printf 'refused: the campaign lock is unheld: %s\n' \
            "$gpu_ownership_verify_path" >&2
        return 1
    fi
    if ! flock -n "$gpu_ownership_verify_fd"; then
        printf 'refused: descriptor %s does not hold the campaign lock: %s\n' \
            "$gpu_ownership_verify_fd" "$gpu_ownership_verify_path" >&2
        return 1
    fi
    return 0
}

gpu_ownership_require() {
    gpu_ownership_require_path=$(gpu_ownership_lock_path "${1:-}")
    if [ -z "${QWEN_GPU_OWNERSHIP_FD:-}" ]; then
        gpu_ownership_acquire "$gpu_ownership_require_path" || return $?
        QWEN_GPU_OWNERSHIP_FD=9
        export QWEN_GPU_OWNERSHIP_FD
    else
        gpu_ownership_verify_inherited "$gpu_ownership_require_path" || return 75
        printf 'gpu_ownership_lock=inherited fd=%s\n' "$QWEN_GPU_OWNERSHIP_FD"
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
            require) gpu_ownership_require "${2:-}" ;;
            *)
                printf 'usage: %s inspect|acquire|require [LOCK_PATH]\n' "$0" >&2
                exit 2
                ;;
        esac
        ;;
esac
