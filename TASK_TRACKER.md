# Task tracker

This file states this repository's open work on the current host: an AMD
Ryzen 5 5600X3D workstation carrying one NVIDIA GeForce RTX 4070 Ti, served
through the CUDA backend alone in the promoted closure `88681bf4d161`.
Vulkan serving and Vulkan admission campaigns are retired here; the retained
dual-backend diagnostic closure `572951d25562` runs by hand for a diagnostic
question and gates no CUDA work.

## Active contract

| Lane | Executes on |
| --- | --- |
| LLM inference | CUDA0 |
| Vision encoder and projector | CUDA0 |
| Image generation | CUDA0, through the CUDA-native `sd-cli` admitted in `evidence/image-appliance/cuda-runtime-admission/` |
| Physics simulation | PhysX with measured CUDA execution |
| Geometry and ray queries | OptiX over CUDA |
| CPU | orchestration, parsing, I/O, validation |

Automatic CPU fallback and automatic Vulkan fallback are refused: every served
launch runs `LLAMA_NO_CPU_FALLBACK=1` with `--device CUDA0` and
`-ot .*=CUDA0`, `QWEN_SERVING_BACKEND` takes `cuda` alone, and
`scripts/promote-llama-build.sh` refuses a closure carrying
`libggml-vulkan.so`. The graphics-latency probe stays as a narrowly named
Vulkan diagnostic exception until a replacement measures the same
desktop-responsiveness property. The workstation's own Vulkan libraries and
compositor are outside this contract.

## Program status

| Program | Recorded now | Advances next |
| --- | --- | --- |
| Uniform-format paged KV | P1, P2-A, and P2-C tail residency admitted on the 2B and the 0.8B, the 2B's served tuple measured under tails, default off (`evidence/ada/paged-kv-buffer/`, `evidence/ada/paged-kv-residency/`) | P2 stops here; typed pages and prefix sharing are separate programs |
| Typed or mixed-format KV | not implemented | kept separate from P2 |
| PhysX sidecar | runtime proof retained (`evidence/physics/d6-runtime-proof/`); the served physics turn admitted through `admit-sidecar-session.sh` under one lease contract with single-use grants, lease identity by device and inode, and bounded output (`evidence/physics/session-integration/run-07/`); profile `refused` | promotion of `physics-d6-chain-4` is its own policy transition, taken from the combined session record rather than from the lane alone |
| Multimodal handoff | SDK decode-to-resize proof retained (`evidence/nvidia-sdk/decode-resize-smoke/`); `patches/llama-mtmd-device-embd.patch` feeds the projector output to the language model as a device view over a batch-owned device copy, admitted on `qwen35-2b` and `lfm25-vl-450m` with identical bytes and tokens, then completed in run 04 (`evidence/ada/embd-handoff/`): every slice joined to its source rows across split ubatches and split decodes, consumer lifetime synchronized ahead of a batch free, and the recorder-off Nsight capture showing one device-to-device copy per batch and no host staging; off by default | a device-resident media input designed against `evidence/media/decode-placement/` (PNG is a CPU decode plus one upload, JPEG decodes through the hybrid nvJPEG backend, a CV-CUDA resize is a separate preprocessing contract), then a served vision tuple under the device path |
| CUDA image generation | `sd-cli` under `SD_CUDA=ON` admitted through the router (`evidence/image-appliance/cuda-runtime-admission/`); the reviewer calibrated on declared fixtures with a three-way constraint status and bound verdicts, where `qwen35-2b` passes eighteen arms and `lfm25-vl-450m` fails grounding (`evidence/image-appliance/vision-review-calibration/`); `image-sdxs-512-a` promoted to `validator-gated` with `review_model` `qwen35-2b` on the serialized generate-then-review record (`evidence/image-appliance/serialized-review-admission/run-05/`), whose serialization is sampled ordering under the image service's lease | the bound-one router shape, a second review in one session, and a load-path lease that makes the reviewer's load mutually exclusive with a generation rather than merely ordered |
| OptiX geometry | service, protocol, runtime, and device admission retained (`evidence/geometry/optix-ray-runtime-proof/`); the served geometry turn admitted alone and the shared-lease contention arm run against the physics lane, where both complete, the driver lists at most one runtime per sample, and the second holder states its `waited_ms` (`evidence/geometry/session-integration/`); profile `refused` | promotion of `geometry-cube-orbit-a` is its own policy transition; a PhysX-to-OptiX scene transfer is a separate typed-data integration rather than part of the combined session |
| Compute lease coverage | the lease admits one job among `image-service.py`, `physics-service.py`, and `geometry-service.py`; the promoted closure `88681bf4d161` reads neither lease name, so the new closure proves loading exclusion and evaluation exclusion rather than extending one; the candidate `patches/llama-server-vulkan-workload-lease.patch` opens and acquires at the top of `load_model` through `workload_lease_acquire_bounded` on a `QWEN_GPU_COMPUTE_LEASE_WAIT_S` deadline, leaves the decode pass its blocking acquire, refuses inactivity sleeping, synchronizes ahead of every release, and keeps the hold a refused unlock did not give back, reading `reach=accepted` under four mutation controls (`evidence/lease-coverage/`); the served stage accepted on the 2B at ten readings with its projector and partial on the 0.8B at the nine its projector-none tuple allows (`evidence/lease-coverage/served-admission/run-02/`), after `evidence/lease-coverage/shutdown-stall/` showed the refused arm's bound is one a lease-free binary reaches, which is a root cause identified rather than a shutdown path repaired; the historical source resolved unrecoverable at `historical_source_reconstruction=unavailable` beside `replacement_source_provenance=verified` and `historical_binary_regression=required`, with companion `fd27a84d9199` built and source/device-code isolation closed (`evidence/lease-coverage/companion-build/`) | the companion behavioral comparison, the historical binary regression, the drain-before-destroy device admission, the strict CUDA0 and router admissions with the production per-model speculation settings, the serialized image review, and the promotion that makes a served child read the lease, all before the combined session; `88681bf4d161` stays the rollback and regression reference and a rollback disables the lease-dependent behavior it compiles in no lease for |
| Combined session | each lane admitted alone: PhysX, OptiX, the CUDA image runtime with its serialized review, and the served LLM and vision path | the combined configuration itself, repeated use, contention between lanes, cancellation and recovery, and the final policy transitions that would promote any `refused` ledger row |
| Coding page arm | the classifier, the phase timeline, and the fixtures are merged (`evidence/coding-agent/page-arm-classification/`), so a refusal names its own termination reason | the intermittent itself, which needs an instrumented occurrence or a controlled reproduction naming the failing mechanism |
The settled operating configuration lives in `README.md`, repository doctrine
lives in `CLAUDE.md`, and `evidence/ada/` holds this host's own measurements.

