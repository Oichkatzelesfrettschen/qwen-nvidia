# Qwen NVIDIA

A local language-model appliance on a discrete NVIDIA GPU: an AMD Ryzen 5
5600X3D workstation (six Zen 3 cores, twelve threads, 96 MiB L3, 31 GiB DDR4)
paired with one NVIDIA GeForce RTX 4070 Ti -- AD104, compute capability 8.9,
12282 MiB of GDDR6X on a 192-bit bus, driver 610.57.04, CUDA 13.3. The
workstation is the whole system: the Git checkout and the runtime share the
host, and `scripts/` holds the scripts the appliance runs from that same
checkout.

Measurements taken on another device, over another driver, are not
authoritative here; `evidence/legacy/raven2/` retains the
conclusions that still bear on a decision here.

## Backend

`scripts/build-llama-cuda.sh` builds the `llama-server` the appliance serves
with the CUDA backend alone; `QWEN_BUILD_VULKAN=ON` adds the Vulkan backend to
a diagnostic closure, on which `llama-bench --device` selects between the two
and two rows differ by the backend alone. `CMAKE_CUDA_ARCHITECTURES=89` emits one SM89
SASS variant plus compute_89 PTX for driver JIT and `cuobjdump`. The compact
local-serving arm selects `89-real` explicitly and emits SASS alone.
`GGML_CUDA_FA_ALL_QUANTS=ON` compiles flash-attention
kernels for the served `cache_type_k=q8_0`/`cache_type_v=q4_0` pair rather than
leaving it off the flash-attention path, and the build runs through `g++-15`
because nvcc refuses a host compiler newer than GCC 15.

CUDA0 is the one serving backend, and the promoted closure `39a6bc778ef4`
carries the CUDA backend alone and the compute lease. Vulkan serving and Vulkan admission campaigns
are retired in this repository: `QWEN_SERVING_BACKEND` takes `cuda` alone and
the launch chain refuses `vulkan`, `scripts/promote-llama-build.sh` refuses a
build carrying `libggml-vulkan.so`, and the retained diagnostic closure
`572951d25562`, which builds both backends, runs by hand for a diagnostic
question and gates no CUDA work; `scripts/serving-closures.tsv` names each
closure by role. The graphics-latency probe stays as a narrowly named Vulkan
diagnostic exception until a replacement measures the same desktop property.
Serving defaults are CUDA graphs on, kernel fusion on, programmatic
dependent launch unset, `--fit off`, and explicit tensor placement
`-ot .*=CUDA0`; a launch that names no device risks the scheduler allocating
on Vulkan0 under the diagnostic closure, which is what `--device` and `-ot`
exist to prevent. The device memory carve-out, not host bandwidth, sets the
serving ceiling: 12282 MiB holds one 9B Q4_K_M trunk, a 0.8B draft, and two KV
caches with little room left over.

## Speculation

`QWEN_SPEC_TYPE=draft-mtp` loads each distill's own multi-token-prediction
block as the draft rather than a second resident model, and it wins on every
measured target class here -- 1.23, 1.42, and 1.47 against baseline on the 2B,
4B, and 9B, for 150 to 470 MiB of additional weights. A resident 0.8B external
draft is refuted on every target class in the same sweep, at 0.42, 0.61, and
0.75 of baseline on the 2B, 4B, and 9B targets.
`evidence/ada/speculation-runtime-classes.md`
carries the sweep.

`scripts/models.tsv` carries the capability and the policy as two columns per
row: `mtp_layers` is what the GGUF header declares -- `0` for no prediction
block, `-` for an unread row -- and `speculation_profile` is what the appliance
does with it, naming a row of `scripts/speculation-profiles.tsv` that
`build-router-presets.sh` emits into that row's own router section. The 2B,
4B, and 9B distills each carry `mtp_layers=1` and `speculation_profile=mtp1`;
`speculation_evidence` points every one of them at
`evidence/ada/speculation-runtime-classes.md`, since that sweep measured all
three as targets. The 0.8B and `qwenseer-2b` rows read `capability-only`: the
block loads on both but only the 0.8B has run as a draft, and neither has run
as an MTP target.

## Runtime classes

