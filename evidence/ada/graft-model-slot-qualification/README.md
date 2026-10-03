# Graft model and slot qualification

Status: bounded device comparison complete; the selection retains the incumbent
and single-slot serving. Backport integration remains pending.

The experiment separates hidden reasoning cost, checkpoint behavior, and slot
geometry. Structural Graft remains the interactive default. Deep arms use fresh
bounded graphs; the existing whole-tree cache remains outside the experiment.
`selection.md` records the decision that admits backport work on
trailhq/Graft#521 and #522 with a local synthesis-concurrency default of one.

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

## Supplied source and focal-span reporting

`scripts/audit-graft-wire.py ARM OUTPUT` supplements the existing ID/containment
grader. The audit reports full, partial, or absent source for requested symbols,
focal spans exceeding the prompt's approximate eight-line preference, and whole
definitions whose extractor references remain gradeable. The audit changes
neither the served prompt nor the existing containment verdict. Whole-definition
selection violates the prompt's focal-span instruction; eight lines is a
reporting threshold for the approximate preference rather than a schema limit.
Three offline calibration tests run with Python warnings treated as errors,
including an interrupted capture whose status remains explicitly incomplete.

The first healthy incumbent-off pilot supplies complete requested extractor
spans for 181 symbols, partial spans for three, and target metadata without
source for 59. Suspect extractor spans remain withheld from body-fidelity
claims; the last character-clipped line is conservatively partial. For example,
the USB request's source ends at line 522 while its target list extends through
line 1211. The same arm returns 110 spans over eight lines and 98 whole gradeable
definitions. These counts explain why full ready-node coverage and a tool reply
whose IDs match cannot establish source accuracy or focal-span compliance.
The fixed-source sample review remains mandatory for each model and geometry.

## Initial healthy matched pair

`measured-results.tsv` records completed arms only. The first incumbent pair
uses one slot, 16384 total context, identical 128/32 submission geometry, the
fixed source, and the same 45-request denominator. Reasoning-off completes in
267.931 seconds versus 367.050 on, a 27.0% wall-time reduction. Completion-token
counts are 25396 off and 37251 on; separate reasoning-token usage is absent from
every response. The on replies include nonempty `reasoning_content`, establishing
reasoning output without an exact reasoning-token attribution.

Both graphs have all 243 symbols ready and zero empty summaries. The ID and
containment grader fails one off request and three on requests; the on failures
include invented IDs that Graft ignores while accepting requested IDs. The
supplementary focal-span failures and source contradictions remain separate.
The fixed sample supports seven off summaries with two contradicted and one
unsupported, versus eight on with two contradicted. Neither arm qualifies a
semantic promotion. Candidate arms remain pending.

The reasoning-on repeat finishes in 369.660 seconds. All 243 symbol summaries
and cruxes match exactly. All 45 request JSON objects and response-message
content, reasoning content, and function payloads match after excluding response
IDs and timing metadata. The ten-symbol sample bytes also match, so the source
review applies unchanged. Repeatability establishes reproducible errors as well
as reproducible supported conclusions; it does not promote the configuration.

The closing off repeat finishes in 274.292 seconds and also reproduces all 243
symbol summaries/cruxes and all 45 request/response-message payloads exactly.
The off mean is 271.112 seconds versus the on mean of 368.355, a 26.4% wall-time
reduction. Every incumbent arm completes 243 symbols and 45 HTTP requests, with
successful owned teardown. The two replicates per setting establish the measured
bounded pilot comparison; broader workloads and concurrency remain separate.

Aggregate completion tokens divided by whole-build wall time are about 94.8/s
off and 101.5/s on, despite the on build taking longer. That ratio includes
reasoning/output work and prefill; it is not decode throughput. The opposite
ordering from requests/s demonstrates why aggregate tok/s cannot decide which
setting completes useful indexing work faster.

The first pair's summed server timings attribute 59.266 seconds to prompt
processing and 207.844 to decode off, versus 59.683 and 306.526 on. Those sums
leave less than 0.85 seconds of each measured deep window outside the reported
prompt/decode timers. The on response messages contain 42020 reasoning
characters versus zero off; character counts do not supply exact token counts.
The served model decodes about 122 tokens/s in either setting. The bounded cold
semantic pass is slow because it generates tens of thousands of tokens across
45 serial requests, not because the evidence shows substantial JavaScript
or graph-writing overhead. Model load, artifact verification, and the structural
preflight are outside the measured deep window. Fresh semantic caches and the
same structural preflight belong to every paired arm.

## Initial Qwen3.5-4B arms

The first Qwen3.5-4B Q4_K_M pilot finishes in 271.461 seconds with 48 successful
HTTP requests. All 243 symbols are ready, but the requested `fault.c` and
`mpu.c` file records remain pending after retries. Requests/s therefore includes
extra repair work and cannot be compared as useful throughput without the
completion denominator. Seven record_symbols attempts fail ID/containment
grading; some replies omit a file ID or invent a replacement ID during repair.
The sample supports nine summaries and withholds one vague resource-allocation
claim as unsupported. The focal audit finds 62 spans over eight lines and two
whole gradeable definitions. Better sampled accuracy does not override pending
requested IDs or focal-span failures.