## Retired programs

Vulkan admission is retired rather than deferred. This repository's serving
authority is CUDA alone, so validating the dual-backend closure outside
production would measure an inference backend the contract already closed:

```text
status=retired
reason=cuda_only_project_authority
diagnostic_artifact=572951d25562
blocks_cuda_work=no
```

`scripts/serving-closures.tsv` keeps `572951d25562` under the `diagnostic` role
for a hand-run diagnostic question, and it is a dependency of no CUDA work.
The graphics-latency probe keeps its narrowly named exception because it
measures desktop responsiveness on the graphics queue, and the workstation's
own Vulkan libraries and compositor stay outside the contract. A later
inference-backend campaign takes a fresh justification rather than this
program's name.

## Compute lease coverage

The compute lease admits one active device workload among the services that
take it, and llama-server sits outside that set. `image-service.py`,
`physics-service.py`, and `geometry-service.py` each take
`flock` on `$QWEN_GPU_COMPUTE_LEASE` across one job, and `sidecar_runtime.py`
`require_lease_identity` refuses a sidecar launch whose lease file differs from
the device and inode the session passed, so the identity check and the lock are
two steps of one sequence rather than one guarantee. `scripts/qwen-capacity-policy.sh:1210` exports one path under both
`QWEN_GPU_COMPUTE_LEASE` and the legacy `QWEN_VULKAN_WORKLOAD_LOCK`, and
`gpu-workload-ownership.sh:129` refuses a configuration naming two files, so
the name resolves to one lease for every participant that reads it.

The promoted closure `88681bf4d161` reads neither name.
`patches/llama-server-vulkan-workload-lease.patch` is a candidate at
`scripts/verify-llama-patch-series.sh:85`, armed under
`QWEN_LLAMA_CANDIDATE_PATCHES=1` alone, so the served language, vision, and
reviewer children evaluate and decode outside the lease. That patch also
leaves the loading paths uncovered where it is applied: `load_model()` calls
`common_init_from_params` at `server-context.cpp:1051` and
`mtmd_init_from_file` at `:1114`, both of which allocate and upload to CUDA0,
and reaches `init()` at `:1308` afterward, which is where the descriptor opens;
the acquire itself lives in the busy-slot branch of `update_slots`. A wake from
sleep runs `load_model` with `is_resume` true (`:963`), where the guard at
`:1307` skips the `init()` call at `:1308` and the function returns at `:1315`,
so a resumed model uploads its weights with no acquire at any point.

