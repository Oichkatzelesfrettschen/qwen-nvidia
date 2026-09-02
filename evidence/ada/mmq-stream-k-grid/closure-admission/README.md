# Three closures differ by one host constant and by nothing else

The campaign compares four closures and its whole reading rests on their
differing by `GGML_CUDA_ADA_MMQ_TILING_EFFICIENCY_PERCENT` alone. Three
identical builds reported as three arms would produce a null result that looks
like a measurement, so the closures are admitted statically before the device
runs.

## What was built

`patches/llama-cuda-mmq-stream-k-grid.patch` applies clean to the pinned
`f280b2698` on top of the production series, and `scripts/build-llama-cuda.sh`
built the three subject closures one at a time at nice 19 with idle I/O.

| closure | `mmq_tiling_percent` | configuration | `llama-bench` SHA-256 |
| --- | ---: | --- | --- |
| null | 90 | `93938392c92a` | `64ea0f0708002f6b` |
| tiling | 1 | `18bc38699c86` | `5dd98942997aa136` |
| candidate | 80 | `e4be5742e429` | `3ad468f7e52cd80e` |

The control is the promoted `88681bf4d161` without the patch, whose
`llama-bench` reads `28266b1589d52d9c` and matches the digest
`scripts/ad104-stream-k-matrix.tsv` already carried.

## The checks

`build-configuration.tsv` of each closure differs from the other two on the
`mmq_tiling_percent` row and agrees on every other row, including the source
commit, the working-tree diff digest, the patch-series digest, the builder
digest, both MMVQ ceilings, and every production lever. Each closure carries
187 native SM89 cubins and zero PTX, which is what `89-real` requires.

The threshold reaches the compiler rather than resting as an ignored argument:
`compile_commands.json` carries
`-DGGML_CUDA_ADA_MMQ_TILING_EFFICIENCY_PERCENT` on all 187 CUDA translation
units of each closure at that closure's own value, and 340 host translation
units carry none, which is the split `-DCMAKE_CUDA_FLAGS` produces.

The device code is identical. `cuobjdump -sass` over each
`libggml-cuda.so.0` produces 1819616451 bytes reading
`c7bb6ff90ecaad4a69854b2f0e7f45f0c3c0770a2261a3b588fc26c985ee2328` for all
three, so every one of the 704 `mul_mat_q` and 704
`mul_mat_q_stream_k_fixup` kernels is byte-identical across the closures. That
is the patch's own claim: it changes grid selection at `mmq.cuh:1436` and
`fixup_needed` at `:1440`, both host-side, and touches no kernel body. A SASS
difference here would have meant another compile variable entered and would
have refused the campaign before device time.

## What this does not establish

Identical SASS proves the kernels are the same code, not that the three
closures dispatch differently at run time. The grid the host selects is
observable only in the launch record, which is what
`scripts/run-ad104-path-audit.sh` reads and what Phase B at threshold 1 exists
to decide.
