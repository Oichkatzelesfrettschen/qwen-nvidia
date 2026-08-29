# What the device does with the types our files hold

A quantization label names a byte layout, and a byte layout reaches the device
through one shader path out of several. This audit reads which ggml types the
served checkpoints actually carry, what RADV on Raven2 advertises, and which
path `ggml-vulkan.cpp` selects for each, so that a rate measured on this machine
is read against the kernel it ran rather than against the bit width in its name.

No GPU workload was submitted. Every device fact is enumeration, `/sys`,
`dmesg`, `strings` on the built binary, or source, at llama.cpp commit
`f280b26983ad0fdb705a0d9ebf0503e76f2899b0`.

## The integer dot product is advertised, functional, and unaccelerated

RADV reports `shaderIntegerDotProduct = true`, so the feature works. Every one
of its thirty `*Accelerated` capability flags reads `false`:

```text
shaderIntegerDotProduct                        = true
integerDotProduct8BitSignedAccelerated         = false
integerDotProduct4x8BitPackedSignedAccelerated = false
Accelerated flags true on GPU0:  0
Accelerated flags false on GPU0: 30
```

`ggml-vulkan.cpp:6492` reads that exact flag:

```cpp
device->integer_dot_product = device->integer_dot_product
    && shader_integer_dot_product_props.integerDotProduct4x8BitPackedSignedAccelerated;
```

so `device->integer_dot_product` resolves false, and that value gates
construction of every `_q8_1` pipeline for mat-vec (`ggml-vulkan.cpp:5330-5410`)
and for mat-mat (`ggml-vulkan.cpp:4944-4960`), with `quantize_y` short-circuiting
at the dispatch site before `ggml_vk_should_use_mmvq` is reached
(`ggml-vulkan.cpp:9669`, `10568`).

The build agrees with the runtime. The deployed `llama-server` contains no
integer-dot shader for the type that carries most of our bytes:

```text
mul_mat_vec_q4_k_q8_1 symbols: 0
mul_mat_vec_q4_k_f16  symbols: 7
```

Three independent facts agree, so this is a property of the silicon rather than
a configuration: the driver's own capability report, the shader set compiled
into the binary, and the instruction set. LLVM's generated syntax reference
lists `v_dot2_f32_f16`, `v_dot4_i32_i8`, and `v_dot8_i32_i4` for gfx906 and
lists no `V_DOT*` mnemonic for gfx900, gfx902, gfx909, or gfx90c. This device
reports `gfx902`, below the Vega 7nm part that gained those instructions.

Nothing is emulated. llama.cpp reads the driver's own "not accelerated" report
and declines the path, so every K-quant, Q8_0, and IQ1 tensor executes through
the same FP16-dequantize-then-dot family that the IQ2, IQ3, and IQ4 types run on
every device, because those never receive a `_q8_1` variant at all.

## What the served checkpoints carry

Summed over the five production rows of `remote/models.tsv`, 9.17 GB of file
bytes:

| type | production share | path on this device |
| --- | ---: | --- |
| Q4_K | 40.38% | fp16 dequantize |
| Q6_K | 27.98% | fp16 dequantize |
| F16 | 16.84% | native, `shaderFloat16` |
| Q8_0 | 8.99% | fp16 dequantize |
| Q5_K | 5.66% | fp16 dequantize |
| F32 | 0.15% | native |

**About 83% of production streamed bytes take a path that exists because the
accelerated one is unavailable.** On a device where
`integerDotProduct4x8BitPackedSignedAccelerated` is true, the same bytes route
through the `_q8_1` MMVQ and MMQ kernels instead. That is the single largest
mismatch between what this tree ships and what this device can do, and it is
not fixable in software.

Every IQ-typed byte in the tree sits in the two 27B files, both `tier=archive`
in `remote/models.tsv`, so the IQ reconstruction question affects 0% of served
traffic today.

`shaderInt8`, `storageBuffer8BitAccess`, and `uniformAndStorageBuffer8BitAccess`
are all true and are used for byte-level unpacking alone. Eight-bit storage and
eight-bit dot-product acceleration are separate capabilities and the driver
reports them separately; this device has the first and not the second.

