# Paged KV buffer, P1: the attention KV layout over a CUDA VMM reservation

P1 answers one question on this device: can the ordinary q8_0/q4_0 KV
tensor layout live over a CUDA virtual memory management reservation with the
same tensor addresses, types, strides, bytes, graph behavior, and outputs.
The whole reservation is physically backed, so P1 proves address stability
and layout and proves nothing about reclamation; mapping physical memory
behind live cells alone is P2 and is designed against what this record
exposes. `evidence/ada/paged-kv-census/` is the P0 census this stage
implements against, and its row A17 is why the recurrent store is untouched.

## Mechanism

`patches/llama-cuda-paged-kv-buffer.patch` adds a KV buffer type to the CUDA
backend and a switch to the KV cache constructor.

The buffer type shares the CUDA buffer type interface and the CUDA buffer
interface, so `ggml_backend_buft_is_cuda`, `ggml_backend_buffer_is_cuda`,
and `ggml_backend_cuda_device_supports_buft` hold for it and the scheduler
places it the way it places a cudaMalloc buffer; the allocation kind lives in
the buffer context, and the six asserts that compared a buffer type pointer
in the asynchronous transfers and graph evaluation now compare the interface
and the device. Its alignment is the driver's minimum allocation granularity,
read through `cuMemGetAllocationGranularity(CU_MEM_ALLOC_GRANULARITY_MINIMUM)`
beside the recommended value the pinned VMM pool already read, so the
allocator pads every tensor extent to that unit and places every tensor start
on it, and one mapping unit sits inside one tensor. `alloc_buffer` reserves
one virtual range with `cuMemAddressReserve` at that alignment, creates one
physical allocation of the same size with `cuMemCreate`, maps it whole with
`cuMemMap`, releases the handle the way the pool does, and grants the device
read/write access with `cuMemSetAccess`; a failure at any step unwinds what
it holds and returns a null buffer, which the constructor turns into a named
exception; the destructor unmaps the whole range before `cuMemAddressFree`.
`init_tensor` asserts the start and extent alignment of every tensor placed
in such a buffer and prints one `paged_kv_tensor` record per tensor;
`alloc_buffer` prints one `paged_kv_buffer` record with the requested,
virtual, and mapped byte counts and both granularities. The buffer type
carries the device's own name, since every placement reader greps it and the
buffer is CUDA memory on that device.

`llama_kv_cache` reads `LLAMA_KV_PAGED_BUFFER`. At `1` it resolves
`ggml_backend_cuda_paged_kv_buffer_type` through the registry's proc-address
table and uses it for every attention K and V tensor; a backend that exposes
no such proc, a device that returns none, a cache kept on the host, a shared
layer whose buffer is another kind, or any other value of the variable ends
construction with a named error rather than serving from the ordinary
buffer. `llama_memory_recurrent` has its own constructor and reads none of
it. Unset, every path is the pinned one.

## Preregistration

Probe. `scripts/probe-cuda-vmm-layout.sh` compiles and runs a driver query
that creates no context, samples the compute client list three times while
the probe holds itself alive, and records both granularities beside the 2B's
attention KV geometry. Falsifiers: the probe's pid appears in a sample, a
sample goes unanswered or finds the probe already gone, or either
granularity reads other than a power of two.

Batch-1 identity. `scripts/run-closure-identity-ab.sh` with the control's own
build as subject and `LLAMA_KV_PAGED_BUFFER=1` in the subject's environment
alone, over the six state-carrying prompts at 256 tokens, with
`QWEN_IDENTITY_SLOT_STATE=1` saving slot 0 after every prompt and comparing
the state files byte for byte. Falsifiers: any token divergence in the
subject arm, any state-file divergence, a placement fingerprint that differs
across the three arms, a compute-client set that moves, or a closing control
that disagrees with the opening one, which reads as drift rather than as the
subject. A comparison count short of six prompts times two arms reads
incomplete rather than identical.

Layout. `scripts/read-paged-kv-layout.py` holds every subject log to: exactly
one paged buffer, `physical_mapped_bytes == virtual_reserved_bytes >=
requested_bytes`, `access=device_rw`, the unit equal to the minimum
granularity and positive, every tensor start and padded extent a multiple of
the unit, padded extents summing to the requested bytes, no two extents
overlapping, every row size agreeing with its type and `ne0`, every byte
count agreeing with its rows, every tensor named `cache_k_l*` or
`cache_v_l*` with both operands per layer, the tensor count the probe's
census predicts, the constructor's own `KV buffer size` line agreeing with
the reservation, and an `RS buffer size` line proving the recurrent store
allocated through its own path; every control log to the default kind and
no paged line.

