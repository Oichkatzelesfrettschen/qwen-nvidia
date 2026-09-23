# Promotion of configuration 39a6bc778ef4

The replacement CUDA closure carries the corrected workload-lease teardown
observation. The source change moves the ownership record after the
idle-acquisition branch; acquisition, synchronization, release, graph dispatch,
and CUDA kernel policy retain their existing mechanisms. The isolated build
uses 89-real, flash attention for mixed quantized KV types, graphs, fusion,
and the Q6_K/Q8_0 MMVQ thresholds of 10 and 16.

The compile-only build finished all five targets and wrote 28 manifest object
rows. Static comparison found 187 SM89 cubins, zero PTX images, and identical
bytes in all 8,167 CUDA instruction sections after matching NVCC's internal
section-name identifiers. Initialized device data differed in 116 sections;
whole-library identity is not claimed. The original source checkout, index,
refs, serving links, and captured binary hashes matched before and after the
isolated build. Raw build records remain under
`.local-artifacts/runtime/llama-graft-teardown/`.

The native API replay used the installed Graft 0.18.0-2 package and
Qwenseer-2B Q4_K_M. It completed eight scoped DiscoBSD files with 137 ready
nodes, queried the graph through `graft_file_api`, cancelled a second job with
a fresh signed grant, then stopped a third job while its inference lease was
acquired. Session retirement returned zero, recorded `teardown: held=yes` and
orderly exclusion, and left all 12 captured process identities exited. The
resumed run recorded identical Git HEAD, index, refs, worktree status, and
SHA-256 values for the eight scoped source files. The scope was
`sys/arch/rp2040/dev`, not the entire repository. Raw replay records remain
under `.local-artifacts/research/graft-llama-discobsd/e2e-corrected-retirement-retry/`.

The first replay attempt met the workstation memory guard before a tool call.
The next completed deep build and query while another writer committed and
pushed an unrelated DiscoBSD branch; the harness preserved that ref-churn
failure. Git reflogs at 18:13:26 and 18:13:32 PDT attribute the ref updates,
while HEAD, index, status, and scoped file hashes remained equal. The accepted
retirement replay resumed from that completed graph after the refs settled.

The promotion gate initially classified a linked build's library under the
wrong manifest role. Resolving the physical build directory aligned the
manifest with the loader's paths. Its vision smoke then exposed
`token_embd.weight` on CPU despite `--n-gpu-layers all`; explicit
`--override-tensor '.*=CUDA0'` returned the image's red, green, and blue
shapes with CPU fallback prohibited. The final gate passed strict CUDA text
and image smokes and switched the serving link to this closure, retaining
`192d0663a533` as the rollback target. The raw promotion log stays under
`.local-artifacts/research/graft-llama-discobsd/promotion-corrected/`.

`serving-summary.tsv` records the admitted outcomes. The native UI approval
hook passed copied-source type, lint, format, build, and fixture checks; the
API replay does not establish an attended browser-click result. Graphics
latency was not measured during this admission.
