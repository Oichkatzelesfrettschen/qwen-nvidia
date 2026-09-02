# The MMQ stream-K grid threshold on AD104: a preregistration

This directory holds the design ahead of the run. No arm has executed, no
closure named here has been built, and nothing in this tree changes a default
on the strength of it.

## The mechanism

Stream-K partitions the K reduction across CUDA blocks rather than across
output tiles, and on this device it is the decomposition rather than a
decision. `ggml_cuda_mmq_get_config` at `mmq.cuh:247-249` routes every NVIDIA
part at Volta or later into `ggml_cuda_mmq_get_config_ampere`, and all 352
`CASE` rows of `mmq-config-ampere.cuh` set `stream_k` true, which is field
eight of the `ggml_cuda_mmq_config` constructor at `mmq.cuh:176-178`. The
xy-tiling body guarded by `if constexpr (!ggml_cuda_mmq_get_stream_k(...))` at
`mmq.cuh:986` is therefore unreachable at SM89, and so is the early return at
`mmq.cuh:1421`.

What varies at run time is the grid and the reduction pass that follows it.
`mmq.cuh:1436` reads

```text
const dim3 block_nums_stream_k(GGML_CUDA_CC_IS_NVIDIA(cc) && tiles_efficiency_percent >= 90 ? ntiles_dst : nsm, 1, 1);
```

and `mmq.cuh:1440` reads `fixup_needed = ntiles_dst % block_nums_stream_k.x != 0`.
At the tiling grid the modulo is zero and one kernel ends the pass. At the
multiprocessor grid a block's last tile is partial, `mmq.cuh:936-937` sends its
partial sum to `tmp_fixup` through `write_back` rather than to `dst`, and
`mmq.cuh:1463` launches `mul_mat_q_stream_k_fixup` to sum the preceding blocks'
partials into the completed tile. `ntiles_dst = ntx * nty * ntzw` with
`nty = ceil(nrows_x / config.I)` and `ntx = ceil(ncols_max / config.J)`
(`mmq.cuh:1404-1406`), `nrows_x` being the weight's output-row count
(`mmq.cu:171`) and `ncols_max` the column count of the second operand.

`patches/llama-cuda-mmq-stream-k-grid.patch` makes that 90 a build-configured
value under `GGML_CUDA_ADA_MMQ_TILING_EFFICIENCY_PERCENT`, gated on
`cc == GGML_CUDA_CC_ADA_LOVELACE`, which is the guard
`ggml_cuda_should_use_mmvq` already takes at `mmvq.cu:295`. An unpatched tree
and every part other than Ada keep the upstream selection, and the patch at its
default of 90 reproduces it on Ada as well. Setting `stream_k` false per row
stays unpatched: it swaps the kernel body, which is a second mechanism.

## Hypothesis

Admitting the tiling grid below 90% on SM89 removes the fixup pass wherever the
tile count then divides the grid, and lowers combined MMQ path time on the
shapes it reaches by more than the control span that bounds per-family kernel
time.

The measured case is `evidence/ada/mmvq-mmq-occupancy-ad104/`: at sixteen
columns on the 0.8B Q8_0 the MMQ arm issued 186 `mul_mat_q` launches and 186
`mul_mat_q_stream_k_fixup` launches, and the fixup took 550.1 us, 22.1% of the
arm's 2490.7 us. That arm is provisional -- its raw reports carried a shell
environment, which is why `scripts/exec-profiler-clean-env.sh` exists -- and
`path-totals.tsv` carries family labels rather than the templated symbols, so
the symbol-level reading belongs to `scripts/read-nsys-mat-mul-kernels.py` and
its `FIXUP` pattern at line 50.

The 5.8% by which MMQ's mat-mul kernel beats MMVQ's in that capture is an upper
bound on what removing the fixup can buy and not a prediction: the tiling grid
changes the mat-mul kernel's own tail, so 1940.6 us is not the patched mat-mul
time.

## Falsifier