The patch now takes the claim in `load_model` instead, so the new closure proves
two exclusions rather than extending one: the load, and the ordinary evaluation
that follows it. The open runs first, since an acquire returns true while the
descriptor is closed and one moved on its own would admit every load while
reporting success. The two call sites take two acquires because the wait bound
belongs to the caller: a load has a caller that carries a refusal, so
`workload_lease_acquire_bounded` polls `LOCK_EX | LOCK_NB` every 50 ms under
`QWEN_GPU_COMPUTE_LEASE_WAIT_S`, 300 seconds by default and forwarded across
the tmux boundary by `qwen-webui-control.sh`, while a decode pass keeps the
blocking acquire because `server_queue::start_loop` re-enters
`callback_update_slots` only when a task arrives and a pass that gave up would
strand its request. One device step sits outside the hold and is named rather
than left to be found: `common/arg.cpp` calls `ggml_backend_load_all()` while
parsing argv, which under `GGML_BACKEND_DL=OFF` registers the statically linked
backends and enumerates the device without allocating or submitting.

Three properties of the lease's lifetime carry with it. Coverage is admitted
with inactivity sleeping disabled, and `load_model` refuses the configuration
naming a lease beside a non-negative `sleep_idle_seconds` ahead of the acquire
and of every upload; `server_queue::start_loop`'s `should_sleep()` returns false
for a negative interval alone, so sleeping is on at zero as well as above it,
and `handle_sleeping_state` turns a false return from the wake into
`GGML_ABORT("failed to reload model after sleeping")` at
`server-context.cpp:919`, so under sleeping a lease held past the deadline ends
the server rather than waiting for it; declining the wake instead needs
`on_sleeping_state` to carry a result rather than `void`. Release follows device
completion rather than a host return:
`workload_lease_sync_device` calls `llama_synchronize` on the target and draft
contexts ahead of the `all_idle` release and inside `destroy()`, which
synchronizes, frees, and releases last, once per ownership transition rather
than per token; a teardown from `~server_context_impl` arrives holding nothing
and takes the lease back for the frees with one non-blocking attempt, logging
which of the two it did. And the release reports what the kernel confirmed,
since `flock(LOCK_UN)` fails before it changes anything: a failure keeps
`workload_lease_held` true and latches one error line rather than reporting a
lease the kernel still holds as given back.

Teardown carries an exception rather than a fourth claim. `destroy()` takes the
lease back with one non-blocking attempt and then synchronizes and frees whether
that attempt won or lost, so an orderly teardown frees inside the lease and a
teardown arriving under another holder frees beside it. The CUDA driver
documentation permits a deallocation to synchronize implicitly, which is not an
application-level guarantee that this teardown joins the shared lease, and two
processes freeing their own allocations is not by itself a correctness failure,
so the contract reads:

```text
load, upload, and warmup exclusion   candidate claim, awaiting device admission
evaluation exclusion                 candidate claim, awaiting device admission
orderly teardown exclusion           holds where the teardown owns the lease
contended teardown                   explicit unprotected-cleanup exception
```

Closing it is a policy: ordinary router eviction and orderly session teardown
drain the active holder before destroying an idle child, and unleased cleanup
stays reserved for an emergency termination the record names. That policy is a
combined-session promotion gate, tested apart from the signal arms.

The real-caller integration is recorded in
`evidence/lease-coverage/runtime-drain-integration/`. Session stop and router
capacity eviction use the existing admission controller; telemetry restoration
binds the recorded owner, executable, argv, libraries and configuration to a
safe campaign cleanup. The router patch requires a new source/build identity.
The three retained runtime subjects keep their existing identities and evidence;
`15bc632adf7f` does not acquire the new router behavior through a script update.
`campaign.json` preserves both behavioral comparisons and separates the new
closure's build requirement from its pending orderly-drain device admission.

The integration closure is built as `821563144f34`. The first 2B companion-to-
candidate text comparison reproduced its control and matched all 12 token and
12 slot-state comparisons. The complete campaign exited 4 on telemetry
restoration: readiness exceeded the deadline, and later health verification
found a different loaded-library inventory. The campaign stopped; historical
regression, integration comparison and drain device admission remain pending.
`evidence/lease-coverage/companion-behavior-telemetry-restoration/` retains the
bounded numerical result and the separate restoration failure.