Primed width-3 identity. `scripts/run-concurrent-sequence-sweep.sh` at widths
1 and 3 under primed admission, four bursts per level, the subject the same
binary under the same environment word. Falsifier: any slot's reply differing
between the control and subject burst at the same width and position. Cold
width-3 is not a gate, per `evidence/ada/concurrent-sequences/`.

Expected accounting: `kv_alignment_padding_bytes` of 0 on the 2B at 65536
cells, because 544-byte K rows and 288-byte V rows over 65536 cells give
34 MiB and 18 MiB tensors that are whole multiples of a 2 MiB unit;
`memory_saved_bytes` of 0 by construction. A row that crosses a unit boundary
is recorded as such: 2 MiB divides by neither 544 nor 288, so P2 maps units
rather than cells.

Decision. Every falsifier absent admits P1 as a buffer mechanism, default off
for serving; any subject divergence rejects it; a refusal names a harness or
environment fault and the arm is rerun; a run whose batch-1 comparisons or
primed widths fall short of the declared set reads partial rather than
admitted. Admission changes no serving default and starts no sparse mapping.

## Result

`2b-run-01/` admits P1 on the 2B under closure `385e13f0df08`, which is the
pinned tree with the crossover patch and this patch alone; the subject arm is
that closure's own binary under `LLAMA_KV_PAGED_BUFFER=1`.

| record | reading |
| --- | --- |
| granularity minimum, recommended | 2097152, 2097152 bytes; 3 of 3 client samples answered with the probe alive, its pid in none |
| batch-1 tokens | 12 of 12 arms identical (subject and closing control against the opening control) |
| slot-0 state files | 12 of 12 byte-identical, 21.9 to 22.1 MB each; digests retained, bytes removed |
| placement fingerprint | one value across the three arms |
| kv_logical_bytes | 327155712 |
| kv_virtual_reserved_bytes | 327155712 |
| kv_physical_mapped_bytes | 327155712 |
| kv_alignment_padding_bytes | 0 |
| memory_saved_bytes | 0, by construction |
| tensors in the paged buffer | 12: K and V of layers 3, 7, 11, 15, 19, 23; no recurrent tensor |
| recurrent store | `CUDA0 RS buffer size` line present in every arm, default path |
| primed width 1 | replies identical in 4 of 4 bursts, delivered ratio 1.0023 |
| primed width 3 | replies identical in 4 of 4 bursts, delivered ratio 1.0003 |
| kernel ring, client set | 0 hazard lines; the desktop compositor and one browser GPU process across every arm |

Every K row is 544 bytes and every V row 288, so a 2 MiB unit holds 3855.06
K rows or 7281.78 V rows: rows cross unit boundaries, and a sparse mapping
maps units rather than cells. The tensors are 17 and 9 units each, which is
why the padding reads zero at this depth; another depth or checkpoint pays
under one unit per tensor.

`graph-lifecycle-control/` and `graph-lifecycle-paged/` run
`scripts/run-graph-lifecycle-trace.sh` on closure `3950bc6e3bb5`, which
layers the census and lifecycle recorders on this patch, once with the
default KV buffer and once under `LLAMA_KV_PAGED_BUFFER=1`, over identical
prompt token arrays. Both arms record 35 warmup resets, every one
`structure` at `model.input_embed` with categories `shape,data`, and zero
rows whose change is a pointer alone; both read ten recurring topology
digests, the same episode medians of two direct executions, one capture,
and one update, and reply digests `c7c786b61660`, `191b3084c056`, and
`95c3695e7d2d` in the same arms. The lifecycle fraction reads 0.02571 under
the paged buffer against 0.02184 under the default, with the denominator
moving 6395.0 to 6612.6 ms between the arms; a first pair on the closure
ahead of the review fixes, since replaced and unretained, read 0.02234
against 0.02284 in the other direction, so the fraction moves with the run
rather than with the buffer while the decision counts agree row for row. The
reply digests differ
from `evidence/ada/graph-lifecycle/2b-run-02/` because the passage the
harness cuts its prompts from is this repository's own doctrine file, which
grew between the two runs; the control and paged arms here read one
passage, as the retained token arrays show.

P1 is admitted as a buffer mechanism and stays off for serving. What it
leaves open, in order of what P2 must answer before any unmap: which mapped
units may be absent while attention reads views padded to 256 rows past the
live cells; whether attention touches masked rows; what the physical
live-range unit is against a 2 MiB unit that neither row size divides; how
page reference counts follow `seq_rm`, `seq_cp`, K-shift, and stream copy;
how a state restore commits its destination units before it writes; and when
`cuMemUnmap` may run relative to queued CUDA work. Prefix sharing waits until
allocation, free, and recycling are exact.
