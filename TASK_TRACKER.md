# Task tracker

This file states this repository's open work on the current host: an AMD
Ryzen 5 5600X3D workstation carrying one NVIDIA GeForce RTX 4070 Ti, served
through the CUDA backend alone in the promoted closure `88681bf4d161`;
Vulkan arms run under the retained diagnostic closure `572951d25562`.
The settled operating configuration lives in `README.md`, repository doctrine
lives in `CLAUDE.md`, and `evidence/ada/` holds this host's own measurements.

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

The open extension is the Vulkan-backend arms.

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

`scripts/image-profiles.tsv` carries every profile at `execution_policy=refused`,
so `scripts/build-web-presets.sh` emits no image MCP configuration from the
checked-in ledger. The image runtime, build, and standalone harnesses that
depended on the prior host's driver were removed. Admitting an image profile
on this host requires a CUDA image runtime placing work on CUDA0,
a `scripts/image-profiles.tsv` row moved to `validator-gated`, and a fresh
admission run before any profile serves.

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

`patches/llama-cuda-mmvq-ncols-19.patch` raises `MMVQ_KERNEL_MAX_NCOLS` to
nineteen with the four coordinated edits, its twenty-column diagnostic form
measured the boundary, and `evidence/ada/mmvq-q8-b17-b20/`
measures Q8_0 at seventeen through twenty against the promoted closure: the
subject closure `8680bc95e989` clears the ten-repetition campaign's 6.3%
floor at every width (12.0, 10.2, 6.9, and 10.0%), launches
`mul_mat_vec_q<Q8_0, 17..20>` where the control launches `mul_mat_q`, holds
153 registers with zero local memory at twenty. Neither block run is promotion evidence: the
three-repetition run changed state between its controls and the
ten-repetition run's 6.3% span exceeds the preregistered 5.1% floor. The
alternating paired campaign under `gpu-quiescence-gate.sh` with the SM clock
pinned is: 86 observations, a 2.3% control span, and paired ratio medians of
1.136, 1.137, 1.088, and 1.053 at seventeen through twenty, so seventeen
through nineteen are admitted under the contiguous rule and twenty is not.
The selected threshold is nineteen. The shipped nineteen-column closure
`73af02b39194` launches MMVQ at nineteen and MMQ at twenty in the boundary
audit, carries no twenty-column instantiation, and leaves the SASS of Q8_0
one through sixteen identical to production; the co-resident alternating
tail campaign on that closure on the 0.8B and on the 2B production control
reads the threshold as a rate control, 60 pairs and 120 measured requests
per model with prefill and decode ratios at unity and a request-level gain
the tail's share bounds to about 1%, under the 5.1% floor, and as a refusal
on identity: the 0.8B reply ids differ between the closures at every
nineteen-column tail, first at position 31, 21, and 0, where the model's
top two candidates sit under 0.1 nats apart and the subject's MMVQ pass
replaces the control's MMQ pass, and agree at every twenty-column tail and
at every length on the 2B. The first two tail runs read identity through an
absent array and through a periodic prompt either kernel copies, and the
harness now requires the ids under `return_tokens` and cuts its prompts from
prose. The preregistered exact-identity gate is not met and is not relaxed,
so the threshold is not promotable under it and production stays at sixteen
on `88681bf4d161`. `QWEN_GPU_OWNERSHIP_FD` replaces the exported held-claim
marker: `gpu_ownership_require` proves an inherited descriptor is open on
the lock inode and holds the lock before a nested sweep inspects the driver's
client list, and `run-ad104-b789-calibration.sh` exports the descriptor it
locked to the baseline sweep each arm runs.

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