A fixup share well below 22.1% on the anchor arm removes the case. A patched
combined time inside the control span, or one moving the wrong way because the
tiling grid's tail exceeds the fixup it removes, refutes the discriminator at
that shape. A `FIXUP` symbol present in the threshold-1 arm refutes the reading
of `mmq.cuh:1436` and `:1440` the whole campaign rests on. That refutation is
read from the `observed_kernel_families` column of `summary.tsv` rather than
from the `verdict` column: the awk at `run-ad104-path-audit.sh:268-277` requires
a FIXUP row for `MMQ+FIXUP` and admits one for `MMQ`, since `mmq.cuh:1463`
reaches the reduction only from the call that already launched `mul_mat_q`, so
a threshold-1 arm reads `agrees` whether or not the symbol appears. The
`cut -f5` at `:230` is what carries the symbol into the summary.

## Arm matrix rationale

`scripts/ad104-stream-k-matrix.tsv` carries thirteen arms at `ne11` 17 across
four closures. Three facts fix that shape.

Seventeen rather than sixteen. The promoted closure `88681bf4d161` carries
`llama-cuda-mmvq-crossover-ad104.patch` with Q6_K at ten and Q8_0 at sixteen
(`evidence/ada/mmvq-q8-b17-b20/`), so a sixteen-column Q8_0 prefill dispatches
to MMVQ and would void the anchor arm rather than reproduce the occupancy
capture. Seventeen is the first count at which Q4_K, Q6_K, and Q8_0 all reach
MMQ under that closure.

The regime is fixed at authoring time. `config.I` is 128 in every Ampere
`CASE` row, `ntx` is 1 at seventeen columns for every `J` the selector at
`mmq.cuh:1478-1494` can reach, `ntzw` is 1 for a dense mat-mul, and `nsm` reads
60 as an observation (grid 60 for `mmq16` in
`evidence/ada/mmvq-mmq-occupancy-ad104/occupancy.tsv`). `ntiles_dst` is then
`ceil(nrows_x / 128)` per weight, read from the GGUF headers:

| rows | tiles | waves | efficiency | flips at |
| ---: | ---: | ---: | ---: | ---: |
| 2048 | 16 | 1 | 26% | 26 |
| 2560 | 20 | 1 | 33% | 33 |
| 3584 | 28 | 1 | 46% | 46 |
| 4096 | 32 | 1 | 53% | 53 |
| 8192 | 64 | 2 | 53% | 53 |
| 9216 | 72 | 2 | 60% | 60 |
| 6144 | 48 | 1 | 80% | 80 |
| 248320 | 1940 | 33 | 97% | already tiled |

The output head at 248320 rows already takes the tiling grid and carries no
fixup today, which is why a whole-model null cannot be built by choosing
`ne11`: one forward pass holds several regimes at once. The nulls this design
does carry are a closure built at the default 90, required to be inert against
the control, and the 4B at threshold 80, which flips nothing because that
artifact carries no 48-tile class.

Four closures, one changed value each. The control is the promoted
`88681bf4d161` without the patch. The null closure carries the patch at 90.
The candidate is 80, which flips the 48-tile class alone. Counting every 2D
tensor of a type in the GGUF, the 16-row and 32-row tensors included, that is
58 of 168 Q4_K weights and 10 of 27 Q6_K weights on the 2B, 18 of 195 Q8_0
weights on the 0.8B, and none of the 222 Q4_K weights on the 4B. The tiling closure is 1, where every shape takes
the tiling grid and no fixup launches at all, which turns the audit's
presence check into a decisive reading and bounds the tail cost at its worst.

Arms run 2B first, 0.8B second, 4B third, the class order CLAUDE.md sets for a
general runtime experiment; control and subject alternate inside a class; the
opening arm repeats last as the closing control. The compositor consumes this
device throughout, so the resident compute client set is read around every arm
through `scripts/gpu-workload-ownership.sh` under
`/tmp/qwen-ad104-gpu-0.lock`, and a change between adjacent arms ends the
campaign.

