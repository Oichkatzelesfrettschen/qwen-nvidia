# Live Model Memory Preflight

## Gate

`remote/model-memory-preflight.sh` takes a model file and a measured or
conservatively estimated Vulkan working set in MiB. It compiles and runs the
headless `VK_EXT_memory_budget` probe against the RADV ICD, then applies two
independent checks:

```text
MemAvailable >= Vulkan working set + model file bytes + 4 GiB desktop reserve
Vulkan aggregate available >= Vulkan working set + 512 MiB allocator margin
```

The first relation protects physical DDR4 and includes a conservative model
loading-page envelope. The second protects the allocation domain exposed by
RADV. This UMA system requires both; the checks are not additive capacity
claims.

The probe requires vendor `0x1002` and the exact device name
`AMD Radeon Graphics (RADV RAVEN2)`. It queries no display surface and performs
no GPU workload.

## Acceptance evidence

On 2026-08-24, the probe reported:

```text
heap_0_budget_bytes=5540085760
heap_1_budget_bytes=11080163328
aggregate_budget_bytes=16620249088
aggregate_usage_bytes=0
aggregate_available_bytes=16620249088
```

RADV's heap budget already reflects its driver and system limits. The zero
usage belongs to the new probe process; desktop allocations remain represented
by the budget and by the separate DRM and host-memory observations.

A one-MiB synthetic requirement against `/bin/sh` passed both gates. A 65,536
MiB requirement rejected both gates and returned exit status 3. Both C and
shell sources pass warnings-as-errors compilation, ShellCheck at error
severity, and shell syntax validation.

At the accepted probe, `MemAvailable` was about 15.5 GB and existing swap use
was about 5.64 GB. Swap use is recorded rather than counted as model capacity.
Later telemetry must stop a run if swap activity or available memory breaches
the operational threshold.

## Model integration

The Qwen3.5-4B preflight uses the actual file size and a working-set estimate
that includes weights, KV, recurrent state, graph buffers, and staging margin.
The estimate is replaced by measured peak allocation after each context-depth
run. No 9B or 27B model is opened when the live gate rejects it.

The verified 9B Distill artifact uses a 6,144 MiB 4K gate derived in
`evidence/qwen38-9b-distill-admission.md`. It rejects 15,140,962,304 available
host bytes against a 16,517,508,416-byte requirement while accepting the RADV
budget. Refreshed `UD-Q2_K_XL` and `UD-IQ3_XXS` preflights also reject host
capacity and accept Vulkan capacity. Every command returns 3 before llama.cpp
opens a model. Exact outputs and source-file pre-sanitization hashes are in
`evidence/model-admission/`.
