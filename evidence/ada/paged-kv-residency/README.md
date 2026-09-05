# Paged KV P2: residency over independently releasable units

P2 reclaims attention-cache backing that nothing can access, over the
virtual reservation P1 admitted, and it stops at proven tail residency and
lifecycle management. This record is the contract every P2 change is held
to: the allocation boundary, the access envelope that decides residency, the
transactional lifecycle of a mapping change, the five accounting quantities,
the admission matrix, and the preregistered targets. `2b-run-01/` under
`evidence/ada/paged-kv-buffer/` is the baseline every arm here compares
against, and the P1 record's own open questions are the order of business.

## Allocation boundary

P1 backs the reservation with one `cuMemCreate` handle mapped whole by one
`cuMemMap`, and its destructor unmaps that one range. `cuMemUnmap` removes a
mapping in whole units of the mapping it was created by, and the driver
returns physical memory only after every mapping and every outstanding handle
reference is gone, so a partial unmap of P1's mapping is not an operation the
API offers and a removed mapping over a retained handle returns nothing to
the device. The first P2 change is therefore the allocation boundary and
nothing else:

```text
one stable virtual reservation, aligned and sized in units of G
    unit 0   own cuMemCreate handle, own cuMemMap, own cuMemSetAccess
    unit 1   own handle, own map, own access
    ...
    unit n-1
```

`G` is `cuMemGetAllocationGranularity(CU_MEM_ALLOC_GRANULARITY_MINIMUM)`,
read at backend initialization the way P1 reads it and 2097152 on this
device; the value stays a query rather than a constant. Every unit is created
and mapped at construction under P2-A, so the tensors, addresses, strides,
bytes, graph decisions, and outputs equal P1's by construction, and the
P1 identity harness is what proves it before any unit is left unmapped.

Five quantities are tracked from the first P2 change and printed on the
buffer's own log lines:

| quantity | meaning |
| --- | --- |
| `virtual_reserved_bytes` | the reservation, `roundup(requested, G)` |
| `physical_allocated_bytes` | bytes held by live `cuMemCreate` handles |
| `physical_mapped_bytes` | bytes of those handles currently mapped and accessible |
| `physical_retained_unmapped_bytes` | handles unmapped and kept for reuse: cached memory, counted as held |
| `physical_released_bytes` | cumulative bytes returned through `cuMemRelease` after unmap |

A unit unmapped and retained for reuse is cached physical memory and never
counts as reclaimed; the memory-saving claim is read from
`physical_allocated_bytes` alone.

## Units from byte intervals

A K row is 544 bytes and a V row 288 at the served `q8_0`/`q4_0` triple, and
neither divides G, so residency is computed from byte intervals rather than
from a cell count per unit. For a tensor at buffer offset `o` with row size
`r`, `S` cells per stream, and stream stride `r * S`, the rows `[a, b)` of
stream `s` occupy

```text
[lo, hi) = [o + s*r*S + a*r,  o + s*r*S + b*r)
units([lo, hi)) = { floor(lo / G), ..., floor((hi - 1) / G) }
```

A row that crosses a unit boundary requires both units, a requirement is the
union of its rows' units, and streams whose regions share a boundary unit
union their requirements in that unit. No integer "cells per unit" appears
anywhere in the design, the planner, or the reader.

## The access envelope is the residency authority

Cell occupancy is not the predicate. `get_n_kv` pads the attention extent to
`min(S, max(256, GGML_PAD(used_max_p1, 256)))` over every stream of the
ubatch, `get_k` and `get_v` expose strided views over that extent from row 0
of each stream, `cpy_k` and `cpy_v` write through `ggml_set_rows` at global
row indices, and the flash-attention kernels tile K in strides of
`FATTN_KQ_STRIDE` (256 rows, `fattn-common.cuh:9`) inside `K->ne[1]`. "No
live token owns this row" and "no operation can touch these bytes" are two
predicates, and the mapped set is decided by the second. The required set is

```text
R = R_live  U  R_attention  U  R_writes  U  R_maintenance  U  R_inflight
```

