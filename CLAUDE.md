# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

`~/AGENTS.md` loads through the user memory and supplies the shared baseline.
This file holds the repository doctrine and wins inside this tree.

## The repository runs on one machine

The Git tree and the runtime share a host. A `scripts/` script executes from the
checkout it is edited in, so an edit takes effect on the next invocation and no
copy step stands between the two. The directory keeps its name because the
diff that renamed it would swamp the work it carries; read `scripts/` as "the
scripts the appliance runs" rather than as a second machine.

An edit takes effect on the next invocation only where it replaces the file
rather than rewrites it. `sh` parses a script incrementally by byte offset, so a
truncating in-place write reaches the interpreter of a process already running
that file and it resumes parsing at an offset that now holds different text. A
guard edited while the appliance serves has executed code no line of its own
logic reached: editing `watch-qwen-kernel-hazards.sh` under a live session wrote
a `reboot-required` taint with no hazard line in its log, no NVRM line in the
ring, and the server it guards never signalled. Every edit to a script the
running appliance owns is written to a temporary file and renamed over the
target, which replaces the inode and leaves the running process on the one it
opened.

That host is a workstation rather than an appliance, so the desktop is a live
consumer of the same device every measurement runs on. `nvidia-smi` reports the
compositor holding about 2.5 GiB of the 12 GiB carve-out and issuing graphics
work at rest, which is a covariate of every recorded rate rather than a
condition to exclude.

This repository derives from the `qwen-apu` appliance tree. Its history begins
at a parentless commit whose tree equals `qwen-apu` commit
`55d8c73268d8c6496e77baaad732e1aea7a6183b`. The prior host's evidence carries
authority only inside `qwen-apu`; here it is retained as prior-host comparison
under `evidence/legacy/raven2/`. `docs/APU_UPSTREAM.md` states the
relationship and lists the capabilities that carry no CUDA counterpart yet.

## Hardware sets every ceiling in this repository

AMD Ryzen 5 5600X3D, six Zen 3 cores at 3.3 GHz with twelve threads and 96 MiB
of L3, 31 GiB of DDR4, and one NVIDIA GeForce RTX 4070 Ti: AD104, compute
capability 8.9, 12282 MiB of GDDR6X on a 192-bit bus, driver 610.57.04 with
CUDA 13.3. `scripts/build-llama-cuda.sh` builds one binary carrying the CUDA
and Vulkan backends, so `llama-bench --device` selects between them and two
rows differ by the backend alone. That script executes no artifact it built and
ends on `runtime_execution=not_run reason=build_only`, because llama-bench calls
`ggml_backend_load_all()` ahead of parsing argv and a closing `--version` print
therefore opened a CUDA context inside a compile; case 30 of
`scripts/test-gpu-workload-ownership.sh` reads that claim out of every
`non-gpu-helper` row rather than trusting the ledger.

CUDA is the serving backend and Vulkan is the fallback the same binary reaches.
That inverts the APU tree, where Vulkan was the only accelerated path the device
offered, and it changes which ceiling binds: device memory rather than memory
bandwidth. A 12 GiB carve-out with 2.5 GiB already resident holds one 9B Q4_K_M
trunk, a 0.8B draft, and two KV caches with little room over, so every paired
serving arm states its resident total before it runs.

`CMAKE_CUDA_ARCHITECTURES=89` emits one SM89 SASS variant plus compute_89 PTX
for driver JIT and `cuobjdump`. The compact local-serving arm selects `89-real`
explicitly and emits SASS alone.
`GGML_CUDA_FA_ALL_QUANTS=ON` is required rather than optional: `scripts/models.tsv`
serves every row at `cache_type_k=q8_0` with `cache_type_v=q4_0`, and the
default CUDA build compiles flash-attention kernels for a subset of KV type
combinations that excludes a mixed pair, so a default build leaves the served
cache triple off the flash-attention path at run time. nvcc reads
`crt/host_config.h` and refuses a host compiler newer than GCC 15 where the
distribution default is GCC 16, so the whole tree builds with `g++-15`.

`scripts/sample-nvidia-clocks.sh` records SM clock, memory clock, temperature,
power draw, both utilisation counters, device memory occupancy, and the active
throttle reason beside every rate, one row per second. A rate whose operating
state went unrecorded is not comparable to a later one, and on this device the
state moves under its own power and thermal budget rather than on a driver DPM
ladder.

`scripts/run-cuda-baseline-sweep.sh` measures each checkpoint forward and again
in reverse, so the same checkpoint meets both ends of whatever drift the sweep
carries and the paired mean is the reported figure. Every arm runs through
`cuda-runtime-env.sh` and names its placement `-ot .*=CUDA0`, which is the
placement `qwen-capacity-policy.sh` gives the server: at `-ngl 99` alone the
scheduler left enough of the 9B on the host to halve its prefill, 2183.61
against 4410.81 tok/s, while decode moved 1.1%
(`evidence/ada/baseline-sweep-02/`). The wrapper's `LLAMA_NO_CPU_FALLBACK=1` is
what makes that placement observable rather than silent, since llama-bench
without `-ot` is refused outright.

| Checkpoint | prefill tok/s | decode tok/s |
| --- | ---: | ---: |
| Qwen3.5-0.8B Q8_0 | 22769.94 | 310.50 |
| Qwen3.8-2B distill Q4_K_M | 14748.05 | 231.37 |
| Qwen3.8-4B distill Q4_K_M | 6703.23 | 113.54 |
| Qwen3.8-9B distill Q4_K_M | 4410.81 | 67.91 |

Four runtime levers are measured on the 2B and two are refuted.
`evidence/ada/cuda-runtime-levers.md`: CUDA graphs buy 7.6% of decode and cost
6.1% of prefill, fusion buys 5.8% of decode, programmatic dependent launch
moves 0.2% against a 0.3% span, and a `GGML_CUDA_FORCE_MMQ=ON` build moves 0.7%
because the flag is unreachable on this device: `mmq.cu:320` reads it eight
lines below a `turing_mma_available(cc)` return that already fires at compute
capability 8.9, and the dispatcher consults `ggml_cuda_should_use_mmvq` first
with no escape on that path. That 0.7% is the build-to-build noise floor.
`ggml_cuda_should_use_mmvq` carries the crossover this device does obey, tuned
on an RTX 4090: Q4_K and Q5_K leave MMVQ above seven columns, Q6_K above eight,
Q2_K above four (`mmvq.cu:295-306`). That crossover is observed rather than
derived. `mmvq.cu:544` declares `template <ggml_type type, int ncols_dst, ...>
__global__ void mul_mat_vec_q`, so an MMVQ launch demangles to
`mul_mat_vec_q<(ggml_type)12, (int)7, ...>` and names the quantization type and
the column count of the mat-mul second operand in the symbol itself.
`scripts/run-ad104-path-audit.sh` profiles one prefill per arm under Nsight
Systems, reads the launches out of `CUPTI_ACTIVITY_KIND_KERNEL`, and refuses an
arm whose executed family differs from the matrix expectation;
`evidence/ada/b789-path-audit/` carries seven arms that agree, including the
mixed forward pass where Q4_K runs MMQ beside Q6_K on MMVQ.
`GGML_CUDA_FORCE_CUBLAS` is the one build-time flag that reaches the same
decision, at `mmq.cu:260`, and `QWEN_FORCE_CUBLAS=ON` builds that tree.
Two candidate-patch levers move a dispatch threshold from
`scripts/build-llama-cuda.sh`. `QWEN_CUDA_MMVQ_Q6K_MAX` and
`QWEN_CUDA_MMVQ_Q8_0_MAX` ride cmake cache entries, because
`llama-cuda-mmvq-crossover-ad104.patch` carries a
`ggml/src/ggml-cuda/CMakeLists.txt` hunk bridging each entry into a compile
definition. Both enter the configuration digest, so two closures differing by
one threshold carry different build directories and different names. The Ada
MMQ stream-K tiling threshold was a third such lever and is now a constant at
the upstream 90: its patch lost the identity gate, so the builder emits no
tiling define on any tree and refuses `QWEN_CUDA_MMQ_TILING_PERCENT` at every
value beside 90 rather than serving the control under a subject request. The
field stays in the configuration record at that value, which holds the identity
of every closure the campaign retained.
The serving default is graphs on, fusion on, PDL unset, cuBLAS free to take
what it wins.

A launch on this device costs about a microsecond before it moves a byte, and
that figure bounds every lever that removes launches rather than bytes.
`evidence/ada/projection-fan-out/` reads it out of two kernels whose traffic is
far under one wave, so their whole recorded duration is the fixed cost:
`quantize_q8_1` at 0.970 us and the `ssm_alpha`/`ssm_beta` `mul_mat_vec_q`
launches at 1.221 us, agreeing to within 64 ns between the 2B and 0.8B captures.
Node granularity is what makes those durations readable and it is not free:
against its own graph-granularity capture it stretches 2B device time 2.25% and
0.8B device time 2.10 times, so a duration read from a node capture is corrected
against the graph arm of the same run rather than taken as measured.

Every checkpoint this tree serves declares `qwen35.full_attention_interval` of
4, so `src/models/qwen35.cpp` builds a full-attention layer one time in four and
a linear-attention layer otherwise. The two shapes fan one normalized activation
out to different weight sets -- `wq`, `wk`, `wv` in the first, and `wqkv`,
`wqkv_gate`, `ssm_beta`, `ssm_alpha` in the second -- and
`ggml_cuda_mul_mat_vec_q` quantizes its own second operand on every call
(`mmvq.cu:1332`) with no cache, so a fan-out of N issues N quantize launches
holding byte-identical buffers. What bounds a merge of those launches is the
weight type rather than the fan-out width, since `mul_mat_vec_q` is templated on
one `ggml_type` (`mmvq.cu:544`): `attn_qkv` is Q6_K against Q4_K for the rest of
its group on the 2B, 4B, and 9B, and `attn_v` splits the attention group the same
way on the 4B and 9B, while the Q8_0 0.8B merges every member of both. Merging
everything the types allow removes 123 to 163 launches per token and buys 4.63%
of the 0.8B token, 3.08% of the 2B, 2.00% of the 4B, and 1.20% of the 9B, so the
lever is refuted against the 5.1% floor on all four and no kernel implements it.
That bound is computed at `ne11` of 1; a concurrent-sequence or
speculative-accept workload moves these mat-muls to MMQ and recomputes it.

Stream-K is the MMQ decomposition on this device rather than a decision:
`ggml_cuda_mmq_get_config` at `mmq.cuh:247-249` routes every NVIDIA part at
Volta or later into the Ampere table and all 352 of its `CASE` rows set
`stream_k` true. What varies at run time is the grid at `mmq.cuh:1436`, which
takes the destination tile count where tiling efficiency reaches 90% and the
multiprocessor count otherwise, and `fixup_needed` at `mmq.cuh:1440`, which
holds where the tile count fails to divide that grid and launches
`mul_mat_q_stream_k_fixup` at `mmq.cuh:1463` over the partial tiles
`write_back` sent to `tmp_fixup` at `mmq.cuh:936`.
`patches/llama-cuda-mmq-stream-k-grid.patch` made that 90 a build-configured
value on Ada Lovelace alone and `evidence/ada/mmq-stream-k-grid/` carries the
three phases that closed against it. The patch is inert at its own default
(`phase-a-null/`), grid selection controls divisibility and divisibility
controls whether the fixup launch exists, 186 against 0 (`phase-b-witness/`),
and removing every fixup costs 18.9% of the pass while the direction splits by
tile class. Threshold 80 then changed the 2B's output at tokens 16, 35, and 146
(`phase-c-identity/`), so the patch is rejected on exact greedy token identity
the way `evidence/ada/mmvq-q8-b17-b20/` rejected the MMVQ width, and
`scripts/verify-llama-patch-series.sh` names it on a `rejected_patch=` line
beside that one. The fixup pass reorders floating-point accumulation by
construction, which is why identity was tested rather than promised.
`scripts/ad104-stream-k-matrix.tsv` retains the arm matrix
`run-ad104-path-audit.sh` read for the campaign.

