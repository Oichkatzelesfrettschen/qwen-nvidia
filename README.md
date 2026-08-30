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

`scripts/build-llama-cuda.sh` builds one `llama-server` carrying both the CUDA
and Vulkan backends, so `llama-bench --device` selects between them and two
rows differ by the backend alone. `CMAKE_CUDA_ARCHITECTURES=89` emits one SASS
variant for this device, `GGML_CUDA_FA_ALL_QUANTS=ON` compiles flash-attention
kernels for the served `cache_type_k=q8_0`/`cache_type_v=q4_0` pair rather than
leaving it off the flash-attention path, and the build runs through `g++-15`
because nvcc refuses a host compiler newer than GCC 15.

CUDA0 is the serving backend and Vulkan0 is the fallback the same binary
reaches, selected by `QWEN_SERVING_BACKEND` and named explicitly with
`--device`. Serving defaults are CUDA graphs on, kernel fusion on, programmatic
dependent launch unset, `--fit off`, and explicit tensor placement
`-ot .*=CUDA0`; a launch that names neither device risks the scheduler
allocating on Vulkan0 for the same card, which is what `--device` and `-ot`
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

## Runtime classes

The 2B class is the appliance's primary performance target and the 0.8B class
its secondary fast target; the 4B class is the quality-heavy fallback and the
9B class the deep-text option. A general runtime experiment runs the 2B first,
the 0.8B second, and the 4B third, and becomes a repository-wide default only
where the classes agree.

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

## Lifecycle

`scripts/qwen-launch.sh` starts the appliance and returns once `/health`
answers; `scripts/qwen-teardown.sh` stops it and proves the server, the tmux
session, and its guards are gone, exiting non-zero on residue.
`QWEN_ROUTER=1` opens the model picker instead of a single checkpoint. The
service starts and stops through these two scripts alone -- no unit file,
crontab entry, or login hook starts it, so a reboot leaves the host with
nothing listening.

```sh
scripts/qwen-launch.sh [default|no-graphs|no-fusion|pdl|unified]
QWEN_ROUTER=1 QWEN_ROUTER_MAX=2 scripts/qwen-launch.sh
scripts/qwen-teardown.sh
```

`CLAUDE.md` carries the repository doctrine: the launch chain, the hardware
ceilings, the registry and quarantine rules, the web and image lanes, and the
full command reference. `evidence/ada/` holds every measurement taken on this
host; the remainder of `evidence/` predates it.
