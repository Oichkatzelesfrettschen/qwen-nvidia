# Qwen APU

A standalone local language-model appliance on a two-compute-unit Raven2 APU:
an AMD Athlon Silver 3050U with 29 GiB of shared DDR4, serving through RADV
Vulkan. The laptop is the whole system. The model, the projector, the static
UI, and the responsiveness guards all live on the machine running the browser,
so the appliance answers with the network off.

This repository retains the setup scripts, runtime policy, source patches,
measurements, and benchmark results that produce that deployment.

`evidence/research-claim-methodology.md` maps the hardware, kernel, driver,
inference engine, appliance policy, measurement, and retention authorities. It
defines which observations support an article-facing claim and which residuals
remain open.

## Evidence classes

Every performance figure below carries its class, because the classes carry
different weight in a decision:

| Class | Meaning |
| --- | --- |
| measured | observed on this machine, reproducible by a named script |
| derived | arithmetic over measured values |
| estimated | model-based extrapolation past the measured range |
| untested | named here so its absence stays visible |

## Selected configuration

| Profile | Checkpoint | Placement | Purpose |
| --- | --- | --- | --- |
| `text` | Qwen3.8-2B-Distill Q4_K_M | all layers on Vulkan | default chat, homework, text reasoning at 9.19 tok/s |
| `balanced-text` | Qwen3.8-4B-Distill Q4_K_M | all layers on Vulkan | coding and formatting, 47 of 55 graded rows |
| `vision` | Qwen3.5-4B Q4_K_M with its matched `mmproj-F16.gguf` | language model and projector on Vulkan | images, diagrams, screenshots, textbook pages |
| `deep-text` | Qwen3.8-9B Distill Q4_K_M | all layers on Vulkan | optional slower candidate, quality unqualified |
| `serialized-prefill` | the selected checkpoint | Vulkan, serialized submissions | fallback for long sustained prefill |
| `cpu-control` | the selected checkpoint | CPU only | diagnostic and regression baseline |

The text profile runs full Vulkan placement, the `low-async` submission
profile, LOW RADV queue priority, one server slot, one CPU orchestration
thread at nice 19, a loopback binding, and tools disabled. Router mode serves
every production and candidate row behind one listener and loads one child at a
time, so the profile above names the default the picker opens on.

## Graded quality

`remote/run-quality-roster.sh` grades every servable row against the same 55 text
rows in one sweep, thinking off, 1024-token budget.
`evidence/model-admission/roster-quality-sweep.md` holds the method and the
per-category table.

The suite reaches past text through one column. A row's `attachment` is `-` for
text, `image:NAME` for a vision row, and `tools:SET` for a tool row.
`remote/generate-quality-images.py` draws every fixture from a declaration in
its own source, so a vision answer is graded against a fact this repository
states rather than against a reader's impression, and `--check` compares pixels
because deflate is not reproducible across hosts while inflate is. A tool row
executes nothing: the appliance runs without `--tools`, so the request body's
`tools` field asks for a `tool_calls` object and the graders read that object.
`evidence/model-admission/vision-and-tool-sweep.md` holds those results.

That measurement carries two claims and the registry keeps them apart.
`raw_tool_selection` is the graded tool category, the model unaided.
`guarded_tool_execution` states whether a row may execute a tool at all, and
every row reads `refused`: `tool-08` puts an instruction inside the note the
user asks about, and all six measured arms carried the injected city into the
call in place of the authorized one. A high selection score is therefore not an
execution grant, and a low one is not a serving hazard -- the 2B distill scores
2 of 10 and remains the `text` default. What would move a row is a runtime that
compares emitted arguments against the user's own authorization before
executing, which this appliance does not have and does not need while it runs
without `--tools`.

| Checkpoint | passed | correct on completed | class |
| --- | ---: | ---: | --- |
| Qwen3.5-4B base Q4_K_M | 47/55 | 0.855 | measured |
| Qwen3.8-4B Distill Q4_K_M | 47/55 | 0.855 | measured |
| LFM2.5-VL-1.6B Q4_K_M | 43/55 | 0.782 | measured |
| Qwen3.5-2B Q4_K_M | 41/55 | 0.745 | measured |
| Qwen3.8-2B Distill Q4_K_M | 40/55 | 0.755 | measured |
| Qwen3.5-0.8B Q8_0 | 33/55 | 0.600 | measured |

A one-row or two-row difference reports position in a request sequence rather
than capability: prepending five rows moves both 2B checkpoints up one
arithmetic row, deterministically.

## Throughput

Measured by `remote/run-placement-sweep.sh` through `llama-bench`, outside the
guarded launch path, at 512 prompt tokens and 64 generated tokens.