A move of that crossover is measured as pairs.
`scripts/run-mmvq-paired-crossover.sh` compares two llama-bench closures width
by width and `scripts/run-mmvq-width-request-tails.sh` asks the same question of
the served path, each alternating which closure runs first so drift and order
bias cancel inside the pair, each observation admitted by
`scripts/gpu-quiescence-gate.sh` against the client set and counter medians
registered at the start of the campaign. Both refuse below four pairs with exit
2 ahead of the ownership claim and either launch, since `statistics.quantiles`
needs four points and the control-drift slices coincide below that, and both
summaries carry `sample_count_valid`, `promotion_eligible`, and
`ineligibility_reason` beside `clears_floor`, so a sample too small to decide
reads `n/a` and `insufficient_pairs` while a measured absence of gain reads `no`
and `below_floor`. `scripts/probe-mmvq-tail-logit-margin.sh` reads the distance
in nats between the top two candidates at one named position per prompt, and it
compares the two closures only where both reached that position under the same
preceding token history, because two free-running greedy samplers that have
already parted condition their later logits on different prefixes.

That harness measured one candidate and rejected it. Q8_0 serves at sixteen on
closure `88681bf4d161`, which is the kernel ceiling `MMVQ_KERNEL_MAX_NCOLS`
sets, and `patches/llama-cuda-mmvq-ncols-19.patch` raises that ceiling to
nineteen. The pinned alternating campaign admitted seventeen through nineteen
on rate, the Nsight read confirmed `mul_mat_vec_q<Q8_0, 19>` with MMQ at
twenty, and the served tails refused the candidate on exact greedy token
identity: the 0.8B reply parts from the production closure at every
nineteen-column tail where its top two candidates sit under 0.1 nats apart.
The whole-request gain the tail's share allows is about 1%, under the 5.1%
floor, so the identity clause decides it and the gate is retained rather than
relaxed. `evidence/ada/mmvq-q8-b17-b20/` carries the record.
`verify-llama-patch-series.sh` names the patch on a `rejected_patch=` line and
applies it to no tree unless a caller sets both
`QWEN_LLAMA_CANDIDATE_PATCHES=1` and `QWEN_LLAMA_REJECTED_PATCHES=1`, which
runs `apply --check` alone; `build-llama-cuda.sh` still bounds an MMVQ
threshold at sixteen, so no build or launch reaches nineteen.

Speculation is where the throughput is. A resident 0.8B draft loses on every
class here -- 0.42, 0.61, and 0.75 of baseline on the 2B, 4B, and 9B --
while the multi-token-prediction block each distill already ships wins on all
three at 1.23, 1.42, and 1.47 for 150 to 470 MiB
(`evidence/ada/speculation-runtime-classes.md`). `QWEN_SPEC_TYPE=draft-mtp`
reaches every router child, which `evidence/ada/cuda-router-mtp/` verifies by
the absence of the `model has unused tensor` lines an ordinary load prints. The
forward-to-reverse span is this host's own instability and it is measured
rather than assumed, because a desktop compositor sharing the device is a
covariate this host carries and a prior host did not.
`evidence/legacy/raven2/comparative-findings.tsv` retains the prior host's own
span figures as comparison alone.

A default here changes when a measurement on this host moves it, and
`evidence/ada/` holds those measurements. A device-derived verdict from
`qwen-apu` -- a kernel-ring hazard, a quarantine row, a bandwidth-bound
K-quant ladder -- carries no authority on this device until it is re-measured
here; `evidence/legacy/raven2/` retains those verdicts as prior-host
comparison.

The registry rather than a constant sets the admitted depth.
`scripts/models.tsv` carries `context_default`, `context_ceiling`, and
`context_target` per checkpoint along with the KV cache types and the
flash-attention setting, and `qwen-capacity-policy.sh` reads them.
`QWEN_CACHE_TYPE_K`, `QWEN_CACHE_TYPE_V`, and `QWEN_FLASH_ATTN` override the
cache triple, so an experiment arm runs through the served path rather than
through llama-bench alone. Any override changes the allocation tuple and must
also set `QWEN_CACHE_OVERRIDE_CONTEXT_CEILING` to a positive depth measured for
that exact tuple. The override ceiling cannot exceed the checkpoint registry
ceiling. A ceiling never exceeds a depth measured to fail.

An allocation and a validated depth are two claims and the registry carries them
as two fields. `context_ceiling` is the depth the policy admits;
`validated_filled_depth` is the deepest depth measured to fill and decode under
the row's own cache triple, Flash Attention state, `batch`, and `ubatch`. A
server that loads a 24576-token allocation has proven it can reserve the memory
and has not proven a near-full cache executes, so `qwen-capacity-policy.sh`
prints the gap between the two fields on its `depth_validation` line at every
launch. Submission geometry belongs to the same claim: `batch` and `ubatch` are
registry fields rather than constants in the argv, because a depth that fills
under one submission geometry can fail under another on the same model and
cache triple. `evidence/legacy/raven2/comparative-findings.tsv` retains the
prior host's own geometry-versus-depth finding as comparison; no arm on this
device has yet run it.

`models.tsv` carries one `validated_filled_depth`/`batch`/`ubatch`/cache/Flash
Attention tuple per row, which cannot state that one submission geometry
passes at a depth where another fails for the same model and cache triple.
`scripts/validated-tuples.tsv` carries every measured arm instead, keyed by
`tuple_id`, with `model_id`, `runtime_mode`, the submission geometry, the cache
triple, `threads`, `parallel`, `projector_state`, `backend`, and `status` over
`validated`, `failed`, or `unverified`. A `validated` row requires its
`evidence` path to exist in the tree; a `failed` row carries the same fields
and belongs in the ledger because a rejected geometry is what steers a later
choice away from it. `scripts/model-registry.sh tuples MODEL_ID` and
`tuple TUPLE_ID [FIELD]` read the ledger after validating every row in it, the
same discipline `emit_servable_rows` applies to the quarantine authority.
`scripts/probe-filled-depth.sh` names its backend through `QWEN_PROBE_BACKEND`,
`cuda` by default or `vulkan`, which resolves the device, the tensor override,
and the runtime wrapper together at the `default` profile; the device has to
belong to that backend, the ledger backend is what the load banner proved
rather than what the environment asked, and an emitted `tuple_id` carries the
backend as `MODEL-BACKEND-dDEPTH-bBATCH-ubUBATCH`, so one model measured on
both backends yields two distinct rows. Rows retained ahead of that change keep
their unqualified ids.
`scripts/check-validated-tuples.sh` derives the tuple each `models.tsv` row with
a numeric `validated_filled_depth` already claims and requires a `validated`
ledger row matching model, depth, batch, ubatch, and cache triple; a gap
between the two files fails the gate rather than serving silently. No row in
this tree yet carries a numeric `validated_filled_depth`, so the gate has
nothing to check until a depth arm runs here.

`check-validated-tuples.sh` maps a `projector` field of `required` onto an
expected projector state of `loaded`.
`scripts/probe-depth-projector.sh` measures the tuple those rows need. It reads
one registry row, resolves the projector through `select-projector.sh` in the
model's own directory, and runs llama-server standalone at the row's cache
triple and submission geometry with the projector attached. A probe request
measures the template and image overhead `/tokenize` cannot see, since that
route tokenizes text and the projector writes image tokens inside the chat
pipeline, and padding measured through `/tokenize` closes the remainder. The
acceptance window is asymmetric because decode follows the fill inside one
allocation: an arm passes on `DEPTH - 2% <= prompt_n <= DEPTH - 32`, where a
prompt at or above the depth evicts rather than decodes. Each arm ends on the
question `bars.png` declares the answer to, so a projector that stopped
encoding into the language model's embedding space fails the control and halts
the chain. A healthy arm emits an appendable ledger line carrying
`projector_state=loaded` beside its evidence directory rather than into
`scripts/validated-tuples.tsv`, because a `validated` row requires its evidence
path to exist in the tree.

The `tier` field states what is claimed about a row and
`scripts/build-router-presets.sh` turns it into what the picker offers.
`production` is a serving tuple measured safe and useful; `candidate` leaves
quality or performance unqualified with no device failure under its admitted
tuple; `quarantine` names a reset, fault, device loss, correctness hazard, or
the absence of any validated safe tuple; `archive` is a valid artifact displaced
or too slow to serve; `rejected` lost admission on measurement without being
dangerous. Only `production` and `candidate` reach the preset file.

Tool selection and tool execution are two claims and the registry carries them
as `raw_tool_selection` and `guarded_tool_execution`. The first is the graded
tool category, the model unaided. The second states whether the row may execute
a tool, over `refused`, `validator-gated`, and `unguarded`. `tool-08` puts an
instruction inside the note the user asks about and all six measured arms
carried the injected city into the call in place of the authorized one, so a
row earns `validator-gated` only from a runtime that compares emitted
arguments against the user's own authorization. Reading one number for both
misleads in both directions: the 2B distill scores 2 of 10 and still serves
text as the `fast-text` default, and the 4B distill scores 9 of 10 while
failing the one row an execution grant exists to survive. The coding lane is
the one such runtime this tree holds -- the coding-agent service verifies a
single-use HMAC grant field by field against live workspace and job state
before anything executes, inside the qwen-coder principal's containment --
and `qwenseer-2b` reads `validator-gated` on the strength of the full-chain
admission `evidence/coding-agent/chain-admission/` retains. Every other row
reads `refused`: the appliance still runs without `--tools` and llama-server
itself executes nothing.

The failure unit is a tuple rather than a checkpoint, so `scripts/quarantine.tsv`
carries two scopes. A `model` row removes a checkpoint entirely; a `profile` row
removes one tuple of a checkpoint that otherwise serves, and
`qwen-capacity-policy.sh` refuses to construct that tuple rather than warning
about it. `evidence/quarantine/` holds one reason record per row with its kernel
signature, its validated safe tuples, and its re-entry gate.
`model-registry.sh servable-ids` and `servable-files` apply the same
router-child exclusions to the registry's default tuple, and an unreadable
or malformed quarantine registry stops router and standalone tuple
construction. Each query validates and consumes one opened quarantine snapshot,
so a replacement cannot separate semantic admission from the rows acted upon.
Profile depth, batch, and ubatch fields use canonical positive decimal integers
without leading zeroes because the runtime builds exact string tuple keys. A
research override labels every
exposed excluded tuple `quarantine` and withholds the `default` tag.
`QWEN_ROUTER_INCLUDE_QUARANTINE=1` exposes a quarantined checkpoint for research.
The generated preset records that override, and `qwen-capacity-policy.sh`
derives the listener restriction from the file on every later launch. It
refuses generated presets that predate the marker and forces an exposed preset
to `127.0.0.1`, because the appliance binds `0.0.0.0` and a warning alone would
put a model with a recorded device failure on the LAN.

Three mechanisms guard the quarantined tuple because two paths construct one
and router presets persist across registry changes. `qwen-capacity-policy.sh`
refuses the tuple on the single-model path, where the policy builds the argv the
server runs. `build-router-presets.sh` filters router-child rows while generating
the child geometry, and `test-model-tiers.sh` checks that generation. Router
startup queries the same quarantine authority and rejects a persisted section
that a later model- or profile-scope row excludes. It also rejects sections
whose registry tier moves to `archive` or `rejected`, and a `quarantine` tier
requires model-scope authority. The marked research override admits authorized
quarantine sections and forces the listener to loopback. Every persisted
quarantine section retains exactly one `LLAMA_ARG_TAGS` key that contains
`quarantine` and excludes `default` and every conflicting tier tag; startup
rejects a stale tag set before the server runs.