| requirement | rows it covers, per stream and tensor |
| --- | --- |
| live state | every cell holding a sequence, and every cell a shared logical range must preserve |
| attention | `[0, n_kv)` for every stream in the ubatch, at the padded `n_kv` the graph was built with |
| writes | every destination row of `set_rows` in the pass, and every row an initialization writes |
| maintenance | state restore destinations; both whole streams of a cross-stream copy (`update`, `ggml_backend_tensor_copy` over `k_stream[s]`); the whole K tensor of every rope layer under K-shift (`build_graph_shift` views `get_size()*n_stream` rows); the resident set of a clear |
| in flight | every unit an outstanding kernel, copy, graph replay, or scheduled compute references, until its completion is observed |

A unit is retained while any requirement needs it and becomes reclaimable
only after every requirement has released it. State save reads the live
ranges alone (`state_write_data` walks `cr.data`), so it adds nothing beyond
the live set.

The planner's own arithmetic states one consequence of the pinned padding
rule: because every attention view starts at row 0 of its stream and extends
to the padded `used_max_p1`, an interior hole left by `seq_rm` lies inside
the attention envelope of the stream that holds cells above it, so the units
under the hole are held by the attention requirement rather than merely
retained by policy. The interior class in the planner is the guard for a
padding rule that stops starting at row 0; under the pinned rule and one
stream it reads zero and the tail is the only reclaimable region. Across
streams the regions of one tensor are adjacent, so a unit on a shared
boundary can be held by one stream's requirement while the other stream's
side of it sits below that stream's high-water mark, which the planner
reports as interior for that region rather than as a tail.

### Tails first, interior holes stay backed

The first sparse implementation leaves unmapped only the suffix of each
stream region above every requirement's high-water unit. A unit below that
high-water mark stays backed even when every cell in it is free, because an
attention mask is a value the kernel multiplies rather than a bound it
respects, and the display GPU is not where that assumption is tested by
provoking an illegal access. Three stages, each admitted on its own:

```text
P2-A  independently created and mapped units; every unit backed; P1 identity repeated
P2-B  shadow residency planner: required and reclaimable sets computed from events,
      every retained unit and every proposed release explained; no mapping changes
P2-C  required units committed and proven-unused tails reclaimed at explicit
      quiescent boundaries; interior holes backed
```

Interior-hole reclamation, physical prefix sharing, and heterogeneous or
mixed-precision pages are outside this admission.

`scripts/paged-kv-residency-planner.py` is P2-B. It takes the layout the P1
reader already extracts (unit, cells, streams, one offset and row size per
tensor) and an event stream of allocation, ubatch writes, sequence removal,
state restore, cross-stream copy, K-shift, clear, and quiescence, computes
the five requirement classes per unit, and prints every retained unit with
the requirements holding it and every release it would propose, proposing
releases at a quiescence event alone. `scripts/test-paged-kv-residency-planner.py`
holds it to the served 2B layout: growth across a unit boundary and across
a 256-row padding boundary, a sequence removed while another still holds
the unit, tail reclamation followed by regrowth, restore across a boundary,
K-shift and cross-stream copy as whole-tensor requirements, and the
in-flight hold released by quiescence alone.

## Whole-buffer operations under holes

A whole-reservation `memset` or copy cannot coexist with an unmapped unit,
so each such operation is resolved rather than preserved:

- **Initialization and clear.** `llama_kv_cache` clears the buffer at
  construction and on `clear(true)` through `ggml_backend_buffer_clear`,
  which `ggml-cuda.cu:847` implements as one `cudaMemsetAsync` over
  `buffer->size`. Under P2 a clear is a logical reset plus a memset of the
  resident units, and every unit committed later is zeroed before any reader
  sees it. A clear whose semantics the buffer cannot honor is refused rather
  than read as zero.
- **State restoration.** `state_read_meta` validates cell count and layout,
  then `state_read_data` scatters rows to `sinfo` destinations. Under P2 the
  destination units are committed and granted access ahead of the first
  `read_tensor`, and the restored sequence is published only when the
  transaction completes.