`scripts/test-load-lease-coverage.sh` reads `reach=accepted served=not_run`
against it. Fifteen synthetic bodies split each predicate, each written against
a demonstrated false positive rather than against its intent -- a `(void)` read
of the sleeping field, a synchronize in one function covering a release in
another, and a return nested inside the error latch all read as failures now --
and four mutations of the real patched file are each caught by their own
predicate and by no other. The seven served arms -- a load that waits, a decode
that waits behind a holder and resumes with no second request, a terminating
signal inside that decode wait, a load refused on its deadline, a fresh attempt
after that refusal, a terminating signal inside a load wait, and a
projector-bearing load -- need a built binary and a device window. Each is read
only after the `vulkan workload lease armed` line proves the closure carries the
patch, and the load arms read the `waiting` and `acquired` lines rather than
absence of health, because a server that ignored the lease and uploaded slowly
looks the same from outside. Every termination the harness performs runs one
bounded escalation -- signal, poll inside a named deadline, escalate to
`SIGKILL`, read absence back -- and a fixture holder that outlived it is a
counted failure
whose state is retained rather than removed. `QWEN_LEASE_EVIDENCE_DIR` names the
fresh directory a served run retains its sanitized logs, completion bodies,
outcomes, timeline, teardown states, and exit status into, and the terminal
line's `served_reason` separates `text_arms_only_projector_none` from
`projector_arm_not_run` so a text-path admission is never read as a multimodal
one.

The served arms ran on the device against `15bc632adf7f` on both the 2B and the
0.8B, and `evidence/lease-coverage/served-admission/run-02/` is the standing
result: `qwen35-2b` reads `served=accepted projector=required` on ten readings
with its own pinned projector, and `qwen35-08b` reads `served=partial` with
`served_reason=text_arms_only_projector_none` on the nine its projector-none
tuple allows. Loading exclusion and evaluation exclusion are therefore measured
rather than claimed on both sizes: a load waits 8910 ms behind a holder and then
serves, and a decode pass behind a holder submits nothing until the release,
with its own wait line as the evidence. Run-01's tenth reading refused the
closure and the criterion is what was wrong.
`evidence/lease-coverage/shutdown-stall/` names the bound that arm read: the
shutdown sits in `ctx_http.thread.join()` while cpp-httplib's listener joins
its workers and one worker waits inside `server_response::recv_with_timeout`
for a result of the task the interrupted pass launched and never answered, and
a completion's wait ends at `is_connection_closed`, so the client's own
departure is what releases it. Five arms measured that on the device: the
departure ends the shutdown in 1230 to 1340 ms, the holder's release moves
nothing, an untouched server exits 2.6 s past its own client's 20 s timeout,
and the promoted closure `88681bf4d161` -- which compiles in no lease at all --
holds the same join for 30.9 s with a generation in flight and leaves it 1.34 s
after its client departs. One thread sample names the chain frame for frame.
Arm G now ends its client before it reads the bound, which holds that server
property constant; what it establishes is that a lease wait does not prevent a
bounded termination, since its fixture holder takes the lock and opens no CUDA
context. `scripts/test-probe-lease-shutdown-stall.sh` drives the probe against
a client-bounded fixture and a lease-bounded one and requires the readings to
swap, so a probe reporting either cell alone fails. That re-run happened: under
the corrected criterion the 2B reads `ended 1s after the client left by=eintr
attached_exit=no` and the 0.8B `ended 0s`. Both are the harness's own
whole-second readings of process absence rather than a shutdown latency, and
the one microsecond interval the logs support is a different pair of boundaries:
`teardown: held=no` lands 426 microseconds after the cancel the client's
departure triggers, which marks the destructor's entry into its lease handling
while the device synchronize and the frees follow it, and the departure itself
carries no microsecond timestamp. Run-01 ended the same arm on the same binary
with `SIGKILL` at the 30 s bound.

The property the record accepts is bounded by the client rather than by the
signal:

> After the attached client departs, the candidate completes the tested
> interrupted-decode shutdown within the declared bound.

The unconditional reading -- that `SIGTERM` ends the process inside a bound
whatever requests are attached -- is what run-01's criterion asserted, and it was
never a validated property of the pinned server. Run-01's failure stands as the
run produced it. The lease patch keeps its contribution: its interrupted acquire
returns without posting `NEXT_RESPONSE`, which is how a task reaches the join
unanswered, and the production control establishes only that the resulting
shutdown behavior exists without the patch. It establishes neither that every
interruption path is equivalent nor that an unanswered task is harmless. The
control contributed timing and a log signature; the one thread sample came from
the candidate, so no stack was taken from the production arm.

Three outcomes stay separate:

| Property | Record |
| --- | --- |
| loading and evaluation exclusion | accepted on the measured 2B and 0.8B conditions |
| process shutdown after client departure | accepted in the tested interrupted-wait arms |
| per-request cancellation preserving the server | open, and a combined-session obligation |