`scripts/build-web-presets.sh` generates a second preset file from
`scripts/web-profiles.tsv`, where a section is named for a profile rather than a
checkpoint and several profiles serve one checkpoint at depths the profile
chooses. Its head marker `# qwen_web_presets=1` switches
`qwen-capacity-policy.sh` to resolve each section through its `LLAMA_ARG_MODEL`
path against the unique `model_file` column and to bound `LLAMA_ARG_CTX_SIZE` by
`context_ceiling` rather than pin it to `context_default`. A preset persists
across a registry edit, so the launch bounds that depth again by the row's
current `validated_filled_depth` and refuses a `-` outright unless the preset
carries the unvalidated-depth marker; a registry that lowers the field would
otherwise leave an unmarked section serving a depth no run has filled and
decoded. A preset also persists across an edit to the ledger, so the launch rejoins each
section to `scripts/web-profiles.tsv` by its `profile_id` and requires the row to
exist, to carry an emitting `execution_policy`, and to carry the same policy the
section's `LLAMA_ARG_TAGS` claims; a row moved to `refused` or removed outright
refuses the launch rather than serving the persisted MCP configuration.
`execution_policy`
decides emission: `refused` emits nothing under every setting, `validator-gated`
emits a section carrying `LLAMA_ARG_MCP_SERVERS_CONFIG` only under
`QWEN_WEB_AUTHORIZER_READY=1`, and `ui-mediated` emits a section naming no
configuration because the UI performs the retrieval. Every checked-in row reads
`refused`, so the generator against the shipped ledger emits nothing and says
so. Every row still meets the registry join, the copied-field comparison, the
tier rule, and the ceiling rule before that gate, so the ledger is validated
whole and an edit to one row's `execution_policy` changes what emits rather
than turning a previously successful ledger into an error. The `# qwen-web-presets: unvalidated-depth-override` marker forces the
listener to loopback the way the quarantine marker does, and
`scripts/qwen-web-launch.sh` binds 127.0.0.1 with `QWEN_ROUTER_MAX=1`, refuses
a caller who asked for any other listener, and reads every
`LLAMA_ARG_MCP_SERVERS_CONFIG` and `LLAMA_ARG_MMPROJ` path its sections name,
since router mode reads a projector only when a request selects that child.
`QWEN_WEB_REVIEW_SECTION` raises both to two for one named section, which
`qwen-image-launch.sh` sets to the review-only vision section an image row's
`review_model` produces; the broker still signs for the one language profile,
so the review section is subtracted before the profile is read.
`multi_source` reads `yes` exactly where `max_fetches` exceeds one, because the
emitted configuration carries the fetch budget alone.

Router mode leaves depth, cache triple, and submission geometry off its own
argv. `server-models.cpp` ends its preset assembly with
`preset.merge(base_preset)` and `common_preset::merge` overwrites, so a router
CLI argument replaces the same key in every model section: passing `--ctx-size
24576` served the vision row at 24576 where its section named 16384. Every
section therefore carries all six keys, since an absent one falls through to the
llama.cpp defaults of batch 2048 and ubatch 512, which is the quarantined
geometry.

Router startup still selects the largest installed servable GGUF as the
resident-memory preflight subject. The launcher copies the source preset to a
unique active-session snapshot, reads every section's model path from that
snapshot, and selects the largest installed artifact as the load-observation
subject. Normal and research presets therefore use the exact set they can
launch rather than separate registry enumerations. The launcher records the
snapshot SHA-256 and forwards both path and digest across the tmux boundary.
The capacity policy validates the current model and quarantine authorities and
records their SHA-256 identities. After the Vulkan wrapper configures the final
environment, `qwen-router-exec-guard.sh` remeasures the preset and both registry
identities immediately before it replaces itself with llama-server. A
terminating launch signal tears down a session whose control start has begun,
removes the launcher-owned snapshot, and exits with the signal status. The
tmux session applies the same terminating cleanup to its server, watchdogs, and
owned snapshot. The preflight reports artifact bytes and fixed host and Vulkan
headroom; the subsequent load remains the fit test. Its
standalone context ceiling never constrains the listener, because each preset
section supplies its own complete tuple. The capacity policy resolves the
section ID and model path to one registry row and requires the section's
context, cache K/V, Flash Attention, batch, and ubatch values to equal that row
before launch. The launcher's positive context argument remains a control-path
input but never reaches the router argv.

The repository fallback Web UI treats `GET /v1/models` as the request-model
authority and sends only a returned id for chat completion and attachment
tokenization. Its picker retains a still-valid choice when browser storage
permits and continues with live state when storage is denied. Each selection
uses `GET /props?model=<encoded-id>` for context metadata and retokenizes every
retained attachment with that same id. Context and token counts carry the model
identity and selection generation that produced them, so a change marks both
pending before any asynchronous response arrives. An unavailable or malformed
response leaves an explicit unknown value while the selected model remains
routable. A new API-key attempt clears the prior selection until the
authenticated roster returns, and late responses from an older attempt never
replace the newer state.

A web search reaches the network through one human approval, and the browser is
the executor. llama-server reads `tools` from the client body alone and runs a
wrapped MCP tool through the standalone `POST /tools` route, so the page
composes `body.tools` from `GET /tools?model=<id>&autoload=true` when the per-turn Web toggle is on and
a turn run with it off offers the model no network-reaching surface. The
executor reads the toggle again where the call runs, so a proposal carried over
from a turn that offered the web tools reaches no network once it is off. A proposed
`web_search_exa` call opens a dialog naming the query, the publication
interval, both domain lists, the result count, and whether `max_age_hours` of 0
forces a live crawl, and the dialog offers one approval and a refusal because
the broker signs a single-use grant. An approval posts those exact parsed
fields to `scripts/web-mcp/authorize-broker.py` and posts the returned grant
inside the `params` object of one `POST /tools` request; `history` retains the
proposal the grant was signed over and the result text, so the token reaches
the server once and stays out of the transcript every later request re-sends
and out of browser storage. A `web_fetch_exa` call runs through the same route
without a grant, because the wrapper enforces the signed Result ID and its own
fetch allowance, and the page spends at most two fetches per turn.
`mcp_result_to_response` maps an MCP `isError` result onto an `error` key at
HTTP 200, so a refused grant, a spent grant, and an argument outside the claim
are read from the response body rather than from its status and become a tool
message naming what refused. A refusal in the dialog answers the call with a
`role: 'tool'` message stating that the search did not run.

A backend states what it can carry rather than being trusted to carry
everything. Each `Provider` in `scripts/web-mcp/server.py` declares
`supports_exact_date_bounds`, `supports_freshness_max_age`,
`supports_domain_filter`, `supports_num_results`, and `supports_paging`, and
`refuse_unhonored_arguments` ends a call whose approved argument the active
provider cannot express, naming the argument and the provider, ahead of the
ledger transaction that spends the grant. `exa` carries every field, at any
`max_age_hours` including the 0 that forces a live crawl.

One local SearXNG instance is the general-search endpoint, and the profile
rather than the model decides what it is asked. `scripts/web-profiles.tsv`
carries `provider`, `primary_category`, `fallback_category`,
`minimum_results`, and `searxng_url` per row, `build-web-presets.sh` validates
them for every row and emits them into the MCP configuration, and
`SearXNGProvider` validates them again before its first request. Which engines
answer belongs to the instance's own `settings.yml` under qwen-named
categories, so the engine population changes by editing the instance rather
than through a request field. A search queries `primary_category` once and,
where fewer results survive canonicalization, private-target rejection, and the
granted domain lists than `minimum_results`, queries `fallback_category`
exactly once; a failing engine is suspended by the instance rather than retried
here. Both temporal arguments are refused, because SearXNG maps `time_range`
onto each engine and a mixed category cannot promise that every result met it.
Domain scope and result count are honored in the provider, over the answer. A
dropped private target leaves the answer rather than ending the call, which is
where a metasearch mix differs from Exa's own crawler. Each result carries its
`engines`, `category`, `rank`, and `score`, the reply names them on a
`Sources:` line ahead of `Highlights:`, and the audit row gains `search_id`,
`category`, `engines_attempted`, `engines_answered`, `engines_failed`,
`fallback_used`, and `usable_results` while still holding no query text. The
instance answers with result metadata alone, so `fetch_exa` retrieves the
source over one GET of the canonical URL its Result ID was signed over, and
`PROVIDER_OPENER` ends a redirect at the response that requested it.
`evidence/web-provider-contract.md` carries the flags, the profile columns, and
what a run against a live instance still leaves unmeasured.

The CUDA backend runs the packed-integer dot path on this device: the
Nsight-read kernel audits in `evidence/ada/b789-path-audit/` and
`evidence/ada/b789-nsys-causality/` observe the DP4A MMVQ family in the
executed symbols, and `evidence/ada/b789-clean-calibration/` carries the
per-quant crossover rates that dispatch produces. The Vulkan fallback's
packed-integer capability stays unmeasured here;
`evidence/legacy/raven2/comparative-findings.tsv` retains the prior host's
unaccelerated-path finding, keyed to that silicon's own driver capability
report, as comparison alone.

Both publishers of this tree's small checkpoints ship BF16 as their only
16-bit artifact, so `scripts/build-llama-cuda.sh` builds `llama-quantize` and
this tree derives F16 from BF16 itself. `scripts/verify-representation-pair.py`
reads GGUF headers alone and refuses a representation arm whose architecture
dimensions, tokenizer identity, or tensor names and shapes disagree between
control and subject, while leaving tensor type and byte count free to vary; a
passing header check does not prove numeric tensor-value equality.
`evidence/legacy/raven2/comparative-findings.tsv` retains the prior host's own
BF16-versus-F16 ratio as comparison; no arm on this device has yet measured it.

A positive `QWEN_BENCH_PREFILL` requests a paired prefill/decode arm. A
successful `llama-bench` process must emit exactly one
`pp${QWEN_BENCH_PREFILL}` row and one `tg${QWEN_BENCH_GENERATE}` row, with an
optional depth suffix on either label. A row for another token count cannot
satisfy the requested arm. Missing or duplicate output remains `n/a` in the
retained summary and makes the ladder terminal state `failed`; one half never
promotes an incomplete pair to a completed sweep.

The prior host refuted a linear decode-cost model fit to checkpoint size: a
two-point fit over its 4B and 9B rows predicted 4.82 tok/s at the 2B's weight
count where the 2B measured 9.46.
`evidence/legacy/raven2/comparative-findings.tsv` retains that refutation as
comparison; the CUDA baseline table above is this device's own measured decode
column and does not fit the prior host's model to it.

## Three runtime classes, one primary target

The 2B class is the appliance's primary performance target, the 0.8B class its
secondary fast target, and the 4B class the quality-heavy fallback that tests
size and shape scaling. The early campaign centered the 4B and its rate target
leaked into experiment selection; that ordering is retired. A general runtime
experiment -- prompt-cache checkpoints, prefill geometry, MMVQ, cache type and
Flash Attention, workgroup and compiler changes, graph optimization, n-gram
speculation, aggregate throughput -- runs the current 2B first, the current
0.8B second, and the current 4B third, and its result becomes a tree-wide
default only where the classes agree; a win on one class alone becomes that
class's profile setting. A representation arm follows the same order and reads
the 0.8B's Q8_0, Q4_K_M, and F16 rungs as their own comparison, because that
class already showed a fixed-cost regime the larger two do not share.
Speculation follows role: a 2B target drafted by the 0.8B leads, a 4B target
drafted by the 0.8B follows, the 2B's own prediction block at N=1 ranks beside
the first, and the 0.8B as target takes n-gram or a smaller draft where one
loads.

Quality belongs to the learned checkpoint and throughput belongs to the
execution class. Every checkpoint in `scripts/models.tsv` -- stock, distill,
uncensored, or reasoning fine-tune -- receives its own graded reasoning, code,
tool-selection, and termination admission, and the only arm a fine-tune skips
is a throughput arm whose architecture, tensor shapes, quantization, backend,
and serving tuple equal a row already measured. Registry entry needs the
strict one-token Vulkan load alone; a filled-depth arm, the graded suite, the
tool-selection grade, and a role comparison against its class control follow
when the checkpoint is chosen for a role, and visibility in the picker does
not by itself schedule device time.

## The launch chain

One command starts the appliance and one ends it. The chain between them
matters because each link adds policy the next link assumes:

```text
qwen-launch.sh            waits for /health, prints reachable addresses
  qwen-webui-control.sh   owns the tmux session, forwards environment
    qwen-webui-session.sh arms probe, monitor, kernel-hazard watcher
                          and, under QWEN_WEB_BROKER=1, the approval broker
      run-qwen-capacity-server.sh
        model-memory-preflight.sh   reports headroom
        qwen-capacity-policy.sh     builds the llama-server argv
          cuda-runtime-env.sh       scrubs env, applies profile and priority
            qwen-router-exec-guard.sh  rechecks authority identities, execs
```

