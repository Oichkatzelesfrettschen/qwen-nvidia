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
The open extension is the Vulkan-backend arms.

## Graded quality suite

`evidence/quality-roster-cuda/` grades all twenty-three servable rows in one
withheld-image sweep on this host's CUDA serving path, with
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
`scripts/test-gpu-workload-ownership.sh` carries eight fixtures over a fake
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

`evidence/credential-incident/` carries the condition set as booleans. The local
half is closed and the publication half waits on the operator's provider-side
deletions; `TASK_TRACKER.md` gains nothing further until `state.tsv` moves.

The ownership authority reaches the sweeps as well.
`run-cuda-baseline-sweep.sh` and `run-speculation-sweep.sh` refused on
`pgrep -x llama-server`, which a fixture's leftover stub satisfied while holding
no CUDA context; that refusal ended the first 4B campaign against a device only
the compositor was using. Both now call `gpu_ownership_require`, which takes the
lock where no ancestor holds it and inspects the driver's client list either
way, since flock is per-process and a nested sweep asking for the path its own
campaign holds would be refused by its parent.