The candidate closure `15bc632adf7f` is built and its source is known.
`scripts/reconstruct-closure-source.sh` replays the builder's own identity
procedure -- pin, apply in `verify-llama-patch-series.sh`'s order, stage, hash
`git diff --binary HEAD` -- inside a scratch clone, reconstructs a control ahead
of every subject, and refuses the run where the control misses, so an
environment change reports as a broken procedure rather than as a verdict.
`evidence/lease-coverage/source-provenance/` carries what it settled. The
candidate reconstructs exactly from the checked-in patch files, and the
lease-off companion is that sequence with the lease patch removed, differing by
`tools/server/server-context.cpp` at 331 insertions and no deletion in one file,
with the patch reapplied reproducing the candidate's recorded digest. The
historical production source is unavailable: twenty distinct historical patch
trees crossed with every candidate subset, over every git serialization setting
shown to move a digest, reproduce neither `88681bf4d161`'s `0d6e3be3` nor the
`689d3f35` the seven closures fourteen minutes earlier share, while the same
sweep reproduces the candidate's digest and the empty-tree value three closures
record. The negative covers eight closures of that day rather than the promoted
binary alone; that those trees were edited live and exported to patch files
afterwards is a hypothesis the timeline fits rather than a finding, since an
unreproduced diff is equally consistent with an export that lost bytes.

```text
historical_source_reconstruction   unavailable
replacement_source_provenance      verified
historical_binary_regression       required
```

Companion `fd27a84d9199` is built from `ca47669a`, with `build_exit=0` and
`runtime_execution=not_run`. `evidence/lease-coverage/companion-build/` records
one host source difference, zero device targets reached, and identical
module-normalized SASS across 8167 functions and 15052727 lines. Whole linked
binaries differ with their embedded build paths. The reader's twenty arms
discriminate sixteen of seventeen mutations; M07's keyed placeholder remains
unproven by an arm, while M07b tests the collision check.

`evidence/lease-coverage/admission-preparation/` binds the remaining comparisons
and records the execution prerequisites. Companion versus candidate attributes
behavior to the lease change. Historical `88681bf4d161` versus candidate checks
compatibility with deployed behavior. Both remain required, followed by separate
orderly session shutdown and capacity-one child-eviction device arms. The
controller and its fixtures are merged; launcher integration and real-child
transition evidence remain prerequisites to an orderly device verdict. The strict CUDA0 admission,
the router admission, and the serialized image review stay `not_run`, since the
served window was authorized for the served stage alone. The combined session
follows all of them.

## Depth validation