The 2B class is the appliance's primary performance target and the 0.8B class
its secondary fast target; the 4B class is the quality-heavy fallback and the
9B class the deep-text option. A general runtime experiment runs the 2B first,
the 0.8B second, and the 4B third, and becomes a repository-wide default only
where the classes agree. The 4B distill's registry row admits `context_default`
and `context_ceiling` both at 32768, so the balanced-text class runs the same
depth interactively and at its policy limit rather than the larger allocation
its 131072 `context_target` names.

Two registry rows depart from the `lru` default and carry
`switch_policy=evict-first`. `qwen38-9b-distill` left its former router
quarantine after the retained evict-before-load admission run
(`evidence/ada/evict-first-9b-readmission/`) proved sequential child
teardown returns memory before the 9B allocates, and `qwen25-coder-7b`
carries the same policy on the transition
`evidence/ada/evict-first-7b-admission/` measured, where the resident child
unloaded 1404 ms before its successor loaded. A roster holding either row
serves one child at a time, so router construction and launch are
constrained to `QWEN_ROUTER_MAX=1`. Nine rows carry
`switch_policy=standalone-only`, which the router never serves: the
coding-agent roster `oxcoder-9b`, `ornith15-9b`, `qwable-9b-fable5`,
`qwen3-4b-instruct-2507`, `klear-agentforge-8b`, `hammer21-3b`,
`granite40-micro`, `swe-dev-7b` and `swe-agent-lm-7b`, and the second
wave `lfm25-8b-a1b`, `lfm25-12b-instruct`, `smollm3-3b` and `phi4-mini`,
admitted in `evidence/ada/agent-model-roster/` as standalone launch
subjects for the summarize roster. Each holds that policy until a router
transition of its own is measured, because three of them are Q6_K 9B
artifacts whose tensor sets alone exceed the device pairwise. The active
model quarantine set in `scripts/quarantine.tsv` consists of
`ministral3-3b`.
`lfm25-8b-a1b` and `phi4-mini` aborted under the appliance's full tensor
override because `llama_context::graph_max_nodes` gave their architectures
eight nodes per tensor where the served `qwen35` gets thirty-two;
`patches/llama-sched-graph-budget.patch` raises the multiplier for those
two architectures, the build that carries it serves both rows, and the
quarantine is lifted. `lfm25-12b-instruct` and `smollm3-3b` render no
`tool_calls` branch and complete no forced tool call, so they produce no
graph input, which is a template property carrying no device observation:
their exclusion is the registry tier and `standalone-only`, the way
`hammer21-3b`'s is. `evidence/quarantine/` carries a record for each of
the four and `evidence/ada/agent-model-roster/WAVE2-REBUILD.md` carries
the rebuild.

## Measured baseline

Paired forward/reverse mean, `evidence/ada/baseline-sweep-02/`, through
`scripts/run-cuda-baseline-sweep.sh` at the served `-ot .*=CUDA0` placement:

| Checkpoint | prefill tok/s | decode tok/s |
| --- | ---: | ---: |
| Qwen3.5-0.8B Q8_0 | 22769.94 | 310.50 |
| Qwen3.8-2B distill Q4_K_M | 14748.05 | 231.37 |
| Qwen3.8-4B distill Q4_K_M | 6703.23 | 113.54 |
| Qwen3.8-9B distill Q4_K_M | 4410.81 | 67.91 |

These four rows are the only current-host throughput figures this file
carries. Every performance number taken before this host was measured on other
hardware, with the conclusions that still bear on a decision here retained
under `evidence/legacy/raven2/`. An off-device number never enters a CUDA
prediction.

## Kernel crossover calibration

`evidence/ada/b789-clean-calibration/` closes the B7/B8/B9 matrix on a clean
boot for Q4_K, Q5_K, and Q6_K: the Q4_K and Q5_K MMVQ-to-MMQ crossovers at seven
columns are correctly placed on AD104, rate-neutral against the run's own
drift floor. The Q6_K move to MMQ at nine columns costs 22% per token instead,
four times that floor, so the RTX 4090-tuned crossover abandons MMVQ at the
point it is still the faster family on this device.
`evidence/ada/b789-cublas-differential/` rules out forced cuBLAS as the fix:
dequant+GEMM runs at roughly half the MMQ rate past the crossover.
`evidence/ada/mmvq-crossover-ad104/` answers the extension question:
`patches/llama-cuda-mmvq-crossover-ad104.patch` parameterizes the Ada Q6_K
and Q8_0 ceilings as named CMake thresholds and instantiates the kernel
through sixteen columns. The promoted serving closure places Q6_K at ten and
Q8_0 at sixteen (`evidence/ada/promotion-39a6bc778ef4/`, carried forward
from `evidence/ada/promotion-192d0663a533/`).

