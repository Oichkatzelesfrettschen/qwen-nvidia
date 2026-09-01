# The runtime mat-mul dispatch census on AD104

Nine arms, one llama-server each, run under `GGML_CUDA_DISPATCH_CENSUS` in
closure `a925c84db3a2`: the promoted levers of `88681bf4d161` (89-real,
Q6_K MMVQ at ten, Q8_0 MMVQ at sixteen, graphs on, fusion on, PDL unset)
plus `patches/llama-cuda-dispatch-census.patch`, whose hooks at the five leaf
launchers and the four cuBLAS entries record every mat-mul launch with the
tensor it multiplied, its types, shape, and strides, one row per distinct
shape per graph compute. `closure-configuration.tsv` is that closure's own
configuration record and `server-version.txt` its build line.
`scripts/run-cuda-dispatch-census.sh` ran the arms and
`scripts/summarize-dispatch-census.py` joined the rows to the requests that
produced them; every rate the server reported here belongs to the
instrumented closure and populates no registry field.

Each text arm answered one `/completion` with a prompt trimmed to exactly 512
tokens through `/tokenize` and `/detokenize`, decoding 64 tokens, at the
row's own cache triple and submission geometry, Flash Attention on, MTP off
(no `nextn` tensor appears in any census), prompt cache off. Each vision arm
loaded its projector through `select-projector.sh` and answered three chat
requests at 32 tokens: text alone, `scripts/quality-images/bars.png` cold, and
the same image warm. The device was owned through
`gpu-workload-ownership.sh`; the client set was the compositor, Microsoft
Edge's GPU process, and Discord's GPU process on every read before and after
every arm (`ownership-*.txt`), which is the workstation's daily state rather
than a condition the census excludes.

## What each arm dispatched

`census-summary.tsv` counts dispatch launches inside request windows.
`graph_replays` counts CUDA graph relaunches, each of which repeats the
population its capture recorded and dispatches nothing through the hooks.
One single-token graph runs at load ahead of the first request on every arm
and is retained under the request id `outside`.

| arm | launches | MMVQ | MMQ | MMVF | cuBLAS | cuBLAS share | distinct cuBLAS shapes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| T0 qwen35-08b Q8_0 | 513 | 327 | 186 | 0 | 0 | 0 | 0 |
| T1 qwen35-08b-f16 | 513 | 0 | 0 | 327 | 186 | 0.3626 | 186 |
| T2 qwen35-08b-bf16 | 513 | 0 | 0 | 327 | 186 | 0.3626 | 186 |
| T3 qwen38-2b-distill Q4_K_M | 513 | 327 | 186 | 0 | 0 | 0 | 0 |
| T4 qwen38-4b-distill Q4_K_M | 683 | 435 | 248 | 0 | 0 | 0 | 0 |
| T5 qwen38-9b-distill Q4_K_M | 683 | 435 | 248 | 0 | 0 | 0 | 0 |
| V0 lfm25-vl-450m | 1244 | 649 | 593 | 0 | 2 | 0.0016 | 1 |
| V1 lfm25-vl-16b (LFM2.5-VL-1.6B) | 1424 | 649 | 719 | 0 | 56 | 0.0393 | 28 |
| V2 qwen35-4b-base | 3241 | 1443 | 1598 | 0 | 200 | 0.0617 | 99 |

MMF launched nowhere. Every quantized text row runs its prefill on MMQ and
its decode on MMVQ, fused and unfused, and reaches cuBLAS zero times across
pp512 and tg64. The two dense 0.8B rows run their decode on MMVF and their
entire prefill on cuBLAS: all 186 trunk weights at 512 columns take
`cublasGemmEx`, at compute type F16 for the F16 row and BF16 for the BF16
row, with identical shapes and counts. `ggml_cuda_should_use_mmf` (`mmf.cu:179`)
refuses a dense weight above sixteen columns and
`ggml_cuda_should_use_mmvf` (`mmvf.cu:829`) refuses F16 above four on compute
capability 8.9, so a dense weight at prefill width has no ggml kernel to take
and the cuBLAS entry is the only path.

