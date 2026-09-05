# Qwen NVIDIA

A local language-model appliance on a discrete NVIDIA GPU: an AMD Ryzen 5
5600X3D workstation (six Zen 3 cores, twelve threads, 96 MiB L3, 31 GiB DDR4)
paired with one NVIDIA GeForce RTX 4070 Ti -- AD104, compute capability 8.9,
12282 MiB of GDDR6X on a 192-bit bus, driver 610.57.04, CUDA 13.3. The
workstation is the whole system: the Git checkout and the runtime share the
host, and `scripts/` holds the scripts the appliance runs from that same
checkout.

This repository is derived from the `qwen-apu` appliance tree, which serves a
different device over a different driver. Its measurements are authoritative
only in that tree; `docs/APU_UPSTREAM.md` states the relationship and what the
isolation pass left unported, and `evidence/legacy/raven2/` retains the
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

CUDA0 is the one serving backend, and the promoted closure `88681bf4d161`
carries the CUDA backend alone. Vulkan serving and Vulkan admission campaigns
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
constrained to `QWEN_ROUTER_MAX=1`. The active model quarantine set in
`scripts/quarantine.tsv` consists of `ministral3-3b`.

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
carries. Every performance number taken before this host belongs to the
`qwen-apu` upstream tree, with the conclusions that still bear on a decision
here retained under `evidence/legacy/raven2/`; `docs/APU_UPSTREAM.md` states
the evidence-class rule that keeps those numbers out of a CUDA prediction.

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
Q8_0 at sixteen (`evidence/ada/promotion-88681bf4d161/`).

## Promotion is CUDA-authoritative

`scripts/promote-llama-build.sh` decides promotion on CUDA0: a strict
one-token placement check and a multimodal smoke both run with
`LLAMA_NO_CPU_FALLBACK=1` and require every weight buffer to name CUDA0. A
build that also carries `libggml-vulkan.so` is refused ahead of both smokes,
and an accepted promotion reports `backend_set=cuda`.
The served closure is configuration `88681bf4d161`
(`evidence/ada/promotion-88681bf4d161/`), using 89-real, CUDA only, Q6_K MMVQ
threshold 10, and Q8_0 MMVQ threshold 16. Configuration `31d0775c5bc6` is
retained as the rollback target, and configuration `572951d25562` is retained
as the PTX-bearing dual-backend diagnostic closure.

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