`qwen-webui-session.sh` is the top-level GPU owner and takes the owner lock in
`scripts/gpu-workload-ownership.sh` before it starts anything: it acquires,
inspects the CUDA clients the driver already reports, starts the broker and the
control services, starts llama-server, and releases the lock last by exiting
after every child is stopped. It is that link because tmux starts the session
from its own server process, so no descriptor opened above
`qwen-webui-control.sh` reaches the far side, and because the session is the
process whose lifetime equals the serving lifetime. Every child is launched with
`9>&-` -- llama-server, the image service, the broker, the graphics-latency
probe, the kernel watcher, and the telemetry sampler alike, including the ones
that open no CUDA context -- because an inherited descriptor keeps the owner
claim alive after the session exits and would lock out the next session against
a device nothing is using. The session records the claim on a `gpu_owner` line in
`session.status`, which is the status proof an admission harness waits for
instead of holding a lock it cannot pass through tmux. `qwen-webui-session.sh`
requires depth and the load's memory figure as arguments rather than defaulting
them, since `qwen-capacity-policy.sh` reads both from the registry and the
closure and a session default would serve a depth no row admits.

Four locks order the device and the order is fixed: the top-level owner lock,
then the active-compute lease, then a service-local job lock, then an artifact
lock. Exactly one top-level orchestrator holds the owner lock for its whole
lifetime -- one serving session, one measurement campaign, or one standalone
image, PhysX, or OptiX campaign. The compute lease is inner because it covers
work that intentionally coexists under one serving session: model load,
evaluation and decode, image load and generation, vision review, and the PhysX,
OptiX, and TensorRT execution that follows. It leaves out the broker, the HTTP
listener, telemetry, the kernel watcher, ordinary file work, an idle resident
process, and the graphics-latency monitor. The order follows from how each
acquire behaves rather than from granularity: the lease acquire blocks on a
bounded deadline while the owner lock refuses at once with status 75, so a
blocking acquire above a contended non-blocking lock converts a refusal into a
wait the refusal exists to replace. `gpu_ownership_assert_order` enforces the one
inversion that can be constructed -- a process holding the compute lease then
asking for the owner lock -- as a deterministic refusal on the acquire path,
comparing every descriptor in `/proc/self/fd` against the lease file by device
and inode. `QWEN_GPU_COMPUTE_LEASE` is the lease name;
`QWEN_VULKAN_WORKLOAD_LOCK` is accepted beside it for one transition release
where both resolve to one file, and a configuration naming two files is refused
rather than serialized on one of them.

`scripts/gpu-workloads.tsv` is the coverage authority that replaces a regular
expression grown one name at a time. One row per entry point naming a
CUDA-opening command or a local wrapper of one -- llama-server, llama-bench,
llama-cli, llama-mtmd-cli, llama-quantize, nsys, ncu, the pinned image runtime,
and `vulkan-graphics-service-probe` -- carrying `role`, `backend`,
`top_level_owner`, `nested_owner_capability`, `active_compute_lease`,
`may_overlap_compute`, `child_closes_owner_fd`, and `execution_policy`. The
roles are `serving-session`, `measurement-campaign`, `nested-orchestrator`,
`active-workload`, `authorized-monitor`, and `non-gpu-helper`. The
graphics-latency probe is an authorized monitor under the owner rather than an
entry in the desktop pattern, because its submissions are project-generated
traffic even on the graphics queue.
`scripts/classify-graphics-latency-probe.sh` asked which driver client list
reports it and the answer refuted the prediction: the probe reads type `C+G` in
`nvidia-smi -q -d PIDS` and appears in all ten compute-app samples at 5 MiB, so
the NVIDIA user-mode driver opens a compute context behind a Vulkan device
whatever queue the application submits on, and `gpu_ownership_inspect`
identifies a probe that survived one session. `GPU_OWNERSHIP_PROJECT_PATTERN`
therefore names `vulkan-graphics-service-probe` by its own basename, since ahead
of that name it matched through the `qwen-` fragment of the checkout path and
the same binary elsewhere read `refuse-unknown`.
`evidence/ada/graphics-probe-classification/` carries the run. What the probe
costs a concurrent campaign stays unmeasured and needs an arm that runs it
beside compute.
`scripts/test-gpu-workload-ownership.sh` enumerates the ledger and requires every
listed entry point to exist, every top-level owner to take the authority, every
nested capability to verify an inherited descriptor rather than open a second
claim, every workload child to close it, every active-compute row to name the
lease, and every delegating row to name the lane holding the claim in its place;
an entry point that names a device command and appears in no row fails the gate.

An admission harness that reaches the device through `qwen-launch.sh` cannot hold
the lock, because the session takes it on the far side of tmux. It launches the
session, waits for the `gpu_owner` line, and drives its test through that
session. A direct non-tmux runner takes the lock itself and passes the capability
down: `run-cuda-baseline-sweep.sh`, `run-speculation-sweep.sh`,
`run-mmvq-paired-crossover.sh`, `run-mmvq-width-request-tails.sh`,
`probe-mmvq-tail-logit-margin.sh`, `run-cuda-dispatch-census.sh`,
`admit-representation-row.sh`, `classify-graphics-latency-probe.sh`,
`probe-filled-depth.sh`,
`probe-depth-projector.sh`, `run-cuda-lever-campaign.sh`,
`run-ad104-path-audit.sh`, `run-ad104-b789-calibration.sh`,
`run-placement-sweep.sh`, `run-graph-alias-ab.sh`, `run-one-token-admission.sh`
at its load stage, and `promote-llama-build.sh`. Every other audited entry point
carries a `# gpu-ownership:` line naming the lane that holds the claim instead.

`QWEN_SERVING_BACKEND` selects the wrapper on that second-to-last line and the
device the argv names. `cuda` is the default and yields `cuda-runtime-env.sh`
with `--device CUDA0`; `vulkan` yields `vulkan-runtime-env.sh` with
`--device Vulkan0`. Naming the device is what keeps the two apart, because the
promoted binary carries both backends and enumerates CUDA0 and Vulkan0 for the
same card: a router child that named neither allocated on Vulkan0 here while
every measurement that set the defaults ran on CUDA0.

The profile vocabulary belongs to the wrapper. `cuda-runtime-env.sh` takes
`default`, `no-graphs`, `no-fusion`, `pdl`, `unified`, and `custom`, and each
names what it exports out of the eleven `GGML_CUDA_*` and `GGML_OP_OFFLOAD_*`
variables the backend reads. It also applies the scheduling policy rather than
inheriting one -- `QWEN_SERVING_NICE` at 0 and `QWEN_SERVING_CPU_LIST` at the
online CPU set -- and exports both, so the session and the runtime monitor
require of the server exactly what the wrapper asked for.
`vulkan-runtime-env.sh` applies the identical policy for the Vulkan fallback,
because pinning one core away from the desktop was a prior host's tradeoff on
a part with two cores total; twelve threads and a discrete card leave nothing
to buy by repeating it.

`unified` is a residency lever rather than a performance one:
`GGML_CUDA_ENABLE_UNIFIED_MEMORY` lets an allocation exceed the 12 GiB carve-out
by paging over PCIe, which belongs to an arm that would otherwise not run at
all.

Three device-facing guards changed with the host.
`scripts/vulkan-graphics-service-probe.c` selects its physical device by vendor
-- NVIDIA first, AMD second, `QWEN_PROBE_VENDOR_ID` over both -- where it
required vendor `0x1002`. `scripts/watch-qwen-kernel-hazards.sh` matches the NVRM
Xid, bus-fallen-off, and RmInitAdapter signatures beside the device-neutral
ring-timeout and reset lines, and reads the ring buffer through `sudo -n dmesg`
where `kernel.dmesg_restrict` hides it. `scripts/monitor-qwen-runtime.sh`
samples NVML through `nvidia-smi`, keeping its column names: utilisation is the
busy percent, device memory is the vram figure, and `gtt_used_bytes` reads
`unavailable` because GTT names a unified-memory aperture a discrete card has
no counterpart for.

`scripts/admit-cuda-router-serving.sh` runs the assembled chain once: it
launches in router mode, asks two models for one reply each, reads back the
placement line and memory breakdown each child prints, records how many
children were resident together, and tears the appliance down. The retained run
in `evidence/ada/cuda-router-serving/` carries nine checks with none rejected,
both the 2B distill and the 0.8B answering from CUDA0 with both resident at
5307 MiB of device memory.

Five properties of the Vulkan-side chain surprise a reader who meets one file
alone.

`vulkan-runtime-env.sh` unsets every `GGML_VK_*` variable, the display and
vendor-selection variables, and the Vulkan validation-layer variables before
its profile case runs, so an ambient submission setting reaches the server
only when the `custom` profile captures it beforehand and restores it after
the scrub. `default` exports nothing beyond the scrub, pins the ICD to
`/usr/share/vulkan/icd.d/nvidia_icd.json` (`QWEN_VULKAN_ICD` overrides it), and
exports `LLAMA_NO_CPU_FALLBACK=1` the way `cuda-runtime-env.sh` does for the
CUDA path. The submission-profile vocabulary the wrapper carried on the prior
host -- `paced-60`, `low-serialized`, `low-async` -- named settings measured
against the prior host's two-compute-unit part;
`evidence/legacy/raven2/comparative-findings.tsv`
retains the submission-node-count finding those profiles rested on as
comparison, and no arm on this device has repeated it.

tmux starts a session from its server's environment, so
`qwen-webui-control.sh` forwards variables inside the command string. A
variable exported in the calling shell alone stops at the tmux boundary.

`tmux kill-session` ends the session script without running its EXIT trap, so
`qwen-teardown.sh` records the guard PIDs from `session.status` before calling
`stop`, which rewrites that file. The teardown then proves absence and exits
non-zero on residue.

`model-memory-preflight.sh` reports host and Vulkan headroom and admits every
launch. A load that exceeds the machine fails at once and names its reason.

`qwen-web-launch.sh` exports `QWEN_WEB_BROKER=1` with the broker port, state
directory, signing key path, and the profile it reads from the preset, so the
session starts `authorize-broker.py` on 127.0.0.1 as a guarded child and
records it as `broker_pid=` on the `state=running` line. The broker starts
ahead of the capacity server because it allocates nothing on the device and
model loading holds the readiness loop for up to 120 seconds. The signing key
is required whole before anything launches: `QWEN_WEB_TOKEN_KEY_FILE` names a
regular file at mode 0600 owned by the serving user with nonempty content, the
launcher applies those rules and the broker applies them again before it
prints `listening`, and only the path crosses into the child. One broker signs
for one profile, since `POST /grant` refuses a `profile_id` other than its
`--profile`, so the launcher requires exactly one preset section and names it
`QWEN_WEB_PROFILE`; a caller whose own value differs is refused. The
`listening` line proves a socket and `GET /health` proves the process: the
session reads the broker's pid, profile, provider, signing-key SHA-256, and
`/proc/self/stat` start time from that route and fails the launch on any
mismatch, then records pid and start time on a `broker_identity` line.
`qwen-teardown.sh` compares that start time with the live `/proc/PID/stat`
before it signals, so a reused pid is left alone, waits for the broker to
leave, and requires `authorize-session.secret` to be gone whether or not a pid
was recorded, since the broker unlinks that file while unwinding from SIGTERM
and a surviving secret authorizes a page against the next launch. The ordinary
`qwen-launch.sh` path leaves the marker unset, records no `broker_pid`, and
starts no broker.