- **Cross-stream copy and K-shift.** Both touch whole streams or whole
  tensors. The first implementation commits the full required range for the
  operation or refuses the experimental mode for it; it never skips an
  unmapped portion. The served path runs `--no-context-shift` and
  `--parallel 1`, so both are absent from the served workload and present in
  the admission matrix as explicit arms.
- **Serialization.** The state format and its logical payload are unchanged.
  No physical handle, virtual address, or residency map is serialized.
- **Recurrent memory.** `llama_memory_recurrent` stays on the default
  buffer, as P1 left it.

Two claims are kept apart in every record: sparse steady-state residency,
which may reduce memory after construction, and sparse initialization, which
may also reduce the model-load peak. The second is claimed only by an
implementation that never allocates and clears the full cache before
reclaiming it.

## Transactional and quiescent mapping changes

Commit, before any newly committed storage is exposed:

```text
compute required byte ranges
-> create the missing physical units (cuMemCreate)
-> map each unit (cuMemMap)
-> grant CUDA0 access (cuMemSetAccess; a mapping alone grants nothing)
-> initialize required contents (zero)
-> complete the dependency (event or stream synchronization)
-> publish the operation as runnable
```

Reclaim:

```text
stop admission of operations touching the candidate units
-> retire all relevant GPU work (explicit completion event, or a conservative
   synchronization boundary for the first candidate)
-> recheck live-state and operation references
-> unmap complete units (cuMemUnmap)
-> release their handles (cuMemRelease)
-> update the five quantities
```

The top-level workload lock orders processes and retires nothing queued
inside this one; completion is observed inside the process. Graph addresses
stay stable and pointer stability is not residency safety: a graph executable
retains its pointers while their backing changes, so residency is validated
before every replay and no reclamation runs while a replay is outstanding.
A failed transaction unwinds the units it created and leaves the previous
runnable state in place, or refuses the request cleanly; the driver-hazard
latch and the kernel-ring watcher keep their roles, and no rapid allocation
retry, unified-memory spill, or CPU fallback is added to make the sparse mode
read as successful.

## Benefit, sized from the measured layout

The P1 record holds six attention layers, twelve tensors, and 312 MiB of
backing at 65536 cells. For a single-stream padded prefix of `h` rows the
backing this layout requires is

```text
M(h) = 6 * G * ( ceil(544*h / G) + ceil(288*h / G) )
```

| padded prefix rows | calculated backing | under fully backed P1 |
| ---: | ---: | ---: |
| 4096 | 36 MiB | 276 MiB |
| 32768 | 168 MiB | 144 MiB |
| 65536 | 312 MiB | 0 MiB |

The same arithmetic states what the 2 MiB unit costs at small envelopes.
The smallest nonempty envelope, 256 padded rows, holds 1.219 MiB of logical
K and V across the six layers and requires 24 MiB of backing, one unit per
tensor, about twenty times its logical bytes; 3840 rows still fit in 24 MiB,
4096 rows require 36 MiB, 7168 rows 36 MiB, and 7424 rows 48 MiB. The first
K unit growth is triggered by padding at used depth 3841, ahead of the
physical row crossing at row 3855, so the padding rule rather than the row
size decides where units are committed at the low end. The standing envelope
also keeps the padded tail of every inactive sequence backed; releasing that
padding between activations would trade memory for recommit traffic while
preserving live bytes, and it is measured rather than assumed.

These are layout calculations. A measured residency adds maintenance ranges,
inactive but preserved sequences, in-flight references, and any retained
pool before it is reported. Residency is updated when a unit boundary or a
sequence lifetime is crossed, never by rescanning cells or calling a mapping
API per decoded token, and the boundary-crossing cost is measured on its
own beside steady decode.

## Preregistration

P2 is judged as memory management. The floors are declared here ahead of any
device run and are not lowered after one:

| claim | target | falsifier |
| --- | --- | --- |
| P2-A identity | every P1 gate holds: 12 of 12 token arms and 12 of 12 state files identical, one placement fingerprint, `physical_mapped_bytes == virtual_reserved_bytes`, padding 0 | one differing token, state byte, or fingerprint refuses the boundary change |
| P2-B planner | every retained unit and every proposed release explained; the test matrix passes; the planner replayed over a retained P2-A log proposes releases only at quiescence and only in tails | an unexplained unit, or a release below a high-water mark |
| P2-C steady-state saving | at a 4096-row envelope on the 2B, `physical_allocated_bytes` at or under 60 MiB (the 36 MiB layout figure plus one 2 MiB unit for each of the twelve tensors as maintenance and in-flight slack) | a reading above 60 MiB with no explained holder |
| P2-C mapping latency | a commit or reclaim transaction at a unit boundary under 2 ms at the median and under 10 ms at the 95th percentile, measured beside and separated from steady decode | a boundary crossing that stalls decode past 10 ms |
| P2-C serving cost | delivered decode rate within 2% of the fully backed P1 arm at batch 1, primed widths 1 and 3 identical in reply | a regression past 2%, or one differing reply |
| P2-C identity | exact batch-1 tokens and state bytes against the P1 control, then the primed multi-sequence regime | any difference |

## P2-A result

`2b-p2a-run-02/` runs `scripts/admit-paged-kv-buffer.sh` against closure
`adb111abc7cf`, the pinned tree with the crossover patch and the P2-A form
of `patches/llama-cuda-paged-kv-buffer.patch` as committed, on the 2B under
the same harness that admitted P1; the subject arm is that closure's own
binary under `LLAMA_KV_PAGED_BUFFER=1`. `2b-p2a-run-01/` is the same run on
closure `f35fe5a95a43`, the form of the patch ahead of the review pass that
moved the unit table's host allocation ahead of the reservation and put the
context under an owning pointer; both runs read the same table.

| record | reading |
| --- | --- |
| granularity minimum, recommended | 2097152, 2097152 bytes; 3 of 3 probe samples answered with no probe pid in the client list |
| batch-1 tokens | 12 of 12 arms identical |
| slot-0 state files | 12 of 12 byte-identical |
| placement fingerprint | one value across the three arms |
| units | 156, each with its own handle, mapping, and access grant |
| virtual_reserved, physical_allocated, physical_mapped | 327155712 bytes each; padding 0 |
| physical_retained_unmapped, physical_released | 0, 0 |
| tensors in the paged buffer | 12, layout and census as in P1 |
| primed width 1 | replies identical in 4 of 4 bursts, delivered ratio 1.0003 (0.9968 in run-01) |
| primed width 3 | replies identical in 4 of 4 bursts, delivered ratio 1.0003 (1.0018 in run-01) |
| kernel ring, client set | 0 hazard lines; the compositor and one browser GPU process across every arm |
| verdict | admitted |

The allocation boundary therefore moves nothing observable: the same
addresses, layout, tokens, and serialized state come out of 156 independent
units as out of one mapping, and memory saved is still 0 by construction.
P2-B is the planner in this record; P2-C waits on it.

## Admission matrix

The 2B runs first and the 0.8B second, holding the primary and secondary
priority. Every level carries five arms: the ordinary CUDA allocation
control, the fully backed P1 control, the independently mapped fully backed
P2-A null, the sparse P2-C subject, and a closing control. The subject
exercises, before promotion:

- growth across a unit boundary and across a 256-row padding boundary;
- deletion of one sequence while another still references the same unit;
- tail reclamation, regrowth, and zero-initialization of reused storage;
- state save and restore across a mapping boundary;
- cancellation with queued work, and failure halfway through a commit, both
  through mocked driver failures for deterministic cleanup;
- exact batch-1 tokens and state bytes, then the primed regime at widths 1
  and 3.

Valid mappings are exercised on the device inside bounded arms; no arm
provokes an intentional GPU fault as its negative control. The tuple names
its MTP state: the ordinary path is admitted first, and the `draft-mtp`
shared-cache path is validated separately before sparse KV is enabled for a
row that serves it.

P2 stops at proven tail residency and lifecycle management. Prefix sharing,
interior holes, typed-page execution, and mixed precision are later stages
with their own records.