`VK_KHR_cooperative_matrix` and any bfloat16 extension are absent from the GPU0
extension list, which confirms from the extension list itself what `CLAUDE.md`
already records. llama.cpp classifies this device `AMD_GCN` from
`minSubgroupSize == maxSubgroupSize == 64` alone (`ggml-vulkan.cpp:441-444`) and
never probes for cooperative matrices.

## A code-level account of the Q5_K trunk

`CLAUDE.md` records that achieved streaming forms two observed groups rather
than ordering by bit width: a Q4_K trunk and a Q6_K trunk both near 8.1 GB/s
where a Q5_K trunk reaches 5.9. The shaders offer a mechanism, and rule one out.

Subgroup utilisation is not it. `mul_mat_vec_q4_k.comp`, `q5_k.comp`, and
`q6_k.comp` are issued with identical tile parameters on this device --
`rm_kq`, `wg_size_subgroup16`, `use_subgroups16` (`ggml-vulkan.cpp:5288-5290`).

Unpack cost survives. Q5_K performs everything Q4_K performs on the 4-bit field
and adds a `qh` high-bit load with four shift, mask, and add operations per
16-element group to fold in the fifth bit (`mul_mat_vec_q5_k.comp:35-51`, absent
from `mul_mat_vec_q4_k.comp`). Q6_K trades that bit-plane for a simpler scale
path: a raw per-group int8 scale through a shared-memory cache with no minimum
to subtract, because Q6_K is symmetric. **Q5_K is the only one of the three
paying both the packed scale-and-minimum decode and the extra bit-plane merge**,
where Q4_K skips the bit-plane and Q6_K skips the complex scale. This is a
hypothesis with code evidence, not a measurement.

Reading the file-level 5.9 GB/s as a Q5_K rate overstates it. The measured
mixture of `i1-Q5_K_M.gguf` is 65.99% Q5_K and 33.89% Q6_K by byte, so under an
additive time model the Q5_K-only marginal rate implied by those figures is
about 5.18 GB/s. The additive model is an assumption; the arithmetic uses
figures this tree already holds and wants a pure-Q5_K arm to check.

## Registered before any arm runs

| # | prediction | falsifier |
| --- | --- | --- |
| 1 | Disabling the integer dot product changes nothing, because it is already off: `GGML_VK_DISABLE_INTEGER_DOT_PRODUCT=1` against an unmodified control gives a paired decode ratio of 1.00 | the ratio falls outside 0.95 to 1.05 |
| 2 | Q5_K costs more per streamed byte than Q4_K, rather than merely streaming more bytes | the paired per-byte-normalised ratio falls inside 0.95 to 1.05 |
| 3 | IQ2_S and IQ3_S decode no faster than a byte-matched Q4_K or Q6_K set, despite carrying fewer bytes | IQ decode exceeds the byte-matched set by more than the byte-count ratio predicts |

Prediction 1 needs the `custom` profile or a direct `llama-bench` call, because
`radv-low-priority-env.sh` unsets every `GGML_VK_*` variable before its profile
case runs. Prediction 3 needs an IQ-bearing file in a servable tier, and both
that carry one are archived.

## Not determined

The FP16 issue rate on gfx902 is not established. `shaderFloat16 = true` says
the type is native and says nothing about whether the part issues it at one or
two operations per cycle, and no AMD architecture document for Raven was read
that settles it. A paired fp16-against-fp32 accumulation arm would.

IQ decode on this device is unmeasured, which is what `CLAUDE.md` already
records; the cost account above is read from shader structure. The IQ2 and IQ3
shaders copy a constant codebook into shared memory per workgroup
(`types.glsl:918-1039`) and then perform a data-dependent shared-memory gather
per element, where the K-quant shaders perform register-level shift and mask
with no indirection. That is a structurally different cost and, on wave64, one
that can conflict on banks.

Per-shader occupancy and register pressure were not profiled, because that needs
a live dispatch.