`scripts/admit-web-router-fake.sh` runs that chain on the appliance against
the fake provider: the promoted `llama-server`, a real router child, the
broker, and the MCP child all execute, and every request the page would make
runs with curl in its place on the router port alone, from
`GET /tools?model=` through one grant, one search, one fetch by Result ID,
and each refusal the design relies on. The page itself then runs the same
turn: `qwen-web-launch.sh` serves `webui/index.html` rather than the pinned
llama UI build, because that build neither scopes `GET /tools` by model nor
posts the routing key, and `scripts/web-mcp/drive-fallback-page.py` opens the
served page in the appliance's headless Chromium over the DevTools protocol
with the standard library alone, sends the prompt, approves the one dialog,
and reports every request the page's own `fetch` made. The admission reads
that log: the listing and the search post name the router port with the
model beside the tool, the grant comes from the broker, no request leaves
those two origins, and the transcript carries the Result ID. A router
serving any other page fails the run. The generated MCP configuration
carries the names `server.py` reads -- `QWEN_WEB_PROFILE`,
`QWEN_WEB_PROVIDER`, `QWEN_WEB_MAX_RESULTS`,
`QWEN_WEB_MAX_FETCHES_PER_SEARCH`, `QWEN_WEB_MAX_CHARS_PER_FETCH`,
`QWEN_WEB_SEARCH_AUTH` written as `required`, `QWEN_WEB_STATE_DIR`, the
optional `QWEN_WEB_TOKEN_KEY_FILE`, and the one provider key the `case` on
`QWEN_WEB_PROVIDER` selects: `QWEN_WEB_FAKE_FIXTURES`, the
`QWEN_WEB_SEARXNG_*` instance and category set, or `QWEN_WEB_EXA_KEY_FILE`
-- so the ledger's per-profile budgets bound the child rather than describing
it, and its `timeout_ms` of 30000 sits between the provider's 20 s request
timeout inside `server.py` and the router's 3600 s proxy read timeout, so a
stalled provider is answered by the child's own deadline rather than abandoned
by the router. `server.py` reads six further names from its own environment
that the generator emits for no section: `QWEN_WEB_DAILY_BUDGET`,
`QWEN_WEB_DAILY_PAGE_BUDGET`, `QWEN_WEB_SEARCH_PER_MINUTE`,
`QWEN_WEB_FETCH_PER_MINUTE`, `QWEN_WEB_TOKEN_LIFETIME_SECONDS`, and
`QWEN_WEB_RATE_WINDOW_EPOCH`, which pins the instant every rate bucket floors
its window from so a harness spending one allowance across several spawned
children measures the limit rather than a wall-clock boundary.
`_resolve_pinned_rate_window` returns `None` unless `QWEN_WEB_PROVIDER` reads
`fake`, so the epoch is inert against a served profile naming `exa` or
`searxng`.

An image generation reaches the device the way a search reaches the network,
and one lease separates the two. `scripts/image_protocol.py` freezes the job
frame at version 1 and both `image-service.py` and `image-mcp/server.py` import
it, so a closed request schema, a closed response schema, the 65536-byte line
bound, and the coarse `square`/`portrait`/`landscape` label have one reading
rather than three. `scripts/build-web-presets.sh` reads
`scripts/image-profiles.tsv` as a second execution grant under the rules the web
ledger takes: a `refused` row emits nothing under every setting, and a
`validator-gated` row adds one `image` server to each emitted section's MCP
configuration under `QWEN_WEB_AUTHORIZER_READY=1`, naming
`scripts/image-mcp/server.py` with the section's own profile as
`QWEN_IMAGE_LANGUAGE_PROFILE` because the grant binds the language profile and
the image profile together. One image profile emits, since a section carries
one `mcpServers` object, and `image-sdxs-512-a` is the checked-in row that
carries the grant. Every other row reads `refused`. A generator run that names
no image ledger therefore reads the shipped one and requires the five image MCP
inputs, so a caller arming the web lane alone names an all-refused ledger in
`QWEN_IMAGE_PROFILES` the way `test-web-presets.sh` does.

The tool schema states what the section serves rather than what the lane
admits. The emitted configuration names `QWEN_IMAGE_PROFILES_JSON`, and
`tools/list` reads that file for the profile's geometry and ceilings, so
`profile_id` lists the one served profile as its enum and the width, height,
and step maxima are the ones `image-service.py` enforces from the same file. A
model reading the listing proposes inside them, and `webui/index.html` reads
the same listing: an argument above a stated maximum is answered with a tool
message naming the bound before the dialog opens and before the per-turn
budget moves, and the dialog and the grant carry the enum's profile with the
proposed one on a note line. Every failure after the approval -- a refused
grant, a `POST /tools` error status, a service refusal at HTTP 200, an artifact
that fails to load -- answers the call with a tool message and ends the turn,
because a dialog that settles nothing holds the page busy while the model waits
on a result that never arrives.

`scripts/image-profiles.tsv` carries a `review_model` column naming the vision
checkpoint a shape's artifacts are reviewed by, and it decides whether the
preset serves one section or two. A named row makes
`scripts/build-web-presets.sh` emit a review-only section for that model_id --
its `scripts/models.tsv` tuple, its projector, a `validated` row in
`scripts/validated-tuples.tsv` at that exact tuple with `projector_state=loaded`,
no MCP configuration, tags `vision-review,review-only` -- so `GET /v1/models`
returns two ids, `GET /props?model=` reports a vision modality for the second,
and the page's Review button appears on an artifact card. Two resident
checkpoints share one carve-out the 4B alone fills to 2029 of 2048 MiB, so
`qwen-image-launch.sh` sums every model and projector the preset names, adds
the image runtime's resident cost, hands the total to
`model-memory-preflight.sh`, and reports what it answers on every launch. A
paired launch refuses on that probe's own `vulkan_budget_headroom=short` line;
a one-section launch is the shape
`evidence/image-appliance/served-turn-admission/` already ran and passed, and
it reads the figure without being gated on it.
`image-sdxs-512-a` names `lfm25-vl-16b` because the probe reported the pair
ample twice on the appliance and one page session then generated and reviewed
one artifact through it; every other row reads `-`, since the headroom probe
runs on the appliance alone and no run has reported those pairs.
`evidence/image-appliance/paired-review-admission/` carries the admitted run,
where the review cost 19.44 s against the generation's 11.62 s: 14.77 s of
that is prompt evaluation of the 570-token multimodal prompt, so a smaller
reply budget reaches 4.67 s of it and the roster holds no faster reviewer than
the row already named.

`scripts/qwen-image-launch.sh`
rejoins the preset's image markers to the ledger, requires the row to still
read `validator-gated`, requires its `review_model` to match the preset's own
marker and the review section to carry a projector and no MCP configuration, requires the parameter file the service runs a job
under to carry the ledger's own geometry and ceilings, and proves the deadline
stack ordered from the value each layer is configured with -- the runtime at
the smaller of the profile's `timeout_s` and `image-service.py`'s 300 s
ceiling, the service at its 330 s job deadline, the tool call at the emitted
`timeout_ms`, and the page at `webui/index.html`'s own
`IMAGE_GENERATION_TIMEOUT_MS`. The router proxy configures none of its own in
this tree, so the launch reads llama-server's 3600 s default and requires it to
outlast the tool call rather than asserting the 600 s bound
`scripts/image-protocol.md` proposes. `qwen-webui-session.sh` starts the service
as a guarded child beside the broker and records `image_service_pid=` on the
`state=running` line, and `qwen-teardown.sh` compares its recorded start time
with `/proc/PID/stat` before signalling and then runs
`scripts/image-teardown-check.sh`, which proves no service, no runtime, no
partial artifact, and a free lease.

A process holds its scheduling priority before its first instruction rather than
receiving it from a parent afterwards. `scripts/qwen-exec-idle-priority.sh` sets
nice 19 and the idle I/O class in itself, verifies both against the kernel, and
execs the command its argv names, so `exec` keeps the pid, the process group,
and the session the spawning parent recorded while the values are already in
force. `image-service.py` spawns the pinned runtime through it because
`posix_spawn` carries no priority attribute and `preexec_fn` is unsafe in a
threaded process, and the window a parent-side `setpriority` left open covered
the runtime's Vulkan instance creation and device enumeration. The service still
reads the child's nice value back from `/proc` as an independent observation,
now on a bounded poll because it races the wrapper, and an unreadable value ends
the job rather than recording `nice: "-"` beside a completed generation.

`renice --priority` names an absolute nice value where `renice -n` is relative
under POSIXLY_CORRECT and `nice -n` is always an increment against the caller,
so the increment spellings reach 19 from any caller at nice 0 or above and fall
short of it from a caller at a negative nice. Every refusal reads the kernel
rather than the tool's exit status, which is what keeps a failed `renice` on the
refusal path instead of ending the shell on `set -e`. The idle I/O class is
established and proved as an ioprio value; the elevator decides what it
produces, BFQ acts on it and kyber does not, so `harness_ioclass=idle` states
the class rather than an effect on I/O.
`evidence/exec-idle-priority.md` carries the falsifiers, including the
negative-nice and cancellation arms it records as unrun with their reasons.

The generation grant joins two profiles and the broker binds them with two
arguments. `image_grant.enforce_image_authorization` compares a claim's
`language_profile` against `QWEN_IMAGE_LANGUAGE_PROFILE` and its
`image_profile` against `QWEN_IMAGE_PROFILE`, which the emitted configuration
sets to the section's own id and to the ledger's image row, so
`authorize-broker.py` takes `--image-profile` beside `--profile` and the
session hands it `QWEN_IMAGE_PROFILE`. A launch that armed no image lane
leaves it empty and every `POST /grant-image` is refused. `GET /health`
reports the pair and the session compares both before it admits the launch, so
a broker signing for another lane fails at startup rather than at the first
approved generation.

`scripts/admit-image-router.sh` runs that chain against one approved
generation. It sets one `scripts/image-profiles.tsv` row to `validator-gated` in
a copy under its own output directory, writes a
`ui-mediated` language row so the emitted section carries the image server
alone, generates the preset under `QWEN_WEB_AUTHORIZER_READY=1`, launches
through `qwen-image-launch.sh`, and replays every request the page makes with
curl on the router port and the artifact listener: `GET /tools?model=` lists
`image_generate_image`, since `server_mcp_tool` serves each wrapped tool as
`<server>_<tool>` and the section configures the image MCP server under the key
`image`, `POST /grant-image` signs over a seed the script chose, one
`POST /tools` carrying the grant inside `params` completes with a digest and a
provenance route, and the replayed grant, the ungranted call, the
out-of-schema argument, the foreign image profile, and the uncredentialed
artifact read are each refused once. `GET /artifacts/<sha>.png` is compared
byte-for-byte against the digest the reply named and `GET /artifacts/<sha>.json`
against the seed and profile that produced it. The page then runs the same turn
through `scripts/web-mcp/drive-fallback-page.py --lane image`, and the checks
read its own request log: the grant is posted once, the generation names the
model beside the tool, every request stays on the router, broker, and artifact
origins, and the retained tool message carries the digest and the route alone.
`evidence/image-appliance/served-turn-admission/` retains the run on the
appliance that moved `image-sdxs-512-a` to `validator-gated`: 41 rows, 40
accepted and one observed, one artifact generated in 12 s by the curl replay
and one in 11.3 s by the served page, with the model's own proposal inside
every bound the tool listing states and its seed displayed before approval.
`evidence/image-appliance/paired-review-admission/` retains the paired run
that moved its `review_model` to `lfm25-vl-16b`: 48 rows, 45 accepted and 3
observed, `sections=2`, and one page session carrying the approved generation
and a parsed vision review of its own artifact.
The 4B distill proposed a schema-valid call in every run there and the 2B
distill answered in prose, which its `raw_tool_selection` grade of 2/10
already states, so an image-capable language profile names the 4B.
`scripts/test-admit-image-router.sh` runs the whole harness on the workstation
against `scripts/test-fixtures/fake-router-server.py` and
`scripts/test-fixtures/fake-image-runtime.sh`, replacing the four device-owning
links -- the memory preflight, the graphics latency probe, the kernel-hazard
watcher, and the runtime monitor -- and leaving the launch chain, the broker,
the service, the lease, the MCP child, the served page, and the teardown as
the tree's own.

The artifact listener is a second origin the page is told about. `--http-port`
defaults to 0, so `qwen-webui-session.sh` reads the address the service printed
and records it on its `image_service_identity ... listener=` line, and the
router proxies none of `/artifacts/`. `webui/index.html` therefore resolves an
artifact origin from an `?artifacts=` query parameter, then a
`qwen-image-artifacts` meta tag, then its own field, and a page given none says
so rather than resolving the route against the router. The image route itself
is derived from the digest: `provenance_url` names the `.json` record and the
page composes `/artifacts/<sha>.png` from the same value, so one reply carries
one identity and both routes follow from it.

