# Paged KV cache, P0: the contiguity, type, and pointer census

`census.tsv` is the machine-readable ledger, one row per assumption the
pinned tree (`f280b26983ad0fdb705a0d9ebf0503e76f2899b0`) makes about the
attention KV cache: where it is made, what contract it states, which of
contiguity, uniform type, and pointer stability it requires, what paging
breaks if that contract lapses, which P1 component owns the replacement, and
the observation that would falsify the row. Eighteen rows cover the eighteen
surfaces the program names, from layer allocation through the context
checkpoint. The Qwen3.5 linear-attention recurrent state is row A17 and stays
outside P1: `llama_memory_hybrid` owns it as a separate
`llama_memory_recurrent` whose rows are whole per-sequence states gathered
through `s_copy`, and `evidence/ada/concurrent-sequences/README-PRIMED.md`
makes that state the history a checkpoint restores, so paging it would change
what a primed slot resumes from rather than where a token's K and V rows live.

## What the census establishes

One `ggml_tensor` per layer per operand carries one `ggml_type` and one base
pointer, and every reader addresses a cell as `base + cell*row_size` with the
stream folded into `nb[2]`. That address arithmetic is the contract in
`get_k`/`get_v` (A06), `cpy_k`/`cpy_v` through `ggml_set_rows` with global
row indices (A07), the K-shift graph (A08), the whole-stream copy (A02, A09),
the checkpoint fast path (A05, A11), and the flash-attention launch, which
takes one base pointer and three strides per operand and a kernel instance
per `(D, type_K, type_V)` (A14). The logical side is already indirect:
`llama_kv_cells` names a cell by index, `find_slot` returns scattered `idxs`
for every caller at the pin since none passes `cont=true` (A04), and
`set_rows` scatters by index. What paging changes is therefore the physical
half alone, and the cliff the program names is A01 plus A14: a page carrying
a second type has no tensor to describe it and no kernel instance to read it.

## The two P1 architectures against the census

Stable virtual aperture over fixed-size physical pages. `ggml-cuda.cu:539`
already carries `ggml_cuda_pool_vmm`: `cuMemAddressReserve` over 32 GiB of
virtual space, `cuMemCreate` of physical chunks rounded to the device's
`vmm_granularity` (read at `:290` through
`cuMemGetAllocationGranularity`), and `cuMemMap` at the end of the pool. That
pool serves compute scratch; the KV buffer goes through
`ggml_backend_cuda_buffer_type_alloc_buffer` at `:887`, which calls
`cudaMalloc` (or `cudaMallocManaged` under `GGML_CUDA_ENABLE_UNIFIED_MEMORY`).
A KV aperture is the same three driver calls behind a buffer type of its own:
reserve the layer's full virtual range at allocation, map physical pages
behind the rows a slot occupies, unmap behind rows `seq_rm` frees. Every row
of the census that requires contiguity or pointer stability is satisfied
unchanged, because the tensor's `data`, `nb`, and type are what they are
today and only the physical backing moves: A02, A06, A07, A08, A09, A11, A14,
A15. The cost is granularity: a page holds `granularity / row_size` cells of one
layer, the allocator's unit is that many cells rather than a token, and the
granularity itself is a device value the pool reads at `:290` and this record
has not measured. The ownership
question the program raises has a positive answer: the buffer type owns the
reservation and the map, the tensor keeps its pointer, and no second
device-memory manager appears.

Logical page table with a gather into a staging tensor. Every attention read
becomes a `ggml_get_rows` (or a page-wise copy) into a contiguous staging K/V
tensor sized `n_kv`, then the existing attention. It satisfies A14 by
construction and needs the page table for A06, A07, A11, and A18. It costs a
copy of `n_kv` rows per layer per compute, a staging allocation of
`n_kv * row_size * n_layer` beside the cache, graph nodes per layer, and it
moves the staging pointer per compute where the pool hands out a new address,
which A15 measures as a warmup reset per compute
(`evidence/ada/graph-lifecycle/`). Under a 12 GiB carve-out with 2.5 GiB
resident for the desktop, the staging allocation is the memory the paging
was meant to recover.

## Decision

P1 takes the stable virtual aperture. The census identifies every reader of
the physical layout and each one is satisfied by a constant `data` pointer
over a virtual range, which the aperture provides and the staging design does
not; the staging design pays bandwidth, VRAM, graph nodes, and graph warmup
to preserve the same interface the aperture preserves for free. The VMM pool
that exists at `ggml-cuda.cu:539` is the mechanism and a KV buffer type is
its home; the page size is the driver's granularity rather than a chosen
constant, and the first measurement of P1 is that granularity on this device
and what fraction of a slot's allocation one page wastes at the 2B's row
size.

What P1 holds constant, as preregistered: K at q8_0 and V at q4_0, the same
stored values, the same token-to-cell map, the same attention order, the same
recurrent memory implementation. Exact Class-A identity is the gate at
batch 1 first and then under the primed width-3 regime, which
`evidence/ada/concurrent-sequences/2b-primed-01/` shows self-reproducible;
cold width-3 is not an identity gate. P4 is separate: quantizing older K
pages into another representation changes arithmetic by construction and
enters no paging admission.

Stop point: P1 implementation waits on a review of this boundary. The one
open measurement ahead of it is the granularity read on this device through
`cuMemGetAllocationGranularity`, which the census cites from the pool's own
call rather than from a number this record measured.