## Promotion is CUDA-authoritative

`scripts/promote-llama-build.sh` decides promotion on CUDA0: a strict
one-token placement check and a multimodal smoke both run with
`LLAMA_NO_CPU_FALLBACK=1` and require every weight buffer to name CUDA0. A
build that also carries `libggml-vulkan.so` is refused ahead of both smokes,
and an accepted promotion reports `backend_set=cuda`.
The served closure is configuration `39a6bc778ef4`
(`evidence/ada/promotion-39a6bc778ef4/`), using 89-real, CUDA only, Q6_K MMVQ
threshold 10, Q8_0 MMVQ threshold 16, and
`patches/llama-server-vulkan-workload-lease.patch`, so llama-server holds the
compute lease across its model load and every decoding pass and its teardown
reports the hold. It carries `patches/llama-sched-graph-budget.patch`, which
is why `phi4-mini` and `lfm25-8b-a1b` load on it, and
`patches/llama-server-tool-choice-object.patch`, which resolves the OpenAI
named-function `tool_choice` object to the named tool under `required`
rather than the `auto` upstream's string read falls back to; graft's
adapter sends that object, so every forced call graft makes is forced on
this closure and on none before it. Configuration `192d0663a533` is retained
as the rollback target, and configuration `572951d25562` is retained as the
PTX-bearing dual-backend diagnostic closure.

`QWEN_CUDA_ARCHITECTURES` defaults to `89`, which emits PTX beside SASS, and
the serving arm is `89-real`, which emits SASS alone; the two decode at the
same rate and differ by 30 MB of PTX the driver never reads on an SM 8.9
device (`evidence/ada/cuda-architecture-89-vs-89-real.md`).
`scripts/promote-llama-build.sh` holds a build's recorded `arch` against the
arm the serving ledger names and refuses the other unless
`QWEN_PROMOTION_ARCHITECTURE` names it: `efa48befa03b` and `1f88e8fca5ef`
took the bare default before that gate existed and are retained unpromoted.

## Roadmap

The bounded coding-agent service runs under the `qwen-coder` principal,
distinct from the serving user, with one ephemeral worktree per job, so an
agent granted execution reaches neither the appliance's credentials nor its
working tree. Fast coding is admitted: `qwenseer-2b` drove the full
WebUI-to-teardown chain at 32768 through two single-use approvals
(`evidence/coding-agent/chain-admission/`), and `code-fast-a` with the
`qwen-code` runtime reads `validator-gated`. Deep coding stays refused:
`qwen25-coder-7b` validates at 32768 and `code-deep-a` carries that
context, but the profile opens only after the same chain passes at that
depth under its `evict-first` transition.

## Lifecycle

`scripts/qwen-launch.sh` starts the appliance and returns once `/health`
answers; `scripts/qwen-teardown.sh` stops it and proves the server, the tmux
session, and its guards are gone, exiting non-zero on residue.
`QWEN_ROUTER=1` opens the model picker instead of a single checkpoint. The
service starts and stops through these two scripts alone -- no unit file,
crontab entry, or login hook starts it, so a reboot leaves the host with
nothing listening.

The router takes two named shapes, because the resident count follows the
roster rather than the command. `router-compact-pair` is the two-child
figure `evidence/ada/cuda-router-serving/` measured, admitted for a roster
of `lru` rows alone; `router-full-evict-first` is the one-child shape any
roster containing an `evict-first` row requires, and the launch validator
refuses an `evict-first` section at any other listener count.

```sh
scripts/qwen-launch.sh [default|no-graphs|no-fusion|pdl|unified]
# router-compact-pair: LRU-only roster, the measured two-child co-residency
QWEN_ROUTER=1 QWEN_ROUTER_MAX=2 scripts/qwen-launch.sh
# router-full-evict-first: mandatory wherever an evict-first row is servable
QWEN_ROUTER=1 QWEN_ROUTER_MAX=1 scripts/qwen-launch.sh
scripts/qwen-teardown.sh
```

`CLAUDE.md` carries the repository doctrine: the launch chain, the hardware
ceilings, the registry and quarantine rules, the web and image lanes, and the
full command reference. `evidence/ada/` holds every measurement taken on this
host; the remainder of `evidence/` predates it.
