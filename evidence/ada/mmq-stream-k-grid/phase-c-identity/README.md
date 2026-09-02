# Phase C: threshold 80 changes the 2B's output, and the campaign ends there

The candidate closure `e4be5742e429` builds
`patches/llama-cuda-mmq-stream-k-grid.patch` at
`GGML_CUDA_ADA_MMQ_TILING_EFFICIENCY_PERCENT=80`, which routes the 48-tile
class to the destination-tile grid and sheds its fixup while every other class
keeps the multiprocessor grid. On `qwen38-2b-distill` that flips 58 of 168 Q4_K
weights and 10 of 27 Q6_K weights. Exact greedy token identity against the
production closure `88681bf4d161` is the promotion gate, and the candidate
fails it.

## The reading

| prompt | subject against control-open | first divergent index |
| --- | --- | ---: |
| accumulator | divergent | 16 |
| stack | identical | - |
| list-transform | divergent | 146 |
| variable-trace | identical | - |
| state-machine | divergent | 35 |
| constraints | identical | - |

The closing control agrees with the opening control on all six prompts, so the
device did not move under the pair and the three divergences are the closure.
Both closures place every buffer on CUDA0 at the same fingerprint
`b30ada0b80b8`, the three desktop clients hold at 1942, 483457, and 483747
across the run, the kernel ring reads zero hazard lines at both ends, and every
one of the eighteen responses carries a 256-entry token array against a
256-token request.

`verdict subject-divergent subject_divergences=3 control_divergences=0
refusals=0`.

## What it decides

`promotion_status=rejected`,
`failure_class=deterministic-grid-reduction-output-divergence`. The patch stays
a rejected artifact that no build in this tree reaches, beside
`patches/llama-cuda-mmvq-ncols-19.patch`, and `build-llama-cuda.sh` keeps its
tiling default at 90.

Phase C stops at the 2B. The campaign's own rule is that a failed identity gate
spends no further device time, so the 0.8B secondary and the 4B null never ran
and no rate matrix followed. A logit-margin probe would name the token pairs the
divergence turns on and could not change the decision under the retained
exact-identity policy, so it is left unrun.

Divergence is what the preregistration predicted. The fixup pass sums two slice
partials through `tmp_fixup` where the tiling grid keeps one running sum, so the
summation order changes for every flipped shape and floating-point addition is
not associative. The campaign's value is what it measured on the way:
`../phase-a-null/` proved the patch inert at its default on both the launch
record and the token record, and `../phase-b-witness/` established that grid
selection controls divisibility and divisibility controls whether the fixup
launch exists, then measured the tail that removing every fixup costs.

## What stays open

The measured fixup cost survives the rejection. `../phase-b-witness/` reads
576708 ns of `mul_mat_q_stream_k_fixup` against 2001680 ns of `mul_mat_q` on the
0.8B Q8_0 at ne11=17, 22.4% of the pass, and the width-32 class spends 62.8% of
its own pass there. Cutting that cost without changing decomposition or
summation order is the remaining route, and a change that preserves each
output's partial-sum order has a claim on exact identity that this one never
had.
