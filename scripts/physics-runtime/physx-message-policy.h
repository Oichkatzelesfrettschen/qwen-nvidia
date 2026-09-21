// Which PhysX diagnostic messages invalidate a simulation result.
//
// PhysX reports a GPU buffer that ran out of room through the error callback
// and then continues: the step completes, the result is returned, and the
// contacts that did not fit are simply absent. `strings` over
// /opt/nvidia/physx/bin/linux.x86_64/release/libPhysXGpu_64.so carries the
// messages verbatim -- "Contact buffer overflow detected, please increase its
// size in the scene desc!", "Patch buffer overflow detected", "Force buffer
// overflow detected", and "PxGpuDynamicsMemoryConfig::collisionStackSize
// buffer overflow detected, please increase its size to at least %u in the
// scene desc! Contacts have been dropped." -- and PhysX raises them at warning
// severity, which a callback filtering on PxErrorCode::eABORT and its
// neighbours never sees.
//
// A result assembled from a step whose contacts were dropped describes a
// different simulation than the one requested, so the message invalidates the
// run rather than annotating it. A kernel launch that failed produced no step
// at all and belongs to the same class.
//
// This header carries no PhysX dependency so the predicate compiles and is
// tested on a host without the SDK; scripts/test-physx-message-policy.sh
// drives it with the library's own strings on both sides.

#ifndef PHYSX_MESSAGE_POLICY_H
#define PHYSX_MESSAGE_POLICY_H

#include <cstring>

// The substrings every invalidating message in libPhysXGpu_64.so carries. The
// overflow reports vary in which buffer and which capacity field they name, so
// the fixed part of each sentence is what the policy matches.
inline bool physx_message_invalidates(const char* message) {
    if (message == nullptr) return false;
    static const char* const invalidating[] = {
        "overflow detected",
        "have been dropped",
        "overflowing initial allocation size",
        "Kernel launch failed",
    };
    for (const char* needle : invalidating) {
        if (std::strstr(message, needle) != nullptr) return true;
    }
    return false;
}

#endif  // PHYSX_MESSAGE_POLICY_H