The vision arms place their cuBLAS calls in the encoder and the projector
rather than in the language model. `cublas-shapes.tsv` carries every one:

- V2 sends the whole Qwen3.5 vision encoder there. `mmproj-F16.gguf` holds
  every encoder weight at F16, so each of the 24 blocks' `attn_qkv`
  (1024x3072), `attn_out` (1024x1024), `ffn_up` (1024x4096), and `ffn_down`
  (4096x1024) runs `cublasGemmEx/F16` at 352 columns, 96 launches per image,
  beside two projector `mm.*` mat-muls and a reshaped 768x352 activation at
  1024 columns. 200 launches over the two image requests, 6.17% of the arm's
  dispatch.
- V1's `mmproj-LFM2.5-VL-1.6b-Q8_0.gguf` keeps its encoder at Q8_0 except
  `ffn_down`, which the publisher left at F16, so 27 of the encoder's 108
  mat-muls per image take `cublasGemmEx/F16` at 4304x1152 by 352 columns and
  the other 81 run MMQ. 56 launches over two images, 3.93%.
- V0's Q8_0 projector reaches cuBLAS once per image, on the reshaped
  768x352 activation at 768 columns.

The image adds 86 prompt tokens on the LFM rows and 87 on Qwen at this
fixture, and the warm request repeats the cold request's population exactly;
the only difference between them is that the second request's graph is the
one CUDA graphs capture, so first use changes no dispatch decision.

## Conclusion

Quantized production text: zero cuBLAS dispatches at pp512 and tg64 on the
Q8_0 0.8B and the Q4_K_M 2B, 4B, and 9B; MMVQ and MMQ are preserved, and no
general text cuBLASLt planner is justified.

Dense 0.8B F16 and BF16 prefill: the whole prefill population reaches
cuBLAS, so a dense prefill planner remains a candidate for a dense row that
is chosen for a role.

Vision and projector: the cuBLAS population appears where the loaded
projector and encoder tensors carry dense F16 weights, so a planner's scope
is representation-specific and architecture-specific. The 450M arm alone
authorizes nothing; the LFM2.5-VL-1.6B and Qwen3.5-4B arms are what any
later dense-plan candidate has to rest on.

## Decision under the pre-registered rules

Production text serving carries no cuBLAS population: T0, T3, T4, and T5
dispatch every mat-mul to MMQ or MMVQ. The general text cuBLASLt planner is
retired; MMVQ, MMQ, MMVF, and MMF stay as they are.

The vision encoder is the one repeated material cuBLAS population, and it
appears on the production-representative arms V1 and V2 rather than on V0
alone. What decides it is the value format of the projector file: a Q8_0
projector runs its encoder on MMQ and an F16 projector runs it on cuBLAS.
Two candidates follow, in the order of their cost. The cheaper is a Q8_0
projector for `qwen35-4b-base`, derived through `llama-quantize` from the
publisher's F16 file, which moves 96 encoder mat-muls per image from cuBLAS
to MMQ without a kernel change and is measured as a paired timing arm with
the F16 projector, output compared through the graded vision rows. The
dearer is a planner scoped to the F16 encoder shapes at 352 columns, which
earns implementation only where the timing arm shows the cuBLAS encoder
holds a share of request time worth the planner's own cost. This census
counts launches and not time, so that share is unmeasured here and is the
second phase's first reading.

BF16 earns no scope of its own: it reaches exactly the paths F16 reaches, on
the same shapes, at the compute type its representation selects. The dense
representation rows' wholesale cuBLAS prefill is a prefill-only planner's
population, and both rows are candidates at tier `candidate` serving no role,
so that planner stays unbuilt until a dense row is chosen for one.

## Falsifiers

A production text row sending any mat-mul to cuBLAS under the promoted
closure refutes the retirement; the census rerun on that row is the check.
A Q8_0 Qwen projector still reaching cuBLAS in the encoder refutes the
projector-format reading, and its census names the tensor. A paired timing
arm showing the F16 encoder's cuBLAS calls inside the drift floor of request
time refutes the planner candidate before it is built.
