# Graft model and slot qualification

Status: harness calibrated; fresh device comparison is running with authenticated
kernel-reader access. Model and geometry selection remain pending.

The experiment separates hidden reasoning cost, checkpoint behavior, and slot
geometry. Structural Graft remains the interactive default. Deep arms use fresh
bounded graphs; the existing whole-tree cache remains outside the experiment.
PRs trailhq/Graft#521 and #522 remain deferred until model and geometry selection.

## Fixed inputs

- Source revision: `0c85040e3bda01913d687fca538b3fa49f6af82b`.
- Pilot paths: `sys/arch/rp2040/dev`, `sys/arch/rp2040/rp2040`.
- Historical denominator: 22 files, 243 describable symbols. A changed structural
  denominator stops comparison and requires an explicit source/extractor audit.
- Source accuracy: the ten symbol IDs in
  `../graft-deep-pilot/accuracy-sample.txt`. Review every summary's factual claims
  against the pinned source and callees; record supported, unsupported,
  contradicted, and withheld separately. An empty/missing summary fails coverage.
- Exact contract: capture the installed Graft client's named `record_symbols`
  requests, 8192-token cap, numbered source, targets and retry subsets. Grade wire
  replies with `record-symbols-contract.py`, keeping ungradeable extractor spans
  separate. The three-file scope adds `sys/kern/kern_mman.c` to `flash_swap.c`
  and `sig_machdep.c`; establish its IDs from the pinned structural graph.
- Incumbent: Qwen3.8-4B-Distill Q4_K_M. Candidates: pinned Qwen3.5-4B Q4_K_M
  and official Granite 4.0 Micro BF16. Quantization differs and belongs in every
  comparison; a BF16 result establishes that artifact rather than all Granite
  representations. Qwen3.5 runs text-only with its projector omitted explicitly.
- Submission geometry: batch 128, ubatch 32, six serving threads for every arm.
  Verify the live argv rather than inheriting a candidate's registry geometry.

## Arm order and decision gates

Run incumbent off/on/on/off at one slot and 16384 context, budget 512. The closing
off arm measures self-reproducibility and order drift. Run each candidate off
twice at that geometry, including the three-file contract scope. Then run the
qualifying incumbent/candidate at two slots, 32768 total context, `graft -j 2`,
twice from fresh graphs. Each slot retains 16384 positions. Compare repeated
per-ID summaries and raw calls across launches; report exact identity separately
from factual agreement. Extend repeats if a result needs a discriminating test.

An arm deadline is 1200 seconds. Capture the live server argv, source revision,
model digest, closure identity, GPU state at one-second intervals, wire request
and response JSON, guard telemetry, graph completion and teardown outcome.
Report requests/s as completed response count divided by the deep wall window;
report failed requests separately. Report prompt, completion, and reasoning
usage when the server supplies them, otherwise mark unavailable. Capture proxy
buffering belongs to every paired arm and does not establish unproxied latency.

Promotion requires all requested IDs ready with nonblank summaries, transport
and tool completion, source accuracy at least the incumbent under matched
conditions, reproducible factual conclusions, successful owned teardown, and
healthy runtime guards. A guard-aborted arm is void. Rate alone never promotes
two-slot serving. Any factual reversal in a fixed sample refuses promotion
pending a source-grounded discriminating measurement. General interactive
serving stays single-slot throughout qualification.

## Runner

Select `PYTHON` in the caller. Invoke `scripts/run-graft-model-arm.py` with
`--source`, `--model`, fresh `--output` under `.local-artifacts`, `--label`,
`--reasoning off|on`, `--slots 1|2`, and `--context 16384|32768`. The runner
selects `--scope pilot|contract` (pilot by default) and verifies its structural
denominator before opening the device. Contract scope contains three files and
seven describable symbols, reproduced by the pinned structural build. The runner
delegates GPU ownership to the serving chain and tears down only its launch
nonce. Raw credentials remain in the external serving state directory and
in-memory request headers; published evidence requires the repository sanitizer.

## Initial guard refusal

The initial incumbent thinking-off arm loads the model and verifies its requested
argv. The kernel-hazard watcher then exits because the restricted kernel reader
requires an authenticated sudo ticket. The serving supervisor stops the server
with `stopped_component=kernel_hazard_watchdog`, `kernel_hazard_status=1`.
The 50 subsequent Graft requests encounter failed transport. The arm is void;
its rates and summaries establish no model-performance or model-quality result.

The retained structural graph contains 22 files and 243 describable symbols,
matching the pilot denominator. The installed client requests 22 file records
alongside those symbols; wire grading keeps their span gradeability separate.
Regrading the retained wire reads 25 record_symbols attempts. Raw logs and the
classification receipt remain under `.local-artifacts/graft-model-slot-qualification`.

The harness preflight requires readable `dmesg` before loading another model.
The serving readiness check binds the watcher receipt to the launched server
PID so a prior ready line cannot admit a replacement watcher. `sudo -v` renews
the existing authentication boundary; the experiment changes neither the kernel
reader's permissions nor runtime-guard thresholds.

Clone-local calibration passes `test-graft-model-arm.py` and
`test-record-symbols-contract.py` with Python warnings treated as errors,
`test-qwen-capacity-policy.sh`, `test-qwen-session-signals.sh` including the stale
watcher receipt refusal, `test-gpu-workload-ownership.sh`, and
`test-qwen-runtime-guards.sh`. Targeted Ruff, ShellCheck at warning severity, and
`git diff --check` pass. The aggregate repository gate and device comparison
are separate gates: `repository-quality-gates.sh` completes with exit 0;
the clone-local CI run also passes. After the owner renewed the sudo ticket,
both `sudo -n -v` and `sudo -n dmesg --color=never` succeeded and the fresh
incumbent reasoning-off arm entered its bounded deep build. All six latest
`test-graft-model-arm.py` cases pass with Python warnings treated as errors.
Model selection, two-slot admission, and backports remain
outstanding; the production defaults retain their existing values.

`source-accuracy-rubric.md` records the fixed source discriminators and replay
queries before the fresh summaries are reviewed.
