# What a 64K allocation costs on this device

`scripts/models.tsv` admits 65536 tokens on every row whose native context
reaches it, except the 4B distill at 32768 and the 9B distill at 16384. The
figures below are what that costs, measured before the registry moved rather
than after.

Each arm starts one `llama-server` through `scripts/cuda-runtime-env.sh` at the
served tuple -- `--device CUDA0`, `-ot .*=CUDA0`, `--fit off`, `-ctk q8_0`,
`-ctv q4_0`, `-fa on`, `--parallel 1` -- waits for `/health`, and reads
whole-device occupancy from `nvidia-smi`. The compositor holds 1239 MiB before
any arm runs, and the resident column subtracts it. Every figure below is
framebuffer occupancy observed at the sampler's interval after `/health`
answered, so it states what the loaded server settles at rather than the peak
the load demanded: `nvidia-smi` reports the framebuffer counter alone, misses a
spike shorter than its interval, and counts none of the driver-managed pinned
system memory, page-table backing, or virtual-address state that
`evidence/quarantine/qwen38-9b-distill-router-load.md` records a refusal in.

| checkpoint | context | resident total | model and KV |
| --- | ---: | ---: | ---: |
| Qwen3.8-2B distill Q4_K_M | 65536 | 3261 MiB | 2022 MiB |
| Qwen3.8-4B distill Q4_K_M | 65536 | 5339 MiB | 4100 MiB |
| Qwen3.8-9B distill Q4_K_M | 32768 | 7561 MiB | 6322 MiB |
| Qwen3.8-9B distill Q4_K_M | 49152 | 7849 MiB | 6610 MiB |

The 9B's two depths give the marginal cost directly: 288 MiB per 16384 tokens,
about 18 MiB per 1024. Extrapolating its 65536 arm reaches roughly 6.9 GiB,
which is why that row stays at 16384.

## Why the 9B is the exception

The router brings a child up before it releases the one it replaces, so the
admitted depth has to hold for a pair rather than for one model alone whatever
`QWEN_ROUTER_MAX` reads. A 9B at 65536 beside a 4B at 65536 reaches about 11.0 GiB
against a 12282 MiB card that already carries the compositor, and a pair that
overruns the carve-out ends the router rather than the child. What the driver
refuses at that point is an `NV01_MEMORY_SYSTEM` allocation rather than a
framebuffer one, which
`evidence/quarantine/qwen38-9b-distill-router-load.md` reads out of the kernel
ring; the settled-occupancy arithmetic here bounds the pair without naming the
pool. The 9B at 16384 beside a 4B at 65536 measures 11373 MiB with the compositor
counted, and that pair refused on the switch rather than settling, which is why
`scripts/quarantine.tsv` removes the 9B from the router path and the 4B row
reads 32768.

Two children at 65536 measured 7397 MiB together with the 4B distill and the
2B heretic resident.

## What this does not establish

A validated depth. Every arm here proves an allocation and a `/health`
response -- every row above is allocated and health-checked rather than
filled-depth validated. None fills the cache and decodes from it, so
`validated_filled_depth` stays `-` on every row and the registry's two claims
stay two claims. The depth campaign that would move that field needs a CUDA
depth prober, which `docs/APU_UPSTREAM.md` records as absent.

The native ceiling is read rather than assumed: the GGUF header of each
uncensored row reports `qwen35.context_length` of 262144, and the six
later candidates report 128000 or above, so 65536 sits inside every published
range.
