# The pipeline is in the SASS, the stall did not move, and the stall is not the cost

The candidate holds exact greedy token identity on all three runtime classes,
passes compute-sanitizer, and moves `long_scoreboard` by 1.3% against a within-
class spread of three to one. Its own preregistered falsifier fired, so
`patches/llama-cuda-mmq-fixup-pipeline.patch` is rejected on measurement with
identity intact, and `verify-llama-patch-series.sh` names it on a
`rejected_patch=` line reading `reason=no_measured_gain` beside the two that
read `numerical_gate_failed`.

Control closure `cb8b1e3e236d` and subject closure `04fdd99ca948` differ by this
patch alone, both at `QWEN_CUDA_ARCHITECTURES=89-real` off the pinned commit
`f280b2698`. The same three desktop clients held across every arm.

## Identity and safety pass

`identity/` holds three `run-closure-identity-ab.sh` runs in the class order the
repository sets, each a control, subject, closing-control triple over six
state-carrying prompts at 256 tokens:

| model | subject divergences | control divergences | placement |
| --- | ---: | ---: | --- |
| qwen38-2b-distill | 0 | 0 | same |
| qwen35-08b | 0 | 0 | same |
| qwen38-4b-distill | 0 | 0 | same |

Eighteen prompt comparisons, no divergence, every closing control agreeing with
its opening arm. The bit-identity argument the patch rests on is confirmed
rather than assumed.

`sanitizer/` holds `compute-sanitizer --tool memcheck` over the ne11=17 shape on
both closures: `ERROR SUMMARY: 0 errors` each. The rates printed there are the
sanitizer's and belong to no comparison.

## The counters refuse the mechanism

`ncu/counter-comparison.tsv`, medians over the same 14 and 6 profiled launches
per class:

| counter | control J=24 | subject J=24 | control J=32 | subject J=32 |
| --- | ---: | ---: | ---: | ---: |
| stall long_scoreboard | 11.66 | 11.51 | 0.36 | 0.24 |
| stall wait | 3.05 | 3.13 | 3.36 | 3.40 |
| duration us | 4.85 | 4.80 | 7.71 | 7.41 |
| DRAM throughput | 33.4% | 34.7% | 3.2% | 3.0% |
| L2 hit | 25.4% | 26.3% | 45.3% | 52.1% |
| achieved occupancy | 16.7% | 17.1% | 23.8% | 24.0% |
| registers | 39 | 48 | 40 | 52 |
| waves per SM | 0.33 | 0.40 | 0.33 | 0.44 |

The registers moved by nine and twelve and the waves by a fifth, so the change
reached the device; `static/sass-instruction-mix.tsv` already showed the
rotation in the emitted instructions. The stall it was built to remove held.

The mechanism explains it. A depth-1 rotation changes when a thread waits, not
how many loads it has outstanding: six either way, since it issues one tile's
loads and then adds the tile issued one iteration earlier. The work it inserts
between issue and consume is six FADDs and roughly twenty integer operations,
tens of cycles against a DRAM latency of hundreds, so the wait it can cover is
around a tenth of the wait present and the measured tenth of that is 1.3%.

That argument condemns the whole prefetch family at this trip count rather than
this depth of it. `static/fixup-walk.tsv` gives an `accum_med` of 2 for the
gate/up shape, which supplies 28 of the 68 accumulating blocks per layer and
fewer than three predecessors for a depth-3 rotation to hold, so a deeper
pipeline would spend registers on tiles that do not exist. No depth-3 arm ran
and this record states the reason rather than leaving it unmeasured by omission.

## The stall counter anti-correlates with the duration

`ncu/control/fixup-08b-q8/counters.csv` splits the J=24 launches into two
sub-groups that separate on both axes at once:

| sub-group | long_scoreboard | duration us | DRAM throughput |
| --- | ---: | ---: | ---: |
| high stall | 14.2 to 18.2 | 4.26 to 4.99 | 34.7 to 38.6% |
| low stall | 6.1 to 9.1 | 4.80 to 6.11 | 24.2 to 32.2% |

The launches that stall more finish sooner. A cost counter cannot behave that
way, so `long_scoreboard` here reports idleness rather than expense: the blocks
carrying more overlappable work stall less per issued instruction and run
longer, and the ones with least to do report the highest stall while finishing
first. Optimizing against that counter is what this arm did, and the inversion
is why it bought nothing.

## What survives, and its falsifier

The DRAM reading from the preregistration holds. The 720 KiB fixup buffer
arrives from DRAM rather than L2 because the `mul_mat_q` pass that wrote it
streams the whole weight matrix through the same 48 MiB cache, and the
retained arithmetic agrees: 162.0 GB/s over a 4.78 us median moves 774 KiB,
which is the buffer once. That traffic is irreducible without changing the
decomposition.

The surviving hypothesis is that the duration is set by how little of the device
requests that traffic rather than by how each thread waits for it. Every launch
runs a (60, 4, 1) grid at 0.33 waves per multiprocessor while
`static/fixup-walk.tsv` derives 4 to 28 of the 60 x-blocks surviving the early
return, so 27 to 47% of the grid asks for memory and the measured DRAM
throughput is 24 to 38% of peak. Those brackets overlap, which is consistent
rather than conclusive: the block counts are derived from a simulation of the
kernel's partition arithmetic rather than read out of the capture.

Its falsifier is a fixup shape where every grid block carries work, which would
read near 1.6 us at the 442.61 GB/s reference rate. Constructing that shape
means changing the decomposition, which this task excludes, so the hypothesis
stays open and no arm here closes it.

## The correction this makes to the campaign that ordered it

`../ncu-decode-baseline/README-RESULTS.md` read the width-24 class as memory
latency bound and called the 0.33-wave launch geometry "real but secondary."
This arm took that branch, implemented it correctly, confirmed it in the
emitted instructions, and measured 1%. The ordering inverts: the launch
geometry is the constraint and the stall counter is its symptom. That record
keeps its measurements as taken and this file carries the correction.

The other half of that campaign's verdict is untouched. Decode already runs at
the sustainable roofline, so #43 shape-bucketed graph prewarming and #44
GPU-side sampling remain the targets, and a mat-mul kernel rewrite is still not
one.