## How a subject closure is built

The patch guards its default with `#ifndef`, so a subject closure is configured
by defining the macro on the compiler command line. The patch carries a hunk
for `ggml/src/ggml-cuda/mmq.cuh` alone and adds no cache-to-define bridge of
the kind `llama-cuda-mmvq-crossover-ad104.patch` puts in
`ggml/src/ggml-cuda/CMakeLists.txt`, so the value travels as
`-DCMAKE_CUDA_FLAGS=-DGGML_CUDA_ADA_MMQ_TILING_EFFICIENCY_PERCENT=80` rather
than as a cmake cache entry the MMVQ ceilings use.
`scripts/build-llama-cuda.sh` carries that pass-through as
`QWEN_CUDA_MMQ_TILING_PERCENT`, which defaults to 90, enters the configuration
digest as `mmq_tiling_percent`, and therefore names each subject closure its
own build directory. The `static_assert` beside the default refuses a value
outside 1 through 100 at compile time and the builder refuses one outside that
range before configuring. A value beside 90 against a tree whose `mmq.cuh`
lacks the macro is refused by name, since a `-D` no source reads would give a
subject closure the control's own dispatch; 90 builds against any tree, which
is what keeps the unpatched control buildable.
`scripts/test-cuda-build-tiling-threshold.sh` proves those relations through
the builder's `QWEN_BUILD_DRY_RUN` path, which resolves the digest and the
configure argv while compiling nothing.

## Gates, in order

1. `QWEN_LLAMA_CANDIDATE_PATCHES=1 scripts/verify-llama-patch-series.sh`
   applies the candidate and prints the post-apply `mmq.cuh` digest, which is
   what identifies a control closure from a subject one.
2. The null arms run first. The patch is inert at 90 -- same families, same
   launch counts, identical tokens -- or the run stops.
3. `scripts/run-ad104-path-audit.sh` reads the executed families. Every arm
   other than the threshold-1 ones expects `MMQ+FIXUP`, which its verdict
   enforces. A threshold-1 arm expects `MMQ` and its absence of a fixup is
   read from `observed_kernel_families`, since the verdict admits one.
4. Exact greedy token identity between the control and each closure the next
   section names it a gate for, on the carriers `scripts/run-graph-alias-ab.sh`
   already uses: temperature 0, top_k 1, a fixed seed, `ignore_eos`, prompt
   cache off, hashed over the `return_tokens` array, asserted present and of the
   predicted length before hashing, since an unset field hashes the empty array
   and passes silently. A 0.01-nat aggregate tolerance is refused as underived
   and retrospectively selected, on the standard
   `evidence/ada/mmvq-q8-b17-b20/` retained.
5. Per-family kernel time, subject against control, on the fixup arms.
6. Paired mirrored rate arms through `scripts/run-cuda-baseline-sweep.sh`.
7. The publication gate of `evidence/research-claim-methodology.md`.

## What each threshold decides

Three thresholds carry three separate claims, and gate 4 promotes on two of
them while deciding nothing on the third. The distinction is stated here rather
than after a result, because the same gate applied to all three would let a
value chosen to be extreme reject the value chosen to be served.

`90` is the implementation null. The patch reproduces the upstream selection at
its default, so exact greedy token identity against the unpatched control is
mandatory and a divergence stops the campaign permanently: it reports that the
patch changes behavior where it changes no value, which is a defect in the patch
rather than a property of the grid.

`1` is the structural witness. Every shape takes the tiling grid there, so a
`FIXUP` symbol in its `observed_kernel_families` refutes the reading of
`mmq.cuh:1436` and `:1440` the design rests on. Its token identity is recorded
and promotes nothing. One is a value no serving closure carries, and its
accumulation order differs from the control on every shape the grid reaches, so
a divergence there is the mechanism working rather than evidence against 80.

