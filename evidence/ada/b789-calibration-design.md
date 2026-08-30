# Preregistration: the AD104 B7/B8/B9 calibration

This record is written before the run and before the reboot that precedes it,
which is what makes the result readable as a test rather than as a summary. It
states what the calibration measures, what would refute each expectation, and
what the run needs that this tree does not yet hold.

## The blocker

B7, B8, and B9 name nothing in this repository. No script registers them, no
evidence file defines them, and `docs/APU_UPSTREAM.md` records no scope cut that
mentions them. The arms they stand for -- an MMVQ-against-MMQ crossover, a DP4A
against INT8-MMA comparison, a BAR1 or virtual-address failure chain -- are
readings of the name rather than a definition of it.

The calibration therefore takes its matrix from a file rather than from a
constant. `scripts/run-ad104-b789-calibration.sh` refuses to run without one and
names this record as the reason. Supplying that file, or the preregistration it
derives from, is what unblocks the run; inventing the three arms here and
calling them the registered matrix would put a fabricated definition in the
place a real one belongs.

Everything below holds whatever the three arms turn out to be, because it is the
run's own discipline rather than its content.

## What the clean boot is for

The device has carried, across one session: repeated overlapping high-allocation
loads, 69 distinct seconds of the terminating NVRM `nv_gpu_ops.c:5077` chain, 34
seconds of `_kgmmuClientShadowFaultBufferPagesAllocate` retries, several SIGKILL
terminations, and relaunches inside the reclaim window.
`evidence/quarantine/qwen38-9b-distill-router-load.md` records the pool the
refusals name and states that the resource is unresolved. A calibration measured
on that state cannot separate a kernel-policy effect from accumulated driver
state, which is exactly the confound the clean boot removes.

The reboot therefore precedes the run, and `scripts/gpu-state-latch.sh` gates
every launch after it.

## Preconditions the runner enforces

- The GPU state latch reads clear.
- No `llama-server` and no CUDA compute client holds the device.
- The promoted binary's SHA-256 and the llama.cpp revision are recorded before
  the first arm. At the time of writing those are
  `c51daa95fe2fc4086264e4694f0d7a10d1e8207184d3d6cdf2a01ed8538b6e4a` for
  `llama-bench` and revision `f280b2698`; the runner records what it finds
  rather than asserting these.
- Every checkpoint the matrix names exists on disk. The K-quant ladder rows
  `qwen38-4b-i1-q2k`, `qwen38-4b-i1-q5km`, and `qwen38-4b-i1-q6k` are registry
  rows whose artifacts are absent; `scripts/download-qwen38-4b-distill-i1-*.sh`
  fetch them, and the fetch runs before the reboot rather than after it, since a
  download is not a use of the clean state.
- The desktop compositor is a covariate this host carries rather than a
  condition it excludes, so its occupancy is recorded before the first arm and
  after the last.

## Run discipline

Each arm runs through `scripts/run-cuda-baseline-sweep.sh`, which already owns
the properties a kernel-policy comparison needs: the served tuple rather than
llama-bench's defaults, `-ot .*=CUDA0` placement under `LLAMA_NO_CPU_FALLBACK=1`
so a host placement is a refusal rather than a silent halving, three repetitions
per arm, and each checkpoint measured at position i and again at position n-i so
the paired mean is reported and the forward-to-reverse span is the sweep's own
instability. `scripts/sample-nvidia-clocks.sh` records SM clock, memory clock,
temperature, power draw, both utilisation counters, occupancy, and the throttle
reason once a second beside every arm.

The span is what makes a difference readable. `evidence/ada/cuda-runtime-levers.md`
measures forward-to-reverse spans of 0.0 to 2.4% on this host, so an arm
separated by less than its own span reports position in the sweep rather than a
kernel policy. A calibration that reports a 1% effect against a 2% span reports
unresolved direction, and this record says so ahead of the run.

Clock and power policy is left where the host sets it: 285 W, persistence mode
disabled, application clocks deprecated on this driver. The device moves its own
state under its power and thermal budget rather than on a driver ladder, which
is why the sampler records the state beside the rate instead of pinning it.

## Output equivalence

A kernel-policy change that alters the reply is not a throughput result. Every
arm answers the same prompts at temperature 0 with `top_k` 1, and each arm's
reply is compared character-for-character against the matrix's control arm.
`evidence/ada/speculation-runtime-classes.md` established that discriminator and
also its limit: a near-tie argmax flips under a different batch shape, so a
divergence in the final tenth of a reply is a different observation from one at
character 33. A diverging arm is reported with the divergence position rather
than dropped.

## Stop conditions

The run halts and retains what it has when any of these appears:

- the GPU state latch is set by the hazard watcher during an arm;
- a new `NV_ERR_NO_MEMORY`, mapping, invalid-state, Xid, or reset signature
  enters the kernel ring between arms;
- `nvidia-smi -q` stops answering;
- an arm's `llama-bench` emits other than exactly one `pp` row and one `tg` row,
  which the tree already treats as `n/a` and a failed ladder rather than half a
  pair.

An arm that halts the run leaves the remaining arms unrun and named as unrun.
The run is not retried on the same boot after a driver-level signature, since
that is the state the clean boot exists to exclude.

## Post-arm controls

- The opening arm is repeated as the closing arm. Agreement between them
  licenses reading the interior arms as kernel-policy effects rather than as
  position in a warming device; disagreement makes the drift the finding.
- The device health check runs after the last arm: latch clear, ring quiet,
  counters returned to the compositor-only baseline.
- The router is restored afterward and its `/health` and roster are recorded, so
  the calibration ends with the appliance in the state it started from.

## What this record does not claim

Any expected direction for B7, B8, or B9. The expectation belongs to their
definition, and stating one here would preregister a prediction about arms whose
content is unknown. When the matrix arrives, its expectations and falsifiers are
appended to this record before the run rather than after it.
