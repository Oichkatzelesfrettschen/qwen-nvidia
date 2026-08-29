# The priority a runtime holds belongs to the runtime, not to its parent

`remote/qwen-exec-idle-priority.sh` sets nice 19 and the idle I/O class in its
own process, verifies both against the kernel, and replaces itself with the
command its argv names. `remote/image-service.py` spawns the pinned image
runtime through it and `remote/measure-dpm-force.sh` applies the same two
values to itself before its first arm.

## What the mechanism replaces

The image service spawned the runtime with `os.posix_spawn` and then called
`os.setpriority(os.PRIO_PROCESS, child_pid, 19)`. Those are two operations with
the child running between them, and what runs there is the runtime's Vulkan
instance creation and device enumeration -- the part of a generation that
competes with a resident language model for the same device. The wrapper closes
that window, because the value is in force before the runtime's first
instruction.

`posix_spawn` carries no priority attribute, and `preexec_fn` runs between fork
and exec in a threaded process, where subprocess(3) documents it as unsafe. A
child-side wrapper is what remains, and `exec` keeps the pid, the process group,
and the session, so the service's cancellation target and its `waitpid` are the
ones its own spawn recorded.

The DPM harness spelled its priority `nice -n 19 ionice -c 3` on each arm's
bench invocation. `nice -n` is an increment against the caller and `renice -n`
is relative where POSIXLY_CORRECT is set (renice(1), util-linux 2.42.2), so both
spellings reach 19 from a caller at nice 0 or above -- 19 is the ceiling and the
increment clamps to it -- and fall short of it from a caller at a negative nice.
`renice --priority` names the value absolutely under either setting, measured on
this host: from nice 1 with `POSIXLY_CORRECT=1`, `renice -n 10` lands at 11 and
`renice --priority 19` lands at 19.

## What the read-back proves and what it does not

The wrapper's own verification is the execution gate; the service's read-back is
an independent observation, and both read the kernel rather than the tool's exit
status. A `renice` that fails therefore reaches the refusal with the value the
process actually holds instead of ending the shell on `set -e`.

The read-back is bounded because the parent races the wrapper: a read taken
immediately after `posix_spawn` returns the inherited value. `wait_for_process_nice`
polls to a 1 second deadline, returns as soon as 19 appears, and otherwise
reports the last value it saw. An unreadable value now ends the job rather than
recording `nice: "-"` beside a successful generation, which is what the previous
`if observed_nice is not None and observed_nice != 19` admitted.

The idle I/O class is set and read back as the ioprio value the kernel holds.
The elevator decides what that class produces: BFQ acts on it and kyber does
not, and this host serves `$HOME` from an nvme device under kyber. The wrapper
establishes and proves the class; no run here measures an effect on I/O, and the
retained `harness_ioclass=idle` column states the class rather than a result.

## Falsifiers

`remote/test-exec-idle-priority.sh` runs thirteen checks and
`remote/test-image-service.py` carries two more.

| Fixture | Required result | Status |
| --- | --- | --- |
| Wrapper called from nice 5 | runtime records nice 19, idle | passes |
| `POSIXLY_CORRECT=1` from nice 5 | runtime records nice 19, idle | passes |
| Priority call fails | exit 125, no readiness marker, runtime unexecuted | passes |
| Absolute renice removed from the wrapper | exit 125, runtime unexecuted | passes |
| DPM harness called from nice 5 | every summary row reads 19 and idle, bench inherits 19 | passes |
| DPM priority call fails | exit 2 before the governor node is written, no arm runs | passes |
| Runtime's own first instruction | nice 19 and idle already in force | passes |
| Read-back against a wrapped child | 19 | passes |
| Read-back against an unwrapped child | the caller's own value, which the spawn refuses | passes |
| Read-back against a departed pid | unreadable | passes |
| Caller at a negative nice | runtime still reaches 19 | not run |
| Cancellation before the wrapper execs the runtime | process group disappears | not run |

The negative-nice arm is unrun because lowering a nice value requires privilege
this test declines to take. The remaining arms establish that the value is
absolute through the mechanism rather than through the caller's position:
`renice --priority` is measured absolute under POSIXLY_CORRECT above, and
removing it from the wrapper fails the fixture.

The cancellation arm is unrun because it has no non-flaky mechanism: the window
between `posix_spawn` returning and the wrapper reaching `exec` is not
addressable from the test. What the change makes true is structural rather than
measured -- `self.job.child_pid` is published immediately after `posix_spawn`
rather than after the read-back, so a cancellation arriving in that window
reaches the child instead of pid 0 -- and the post-exec cancellation arm the
suite already carries is unaffected.

## Evidence class

Fixture-verified rather than device-verified. Both hardened surfaces are pinned
to the other host in this tree: `measure-dpm-force.sh` writes
`power_dpm_force_performance_level`, which is an amdgpu node with no counterpart
here, and every `remote/image-profiles.tsv` row reads `refused` against a
RADV-pinned runtime. The change is source and fixture work, and no arm of it ran
against this host's device.