| Checkpoint | weights | prefill tok/s | decode tok/s | class |
| --- | ---: | ---: | ---: | --- |
| Qwen3.8-4B distill Q4_K_M | 2.58 GiB | 22.00 | 3.02 | measured |
| Qwen3.5-4B base Q4_K_M | 2.54 GiB | 20.88 | 2.84 | measured |
| Qwen3.8-9B distill Q4_K_M | 5.37 GiB | 11.47 | 1.76 | measured |
| Qwen3.8-27B UD-Q2_K_XL | 9.15 GiB | -- | about 1.17 | estimated |

The 27B figure extrapolates a two-point cost model of 0.158 s per token plus
0.0763 s per GiB across a change of model size, quantization family,
dequantization arithmetic per byte, tensor shapes, cache behavior, and kernel
efficiency at once. Two model sizes establish no general law, and the operating
conclusion holds across the plausible range: at 0.8 through 1.2 tok/s a
200-token reasoning span costs three to four minutes of decode before prefill.
The 27B quantizations stay capacity experiments rather than interactive
profiles.

## Full Vulkan placement is settled

Decode against the count of layers resident on Vulkan, Qwen3.5-4B Q4_K_M, two
threads, measured:

| Layers on Vulkan, of 32 | prefill tok/s | decode tok/s |
| ---: | ---: | ---: |
| 0, CPU only | 16.09 | 2.63 |
| 9 | 20.00 | 2.30 |
| 18 | 20.04 | 2.42 |
| 27 | 21.21 | 2.59 |
| 32, all | 21.20 | 2.84 |

Every tested hybrid placement lost to full Vulkan, and decode rises from the
9-layer minimum through the fully offloaded endpoint. The ladder dips below
CPU-only at its first partial point rather than rising throughout: a split adds
CPU-to-Vulkan synchronization and activation transfers while both sides draw on
the one DDR4 controller, so the two placements share a bandwidth domain instead
of combining independent ones. Full offload also leaves both CPU cores to the
desktop.

Sequential host read bandwidth measures 7.97 GB/s on one thread and 15.44 GB/s
on two, while one decode arm moves weights at roughly 7.8 GB/s. The numerical
similarity is descriptive rather than a ceiling: the Zen+ load/store path and
the Vega compute units are different consumers of the shared controller, and
the retained host test does not measure the GPU path.

## The responsiveness guards show no resolved throughput cost

| Configuration | decode tok/s | class |
| --- | ---: | --- |
| Unconstrained `llama-bench`, full Vulkan | 2.86 | measured |
| Guarded server, same checkpoint and placement | 2.87 | measured |

LOW RADV queue priority, nice 19, single-core affinity, idle I/O priority, one
slot, and one thread land within measurement variation of the unconstrained
rate. A separate six-pair nice 19 against nice 0 run under desktop load measures
a 1.10% mean difference in favour of nice 19, while its nominal paired interval
spans -6.1% to +3.9%. The retained data resolve no directional cost and do not
establish statistical equivalence. The guards remain the operating
configuration because they preserve desktop priority without a measured
throughput regression.

The graphics latency probe measures the desktop side of that claim: 99.87% to
99.96% of probe submissions complete inside one 60 Hz frame under chat load,
with two to six deadline breaches across five to eight thousand samples. The
probe counts a late frame and reports it. Thermal behavior is observed and
reported rather than aborted, and the system governs its own clocks.

## Submission profiles

`low-async` is the default. It exports `GGML_VK_MAX_NODES_PER_SUBMIT=16` and
leaves `GGML_VK_SERIALIZE_SUBMISSIONS` **absent from the environment**, which
is the literal state responsible for the measured 1.348 to 2.718 decode tok/s
difference against `low-serialized`. Setting that variable to `1` selects the
serialized fallback. Submission node count is close to irrelevant by
comparison: 32 to 512 moved the same request 1.348 to 1.396.

The evidence supports low-priority asynchronous Vulkan as harmless to frame
timing **during chat decode**, where it produced zero breaches. It does not yet
cover arbitrary long prompt ingestion: a 4,096-token prefill raised probe p90
8.6-fold, and long prefill and autoregressive decode present different
submission shapes and duty cycles. `low-serialized` therefore remains the
explicit long-prefill fallback.

`GGML_VK_ALLOW_GRAPHICS_QUEUE=1` is rejected on both terms at once: 66% of
frames on time with 346 breaches, and slower inference than the compute queue.

## Model selection

Two text profiles carry two different claims. `text` opens on the 2B distill,
which decodes 9.19 tok/s and grades 40 of 55; `balanced-text` holds the 4B
distill, which decodes 3.34 tok/s and grades 47 of 55. The picker offers both
and the selected-configuration table above states which one it opens on.

Inside the 4B pair the distill is selected over the base on measured appliance
behavior rather than on an accuracy claim. Five fixed prompts, reasoning
enabled, 2,048-token ceiling, through `remote/reasoning-span-probe.sh`:

