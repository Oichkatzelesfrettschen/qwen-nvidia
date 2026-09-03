# Preregistration: hide the fixup's DRAM latency without moving one add

`evidence/ada/ncu-decode-baseline/` measured `mul_mat_q_stream_k_fixup<Q8_0,24>`
at 11.85 `long_scoreboard` stalls per issued instruction against 3.05 for the
next stall reason, 25.1% L2 hit rate, and 33.3% DRAM throughput. That class
carries 150 of the 186 launches Phase B counted and 65% of the fixup time. The
kernel is waiting on global memory, so this arm targets the wait rather than the
launch geometry.

## Why the traffic is fixed and the latency is not

The fixup buffer is `nsm * J * I` floats: 60 * 24 * 128 * 4 bytes, 720 KiB. AD104
carries 48 MiB of L2, so a buffer that size fits with room over, and a 25.1% hit
rate therefore reports eviction rather than capacity. The `mul_mat_q` pass that
writes it streams the whole weight matrix through the same cache between the
write and the read, which is what evicts it. The NCU arm's own arithmetic agrees:
162.0 GB/s over a 4.78 us median launch moves 774 KiB, which is the buffer once.

A buffer read once from DRAM has one traffic figure and no locality to recover,
so the reachable term is the latency of those reads. Reading 720 KiB at the
442.61 GB/s this device's bandwidth-bound reference kernel achieved takes 1.63 us
against the 4.78 us measured, and the difference is what a pipeline can address.

## The walk length decides the shape of the candidate

The accumulation loop steps `bidx` downward and skips predecessors that wrote no
partial sum. A pipeline that prefetches `bidx - 1` fetches a tile the walk
discards whenever the predecessor is empty, so the skip rate decides whether the
change is a two-buffer rotation or a restructured index walk.

`static/derive-fixup-walk.py` replicates the kernel's own partition arithmetic
over the 0.8B Q8_0 matmul shapes at ne11=17 and reports the distribution in
`static/fixup-walk.tsv`. Every shape walks zero empty predecessors except the k
and v projections, whose 512 output rows give four destination tiles and a
2.13-block chunk against a `blocks_per_iter` of 8. Counting accumulating blocks
per layer, 8 of 68 walk empties and the other 60 walk none, and the median
accumulating block runs its body 3 to 7 times.

The candidate is therefore a two-buffer rotation rather than an index-walk
restructure. It also needs no speculative load: the index advance is pure
arithmetic and always lands on a predecessor that wrote a partial sum before its
tile's loads are issued, so no address outside the walk is ever read.

## The candidate

`patches/llama-cuda-mmq-fixup-pipeline.patch` rewrites the reduction loop as two
rotations of one body over `tile_a` and `tile_b`, so the loads for one
predecessor are in flight while the previous predecessor's values are added and
no register copy stands between a load and the add that consumes it. It also
takes `tmp_last_tile` as `const float * __restrict__`.

Each output still accumulates its predecessors in descending `bidx` order into
the same accumulator, starting from the same 0.0f, so the emitted sum is
bit-identical by construction rather than by tolerance.

## What the static read already establishes

`static/` retains the comparison, taken by compiling
`template-instances/mmq-instance-q8_0.cu` with the appliance's own
`compile_commands.json` flags at `sm_89`, control and subject.

Registers rise from 39 to 48 at J=24 and from 40 to 53 at J=32, with `LOCAL:0`
in both, so the two buffers stay in registers and nothing spills. At 128 threads
and 48 registers the SM holds 10 blocks against 12, which the arm records
because the kernel achieves 17.0% occupancy of a geometry it never fills.

The SASS confirms the rotation. The control's loop body reads
`6xLDG.E.CONSTANT` followed immediately by `6xFADD`, which is the serialized
shape the stall counter reports. The subject seeds `6xLDG.E.CONSTANT` with no
add, then each rotation reads `6xLDG.E.CONSTANT` for the next predecessor
followed by `6xFADD` consuming the previous one, with the index advance and its
branch between issue and consume.

The `const` qualifier changes no code: the control already emits
`LDG.E.CONSTANT` for these loads, because `__restrict__` alone lets nvcc prove
non-aliasing. It is retained as an interface statement rather than as a
generated-code lever, and this record says so rather than claiming the load path
moved.

## Falsifiers, stated before the device runs

- `long_scoreboard` in the J=24 class falls and `wait` does not rise to replace
  it. A run where the two trade places reports that the kernel moved from
  memory-latency bound to execution-dependency bound and bought nothing, which
  is the width-32 class's own bottleneck arriving in the width-24 class.
- Achieved occupancy holds or rises. A fall tracking the register increase
  reports that the pipeline's own cost exceeds what it hides.
- Exact greedy token identity holds on the 2B, then the 0.8B, then the 4B. The
  bit-identity argument above is an argument about the source; the gate is the
  measurement. A divergence refutes the argument and rejects the patch, and the
  arm stops at the first divergence rather than characterizing the rest.
- `compute-sanitizer` reports no invalid access. The rotation reads the same
  addresses in the same order, so a report would mean the advance lands
  somewhere the serial walk did not.

## Order of operations

Identity first, sanitizer second, rate last. A patch that changes accumulation
order is rejected on identity whatever it measures, which is how
`patches/llama-cuda-mmvq-ncols-19.patch` and
`patches/llama-cuda-mmq-stream-k-grid.patch` closed, and neither reached a rate
arm. This patch claims identity by construction, so identity is the cheapest
falsifier and it runs first.

Nothing is measured on the device yet.