`scripts/probe-filled-depth.sh` fills and decodes on the CUDA path, and
`evidence/depth-validation-cuda/` carries the first campaign: all four
runtime classes validated at their registry ceilings (2B and 0.8B at 65536,
4B at 32768, 9B at 24576), plus the two coding rows (qwenseer-2b at 65536
covering the coding lane's 32768 floor, qwen25-coder-7b at 32768), each
with needle retrieval from the head of the fill,
the ledger rows in `scripts/validated-tuples.tsv`, and the registry claims
checked by `scripts/check-validated-tuples.sh`.

The second submission geometry is closed for all four runtime classes. Each
fills and decodes at its registry ceiling under batch 1024 and ubatch 256 as
well as under the served 2048 and 512, at the same `q8_0`/`q4_0` cache triple
with Flash Attention on, and each retrieves the needle planted at the head of
the fill: 65197 of 65536 on the 0.8B and the 2B, 32577 of 32768 on the 4B, and
24415 of 24576 on the 9B. Halving the submission size moves no ceiling on this
device, including the 9B where the compute buffer is the tightest, so the
served geometry is the registry's claim rather than the only geometry the depth
survives. `evidence/depth-validation-cuda/*/second-geometry/` carries the arms.

The claim is narrow by construction. The campaign moved batch and ubatch
together, so it establishes a second safe geometry rather than attributing the
result to either dimension, and it measured fill completion and needle
retrieval rather than comparative prefill throughput or the instantaneous
allocation peak. An orthogonal matrix separating 2048/256 from 1024/512
belongs to a performance or memory task rather than to filled-depth
validation. 2048/512 stays the served geometry and the registry's claim;
1024/256 is a validated alternate rather than a serving promotion.

Each ledger row now names the arm that proves it. `probe-filled-depth.sh`
emitted every row against the model directory whatever geometry ran, so the
served and second-geometry arms of one model resolved to one path and neither
identified its own result; `QWEN_PROBE_EVIDENCE_PATH` names the arm directory
and the run's own output directory is the default. `model-registry.sh`
requires a directory-shaped evidence path to hold a
`validated-tuples-rows.tsv` naming the tuple and a `filled-depth-summary.tsv`
carrying an accepted arm at the same model, depth, batch, and ubatch, which the
`tuple_evidence_binds_to_its_own_arm` fixture holds by moving one row's
evidence to another model's valid directory. Applying that binding found two
rows whose evidence did not identify them: the 7B's superseded 8192 arm, whose
summary the 32768 rerun overwrote in the same directory and which is recovered
from `bf73278` with a `prompt_n` matching its retained result exactly, and
`qwenseer-2b`, which carried no emitted row file at all.

The Vulkan-backend extension is retired with Vulkan serving:
`scripts/validation-classes.tsv` reads `retired` on every class, and the
rows measured under the Vulkan diagnostic selection stay in
`scripts/validated-tuples.tsv` as history.

## Graded quality suite

`evidence/quality-roster-cuda/` grades the twenty-three rows servable at its
run in one withheld-image sweep on this host's CUDA serving path, with
`lfm25-12b-thinking` re-run at a 4096-token budget as its own condition. The
code category places `qwenseer-2b` at 9 of 10 near 232 tok/s, which moved
the fast-coding role to it; the 4B Q5_K_M and Q6_K rungs hold 10 of 10 in
the deeper tier. Open work here is incremental: a new registry row takes
one graded arm inside its own sweep rather than a roster rerun.

## Coding lane

The full chain -- served WebUI, two single-use approvals, the coding MCP,
the coding-agent service under the qwen-coder principal, the pinned Qwen
Code v0.22.3, and the promoted llama-server -- is admitted with
`qwenseer-2b` at 32768 (`evidence/coding-agent/chain-admission/`, 36
checks), and `code-fast-a` with the `qwen-code` runtime row read
`validator-gated`. The deep-coder condition refuted itself at the 7B's
first-validated 8192 depth: Qwen Code's opening request measures
16275-18348 tokens. The RCA (`depth-8k-rca.md`) traced that 8192 to a
circular default -- the admission arm filled the entry boilerplate ceiling
rather than the row's declared 32768 target -- and the re-run validates
`qwen25-coder-7b` at 32768 (32539 of 32768, needle retrieved). The row's
ceiling and `validated_filled_depth` now read 32768 and `code-deep-a`
carries `maximum_context=32768`; the profile stays `refused` and its
re-entry gate moved: the rerun at 32768 fits the window (27212 and 28647
input tokens, no API error) and the 7B then printed a fenced JSON block
describing an `edit` call instead of emitting one, so the worktree went
unchanged. The gate is now a demonstrated structured tool-call emission
through this runtime rather than a deeper depth.

## Image lane

`scripts/image-profiles.tsv` carries one promoted row. `image-sdxs-512-a`
reads `execution_policy=validator-gated` with `review_model=qwen35-2b` on
`evidence/image-appliance/serialized-review-admission/run-05/`, so
`scripts/build-web-presets.sh` emits its image MCP configuration under
`QWEN_WEB_AUTHORIZER_READY=1` and every other row stays `refused` and emits
nothing under every setting. Promoting a second row takes a CUDA image runtime
placing work on CUDA0, the row moved to `validator-gated`, and its own
admission run.

What run 05 proves about serialization is sampled ordering under one service's
lease rather than kernel mutual exclusion across both participants. The run
served the promoted closure `88681bf4d161`, which carries no
`patches/llama-server-vulkan-workload-lease.patch`, so `image-service.py` was
the one lease holder and llama-server loaded the reviewer outside the lease
entirely. The reviewer's first appearance in the driver's client list 0.135 s
after an observed free-lease sample is a separation between samples at
7.39 Hz, and the page's own request order is what placed the review after the
generation. The bound-one router shape, a second review in one session, and a
load-path lease all stay unrun.

## CUDA runtime levers

`evidence/ada/cuda-runtime-levers.md` measures CUDA graphs, kernel fusion,
programmatic dependent launch, and the `GGML_CUDA_FORCE_MMQ` build arm on the
2B distill. `evidence/ada/cuda-runtime-levers-cross-class.md` closes the other
two classes through `scripts/run-cuda-lever-campaign.sh`, which runs each
subject profile between two adjacent default arms forward and reversed and
reads every ratio against that campaign's own default spread. The promoted
defaults hold on all three: graphs buy decode and cost prefill everywhere, with
the decode gain falling from 8.5% on the 0.8B to 1.7% on the 4B as a larger
model does more work per launch; fusion buys decode on every class with an
unresolved prefill direction; and PDL sits inside the drift floor on all three,
so it stays unset. One greedy fixed-seed completion per profile produced one
token digest per class, so every lever is a scheduling change rather than a
numerical-policy one. The `GGML_CUDA_FORCE_MMQ` build arm remains 2B-only.

## Quantized mat-mul dispatch

`evidence/ada/cuda-mat-mul-dispatch-census.md` reads
`ggml/src/ggml-cuda/` at `f280b2698` and states which conditions reach the
dense path; `evidence/ada/cuda-dispatch-census/` then measures them at
runtime. `ggml_cuda_should_use_mmq` admits twenty-two weight types
and every quantization `scripts/models.tsv` serves is inside that set, so the
dense cuBLAS path is reached by activation type and tensor shape --
`ggml-cuda.cu:1829` on a non-F32 `src1` or `dst`, `:1869` where all four
specialized predicates decline -- rather than by a weight type lacking a
kernel. IQ1_M is the one absent weight type a GGUF could carry. A planner keyed
on weight type would act on a condition this roster never presents.

The same census scoped the Q8_0 width arm, and that arm is closed against its
candidate. `mmvq.cuh:14` sets `MMVQ_KERNEL_MAX_NCOLS` to 16, held there by a
launch assert (`mmvq.cu:934`), the instantiation switch ending at
`mmvq.cu:1167`, and two `static_assert`s at `mmvq.cuh:15-20`.
`patches/llama-cuda-mmvq-ncols-19.patch` carries the four coordinated edits
that raise it to nineteen -- the constant,
`mul_mat_vec_q_switch_ncols_dst`, `calc_nwarps`, and `calc_rows_per_block` --
and `evidence/ada/mmvq-q8-b17-b20/` measures Q8_0 at seventeen through twenty
against production closure `88681bf4d161`. Register pressure was the falsifier
and it did not fire: the twenty-column instantiation holds 153 registers with
zero local memory, shared memory grows from 4096 to 5120 bytes against roughly
96 KiB per SM, and the SASS of Q8_0 one through sixteen is identical between
the closures. The pinned alternating campaign admitted seventeen through
nineteen at paired ratio medians of 1.136, 1.137, and 1.088 over a 2.3%
control span and refused twenty, and the Nsight boundary read observed
`mul_mat_vec_q<Q8_0, 19>` with `mul_mat_q` at twenty on the nineteen-column
closure. The served tails then refused the candidate on the preregistered
exact-token-identity gate: over 60 alternating pairs and 120 measured requests
per model the 0.8B reply parts from the control at every nineteen-column tail,
first at position 31, 21, and 0, where the control's top two candidates sit
0.014, 0.024, and 0.096 nats apart, and agrees at every twenty-column tail and
at every length on the 2B, which carries no Q8_0 weight. The tail is one MMVQ
pass of a request the control answers in about 30 ms, so the 8.8% the pinned
campaign measured there moves the request by about 1%, under the 5.1% floor:
the candidate offers nothing a request can read to trade a changed reply
against, and the gate is retained rather than relaxed. The 0.01-nat aggregate
tolerance proposed after the divergence is refused as underived,
retrospectively selected, and insufficiently specified, and its per-logit
reading fails on arithmetic, since 0.01 per logit admits 0.02 nats of pairwise
movement and the 0.024 and 0.096 nat witnesses exceed that. A bounded-numerics
admission class is deferred to a separately preregistered design. Q8_0 stays at
sixteen on `88681bf4d161`, the patch is registered as rejected in
`verify-llama-patch-series.sh` and applies to no tree a build reads, and
`build-llama-cuda.sh` still refuses an MMVQ threshold above sixteen.

`cuda-runtime-env.sh` names every backend environment variable that reaches
this dispatch, including the `GGML_CUDA_CUBLAS_COMPUTE_TYPE` override at
`ggml-cuda.cu:1634`. `GGML_CUDA_P2P` is the one it leaves alone, and peer
access between devices is what one card cannot express.

The runtime census is closed. `patches/llama-cuda-dispatch-census.patch` is
a default-off counter at the five leaf launchers and the four cuBLAS entries,
built into diagnostic closure `a925c84db3a2` at the promoted levers and kept
out of `build-appliance-current`; `scripts/run-cuda-dispatch-census.sh` ran
the 0.8B at Q8_0, F16, and BF16, the three Q4_K_M distills, and three
projector-loaded vision rows through it. Production text serving reaches
cuBLAS zero times at pp512 and tg64, so the general text cuBLASLt planner is
retired. The dense F16 and BF16 rows run their whole prefill on
`cublasGemmEx` because `ggml_cuda_should_use_mmf` refuses a dense weight above
sixteen columns, and BF16 reaches exactly the paths F16 reaches. The one
repeated material population is the vision encoder wherever the projector
file carries F16 weights: all 96 encoder mat-muls per image on
`qwen35-4b-base`, 27 `ffn_down` per image on LFM2.5-VL-1.6B, one reshaped
activation on the 450M. The next arm is the cheaper lever, a Q8_0 projector
for `qwen35-4b-base` timed against the F16 one, and a planner scoped to the
F16 encoder shapes earns implementation only where that timing shows the
cuBLAS share of request time worth it.
`qwen35-08b-bf16` was registered for that census as the representation
control beside the F16 row: `scripts/admit-representation-row.sh` admitted it
on the promoted closure through the publisher digest, the header, the pair
check, and one strict CUDA0 load
(`evidence/ada/representation-admission/qwen35-08b-bf16/`), at tier candidate
with its ceiling at 8192 and every rate field empty.

### The stream-K grid threshold

`evidence/ada/mmq-stream-k-grid/` closed the campaign across three phases and
`patches/llama-cuda-mmq-stream-k-grid.patch` is rejected. The patch gates the
tiling-efficiency threshold at `mmq.cuh:1436` on
`cc == GGML_CUDA_CC_ADA_LOVELACE` and defaults it to the upstream 90, and it is
inert at that default (`phase-a-null/`). Grid selection controls divisibility
and divisibility controls whether the fixup launch exists, 186 against 0
(`phase-b-witness/`), while removing every fixup costs 18.9% of the pass with
the direction splitting by tile class. Threshold 80 then changed the 2B's
emitted tokens at positions 16, 35, and 146 (`phase-c-identity/`), so the patch
lost the exact greedy token-identity gate the way
`patches/llama-cuda-mmvq-ncols-19.patch` lost it on the 0.8B. The fixup pass
reorders floating-point accumulation by construction, which is why identity was
tested rather than promised.

`scripts/verify-llama-patch-series.sh:175` names it on a `rejected_patch=` line
beside that one and `llama-cuda-mmq-fixup-pipeline.patch`, each carrying its own
reason: two patches changed the emitted tokens, and the third held identity,
passed compute-sanitizer, and moved no counter it was built to move
(`evidence/ada/mmq-fixup-pipeline/`). A rejected patch leaves the candidate
stack so the next `mmq.cuh` candidate builds on arithmetic this repository
still accepts. The threshold is a constant at the upstream 90:
`scripts/build-llama-cuda.sh:203` refuses `QWEN_CUDA_MMQ_TILING_PERCENT` at
every other value, and the field stays in the configuration record at 90, which
holds the identity of every closure the campaign retained.
`scripts/ad104-stream-k-matrix.tsv` retains the arm matrix
`run-ad104-path-audit.sh` read.

## Device ownership for depth campaigns

`scripts/gpu-workload-ownership.sh` is the authority the depth probes take, and
it answers two separate questions. An exclusive `flock(2)` on
`/tmp/qwen-ad104-gpu-0.lock` serializes this tree's own campaigns and is held
across server launch, cache fill, needle decode, server stop, and the post-arm
health reads. Device residency is answered by the driver:
`nvidia-smi --query-compute-apps` lists the processes holding a CUDA context and
each pid resolves through `/proc` to an executable path, a start time, and a
cgroup before it is classified -- the compositor recorded as the covariate this
workstation always carries, a project workload or an unnamed compute client
refusing, and a process merely named `llama-server` with no context recorded
rather than read as ownership. `pgrep` remains diagnostic output alone, which is
what it always was: reading it as the ownership authority is why
`probe-depth-projector.sh` intermittently refused against a device nothing held.
`scripts/test-gpu-workload-ownership.sh` carries nine fixtures over a fake
driver and a fake `/proc`.

The authority found two things on its first run. Microsoft Edge's GPU process
holds a CUDA context at about 98 MiB beside the compositor, which a
compute-app list reports and a process-name match never saw; browsers are
classified with the desktop because that context is rasterization rather than a
competing campaign. And a child inherits the open lock descriptor, so the
server, the dmesg follower, and the clock sampler each close it with `9>&-`: a
server outliving its probe otherwise holds the claim and the next campaign
exits 75 against a device nothing is using.

## Credential incident

`evidence/credential-incident/` carries the condition set as booleans. The
reachable history is sanitized and the provider-side deletions are done. The
remaining exposure was the cached pull-request ref, which retains a merged
PR's head commit independently of every branch and no push reaches: deleting
and recreating the repository purged `refs/pull/1/head` along with the eight
Nsight captures it reached, and a fetch of that commit by SHA now answers
`upload-pack: not our ref`.

The ownership authority reaches the sweeps as well.
`run-cuda-baseline-sweep.sh` and `run-speculation-sweep.sh` refused on
`pgrep -x llama-server`, which a fixture's leftover stub satisfied while holding
no CUDA context; that refusal ended the first 4B campaign against a device only
the compositor was using. Both now call `gpu_ownership_require`, which takes the
lock where no ancestor holds it and inspects the driver's client list either
way, since flock is per-process and a nested sweep asking for the path its own
campaign holds would be refused by its parent.
