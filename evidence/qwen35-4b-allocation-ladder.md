# Qwen3.5 4B Allocation Ladder

The Q4_K_M artifact is 2,740,937,888 bytes, or about 2,614 MiB. The eight
full-attention layers carry a Q8 K plus Q4 V cache costing 13 MiB per 1,024
tokens, so the cache scales linearly with the served context.

## Operational rungs

`qwen-capacity-policy.sh` caps the served context at 24,576 tokens and
`run-depth-benchmark.py` caps a benchmark prompt at 24,000 tokens. The served
ladder therefore spans 4K through 24K. Each estimate below sums the measured
model buffer, the linear KV term, the measured recurrent state, and the
interpolated Vulkan compute buffer.

| Context | Model | KV | Recurrent state | Vulkan compute | Estimated Vulkan self | Required gate | Headroom |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 4K | 2,603.50 MiB | 52.00 MiB | 50.25 MiB | 18.52 MiB | 2,724 MiB | 4,096 MiB | 1,372 MiB |
| 8K | 2,603.50 MiB | 104.00 MiB | 50.25 MiB | 19.52 MiB | 2,777 MiB | 4,096 MiB | 1,319 MiB |
| 16K | 2,603.50 MiB | 208.00 MiB | 50.25 MiB | 21.52 MiB | 2,883 MiB | 4,608 MiB | 1,725 MiB |
| 24K | 2,603.50 MiB | 312.00 MiB | 50.25 MiB | 23.52 MiB | 2,989 MiB | 4,608 MiB | 1,619 MiB |

The 4K and 24K rows are measured. Loading at `--ctx-size 24576` reports a
2,974 MiB Vulkan self figure against the 2,989 MiB interpolated estimate, a
0.5% overstatement, and leaves 12,804 MiB free under a 4,608 MiB gate. The 8K
and 16K rows interpolate between the measured 4K and 32K allocations and remain
conservative admission estimates until a run replaces each one with the values
the exact binary reports. The
headroom covers recurrent state, graph and scratch buffers, allocator rounding,
and staging. Any measured allocation above its gate, or any desktop-reserve
failure, stops escalation to the next depth.

## Measured allocation results

The 4K, 32K, 64K, and 128K rungs were measured while establishing that the
architecture, quant, KV type, Flash Attention, queue, and strict-placement
choices hold together. The 32K, 64K, and 128K depths exceed the 24,576 token
operating ceiling; they are retained as the evidence that fixes the linear KV
term and the Vulkan compute slope used above, not as served configurations.

All four rungs pass with Q8 K, Q4 V, Flash Attention, one slot, zero context
checkpoints, zero RAM cache, strict Vulkan placement, and zero matching kernel
hazards after each run.

| Context | Model | KV | Recurrent state | Vulkan compute | Vulkan self | Vulkan free |
|---:|---:|---:|---:|---:|---:|---:|
| 4K | 2,603.50 MiB | 52.00 MiB | 50.25 MiB | 18.52 MiB | 2,724 MiB | 13,102 MiB |
| 32K | 2,603.50 MiB | 416.00 MiB | 50.25 MiB | 25.52 MiB | 3,095 MiB | 12,723 MiB |
| 64K | 2,603.50 MiB | 832.00 MiB | 50.25 MiB | 33.52 MiB | 3,519 MiB | 12,291 MiB |
| 128K | 2,603.50 MiB | 1,664.00 MiB | 50.25 MiB | 49.52 MiB | 4,367 MiB | 11,426 MiB |

The Vulkan memory breakdown includes an unaccounted driver and desktop term of
about 1,216 to 1,249 MiB. The host-visible compute buffer grows from about 2.5
MiB at 4K to 33.5 MiB at 128K; model tensors remain entirely in the `Vulkan0`
model buffer. Each graph reports one executable split.
