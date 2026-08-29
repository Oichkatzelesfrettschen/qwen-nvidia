# Qwen3.8-27B Recurrent Checkpoint Memory

## Scope

This derivation binds the published `Qwen3.8-27B-UD-Q2_K_XL.gguf`
architecture metadata to llama.cpp commit
`f280b26983ad0fdb705a0d9ebf0503e76f2899b0`. It covers one server slot,
one active sequence, text-only inference, and no draft or MTP context.

The GGUF range probe on 2026-08-24 resolved repository commit
`4ca720788d1e01f1bff70c033e0d0028fd02e502` and linked-object SHA-256
`fd4730dd8aad070517978752b63d530aeb1740d2283cab9fa24f1e404032ddb0`.
The header reports:

```text
general.architecture=qwen35
qwen35.block_count=65
qwen35.nextn_predict_layers=1
qwen35.ssm.conv_kernel=4
qwen35.ssm.state_size=128
qwen35.ssm.group_count=16
qwen35.ssm.time_step_rank=48
qwen35.ssm.inner_size=6144
qwen35.full_attention_interval=4
```

The 65 blocks comprise 64 main blocks and one NextN block. The full-attention
interval makes every fourth main block full attention, leaving 48 recurrent
blocks and 16 full-attention blocks. The published source configuration agrees
with the GGUF header:

- https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/blob/4ca720788d1e01f1bff70c033e0d0028fd02e502/config.json
- https://huggingface.co/Qwen/Qwen3.5-27B/blob/main/config.json

## Tensor bytes

`src/models/qwen35.cpp` loads the five SSM fields and marks every non-fourth
main block recurrent. `src/llama-hparams.cpp` defines the recurrent row widths:

```text
R elements per recurrent block
  = (conv_kernel - 1) * (inner + 2 * groups * state)
  = 3 * (6144 + 2 * 16 * 128)
  = 30,720

S elements per recurrent block
  = state * inner
  = 128 * 6144
  = 786,432
```

`src/llama-model.cpp` constructs Qwen hybrid recurrent R and S tensors as F32.
For 48 recurrent blocks, one live state image therefore contains:

| Component | Bytes | MiB |
|---|---:|---:|
| R convolution state | 5,898,240 | 5.625 |
| S recurrent state | 150,994,944 | 144.000 |
| Total tensor data | 156,893,184 | 149.625 |

The 149.625 MiB value is exact tensor data. The backing Vulkan buffer can add
backend alignment, which the eventual startup log must measure.

## Server checkpoint payload

`tools/server/server-context.cpp` stores each context checkpoint through
`common_prompt_checkpoint::update_tgt()`. `common/common.cpp` serializes that
state into the host `data_tgt` byte vector. The `PARTIAL_ONLY` flag makes
`src/llama-memory-hybrid.cpp` omit the attention KV and retain the recurrent
state. The checkpoint is therefore system RAM, not another permanently
resident Vulkan state image.

For one occupied sequence cell, the serialized recurrent state adds 1,180
bytes of format metadata to the tensor data:

```text
8 bytes   sequence-state magic and sequence id
4 bytes   recurrent cell count
8 bytes   recurrent cell position metadata
8 bytes   S-transpose flag and layer count
576 bytes R type and row-size headers for 48 recurrent blocks
576 bytes S type and row-size headers for 48 recurrent blocks
```

One checkpoint payload is therefore 156,894,364 bytes, or 149.626125 MiB.
The host allocator and list/vector objects add a small implementation-dependent
amount beyond the payload.

| Checkpoints | Serialized host payload | GiB |
|---:|---:|---:|
| 0 | 0 MiB | 0 |
| 1 | 149.626 MiB | 0.146119 |
| 4 | 598.505 MiB | 0.584477 |
| 8 | 1,197.009 MiB | 1.168954 |
| 16 | 2,394.018 MiB | 2.337908 |
| 32 | 4,788.036 MiB | 4.675816 |

The live recurrent tensor remains 149.625 MiB with zero server checkpoints.
With four checkpoints, the lower bound across the live Vulkan state and host
checkpoint payloads is 748.130 MiB, split across different memory accounting
domains on this UMA system.

## Version-specific distinction

`--ctx-checkpoints` governs the server's host checkpoint list. It does not set
`llama_context_params.n_rs_seq` in the pinned revision. `n_rs_seq` provides
in-context recurrent rollback planes and is wired from speculative decoding;
MTP and other speculation remain disabled for the initial capacity runs.

`--cache-ram` governs a separate prompt-state cache. A cached prompt includes
its full saved state and copies of its checkpoint vectors, so `--cache-ram 0`
remains required for the one-shot capacity mode.

## Falsifiers and runtime gates

The derivation fails for the selected runtime artifact if any of these checks
differs:

- The actual GGUF header reports different SSM dimensions, block count, or
  NextN count.
- The pinned llama.cpp revision changes R/S types or recurrent row formulas.
- The server log reports a live recurrent tensor size other than 149.625 MiB
  plus backend alignment.
- The server's checkpoint trace reports a payload materially different from
  149.626 MiB with one slot, no draft, and no MTP.

The first admitted model run must retain the startup memory breakdown and one
measured checkpoint trace before the four-checkpoint daily profile is accepted.