| Quantity | base | distill | class |
| --- | ---: | ---: | --- |
| Generated tokens across the set | 4,874 | 2,111 | measured |
| Wall clock for the set | 33.3 min | 12.3 min | measured |
| Completed answers | 4 of 5 | 5 of 5 | measured |
| Decode over matched-length spans | 2.563 | 2.721 | measured |
| Share of base tokens | -- | 43.3% | derived |
| Time-to-answer improvement | -- | 2.71x | derived |
| Completed answers per wall-clock minute | -- | 3.38x | derived |

Matched-length decode differs by 6.2%, so the practical gain comes from
reasoning efficiency and termination rather than from faster Vulkan kernels.
On the fourth prompt the base model consumed its entire 2,048-token budget
inside the reasoning span and returned an empty answer after 830 seconds. That
result establishes unsuitability under the appliance's configured ceiling. What
the base model does under a different reasoning setting is since measured: with
thinking off across 55 rows the two 4B checkpoints tie at 47, at 0.855
correct-on-completed, and within one row in every category, so the distill's
advantage over the base is throughput and termination rather than accuracy.

The distill's published `gsm8k_cot` score falls from 0.850 to 0.785 against the
base while `mmlu` CoT rises from 0.354 to 0.553. Three arithmetic prompts in
the set above succeeded on both models, which shows the regression absent from
a very small sample and falsifies nothing at population scale. Local math
accuracy is **untested**. Separating those two scores at conventional
significance needs several hundred items per model, about a day of wall clock
each at these rates, and that run belongs to estimating accuracy rather than to
selecting a default.

The 9B distill decodes at 58.3% of the 4B distill's rate. It earns a profile
rather than the default, and it becomes competitive only by generating fewer
tokens, terminating more reliably, or solving materially harder work. The same
five-prompt suite against the 9B, under an identical template, reasoning
setting, ceiling, and scoring, is the decision-relevant next measurement.

## Projectors pair with their checkpoint by directory

`qwen-launch.sh` searches for a projector beside the model file. A projector
encodes images into the embedding space of the checkpoint that exported it. A
foreign projector of matching dimensions loads cleanly and places image tokens
where the language model reads nothing, so it answers wrongly rather than
failing. Directory pairing is a correctness requirement, and `models.tsv`
names the exact projector fetch script for every required pairing. A checkpoint
published without a projector runs text-only unless an explicit fetch uses that
row's downloader.

The 4B distill ships text-only, and `/props` reports `vision: false` under it.
Vision therefore selects the base checkpoint, whose projector is pinned to the
same Hugging Face revision as its language GGUF.

## Tools are disabled by default

Tool schemas travel in the request body and render into the prompt through the
chat template, so they are paid on every turn.

| Request | prompt tokens | prefill seconds | class |
| --- | ---: | ---: | --- |
| Bare five-word question | 20 | 1.7 | measured |
| Same question, three read-only tool schemas | 527 | 28.2 | measured |
| Cost of the schemas | +507 | +26.5 | derived |

An observed llama-ui turn carrying its client-side tool definitions reached 418
prompt tokens for the same five-word question. Tool schemas therefore cost
roughly 400 to 500 prompt tokens and 21 to 27 seconds before the first
generated token, which exceeds every remaining inference-tuning gain available
on this hardware.

Modes select their own schemas: chat sends none, files sends `read_file`,
`file_glob_search`, and `grep_search`, math sends a calculator or verifier, and
an agent mode sends a chosen read-only subset. Prompt caching lowers the cost of
repeated tool-enabled turns and leaves the first turn's penalty intact.

The pinned llama-ui at `f280b26` declares `exec_shell_command`, `write_file`,
and `edit_file` with `ToolSource.SERVER` in `tools/ui/src/lib/enums/tools.enums.ts`,
so llama-server executes them and the front end only offers them. `--tools`
grants them, the appliance binds `0.0.0.0` in router mode, and no launch script
in this tree emits that flag. `remote/test-qwen-capacity-policy.sh` asserts its
absence from both the single-model and the router argument list, and
`remote/test-model-tiers.sh` asserts `LLAMA_ARG_TOOLS` appears in no preset
section, since a preset key grants what a flag grants. `run_javascript` is
`ToolSource.BROWSER` and executes in the viewer's own sandbox.

## Memory admission

The Vulkan heap on an APU is carved from system RAM, so a Vulkan allocation
already holds the resident weights. The retired formula summed the Vulkan
allocation, the model file, and the desktop reserve, which charged the weights
twice and refused Qwen3.8-9B at 17.591 GB required against 15.373 GB
available. A live server holding 2.74 GB of weights reports 229 MB resident and
no swap in `smaps_rollup`, so the second charge described memory nothing
allocates.

