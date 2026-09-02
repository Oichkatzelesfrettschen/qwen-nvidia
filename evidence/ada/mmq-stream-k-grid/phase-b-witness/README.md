# Phase B: grid selection is what launches the fixup, and the tiling tail is real

Threshold 1 forces `block_nums_stream_k.x` to `ntiles_dst` at `mmq.cuh:1436`
for every shape, so `ntiles_dst % block_nums_stream_k.x` is zero at
`mmq.cuh:1440` and `fixup_needed` never holds. If the reduction still launched,
the reading of those two lines the whole campaign rests on would be wrong.

Closure `18bc38699c86` at `mmq_tiling_percent=1` against the promoted
`88681bf4d161`, on `qwen35-08b` Q8_0 at `ne11` 17, the arm that reads directly
against the retained occupancy capture. One profiled prefill each, run
back to back under the top-level GPU owner lock with the same three desktop
clients throughout.

## The mechanism holds

| arm | MMQ | FIXUP | MMVQ |
| --- | ---: | ---: | ---: |
| `sk-control-08b-q8` | 186 | 186 | 164 |
| `sk-tiling-08b-q8` | 186 | 0 | 164 |

The fixup disappears completely and the mat-mul count is untouched, which is
the pass criterion. Every MMVQ launch in both arms carries `ncols=1` and
belongs to the single generated token rather than to the 17-column prefill, so
no MMVQ reaches the work under test.

The control reproduces the anchor it was preregistered against. The fixup takes
22.4% of combined MMQ path time here against the 22.1% that
`evidence/ada/mmvq-mmq-occupancy-ad104/` measured on the same artifact, and
both arms carry 186 mat-mul launches as that capture did.

## The tiling grid costs more than the fixup it removes

This is beyond the pass criterion and it is the finding.

| tile width | control mat-mul | control fixup | tiling mat-mul | move | fixup share |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 24 | 1881616 ns | 373602 ns | 2779799 ns | +23.3% | 16.6% |
| 32 | 120064 ns | 203106 ns | 286241 ns | -11.4% | 62.8% |
| both | 2001680 ns | 576708 ns | 3066040 ns | +18.9% | 22.4% |

Removing the reduction pass costs 487652 ns more than it saves. The direction
splits by tile class and it splits the way the mechanism predicts: where the
fixup dominates the pass at 62.8%, the tiling grid wins; where it is 16.6%, the
tiling grid's own tail exceeds it. `mul_mat_q<(ggml_type)8, (int)24, (bool)0>`
carries 150 of the 186 launches and drives the aggregate.

## What bounds the reading

The two unchanged `mul_mat_vec_q<Q8_0, 1>` symbols are the within-pair noise
floor, since neither closure changes them: they move -2.70% and +7.49%, summing
to +0.11%. A single capture per arm therefore resolves a per-symbol difference
of roughly 7.5% and no better. The aggregate +18.9% and the width-24 +23.3%
sit outside that; the width-32 -11.4% is about 1.5 times it and is provisional.
The preregistered per-family floor of 12.4% comes from two captures taken on
separate occasions and is the conservative bound to read these against.

## What this does not decide

Threshold 1 is a mechanism witness rather than a candidate. It routes every
shape to the tiling grid, including the 13% and 26% efficiency classes where
`ntiles_dst` is 8 or 16 against 60 multiprocessors, so its regression is the
worst case by construction and predicts nothing about threshold 80. Threshold
80 flips the 48-tile class alone, at 80% tiling efficiency, where the tail is
far shorter.

The width-32 result is the one that argues for the campaign continuing: a class
whose fixup takes 62.8% of its pass improved when the fixup was removed, which
is the shape of win threshold 80 is looking for on the 48-tile population.

Token identity was not measured here and would decide nothing if it had been.
Threshold 1 changes the summation order on every shape the grid reaches, so a
divergence there is the mechanism working.

## Device state

The kernel ring carried 44 pre-existing signatures before the run and 44 after,
a delta of zero under the audit's own halt pattern. The GPU state latch reads
clear, the owner lock released with the harness, and the compute-client set was
the same three desktop processes at both ends.
