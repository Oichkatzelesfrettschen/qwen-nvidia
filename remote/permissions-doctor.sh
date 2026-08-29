#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
    printf '%s\n' 'permissions-doctor: run as root' >&2
    exit 1
fi

render_node=/dev/dri/renderD128
card_node=/dev/dri/card1
radeon_icd=/usr/share/vulkan/icd.d/radeon_icd.x86_64.json
target_users='eirikr nick'

require_command() {
    command_name=$1
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf 'permissions-doctor: required command is missing: %s\n' "$command_name" >&2
        exit 1
    fi
}

for command_name in getent id runuser stat timeout usermod vulkaninfo; do
    require_command "$command_name"
done

for group_name in render video; do
    if ! getent group "$group_name" >/dev/null; then
        printf 'permissions-doctor: required group is missing: %s\n' "$group_name" >&2
        exit 1
    fi
done

for device_node in "$render_node" "$card_node"; do
    if [ ! -c "$device_node" ]; then
        printf 'permissions-doctor: DRM character device is missing: %s\n' "$device_node" >&2
        exit 1
    fi
done

if [ ! -r "$radeon_icd" ]; then
    printf 'permissions-doctor: RADV ICD is missing: %s\n' "$radeon_icd" >&2
    exit 1
fi

printf '%s\n' '[before]'
stat -c '%n %A %U:%G %a' "$card_node" "$render_node"
for target_user in $target_users; do
    id "$target_user"
done

for target_user in $target_users; do
    usermod --append --groups render,video "$target_user"
done

if [ "$(stat -c '%U:%G:%a' "$render_node")" != 'root:render:660' ]; then
    printf '%s\n' 'permissions-doctor: render node ownership or mode differs from root:render:660' >&2
    exit 1
fi

if [ "$(stat -c '%U:%G:%a' "$card_node")" != 'root:video:660' ]; then
    printf '%s\n' 'permissions-doctor: card node ownership or mode differs from root:video:660' >&2
    exit 1
fi

printf '%s\n' '[after]'
for target_user in $target_users; do
    user_home=$(getent passwd "$target_user" | cut -d: -f6)
    target_uid=$(id -u "$target_user")
    runtime_dir=/run/user/$target_uid
    id "$target_user"

    if [ ! -d "$runtime_dir" ]; then
        printf 'permissions-doctor: runtime directory is missing for %s: %s\n' "$target_user" "$runtime_dir" >&2
        exit 1
    fi

    for required_group in render video; do
        if ! id -nG "$target_user" | tr ' ' '\n' | grep -Fx "$required_group" >/dev/null; then
            printf 'permissions-doctor: %s is not a member of %s\n' "$target_user" "$required_group" >&2
            exit 1
        fi
    done

    probe_output=$(runuser -u "$target_user" -- env -u DISPLAY -u WAYLAND_DISPLAY \
        HOME="$user_home" \
        XDG_RUNTIME_DIR="$runtime_dir" \
        VK_DRIVER_FILES="$radeon_icd" \
        timeout 30s vulkaninfo --summary 2>&1)

    printf '[offscreen-vulkan:%s]\n%s\n' "$target_user" "$probe_output"

    if ! printf '%s\n' "$probe_output" | grep -F 'driverName' | grep -F 'radv' >/dev/null; then
        printf 'permissions-doctor: %s did not select RADV\n' "$target_user" >&2
        exit 1
    fi

    if printf '%s\n' "$probe_output" | grep -F 'deviceName' | grep -F 'llvmpipe' >/dev/null; then
        printf 'permissions-doctor: %s selected llvmpipe\n' "$target_user" >&2
        exit 1
    fi
done

printf '%s\n' 'permissions-doctor: both accounts can use offscreen RADV through the DRM render node'
