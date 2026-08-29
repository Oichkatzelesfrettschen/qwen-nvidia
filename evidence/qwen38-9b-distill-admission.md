# Qwen3.8 9B Distill Admission

## Artifact

The exact candidate is `empero-ai/Qwen3.8-9B-Distill-GGUF` at revision
`760121cd70bb4c36b2b5ec58eb765e0df5987efe`. The Q4_K_M artifact is
`Qwen3.8-9B-Q4_K_M.gguf`, 5,780,090,176 bytes, with SHA-256
`df13d66021cef676f82be74053220fd75af6bf2a6a7fb77f5222ab9e50744a7a`.
The repository declares Apache-2.0 and identifies the unquantized source as a
full-parameter distillation into the Qwen3.5-9B architecture. The filename
omits `Distill`; the pinned repository identity carries that provenance.

Primary sources:

- https://huggingface.co/empero-ai/Qwen3.8-9B-Distill-GGUF/tree/760121cd70bb4c36b2b5ec58eb765e0df5987efe
- https://huggingface.co/empero-ai/Qwen3.8-9B-Distill-GGUF/blob/760121cd70bb4c36b2b5ec58eb765e0df5987efe/README.md
- https://huggingface.co/empero-ai/Qwen3.8-9B-Distill-GGUF/blob/760121cd70bb4c36b2b5ec58eb765e0df5987efe/SHA256SUMS
- https://huggingface.co/empero-ai/Qwen3.8-9B-Distill/blob/0934f3d2327ff2df2197495278c4c46ae5a56bd9/config.json

## Role

This model is the intermediate reasoning candidate between the resident
Qwen3.5-4B control and the Qwen3.8-27B benchmark ladder. It uses the same
hybrid Gated DeltaNet architecture family as the existing 4B model, so it tests
quality scaling without changing the runtime architecture. Its published
MMLU and GSM8K values remain model-card claims until reproduced locally.

`remote/download-qwen38-9b-distill-q4km.sh` pins the repository, revision,
byte count, and SHA-256. The script retains an interrupted `.part` file and
renames it only after verification. The GGUF remains an external model artifact
and stays outside Git and LFS.

## Runtime gate

The first run uses 4,096 context tokens, Q8 K plus Q4 V cache, one slot, strict
Vulkan placement, and the `low-serialized` profile. `model-memory-preflight.sh`
must preserve 4 GiB MemAvailable and accept the live Vulkan budget before
llama.cpp opens the artifact. A 24K run follows only after measured 4K peak
host memory, Vulkan allocation, graphics-service latency, temperature, and
kernel hazards pass.

The pinned text configuration has eight full-attention layers, four KV heads,
256 elements per head, and 24 recurrent layers. At 4K, Q8 K plus Q4 V consumes
52 MiB. The exact llama.cpp recurrent formulas allocate 50.25 MiB of F32 live
state. The 5,512.324 MiB file plus those caches and a 64 MiB provisional graph
allowance totals 5,678.574 MiB; the admission gate rounds that value to 6,144
MiB. Including the simultaneous file envelope and 4 GiB desktop reserve
requires 16,517,508,416 host bytes.

The artifact verified at the pinned byte count and SHA-256. The live preflight
reported 15,140,962,304 available host bytes and rejected that host requirement.
RADV reported 16,608,825,344 available aggregate Vulkan bytes and accepted the
6,979,321,856-byte working-set-plus-margin requirement. The gate returned 3,
and no llama.cpp process opened the model. The verified artifact remains ready
for a later preflight after host pressure falls; swap does not authorize a run.
Evidence is retained in `evidence/model-admission/` and
`evidence/runtime-logs/model-download/`.
