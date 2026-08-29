# The 2B distill decodes at 9.46 tok/s and refutes the linear cost model

`empero-ai/Qwen3.8-2B-Distill-GGUF` at revision
`f4f73582d0b149595450c719b9a7521a03894f9c`, Q4_K_M, 1,312,164,224 bytes,
`4aa0fb13c431514262f259d420ecc95a8714df58ac2a2384514e20b93983f0ff`. Full RADV
Vulkan offload, nice 19 with idle I/O, two threads, phases split.

| Checkpoint | weights | prefill tok/s | decode tok/s |
| --- | ---: | ---: | ---: |
| Qwen3.8-2B distill Q4_K_M | 1.21 GiB | 57.15 | 9.46 +/- 0.41 |
| Qwen3.8-4B distill Q4_K_M | 2.58 GiB | 23.48 | 3.07 +/- 0.02 |
| Qwen3.8-9B distill Q4_K_M | 5.37 GiB | 11.47 | 1.76 |

## The prediction failed by a factor of two

Two decode points, the 4B and the 9B, fit a linear cost model of 0.1015 s per
token plus 0.0869 s per GiB of weights. Applied to 1.21 GiB it predicts 4.82
decode tok/s. The measurement is 9.46, so the model is refuted rather than
confirmed, and the deviation is the result.

The refutation is informative because of which term fails. Read as pure
streaming of the whole file, 1.21 GiB is 1.299 GB and 9.46 tokens per second
moves 12.29 GB/s against the 11.5 GiB/s asymptote the model's own slope
implies, so the 2B reaches that slope with the fixed per-token term absent and
that term is not a constant of the machine. A two-point fit across two model
sizes attributed depth-dependent overhead to an intercept, and a third point at
a different depth exposes it. Both the fit and its refutation take file size as
a stand-in for per-token traffic, which the next section corrects for the 9B and
leaves unchanged for the 2B and the 4B, so the refutation stands on corrected
figures as well.

## Embedding tying decides what decode streams, and it splits these three

Multiplying GGUF size by decode rate gives an effective-throughput proxy rather
than measured DRAM traffic. The correction that matters is the token embedding
tensor, and it depends on `tie_word_embeddings` rather than on file size.

An untied checkpoint carries two tensors of shape vocabulary by hidden width.
Decode reads `token_embd` as one row of a few kilobytes and streams
`output.weight` in full through the logit projection, so the file's copy of
`token_embd` leaves the per-token total. A tied checkpoint carries one tensor
that serves both, and the logit projection reads all of it every step, so
nothing leaves the total. `config.json` gives `tie_word_embeddings` true for the
2B and the 4B and false for the 9B, so the correction applies to the 9B alone:

| Checkpoint | tied | file bytes | streamed per token | GB/s |
| --- | --- | ---: | ---: | ---: |
| Qwen3.8-2B distill | yes | 1.299 GB | 1.299 GB | 12.29 |
| Qwen3.8-4B distill | yes | 2.770 GB | 2.770 GB | 8.50 |
| Qwen3.8-9B distill | no | 5.766 GB | 4.932 GB | 8.68 |

The 9B row subtracts a `token_embd` read at Q6_K, the type llama.cpp's Q4_K_M
recipe usually assigns it, so that row alone is estimated;
`remote/gguf-tensor-census.py` reads the actual assignment and settles it. At
Q4_K the row reads 9.14 GB/s instead, which changes the margin and leaves the
ordering intact.

## The 4B is not the outlier; the 2B is

The corrected table reverses the question. The 4B and the 9B agree to 2% across
a 1.8-fold span in streamed bytes, so at 32 layers per-token cost is
proportional to bytes and the pair fixes a rate of about 8.6 GB/s. The 2B
reaches 12.29 GB/s, 42% above both, and it is the row that needs explaining.

Depth alone does not explain it. Fitting per-layer and per-byte terms to the two
32-layer points gives 0.472 ms per layer and 0.11214 s per GB, which applied to
24 layers and 1.299 GB predicts 6.37 decode tok/s against 9.46 measured. That is
the second cost model this checkpoint refutes, and it fails in the same
direction as the first: whatever the 2B does, it is cheaper than either a fixed
per-token term or a fixed per-layer term allows.

What separates the 2B from the other two is more than layer count. It runs 24
layers at 2048/6144 against 32 layers at 2560/9216 and 4096/12288, and it also
carries 8 attention heads with 2 key-value heads and 16 linear value heads,
against 16 attention heads with 4 key-value heads and 32 linear value heads in
both of the others. The layer pattern is identical across all three, three
linear-attention layers followed by one full attention layer, so the Gated
DeltaNet ratio is constant and is not a candidate.

Sequential host read bandwidth measures 7.97 GB/s on one CPU thread and 15.44
GB/s on two. Those figures measure two Zen+ cores through the load/store path,
which is a different consumer of the same DDR4 controller than the two Vega
compute units, so they bound nothing about the GPU. The device ceiling stays
unmeasured until a direct Vulkan buffer-read and Q4_K dequantization benchmark
runs, and until then 12.29 GB/s is the highest rate observed rather than a
ceiling.

Prefill behaves as the compute-bound half should, with both checkpoints near the
arithmetic ceiling of 281.6 GFLOP/s: the 2B reaches 221.7 GFLOP/s at 79% and the
4B 203.3 GFLOP/s at 72%. That ceiling is a heuristic from clock, compute-unit
count, and lane width rather than a measured device bound.

## What is settled and what is open

Settled: the 2B decodes 3.1 times faster than the 4B and prefills 2.4 times
faster, this appliance serves a Qwen-class checkpoint at 9.46 tok/s, and at 32
layers achieved rate is independent of width across a 1.8-fold byte span.

Open: why the 2B moves 42% more streamed bytes per second than either of the
other two. The profile that separates the candidates is the 2B against the 4B,
because the 4B and the 9B already agree and serve as the control that rules
width out. Head count, layer count, Gated DeltaNet value-head width, tensor
shapes selecting different kernels, dispatch count per token, and two-compute-
unit occupancy all remain, and a per-operator Vulkan capture normalized to
microseconds per token separates them.

Untested: quality. Throughput states nothing about whether the 2B answers
correctly, and the five-prompt suite and reasoning-span probe that promoted the
4B over the base have not run against it. A checkpoint that reaches an answer
three times faster and reaches a wrong one is not a candidate.
