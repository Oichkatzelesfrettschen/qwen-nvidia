# Drain failure-boundary review and repairs

This record reviews source commit `792808f8ddf83a9bdeb0130d9b46861982c7df8e`
through isolated host fixtures. The working branch under review and the served
runtime remain unchanged. Every process used here is a shell or fake runtime;
no CUDA workload, model load, or device admission ran.

## Reproduced and repaired

Eight new boundary tests ran against the original implementation: seven failed
and one passed. The repaired implementation passes all eight, the original
eight barrier tests, and the controller's 25 readings.

| Boundary | Original result | Repair |
| --- | --- | --- |
| Failed destroy | Reopens admission | Preserve quiescence until explicit recovery |
| Drain deadline | Reopens with a holder still active | Preserve quiescence |
| Resume during active work | Opens admission | Require an exclusive in-flight reference |
| State publication | Replaces the locked inode | Publish on the same inode under its exclusive lock |
| Second state read raises | Leaks the acquired shared descriptor | Close every failed entry's descriptor |
| Unlock raises | Retains the descriptor | Close in finally and clear local ownership |
| Destroy child | Inherits the controller's exclusive descriptor | Close descriptor 9 in the child |
| Runtime exec | Descriptor is non-inheritable | Retain and test with close_fds disabled |

The state file is lock-protected data, not an executing script. Writing its new
value on the same locked inode is the synchronization contract. Source-script
edits in this worktree were separately published through atomic replacement.

## Mutation calibration

Restoring each original file in a temporary fixture copy changes the new suite
from accepted to refused. The Python barrier produces two failed readings,
the shell barrier one, and the controller four. `mutation-summary.tsv` and
its three logs retain those independent controls.

## Service regression environment

The remote command process inherits SCHED_IDLE. The existing priority wrapper
sets nice 19, then reads ps, which prints a dash for that scheduling class. The
first physics fixture therefore refused before its fake runtime. The rerun
changes only the test supervisor to SCHED_OTHER with nice 19; it changes no host
policy or service process. Physics and geometry report accepted, and the image
suite passes 39 tests. Both attempts and the scheduler declaration are retained.

## Remaining integration blockers

The crash fixture terminates the admitting supervisor while its ordinary child
continues running. The shared descriptor closes with the supervisor and the
controller reports orderly drainage while the child is still alive. The fixture
reaps its own processes afterward. `supervisor-crash.json` retains this result.
The repaired exception paths do not solve supervisor-death accounting; durable
operation identity and crash recovery remain required before device admission.

The three sidecars consult admission_barrier.require_admission, but neither the
LLM request path nor router-triggered model loads participates in this branch.
The controller alone therefore does not establish whole-session admission
closure. Source integration is required before a device run can verify it.

The destroy deadline is exported as QWEN_DRAIN_ESCALATION_MS; an arbitrary
command is executed directly. The caller contract, rather than the controller,
must establish bounded destruction and residue checks. The current controller's
zero exit status proves command success, not process/socket/device absence.

The optional-barrier behavior admits when barrier files are absent. An integrated
required mode and identity checks at the actual open descriptors remain design
obligations; the existing identity helper test does not establish that a service
calls it. These are promotion blockers, not admitted behavior.

## Scope

This is a source-only hardening candidate. It neither promotes the drain branch
nor changes the canonical runtime or any execution-policy ledger. The original
lease-orderly-drain worktree is preserved for its owner and external review.