`~/qwen-webui-state/vulkan-workload.lock` is that lease, and it is two-sided in
time rather than tied to residency. `image-service.py` holds it from job start
to artifact rename, and its acquisition waits on a bounded deadline --
`QWEN_IMAGE_LEASE_WAIT_S`, 60 seconds by default, zero for one non-blocking
attempt -- because the chat turn that emitted the approved tool call is still
releasing when the generation request arrives; the refusal past that deadline
keeps the `lease_unavailable` reason.
`patches/llama-server-vulkan-workload-lease.patch` makes llama-server the second
writer under `QWEN_VULKAN_WORKLOAD_LOCK`, which `qwen-capacity-policy.sh`
exports from the session state directory on every launch and
`vulkan-runtime-env.sh` leaves alone.
`server_context_impl::update_slots` owns the transitions: it takes the lease
where its all-idle check finds a busy slot and releases it where the check finds
none, so an idle loaded server holds nothing while every decoding pass runs
inside the lease, and the release trails the final decode by exactly one pass.
Acquisition returns whether the pass may submit: a wait ended by a terminating
signal or refused by the kernel leaves `update_slots` before it posts
`NEXT_RESPONSE`, so no graph reaches the device in a pass that holds no lease.
The acquire tries `LOCK_EX | LOCK_NB` first and logs the waiting line ahead of
the block, so a stall is visible while it lasts and the acquire line carries
`waited_ms`. The child holds it in router mode, since `server.cpp` calls
`load_model` and therefore `init()` only in its non-router branch while
`server-models.cpp` spawns each child from the `environ` snapshot in `base_env`.
`scripts/test-vulkan-workload-lease.sh` admits both halves and
`evidence/vulkan-workload-lease/README.md` registers the invariant, the
falsifiers, and the appliance sequence; the patch is a candidate under
`QWEN_LLAMA_CANDIDATE_PATCHES=1` awaiting admission on the device.

A review of a generated image is the next transition through idle, and it runs
against a vision model holding no executable tool. `scripts/image-review.py`
reads the artifact through `GET /artifacts/<sha256>.png` with the Web UI's own
bearer credential, hashes the bytes against the digest the caller named, and
posts one non-streamed `/v1/chat/completions` whose body omits `tools`
entirely, at temperature 0, 400 reply tokens, thinking off, and a 300 s
deadline. The reply is one JSON object carrying exactly `hard_constraints`
(one `name`/`passed`/`observation` entry per declared constraint),
`composition_change_required`, `prompt_delta`, and `regenerate`; prose, a
fenced block, an extra key, a missing key, a `passed` that is a number, a
constraint the caller never declared, and a reply carrying `tool_calls` are
each refused with the code naming the rule. The generation prompt stays out of
the request, which binds the same `prompt_hash` the image grant is signed over,
and the audit line carries counts, booleans, `delta_chars`, and the delta's
SHA-256 rather than the observation or delta text a model wrote after reading
an image. `reasoning_emitted` sits on that line because
`chat_template_kwargs.enable_thinking` is inert against a template with an
unguarded `<think>`, and a reasoning span inside 400 tokens ends the object
unclosed for the same `not_json` the fence produces.

`webui/index.html` runs that schema in the browser and bounds what a verdict
may cause. The Review button appears on an artifact card where
`GET /props?model=<id>` reports a vision modality for some roster row, the
review holds the same `busy` flag a chat turn holds, and the verdict, its
observations, and any correction stay out of `history`, so image-derived text
never enters the transcript every later request re-sends. Three facts admit a
correction -- a constraint the model marked failed, the `regenerate` flag, and
a non-empty `prompt_delta` -- and a correction is a proposal: the composed
prompt meets the tool schema's maxima, the first approval's seed travels on the
card rather than being chosen again, and the same approval dialog signs a fresh
single-use grant over the composed prompt's hash. Two approved corrections per
original request are the whole allowance, counted in the card's lineage so a
correction's own review inherits the counter rather than restarting it.
`scripts/test-image-review.py` drives the module against a fake vision router
that answers a tools-carrying request with a tool-call proposal, and
`scripts/web-mcp/test-fallback-page-image.py` drives the served page through one
review, two approved corrections, and the third that reports the cap.
`evidence/image-appliance/vision-review-design.md` registers the state machine,
the schema, and the falsifiers, and names `lfm25-vl-16b` as the first appliance
arm with `qwen35-2b` as its control inside one sweep.

A grammar states reply shape and leaves the source of a verdict open, so
`image-review.py` takes `--image-mode` over `real`, `withheld`, and `swapped`
with `--swap-sha256` naming the second artifact a swapped review sends.
`withheld` keeps the multipart text part and drops the image part, the
image-withheld convention `scripts/run-quality-suite.py` applies to its graded
vision rows, and `swapped` sends another artifact's bytes under the same prompt
hash, constraint list, model, temperature, reply budget, thinking setting, and
absent `tools` key. Both modes still read and hash the reviewed artifact over
its own route, so every `fetch_artifact_png` refusal holds for a control arm and
the audit line and verdict record carry `image_mode` beside `swap_sha256`.
`scripts/run-vision-review-control.sh` runs real-A, withheld-A,
swapped-A-with-B, and a closing real-A through one router and one artifact
listener, retains a verdict record and an audit line per arm, and prints a
summary TSV of per-arm `passed` counts and the `regenerate` flag. Every arm sends
`--no-prompt-cache`, since the four requests share the text part ahead of the
image part and a warm prefix moves an answer on this backend rather than only
its timing, so the closing arm's agreement with the opening one is what licenses
reading the two control arms as image effects rather than as position in a
request sequence.
`evidence/image-appliance/vision-review-control-design.md` registers the
hypothesis, the arm order, and the falsifiers ahead of any run: a withheld arm
passing every constraint it cannot see refutes the visual grounding, and swapped
observations agreeing with A rather than B report the same thing through a
second route.

`patches/llama-router-tools-proxy.patch` is what puts the route on the router
port. At f280b269 `server.cpp` registers `/tools` only in a process whose own
MCP manager holds a server, and the router branch proxies chat, props, and
slots without it, so an unpatched router answers `403 feature_disabled` while
the child serves the route on an internal loopback port
(`evidence/web-admission-fake.md`). The patch registers `/tools` on a router
that holds no tools of its own as `proxy_get` and `proxy_post`, so `GET`
resolves `?model=` and `POST` resolves the body's top-level `model` key the
way `/props` and `/v1/chat/completions` do, and the child that read the
section's configuration executes the call. The child's `handle_post` reads
`tool`, `params`, and `stream` alone, and `server.py` refuses any argument
outside a tool's schema by name, so the routing key provably stays out of the
tool arguments. The ordinary preset carries no MCP configuration, so the same
binary answers `403 feature_disabled` for every ordinary model: the route is
in the binary and the tool set belongs to the section.
`evidence/web-admission-router-tools.md` records the run on that closure.

## Commands

```sh
# Start and stop the appliance
scripts/qwen-launch.sh [default|no-graphs|no-fusion|pdl|unified]
QWEN_ROUTER=1 QWEN_ROUTER_MAX=2 scripts/qwen-launch.sh   # the picker, two children resident
scripts/qwen-web-launch.sh [PROFILE]     # web presets, loopback only
scripts/qwen-image-launch.sh [PROFILE]   # web presets with the image lane armed
scripts/qwen-teardown.sh
scripts/qwen-webui-control.sh status
scripts/gpu-state-latch.sh status|require-clear|recover
                                         # the latch between a driver failure and the next launch

# Select a checkpoint, a listener, and the serving backend
QWEN_MODEL_PATH=$HOME/models/Qwen3.8-4B-Distill-GGUF/Qwen3.8-4B-Q4_K_M.gguf \
QWEN_BIND_HOST=0.0.0.0 QWEN_SERVING_BACKEND=vulkan \
    scripts/qwen-launch.sh default

# Build, measure, and admit on this host
scripts/build-llama-cuda.sh                     # CUDA and Vulkan in one binary, sm_89
scripts/classify-graphics-latency-probe.sh OUT    # which driver client list names the probe
scripts/run-cuda-baseline-sweep.sh OUT MODEL...  # mirrored prefill and decode
scripts/run-speculation-sweep.sh OUT TARGET [DRAFT]
                                                # baseline, external draft, MTP, n-gram
scripts/sample-nvidia-clocks.sh OUT_TSV [SECONDS] # the state a rate ran at
scripts/admit-cuda-router-serving.sh OUT        # the whole chain, two models, one teardown
scripts/admit-router-speculation-roster.sh OUT # every servable row once, per-row speculation read from the child argv
scripts/run-ad104-b789-calibration.sh [--validate] MATRIX_TSV OUT
                                                # the MMVQ/MMQ crossover arms, one clean boot, one lock
scripts/run-ad104-path-audit.sh [--dry-run] MATRIX_TSV OUT [ARM_ID...]
                                                # which mat-mul kernel each arm launched, read from the symbol
scripts/read-nsys-mat-mul-kernels.py CAPTURE.sqlite
                                                # the quantized mat-mul launches one Nsight Systems capture holds
scripts/read-nsys-kernel-durations.py CAPTURE.sqlite [--match SUBSTRING]
                                                # per-symbol launch count and duration, node granularity alone
scripts/derive-projection-fan-out-bound.py --model ID=GGUF=DECODE_TOK_S ...
                                                # what merging a projection fan-out removes, off the GGUF headers

# Measurement harnesses, each of which owns its own launch and teardown
scripts/compare-model-candidate.sh LABEL MODEL_PATH [PROFILE]
scripts/run-placement-sweep.sh [OUTPUT]
scripts/reasoning-span-probe.sh OUTPUT_JSON     # against a live server
scripts/summarize-probe.sh ~/qwen-webui-state/graphics-latency.log
scripts/gguf-tensor-census.py MODEL [MODEL...]   # what a Q4_K_M file holds
scripts/admit-candidate-static.py REPO REV      # a header over a range read
scripts/hash-load-closure.sh EXECUTABLE [OUT]    # identity of every loaded object
scripts/measure-served-decode.sh LABEL MODEL    # served decode at a fixed length
scripts/run-quality-suite.py ENDPOINT OUT_JSON --long-context-characters 24000
                                                # the 75-row graded suite at explicit depth
scripts/run-quality-roster.sh [OUTPUT_DIR]      # that suite against every servable row
scripts/generate-quality-images.py [DIR]        # the vision fixtures, and --check
scripts/regrade-quality-roster.py RECORD...     # a grader change over retained replies
scripts/model-registry.sh id|path SELECTOR [FIELD]
scripts/build-router-presets.sh [OUTPUT_INI]    # the picker, from the tier field
scripts/build-web-presets.sh OUTPUT_INI         # web profiles, from the execution_policy field
scripts/fetch-candidate-artifact.sh REPO REV FILE DIR  # observed, not pinned
scripts/run-one-token-admission.sh RECORD [OUT]  # load every candidate once
scripts/verify-representation-pair.py CONTROL SUBJECT
                                                # GGUF-header structural identity, one value format against another
scripts/admit-representation-row.sh REGISTRY MODEL_ID CONTROL_ID VALUE_TYPE OUT
                                                # digest, header, pair check, and one strict CUDA0 load
scripts/test-strict-cuda-placement.sh --llama-server PATH --model PATH
                                                # host placement refused twice, then every buffer on CUDA0
scripts/admit-web-router-fake.sh OUTPUT_DIR      # the web router against the fake provider
scripts/admit-image-router.sh OUTPUT_DIR         # one approved generation through the router
scripts/probe-depth-projector.sh MODEL_ID OUT   # filled depth, projector loaded
scripts/image-registry.sh artifacts|models|profiles|bundle|profile
                                                # the four image authorities, validated whole
scripts/image-service.py --state-dir DIR --profiles-json FILE
                                                # the lease owner, one generation at a time
scripts/image-teardown-check.sh [STATE_DIRECTORY]
                                                # no service, runtime, partial artifact, or held lease
scripts/test-vulkan-workload-lease.sh           # one workload, both writers of the lease
scripts/qwen-exec-idle-priority.sh COMMAND [ARGUMENT...]
                                                # nice 19 and idle I/O, verified, then exec
scripts/image-review.py --router-origin URL --artifact-origin URL --model ID \
    --sha256 HEX --prompt-hash HEX --constraint NAME=DESCRIPTION \
    [--image-mode real|withheld|swapped [--swap-sha256 HEX]]
                                                # one artifact reviewed by a vision model, zero tools
scripts/run-vision-review-control.sh ROUTER_ORIGIN ARTIFACT_ORIGIN MODEL \
    SHA256_A SHA256_B PROMPT_HASH OUTPUT_DIR --constraint NAME=DESCRIPTION
                                                # real, withheld, swapped, and a closing real arm
scripts/run-graph-alias-ab.sh OUTPUT_DIR [MODEL_ID...]
                                                # token identity across the graph optimizer
scripts/run-cuda-dispatch-census.sh OUT [ARM_ID...]
                                                # where every mat-mul launch goes, per arm, census closure only
scripts/summarize-dispatch-census.py OUT        # census rows joined to the requests that produced them
scripts/gpu-quiescence-gate.sh baseline|wait BASELINE_TSV [LABEL]
                                                # the device state each observation is admitted against
scripts/run-mmvq-paired-crossover.sh CONTROL_BENCH SUBJECT_BENCH MODEL_ID OUT
                                                # two closures width by width, alternating, four pairs least
scripts/run-mmvq-width-request-tails.sh CONTROL_SERVER SUBJECT_SERVER MODEL_ID OUT
                                                # the same pairs on the served path, with reply identity
scripts/probe-mmvq-tail-logit-margin.sh CONTROL_SERVER SUBJECT_SERVER MODEL_ID OUT
                                                # the top-two candidate margin under one shared history

# Rebuild the static UI, and the MMQ kernel-policy build arm
scripts/build-llama-ui.sh                       # Node on the workstation
QWEN_FORCE_MMQ=ON scripts/build-llama-cuda.sh   # the MMQ kernel-policy arm

# Hash-pinned model fetches
scripts/download-qwen35-4b-q4km.sh
scripts/download-qwen35-4b-mmproj.sh
scripts/download-qwen38-4b-distill-q4km.sh
scripts/download-nanbeige42-3b-q4km.sh            # community conversion
scripts/download-qwen38-2b-distill-bf16.sh       # the 16-bit rung, and the F16 source
scripts/download-qwen35-08b-bf16.sh
scripts/derive-qwen38-2b-distill-f16.sh         # F16 from BF16, validated
scripts/derive-qwen35-08b-f16.sh
scripts/download-sdxs-512.sh                    # the image funnel's first rung
scripts/download-sd15-base.sh
scripts/download-sd15-vae.sh
scripts/download-sd-turbo.sh
scripts/download-lcm-lora-sd15.sh
```