`80` is the candidate. It flips the 48-tile class alone -- 58 of 168 Q4_K
weights and 10 of 27 Q6_K weights on the 2B, 18 of 195 Q8_0 weights on the
0.8B, and none of the 222 Q4_K weights on the 4B -- and exact greedy token
identity is its promotion gate on the 2B primary, the 0.8B secondary, and the
4B control. A divergence rejects it under the standard
`evidence/ada/mmvq-q8-b17-b20/` set, and no bounded-numerics exception is
created for this campaign. Identity runs before any mirrored rate matrix,
because a rejected candidate spends no further device time and a rate measured
on a divergent closure decides nothing.

Phase B set the rule the candidate is judged against.
`evidence/ada/mmq-stream-k-grid/phase-b-witness/` measured the fixup removed at
every shape and the aggregate pass 18.9% slower, with the direction splitting by
tile class: the 62.8%-fixup width-32 class gained 11.4% while the 16.6%-fixup
width-24 class lost 23.3%. A fixup is therefore worth removing exactly where the
alternative grid's own tail is shorter than the reduction it eliminates, which
is the population threshold 80 selects and threshold 1 deliberately does not.

Gate 4 rejected it. `phase-c-identity/` ran the 2B primary against the
production closure and the candidate diverged on three of six prompts, first at
token 16, 35, and 146, with the closing control agreeing with the opening
control on all six and placement, client set, and kernel ring holding across
the run. `promotion_status=rejected`,
`failure_class=deterministic-grid-reduction-output-divergence`. The 0.8B
secondary and the 4B null never ran and no rate matrix followed, because a
failed identity gate spends no further device time.
`patches/llama-cuda-mmq-stream-k-grid.patch` stays a rejected artifact and
`build-llama-cuda.sh` keeps its tiling default at 90.

Identity is expected to fail. The patch reorders floating-point accumulation by
construction: a tile split across blocks sums two slice partials through
`tmp_fixup` where the tiling grid keeps one running sum, so the summation order
changes for every flipped shape. Failing gate 4 rejects the candidate under the
standard this repository just retained for the MMVQ threshold, where four gates
passed, exact token identity failed, and
`patches/llama-cuda-mmvq-ncols-19.patch` stayed a rejected artifact that no
build in this tree reaches. The campaign's residual value on that outcome is the
per-family kernel-time reading and a documented rejection, and the patch stays
a candidate pending a bounded-numerics design this tree does not have.

## The preregistered floor

Three measured controls bound three separate quantities, and each bounds its
own. Averaging them or taking the smallest is the retrospective selection this
tree refuses.

- Per-family kernel time from a capture: 12.4%, the spread on the unchanged
  `mul_mat_vec_q` single-column kernel across the two occupancy captures,
  664.3 us against 591.2 us
  (`evidence/ada/mmvq-mmq-occupancy-ad104/README.md`). The 22.1% fixup share
  clears it by 1.8x, thin by that README's own reading.
- Paired build-to-build rate: 0.7%, 231.85 against 230.15 decode tok/s on two
  builds that dispatch identically
  (`evidence/ada/cuda-runtime-levers.md:37,47`).
- Within-boot per-token prefill: the +5.1% closing-control drift with
  within-arm pp spans reaching 21.6%
  (`evidence/ada/b789-clean-calibration/README.md`).

## What this design cannot settle

- Whether `evidence/ada/b789-path-audit/` held fixup launches. The reader
  dropped the symbol at the time and the raw reports were removed
  (`removed-raw-reports.sha256`), so the mechanism is unread there.
- Whether the 22.1% fixup share generalizes past Q8_0 at sixteen columns. One
  provisional paired capture carries it.
- Whether the tiling grid's tail exceeds the fixup it removes across shapes,
  which is the tradeoff `mmq.cuh:1431-1432` names in its own comment.
- Bitwise tensor equality, which token identity does not establish in either
  direction.
- The replacement threshold value. Three values are measured rather than
  fitted, and a fourth between 46 and 60 would reach populations no closure
  here does.
- Serving-rate consequence. The audit discards its own timings, and only gate 6
  reads a rate.