The estimator is now advisory: it prints a signed surplus or shortfall and
admits every launch. An estimate is an estimate, and this one was wrong in a
way that read as a hardware limit.

Advisory admission alone remains incomplete. Linux can accept an oversized
allocation and then fill zram, swap unrelated applications, sustain major
faults, enter prolonged reclaim, or invoke the OOM killer, leaving the desktop
unusable well before the model process exits. A pressure guard keyed to
observed state -- `MemAvailable`, `SwapFree`, zram occupancy, memory PSI, major
fault rate, server RSS, Vulkan allocation, desktop reserve -- rejecting only
when pressure is already severe, plus a post-load single-token verification for
swap growth and frame budget, is **untested** and outstanding.

Capacity measurement requires a defined machine state. A concurrent desktop
session holding Firefox, a QEMU guest, near-full zram, and 8.6 GiB of swap
disqualifies a 9B capacity result. The machine measures idle and again under a
stated representative load.

## Context

| Setting | Tokens | Status |
| --- | ---: | --- |
| Active interactive profile | 24,576 | measured operating point |
| Capability floor | 32,768 | untested |
| Extended targets | 65,536 and 131,072 | untested |

The active setting is a valid operating point and leaves the floor unmet. At
roughly 18 prompt tokens per second a full large-context prefill is a capacity
operation rather than an interactive one, and prefill and decode are reported
separately for that reason.

## Network profiles

| Profile | Binding | Key | Tools |
| --- | --- | --- | --- |
| Standalone, canonical | `127.0.0.1:8080`, `--offline` | none | permitted inside the OS sandbox |
| LAN, explicit opt-in | `QWEN_BIND_HOST=0.0.0.0` | none on a trusted network | disabled unless authenticated or source-restricted |

Loopback is the canonical address. A keyless LAN endpoint is a deliberate
trusted-network test profile, and once local file tools are enabled an
unauthenticated LAN endpoint grants every client on the network the server
process's file-reading capability. The startup summary lists real network
interfaces; libvirt and Docker bridge addresses are labeled as such.

## Lifecycle

`remote/qwen-launch.sh` starts the appliance and returns once `/health`
answers. `remote/qwen-teardown.sh` stops it and proves that the server, the
tmux session, the guards, and the probe are gone, exiting non-zero on residue.
No unit file, crontab entry, or login hook starts the service, so a reboot
leaves the laptop with nothing listening.

`llama-server` is the only persistent process. It serves inference, the
OpenAI-compatible API, the static UI, multimodal processing, and prompt
caching. Node is a build-time dependency on the workstation, and
`remote/build-llama-ui.sh` delivers the SvelteKit output as static files.

## Layout

`CLAUDE.md` carries the repository doctrine, the launch chain, and the prose
voice. `TASK_TRACKER.md` is the execution ledger. `remote/` holds the
launchers, guards, tests, and measurement harnesses. `patches/` reconstructs
the pinned llama.cpp changes. `evidence/` retains raw and synthesized
measurements. The executables stay outside Git, and `ARTIFACTS.md` records the
byte count and SHA-256 that a rebuild reproduces.
`webui/` holds the diagnostic panel, and `WEBUI.md` defines deployment and
control.

GGUF weights stay outside Git and LFS because their sizes exceed the 2 GB
per-file limit. Each fetch script pins a Hugging Face revision, a byte count,
and a SHA-256, and verifies an existing file in place:
`remote/download-qwen38-2b-distill-q4km.sh` for the text default and
`remote/download-qwen38-4b-distill-q4km.sh` for the balanced-text profile,
`remote/download-qwen35-4b-q4km.sh` with
`remote/download-qwen35-4b-mmproj.sh` for the vision profile, and
`remote/download-qwen38-9b-distill-q4km.sh` for the deep profile.

## Outstanding

- The same five-prompt suite against the 9B distill, identical template,
  reasoning setting, ceiling, and scoring.
- CPU0 against CPU1 for the inference pin, measured on decode, prefill, frame
  p50/p90/p99, breach count, and amdgpu IRQ rate. `/proc/interrupts` places the
  keyboard, touchpad, and GPIO controller wholly on CPU0 and amdgpu's
  completion interrupts three-to-one on CPU1, so the two effects oppose and
  `QWEN_INFERENCE_CPU` stays configurable with the existing pin as default.
- A prefill microbatch sweep under `low-async`, varying `--ubatch-size`
  directly. The 32-to-512 submission-node experiment varied graph submission
  size and settles nothing about microbatch size.
- A reasoning-termination safeguard: cancel a request that emits only
  `reasoning_content` past a configured threshold, retry once with
  `enable_thinking: false`, and report the fallback rather than presenting two
  runs as one generation.
- The observed-pressure memory guard and post-load verification.
- The 32K capability run on the selected checkpoint.