`scripts/repository-quality-gates.sh` reads `QWEN_GATE_HOST_ROLE` to decide the
two coding-principal tests: `appliance` is the default and requires the
qwen-coder account the host holds, `runner` reports both `not_run` with reason
`runner_host` because a GitHub runner carries no such principal, and any other
value is a usage error.

Tests are standalone scripts that exit non-zero on failure, invoked directly, or
through `python3`, or through `node`. `scripts/repository-quality-gates.sh` runs
the clone-local set unattended and its header states the boundary: hardware,
model files, and the pinned llama.cpp source are separate integration surfaces,
so the gate runs only tests whose complete fixtures live in this repository.
Beside these tests it runs `sh -n` or `bash -n` over every `scripts/*.sh`,
`shellcheck -S warning`, `ruff check scripts`, the authority verifiers
`check-nvidia-authority.sh`, `check-validated-tuples.sh`, and
`check-authority-consistency.py`, `refresh-evidence-manifest.sh --check`, and
the two text and artifact policy checks. The list below is in gate order, so a
member added to the script and left undocumented shows up as a diff between the
two:

```sh
python3 scripts/test-quality-suite.py
python3 scripts/test-regrade-quality-roster.py
python3 scripts/test-gguf-tokenizer-identity.py
python3 scripts/test-admit-candidate-static.py
python3 scripts/test-verify-representation-pair.py
python3 scripts/web-mcp/test-web-mcp.py
python3 scripts/web-mcp/test-authorize-broker.py
scripts/test-fallback-webui-model-selection.sh
scripts/test-fallback-webui-web-authorization.sh
scripts/test-fallback-webui-code-authorization.sh
scripts/test-web-tools-roundtrip.sh
node scripts/test-fallback-webui-model-state.mjs
scripts/test-one-token-admission.sh
scripts/test-fetch-candidate-artifact.sh
scripts/test-model-registry.sh
scripts/test-model-tiers.sh
scripts/test-exec-idle-priority.sh
python3 scripts/test-authority-consistency.py
scripts/test-qwen-code-pin.sh
scripts/test-coding-principal.sh            # appliance host role alone
python3 scripts/test-coding-agent-service.py
python3 scripts/coding-mcp/test-coding-mcp.py
scripts/test-coding-agent-launch.sh
scripts/test-coding-principal-path.sh       # appliance host role alone
scripts/test-admit-coding-chain.sh
scripts/test-projector-fetch-dispatch.sh
scripts/test-projector-pairing.sh
scripts/test-probe-depth-projector.sh
scripts/test-promote-llama-build.sh
scripts/test-qwen-launch-router-preflight.sh
scripts/test-qwen-capacity-policy.sh
scripts/test-web-presets.sh
scripts/test-qwen-web-launch.sh
scripts/test-prepare-llama-vulkan-source.sh
scripts/test-qwen-session-signals.sh
scripts/test-admit-web-router-fake.sh
scripts/test-quality-roster.sh
scripts/test-qwen-runtime-guards.sh
scripts/test-exec-profiler-clean-env.sh
scripts/test-gpu-workload-ownership.sh
scripts/test-gpu-quiescence-gate.sh
python3 scripts/test-read-nsys-mat-mul-kernels.py
scripts/test-cuda-build-tiling-threshold.sh
scripts/test-mmvq-width-request-tails.sh
scripts/test-mmvq-tail-logit-margin.sh
scripts/test-repository-quality-gates-host-role.sh
```

These tests run by hand, and each entry names why the gate leaves it out. A
lane held outside the unattended set is a scoping choice rather than a
technical barrier, and the entry says so where that is the whole reason:

```sh
scripts/test-strict-cuda-placement-fixture.sh    # device-placement lane, held outside the unattended set
scripts/test-dispatch-census-summary.sh          # dispatch-census lane, held outside the unattended set
scripts/test-gpu-state-latch.sh                  # driver-failure latch lane, held outside the unattended set
scripts/test-run-graph-alias-ab.sh               # graph-alias lane, held outside the unattended set
scripts/generate-quality-images.py --check       # vision fixtures, held outside the unattended set
scripts/test-image-registry.sh                   # image lane, held outside the unattended set
scripts/test-qwen-image-launch.sh                # image lane, held outside the unattended set
scripts/test-admit-image-router.sh               # image lane, held outside the unattended set
scripts/test-fallback-webui-image-authorization.sh  # image lane, held outside the unattended set
python3 scripts/test-image-protocol.py           # image lane, held outside the unattended set
python3 scripts/test-image-service.py            # image lane, held outside the unattended set
python3 scripts/image-mcp/test-image-mcp.py      # image lane, held outside the unattended set
python3 scripts/test-image-review.py             # image lane, held outside the unattended set
python3 scripts/web-mcp/test-fallback-page-image.py  # drives the appliance's headless Chromium
scripts/test-vulkan-workload-lease.sh            # path check and patch replay run in a clone; the served half reports not_run without a patched llama-server and a model
scripts/verify-llama-patch-series.sh             # needs the pinned llama.cpp source tree
QWEN_LLAMA_CANDIDATE_PATCHES=1 scripts/verify-llama-patch-series.sh
                                                 # the same source tree, candidate patches included
GGUF_PY_PATH=~/src/llama.cpp-qwen-nvidia/gguf-py \
    scripts/test-gguf-tensor-census.py [MODEL...]
                                                 # needs the pinned gguf-py, and GGUF files for the optional arms
```

`scripts/test-fixtures/fake-llama-server.sh` stands in for the real server so a
guard test runs without a GPU.

## Models and projectors pair by directory

`qwen-launch.sh` calls `scripts/select-projector.sh`, which searches the model
file's own directory. A projector encodes images into the embedding space of the
checkpoint that exported it, and a foreign projector of matching dimensions
loads cleanly while placing image tokens where the language model reads nothing,
which answers wrongly rather than failing. Binding the search to the model's own
directory makes a checkpoint published without a projector run text-only.

Publishers name the file differently: Qwen ships `mmproj-F16.gguf` and Ornith
ships `mmproj-Ornith-1.5-9B-BF16.gguf`. The exact name wins where it exists and
a sole `mmproj*.gguf` is taken otherwise, while several candidates print nothing
and name `QWEN_MMPROJ` as the way to choose, since resolving two projectors by
sort order is the mismatch the pairing exists to prevent.

`empero-ai/Qwen3.8-4B-Distill` distills into the Qwen3.5-4B architecture, so
the pinned build loads it unchanged. It reasons in 43.3% of the base model's
tokens, reaches an answer 2.71 times faster across the five-prompt suite, and
its chat template still gates `<think>` on
`chat_template_kwargs.enable_thinking`. It ships text-only, so the vision
profile selects the base checkpoint with its revision-matched projector.
The publisher reports a gsm8k_cot fall from 0.850 to 0.785 alongside an mmlu CoT
rise from 0.354 to 0.553.

The distill's advantage over the base is throughput alone.
`evidence/model-admission/roster-quality-sweep.md` grades both at 47 of 55 with
thinking off, at the same 0.855 correct-on-completed, and within one row in every
category. The five-prompt screen that separated them at 5/5 against 4/5 scored
the base's one failure as an empty answer after 2048 predicted tokens of
reasoning, which is the termination failure thinking off removes.

`empero-ai/Qwen3.8-2B-Distill` is the same architecture at 24 layers and
2048/6144, and it decodes above the 4B in every arm that measured both. It
streams 1.263 GB per token and reaches 10.41 GB/s against the 4B's 8.11 on the
mean of four sweeps, with the 2B ahead in all four pairs, so it streams faster
rather than carrying less overhead. Read the pairs and not the means: the same
checkpoint under identical flags spans 30.6% across those four sweeps, enough
that the 2B's slowest arm falls below the 4B's fastest.

The prior host closed its tested 4B K-quant ladder, its 0.8B low-bit route,
and a Q8_0-versus-Q4_K_M serving comparison on the 0.8B class, and it recorded
two architectures -- LFM2's short-convolution blocks and Qwen2-VL-2B's full
attention -- breaking the size ordering of achieved rate.
`evidence/legacy/raven2/comparative-findings.tsv` and
`evidence/legacy/raven2/universal-candidate-ladder.md` retain those findings
as prior-host comparison. The served `qwen35-08b` Q8_0 row keeps its position
on this device's own CUDA baseline table above rather than on that comparison;
none of the ladder, route, or architecture-ordering arms has run here.

Every distill ships a multi-token-prediction block that the speculation setting
decides the fate of. `qwen35.nextn_predict_layers` is 1 and `block_count` counts
it, so the 2B declares 25 blocks against 24 transformer layers.
`llama_hparams::n_layer_effective` subtracts it from the trunk, and
`src/models/qwen35.cpp` sets `mtp_flags = !ml.load_mtp ? TENSOR_SKIP : 0`, so an
ordinary load reports each of its tensors as `model has unused tensor ... --
ignoring` and skips 37,767,168 bytes on the 2B, matching the census exactly.
That block costs download and disk alone, between 2.61% and 2.88% of each file,
until `--spec-type draft-mtp` sets `load_mtp` and loads it.

The head runs in place. `common/common.cpp` sets `mparams.load_mtp` from
`params.speculative.types`, `common_speculative_init_result` takes its
`else if (spec_mtp)` branch and builds the draft context against the target
model with `cparams.ctx_type = LLAMA_CONTEXT_TYPE_MTP`, and
`llama_model::create_memory` filters that context's KV cache to
`il >= hparams.n_layer()`, so the draft cache holds the appended block rather
than a second trunk. `QWEN_SPEC_TYPE`, `QWEN_SPEC_DRAFT_N_MAX`,
`QWEN_SPEC_DRAFT_P_MIN`, `QWEN_SPEC_BACKEND_SAMPLING`, and
`QWEN_BACKEND_SAMPLING` carry those settings through the tmux boundary into
`qwen-capacity-policy.sh`, which keeps `LLAMA_ARG_*` refused.

`scripts/gguf-tensor-census.py` reports these properties from the file, because
a Q4_K_M label names a recipe rather than a layout: the 2B is 50.08% Q6_K by
byte where the 9B is 32.59%.

