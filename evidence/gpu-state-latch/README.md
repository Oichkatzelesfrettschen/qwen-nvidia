# The latch between a driver-level failure and the next launch

## What it answers

`scripts/watch-qwen-kernel-hazards.sh` matches `out of memory` in the kernel
ring and signals the server, so an NVRM allocation refusal already ends the
appliance. What had no guard was the relaunch: the device answers `nvidia-smi`
immediately afterward and its framebuffer counter reads free while the driver
has not finished reclaiming, so a launch started inside the same minute meets
state no counter here reports.
`evidence/quarantine/qwen38-9b-distill-router-load.md` records the consequence
-- a sweep that lost every one of fifteen rows after one refusal, where the
refusal itself had cost one.

`scripts/gpu-state-latch.sh` writes `gpu-state-tainted` into the session state
directory and `scripts/qwen-launch.sh` calls `require-clear` before anything
else runs, so the refusal is a refusal rather than a warning.

## Two severities because two recoveries exist

`allocation-refusal` is a refused allocation with no mapping, invalid-state,
Xid, or reset signature beside it. The device keeps answering, so its own
reclaim is what the gate waits on and measurement clears the latch.

`reboot-required` is everything else the watcher fires on: `NV_ERR_INVALID_STATE`,
`dmaAllocMapping`, `mapping_reuse`, `mmuWalkMap`, an `NVRM Xid`, a fallen-off-bus
record, `RmInitAdapter failed`, a GPU reset, a ring timeout, a VM fault, or a
device loss. Those name driver state this tree holds no measurement for, so the
taint file records the running boot id and the latch clears when the running one
differs. A gate run against that class is refused rather than attempted.

An `allocation-refusal` taint does not clear on a boot. The class states which
recovery answers it, and a boot answers only the class whose recovery is a boot.

## The recovery gate

Each stage is an observation rather than a wait, and the stage that fails names
itself:

- `no_server`: no `llama-server` process remains.
- `no_compute_clients`: `nvidia-smi --query-compute-apps` returns nothing.
- `device_answers`: `nvidia-smi -q` succeeds.
- `counters_stable`: framebuffer and BAR1 occupancy repeat across four samples
  two seconds apart. A counter still moving is the driver still reclaiming, and
  that window is what the latch exists to keep a launch out of.
- `ring_quiet`: the hazard signature count in the ring is equal across a fifteen
  second interval. It is counted twice rather than tailed, because the reader
  may be the `sudo -n dmesg` path and a follow would outlive the gate. An
  unreadable ring is a refusal rather than a pass, since a blind gate clears
  nothing, and the refusal names `sudo -v` as the unblock: an
  `allocation-refusal` taint survives a boot by design and a fresh boot holds no
  sudo timestamp.

`grep -c` prints its count and still exits 1 when that count is zero, which is
the state a clean boot is in, so both readers take the count from the output and
discard the status. The `|| printf 0` that shape invites appends a second line
to a record this tree is meant to read later.
- `cooldown`: a bounded twenty seconds after every check passed.

## Falsifiers

- A launch admitted while `gpu-state-tainted` names a class the running boot id
  matches refutes the gating.
- A `reboot-required` taint cleared by `recover` refutes the severity split.
- An `allocation-refusal` taint cleared by a boot alone refutes the same split
  from the other side.
- A hazard line naming an Xid classified as `allocation-refusal` refutes the
  classifier.

`scripts/test-gpu-state-latch.sh` runs each of those as an arm. The classifier
arms drive `watch-qwen-kernel-hazards.sh` itself against a ring fixture and a
process the test owns, and `launch_refuses_tainted_state` drives
`scripts/qwen-launch.sh` rather than the latch alone, because a check wired into
a launch that discards its status refuses nothing. The latch runs ahead of the
already-running process check, so that arm holds while the appliance serves and
the launch ends on the latch's own status.

## What is unrun

The recovery gate against a real refusal. Every arm in the test covers the
taint vocabulary, the boot-id rule, the launch refusal, and the classifier; the
gate's six stages are exercised on the appliance alone and no run has driven
them after an actual `NV_ERR_NO_MEMORY`. Whether `counters_stable` and
`ring_quiet` are the right observations -- rather than the pinned-page,
page-table, or BAR1-mapping counters
`evidence/quarantine/qwen38-9b-distill-router-load.md` lists as candidates for
the refused pool -- is open until a switch-time instrumentation campaign names
the resource. The gate waits on what this host can read.

## An unexplained stop keeps its evidence

The watcher truncated its log at every start, so the run that ended a server
left no record of which ring line it fired on once the next launch began. One
generation is now retained at `kernel-hazards.log.previous`. A server that
exits 0 with `stopped_component=server` and no retained hazard line is the
state this tree could not read on 2026-08-29, when a launch ran 57 seconds and
ended through llama-server's own `cleaning up before exit` handler with no
kernel signature in the same minute.

## One spurious taint, and what wrote it

The latch fired once against a session that had no hazard: the taint read
`class=reboot-required reason=kernel-hazard` while `kernel-hazards.log` carried
no `hazard_utc` line, the kernel ring carried no NVRM line in the preceding half
hour, and the server the watcher guards was alive, unsignalled, and answering
`/health`.

`watch-qwen-kernel-hazards.sh` had been edited in place while that watcher was
running it. `sh` parses a script incrementally by byte offset, so the running
interpreter resumed at an offset the rewrite had moved and reached the taint
call without the match that gates it. The device state was never in question;
the guard's own text was.

The fix is the write rather than the guard: an edit to a script the running
appliance owns is written to a temporary file and renamed over the target, which
replaces the inode and leaves the running process on the one it opened.
CLAUDE.md carries that rule. The arm is retained here because a latch that can
be set by an editor rather than by the device is a latch whose every reading has
to be checkable, and the three observations above are what checked this one.
