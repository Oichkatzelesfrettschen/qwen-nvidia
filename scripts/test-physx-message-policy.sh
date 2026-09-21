#!/bin/sh
set -eu

# Admit scripts/physics-runtime/physx-message-policy.h without the card and
# without the SDK: a driver compiled from the header alone classifies the
# messages libPhysXGpu_64.so carries, formatted the way PhysX hands them to the
# error callback, against benign messages from the same library. Where the SDK
# is installed the test also reads each policy substring back out of the
# library, so an upgrade that rewords an overflow report fails here rather than
# silently returning results assembled from dropped contacts.

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
header=$script_directory/physics-runtime/physx-message-policy.h
host_cxx=${QWEN_HOST_COMPILER:-/usr/bin/g++-15}
physx_prefix=${QWEN_PHYSX_PREFIX:-/opt/nvidia/physx}
gpu_library=$physx_prefix/bin/linux.x86_64/release/libPhysXGpu_64.so
work_directory=$(mktemp -d "${TMPDIR:-/tmp}/physx-message-policy.XXXXXX")
trap 'rm -rf "$work_directory"' EXIT INT TERM

checks_total=0
checks_failed=0
check() {
    checks_total=$((checks_total + 1))
    if [ "$2" = pass ]; then
        printf 'check=%s outcome=pass\n' "$1"
    else
        checks_failed=$((checks_failed + 1))
        printf 'check=%s outcome=FAIL detail=%s\n' "$1" "${3:-}" >&2
    fi
}

[ -r "$header" ] || {
    printf 'the policy header is absent at %s\n' "$header" >&2
    exit 1
}
command -v "$host_cxx" >/dev/null 2>&1 || {
    printf 'physx_message_policy=not-run reason=no_host_compiler compiler=%s\n' "$host_cxx"
    exit 0
}

cat >"$work_directory/driver.cpp" <<'CPP'
#include "physx-message-policy.h"

#include <iostream>
#include <string>

int main() {
    std::string line;
    while (std::getline(std::cin, line)) {
        std::cout << (physx_message_invalidates(line.c_str()) ? "invalidates" : "admits")
                  << '\t' << line << '\n';
    }
    return 0;
}
CPP
"$host_cxx" -std=c++17 -Wall -Wextra -Werror \
    -I"$script_directory/physics-runtime" \
    -o "$work_directory/driver" "$work_directory/driver.cpp"

# The messages PhysX formats and hands to the callback when a GPU buffer ran
# out of room. Each is the library's own sentence with its placeholder filled.
cat >"$work_directory/invalidating.txt" <<'BAD'
Contact buffer overflow detected, please increase its size in the scene desc!
Contact buffer overflow detected, please increase its size to at least 262144 in the scene desc!
Patch buffer overflow detected, please increase its size in the scene desc!
Patch buffer overflow detected, please increase its size to at least 81920 in the scene desc!
Force buffer overflow detected, please increase its size in the scene desc!
PxGpuDynamicsMemoryConfig::collisionStackSize buffer overflow detected, please increase its size to at least 67108864 in the scene desc! Contacts have been dropped.
Particle system contact buffer overflow detected, please increase PxGpuDynamicsMemoryConfig::maxParticleContacts to at least 4096
Deformable surface contact buffer overflow detected, please increase PxGpuDynamicsMemoryConfig::maxDeformableSurfaceContacts to at least 4096
Deformable volume contact buffer overflow detected, please increase PxGpuDynamicsMemoryConfig::maxDeformableVolumeContacts to at least 4096
PxgPinnedHostLinearMemoryAllocator: overflowing initial allocation size, increase capacity to at least 16777216
Kernel launch failed - register resource overflow. Error: 701
BAD

# Messages from the same library that report no lost state. The partition line
# is the near miss the policy has to admit: it warns, and it drops nothing the
# result is assembled from.
cat >"$work_directory/benign.txt" <<'GOOD'
PxgConstraintPartition: attempting to remove an edge from an empty partition. Skipping.
PxgAABBManager::processFoundPairs: found null elements!
PxArray::allocate: allocator returned null pointer.
GPU kernel launch completed
the scene desc names a broad phase
increase its size
contacts
GOOD

"$work_directory/driver" <"$work_directory/invalidating.txt" >"$work_directory/invalidating.out"
admitted=$(awk -F '\t' '$1 == "admits" { print $2 }' "$work_directory/invalidating.out")
if [ -z "$admitted" ]; then
    check every_overflow_report_invalidates pass
else
    check every_overflow_report_invalidates fail "$(printf '%s' "$admitted" | tr '\n' '|')"
fi

"$work_directory/driver" <"$work_directory/benign.txt" >"$work_directory/benign.out"
refused=$(awk -F '\t' '$1 == "invalidates" { print $2 }' "$work_directory/benign.out")
if [ -z "$refused" ]; then
    check no_benign_message_invalidates pass
else
    check no_benign_message_invalidates fail "$(printf '%s' "$refused" | tr '\n' '|')"
fi

printf '' | "$work_directory/driver" >"$work_directory/empty.out"
if [ ! -s "$work_directory/empty.out" ]; then
    check empty_input_classifies_nothing pass
else
    check empty_input_classifies_nothing fail "$(cat "$work_directory/empty.out")"
fi

# The policy's substrings are read back out of the shipped library, so an SDK
# upgrade that rewords a report fails here instead of passing a run whose
# contacts were dropped.
if [ -r "$gpu_library" ]; then
    missing=
    for needle in 'overflow detected' 'have been dropped' \
        'overflowing initial allocation size' 'Kernel launch failed'; do
        if ! strings "$gpu_library" 2>/dev/null | grep -qF "$needle"; then
            missing="$missing$needle|"
        fi
    done
    if [ -z "$missing" ]; then
        check policy_substrings_present_in_sdk pass
    else
        check policy_substrings_present_in_sdk fail "$missing"
    fi
else
    printf 'check=policy_substrings_present_in_sdk outcome=not-run detail=%s\n' "$gpu_library"
fi

printf 'physx_message_policy checks_total=%s checks_failed=%s\n' "$checks_total" "$checks_failed"
[ "$checks_failed" -eq 0 ]