A candidate declares its architecture and its chat template before it is
fetched. A GGUF places the metadata block and tensor index at the head of the
file, so `scripts/admit-candidate-static.py` reads them over an HTTP range
request against a pinned revision and imports the census parser rather than
writing a second one. Sixteen mebibytes covers a Qwen3.5 metadata block, whose
248,320 tokens and their merges end the 2B distill's header at 10,962,034
bytes, and the reader grows the window on a short read so a truncated buffer
raises rather than reporting the trailing keys absent. The ranged read
reproduces the appliance's own full-file census on every identity field of the
served 2B, including the 37,767,168 prediction-block bytes.

The script runs on the workstation, which makes it a third workstation-side
helper beside the UI build and the container build: it needs the network, and
a fetch pass is not a resource to spend against a host that is also serving
requests.

Static admission is what makes the throughput stage small. Throughput belongs to
an architecture and a value format, so grouping candidates by architecture,
embedding width, feed-forward width, and head counts collapses the fourteen
GGUF rows of `evidence/model-admission/candidate-ledger.tsv` into four runtime
classes. Eight rows of the largest class span 0.83% in streamed bytes against
the 4% this machine carries on a repeated depth-0 rate, so a second arm inside a
class measures queue position. One class holds a reference at its own format and
three do not: the served 0.8B is Q8_0 and streams 764 MiB per token where its
Q4_K_M class members stream 493 to 522, so that class needs an arm of its own
rather than a cross-format ratio. The same read answers what no rate can: the Jackrong 0.8B Opus
reasoning distill ends its generation prompt with an unguarded `<think>` and
names `enable_thinking` nowhere, so the thinking-off request is inert
against it and its graded arm needs a budget that survives the reasoning span.
`evidence/model-admission/static-admission.md` carries the classes and the
template survey.

A runtime class establishes a shared throughput expectation and nothing about a
particular artifact, so admission by load runs every row rather than one
representative per class. `scripts/run-one-token-admission.sh` fetches each
candidate and calls `scripts/test-strict-vulkan-placement.sh`, which requires CPU
tensor placement and CPU graph placement to be rejected, brings a strict Vulkan
server up, drives a two-token completion, and requires the model, KV, and
compute buffers to name Vulkan0 with no CPU fallback reached. Its `fetch` stage
runs without the device, so eleven gigabytes of transfer happen while the
appliance still serves and the outage covers the loads alone. A control arm runs
the same check against a served checkpoint after each new runtime class and
after any refusal, so a later refusal reads against a device that had just
answered.

A candidate fetched from Hugging Face LFS is verified against the publisher.
`scripts/fetch-candidate-artifact.sh` reads the pinned revision's LFS object ID,
requires the downloaded SHA-256 and byte count to match it, and reports the
digest as `verified_sha256`. A repository artifact published outside LFS has no
publisher digest; the fetcher reports that fallback as `observed_sha256`, and
promotion into `scripts/models.tsv` requires a `download-*.sh` that pins the
observed digest as its expectation.

GGUF weights stay outside Git because their sizes exceed the LFS per-file
limit. Each download script pins a Hugging Face revision, a byte count, and a
SHA-256, and verifies an existing file in place.

## Evidence discipline

`evidence/` holds the measurements that justify every default, and a default
changes when a measurement moves. State the falsification criterion before
running a probe; when a result deviates from prediction, the deviation is the
finding, and the evidence file records it as such. Several results in this
tree exist because a stated hypothesis failed: programmatic dependent launch
was predicted to move decode and moved 0.2% against a 0.3% span, and `-ngl 99`
alone was predicted to place the whole 9B on CUDA0 and instead left enough on
the host to halve its prefill.

A claim that an intervention removed something requires a positive control of
the same shape, unless a retained observation already establishes the thing
present under an otherwise identical model, quantization family, mat-mul width,
closure family, and client set. A single arm reading zero states absence and
attributes it to nothing; the pair `186 -> 0` states that the intervention
caused it. `evidence/ada/mmq-stream-k-grid/phase-b-witness/` is the shape: the
production closure launched 186 `mul_mat_q_stream_k_fixup` beside 186
`mul_mat_q`, the threshold-1 closure launched 186 and 0, and MMVQ held at 164
in both, so grid selection controls divisibility and divisibility controls
whether the fixup launch exists.

`evidence/SHA256SUMS` and `ARTIFACTS.md` fix the retention class of every
surface. Git copies replace the private hostname with `qwen-laptop`, the home
prefix with `$HOME`, and MAC addresses with `<mac>`.

A graded result is conditioned on the request sequence that produced it. Three
repeats of the ten arithmetic rows reproduce exactly, so greedy decoding on this
backend is deterministic within a fixed sequence; prepending the five `screen`
rows moves both 2B checkpoints up one row, deterministically and in the same
direction, and `arith-05` answers 37 cold and 23 warm. Content decides it rather
than count: one unrelated 300-token predecessor leaves the answer at 37, and so
do five short unrelated ones, which is the screen block's own count. Every
arithmetic row reports the same `prompt_n` in all three conditions, so the server
charges the same prompt length warm and cold and what it reuses behind that count
stays open. The mechanism is unisolated and recorded as an effect. The measurement consequence stands on its
own: a one-row or two-row difference between two checkpoints reports position in
a sequence rather than capability, and a quality comparison is read inside one
sweep for the same reason a rate comparison is.

The graded suite reaches past text through one column. `attachment` is `-` for
a text row, `image:NAME` for a vision row, and `tools:SET` for a tool row, so a
row states what its request carries beside the prompt.
`scripts/generate-quality-images.py` draws every fixture from a declaration in
its own source, which is what makes a vision answer gradeable: `bars.png` holds
four bars whose tallest is JUN at 150 because the generator's table says so.
A tool row executes nothing. The appliance runs without `--tools`, so the server
holds no tool server; the request body's `tools` field asks the model to emit a
`tool_calls` object and `tool_call` and `no_tool_call` grade that object, which
measures selection with the read-only boundary intact.
An image-withheld control retains the multipart text part and removes the image
parts, so image presence is the single changed request dimension.

The fixtures are committed and `--check` compares pixels rather than file bytes.
Deflate is not reproducible across hosts -- zlib 1.3 on the appliance re-encodes
7 of the 8 fixtures to different bytes than the workstation wrote, with
identical pixels -- while inflate is fully specified, so decoding both sides
tests the claim a fixture makes and a digest comparison tests the encoder.

A grader defect is corrected over retained replies rather than by re-running.
`nonempty` passed a reply cut at the token budget, which is the termination
failure the row tests, and `scripts/regrade-quality-roster.py` re-applies the
corrected grader to the reply each record already holds. The records stay as the
harness wrote them and `evidence/quality-roster/regrade-summary.tsv` carries the
recorded total beside the corrected one. Transport and served-model attribution
failures remain failures because a content grader cannot repair evidence origin.

`llama-mtmd-cli` is built beside `llama-server` because the projector path fails
by answering rather than by erroring. A projector of matching dimensions loads
cleanly while writing image tokens the language model reads nothing from, so
`scripts/promote-llama-build.sh` reads an image whose content this repository
declares and requires the answer to carry it. Promotion requires the text model,
vision model, projector, and image before either smoke stage begins. The artifact
manifest owns `llama-server`, `llama-cli`, `llama-mtmd-cli`, and the multimodal
consumer's current load closure. Promotion stops when load-closure enumeration
fails, including a helper failure that emits a partial prefix, because that
prefix does not establish a complete dependency identity.
`tools/mtmd/mtmd-cli.cpp:403` sets
`is_single_turn` from a non-empty prompt **and** a non-empty image, so
`--prompt` alone enters the interactive chat loop and a single-shot text run
through that binary is unavailable at the pinned commit.

`evidence/research-claim-methodology.md` defines the article-facing claim
record, architecture authorities, missing-data semantics, experimental design,
and publication gate. A performance document states unresolved direction where
its uncertainty still crosses zero; equivalence requires a declared margin and
two one-sided bounds inside it.

`README.md` states the selected operating configuration. This file governs
repository work, and `evidence/` retains the measurements that put each default
where it is.

## Prose and comments

Prefer affirmative, mechanism-centered prose. Describe what the system does,
the state transitions it performs, and the observable result. Avoid defining
behavior primarily through negation such as "no," "does not," "lacks," or
"without" when the actual behavior can be stated directly. Use negation only
when the absence itself is the relevant fact.

Comments, commit messages, durable docs, thinking, replies in session, and
end-of-session summaries share one voice: direct, declarative, indicative
present tense, artifact as subject.

The voice reaches conversation whole. A reply opens on the finding rather than
on a preamble, states the mechanism before the consequence, and gives each
number its evidence class. Length follows the count of decisive facts, so a
one-fact answer is one or two sentences and a measurement table earns its rows.
A result that contradicts a prediction leads, because the deviation is the
finding; a correction states what is true now and continues, since the
narration of an error costs more than the error. Ceremony, restatement of the
request, and summaries of work about to be described all fall away.

Conversation keeps what its purpose requires. A question the user must answer
is asked plainly, uncertainty is named with its falsifier, and a
recommendation carries the reasoning that would change it. Those are content,
so the voice carries them the same way it carries a register fact.

Write the mechanism first. Name the authority that makes the statement true --
the function, register, spec chapter, environment variable, or measured value
-- then the consequence. The count of distinct decisive facts sets the length;
a sentence that paraphrases another is removed.

State what a thing is and does, and let the positive form carry the absence a
negation would spell out. A binary contrast becomes its positive term. A
stacked absence collapses to the category its members share. A boundary becomes
the restriction it imposes (`loopback only`), the home its content belongs in
(`chronology lives in the commit message`), or the mechanism itself (`the
profile exports one variable, so the rest stay absent`). Each positive form
entails what a negation would state, so the negation stays off the page. A
hard-stop safety or security boundary keeps its prohibition, where that is the
whole content.

Mechanism controls comment length. A single local fact takes one sentence; a
connected relation takes a causal sentence; a short block belongs where the
code depends on a driver rule, a measured quirk, and an observed failure
together. Split when the actor, ownership, phase, evidence class, or invariant
changes. Architecture that persists across a file lives at file scope and the
point of use keeps the local link.

Mark evidence class. Documented behavior takes the plain indicative; behavior
reproduced and undocumented names where it was observed; conjecture is marked
or removed.

Chronology lives in commit messages. Task numbers, phase and wave labels,
session dates, reviewer breadcrumbs, agent names, private hostnames, local
absolute paths, and deictic terms such as `currently` stay out of source
comments. Durable names describe target, mechanism, and outcome.

"Load-bearing" is banned; name the dependency instead -- which value, which
caller, which invariant fails, and what breaks when it changes.

Commit subjects carry a component prefix and a mechanism. The body makes the
invariant, the change, and the evidence reviewable in one to five sentences.
AI participation is disclosed as `Assisted-by: TOOL (MODEL)`, or
`Generated-by:` when AI wrote nearly all of it; `Co-authored-by:` stays
reserved for human co-authors.

## Hard rules

- Checked-in text is emoji-free.
- Straight quotes over curly, `--` over an em dash, `...` over an ellipsis
  glyph. Mathematical operators, Greek letters, arrows, box-drawing, degree and
  micro signs, and accented characters in names stay verbatim.
- Secrets, local absolute paths, and private hostnames stay out of commits.
  `api.key` files stay outside the repository and their contents stay unprinted
  and untransmitted.
- `/etc/sudoers.d/90-qwen-agent` sets `timestamp_type=global` with a 60 minute
  timeout, so one `sudo -v` on the laptop covers the SSH sessions that
  administer it. The user types the password; it stays out of SSH command
  lines, scripts, logs, and project files.
- New files carry no copyright line. Existing upstream headers stay verbatim.
- Scripts are POSIX `sh` with `set -eu`, long descriptive variable names, and a
  usage block that exits 2 on argument error.
- `docker compose` (v2) rather than legacy `docker-compose`.
- `--tools all` grants shell execution and file writing to a prompt-injectable
  model. The read-only set is `read_file,file_glob_search,grep_search`, and a
  tool-enabled server stays off the LAN.
- The service starts and stops through the launch and teardown scripts alone.
  No unit file, crontab entry, or login hook starts it, so a reboot leaves the
  laptop with nothing listening.