The separate three-file contract finishes in 23.196 seconds with seven
successful HTTP requests, seven ready symbols and three ready file records.
All three record_symbols replies pass ID/containment grading. Two focal spans
exceed eight lines; zero whole gradeable definitions are returned. This scope
has no ten-symbol pilot sample and carries `NA` sample columns in the table.
The repeated pilot finishes in 271.044 seconds and the contract in 23.147.
Every pilot node's summary, crux, and summary state matches across 265 nodes,
including the two pending file records. The contract matches across all ten
nodes. All 48 pilot and seven contract request/response-message payloads match
after excluding response IDs and timing metadata. The identical pilot sample
permits source-review reuse. Granite's full-pilot tuple fails qualification as
recorded below.

Representative arms retain sanitized live server argv, loaded-closure hashes,
session status, and owned teardown receipts. `kernel-guard-readiness.log` is
explicitly a readiness-only publication view. Full kernel events remain in the
owning local artifact area because the monitor also captures unrelated device
identifiers. The readiness view establishes reader admission rather than the
absence of hazards; arm health classification reads the retained full guard and
telemetry logs. Publication filtering changes neither runtime guards nor raw
measurement records.

## Granite refusal and diagnostic rescope

Granite 4.0 Micro BF16 exceeds the registered 1200-second full-pilot deadline
with 111 symbols ready and 132 pending. Forty-three HTTP captures finish with
status 200; request 43 remains incomplete when cancellation closes the arm.
USB, `machdep.c`, and `swapram.c` attempts reach the context/output limit after
long plain-prose responses without parsed tool calls. The USB repeats generate
7801 tokens each and report `finish_reason=length`. The failed arm supplies
partial contract and source-coverage evidence, not a comparable requests/s rate.

The retirement helper drains admission, then escalates when the server exceeds
the 10-second TERM bound. Forced retirement returns status 1 and invalidates the
arm. The later observations establish absence of the four recorded session,
server, monitor, and kernel-reader PIDs and the port-8080 listener; the GPU
process query contains four desktop applications. The full drain/retirement
receipts remain retained. Current absence does not retroactively establish
orderly retirement. The full-pilot repeat remains unrun after that refusal.

Two independent short-contract arms discriminate the refusal from general tool
support. Both complete in about 43.4 seconds with orderly teardown. Each passes
`flash_swap.c` ID/containment grading but invents IDs instead of the requested
IDs for `sig_machdep.c` and `kern_mman.c`. The comparison therefore refuses
Granite promotion on exact contract/completeness evidence as well as the full
pilot's deadline and retirement failure. The failed pilot's four missing
fixed-sample summaries fail source coverage; their factual verdict is withheld.

The two-slot experiment measures the retained incumbent and the strongest
sampled candidate, Qwen3.5-4B, diagnostically even though their one-slot contract
residuals block promotion. Each gets two fresh 32768-total-context pilot arms
with `graft -j 2`. Every promotion gate remains in force. The diagnostic rescope
does not replace a failed model result with a successful fixture or weaken a
runtime guard. `selection.md` records the resulting single-slot decision.

## Two-slot results

Both incumbent arms complete all 243 symbols and 22 file records with 45 HTTP
responses. The mean deep window is 210.502 seconds, 22.4% shorter than the
one-slot off mean, with about 0.214 completed requests/s. The first source sample
supports nine summaries and contradicts one; the second supports eight and
contradicts two. The second `swap_cursor_init` summary invents a free-sector
search. Across 265 nodes, 166 summaries and 254 cruxes match; 30 request-matched
reply messages match. Faster execution therefore refuses semantic promotion.

Both Qwen3.5 arms complete all 243 symbols while leaving the `fault.c` and
`mpu.c` file records pending. The windows are 253.090 and 256.056 seconds,
about 0.189 completed requests/s. The samples support seven summaries each;
the first contradicts one and leaves two unsupported, while the second
contradicts two and leaves one unsupported. `usbgetc` changes from vague ring
draining to explicitly false transmit-ring draining. Across 265 nodes, 204
summaries and 240 cruxes match; 38 of 48 request-matched replies match.
The whole-definition counts rise from two in the one-slot Qwen3.5 pilots to
37 in each two-slot pilot. Geometry affects reply content and focal selection.

All four completed two-slot arms report successful owned teardown. Their full
private telemetry and session receipts carry the healthy execution classification;
the published readiness-only views establish kernel-reader admission. The
experiment leaves guard thresholds unchanged and records desktop latency as
unmeasured. Granite's failed retirement remains a separate failed receipt.
The short Granite contracts reproduce every graph field and all seven replies,
including their two exact-ID failures. Ready-node counts reflect Graft's
normalization and coexist with those wire failures.
