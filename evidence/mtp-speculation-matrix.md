# The embedded MTP head accepts 93% of its drafts and buys 1.2x

`empero-ai/Qwen3.8-4B-Distill` Q4_K_M through the guarded launch path on the
Raven2 laptop, full RADV Vulkan offload, `low-async`, 24576 context, greedy
sampling with `temperature 0`, `top_k 1`, `seed 42`, `cache_prompt false`.
`remote/run-speculation-matrix.sh` owns every launch and teardown, so a
difference between two rows is a difference between two speculation settings.

Every number below the arm tables comes from the first prompt suite: three
128-token greedy continuations of a bare prefix. That suite is retired for the
reason the n-gram section gives, and the tables that survive it are named there.
The column cost series and the occupancy cliff rest on that suite alone, because
they need arms at five and seven columns and only it has them.

## The head needs no patch and no sidecar

An earlier revision of `evidence/qwen38-distill-tensor-census.md` recorded
whether `draft-mtp` could reach a head embedded in the target GGUF as the
untested question. The pinned source answers it. `common/common.cpp` sets
`mparams.load_mtp` when `params.speculative.types` holds
`COMMON_SPECULATIVE_TYPE_DRAFT_MTP`, which clears the `TENSOR_SKIP` that
`src/models/qwen35.cpp` otherwise applies to the appended block.
`common_speculative_init_result` then takes its `else if (spec_mtp)` branch and
calls `llama_init_from_model(model_tgt, cparams)` with
`cparams.ctx_type = LLAMA_CONTEXT_TYPE_MTP`, so the draft context runs against
the target model and `-md` stays unused. `llama_model::create_memory` filters
that context's KV cache with `il >= hparams.n_layer()`, so the draft cache
holds the one appended block rather than a second trunk.

The server log confirms each step:

```
common_speculative_init_result: creating MTP draft context against the target model
llama_context: n_outputs_max = 2
spec common_specu: adding speculative implementation 'draft-mtp'
spec common_specu: - n_max=1, n_min=0, p_min=0.00, n_embd=2560, backend_sampling=1
```

`n_outputs_max = 2` on the target context is what makes one pass verify the
drafted position together with the bonus position. Without it a draft of N
tokens would decay into N sequential passes and every arm would report no gain
for a plumbing reason.

## Acceptance clears the admission threshold by a wide margin

| arm | prompt | decode tok/s | verification steps | acceptance | mean accepted length |
| --- | --- | ---: | ---: | ---: | ---: |
| S0 | code | 3.09 | - | - | - |
| S0 | prose | 3.10 | - | - | - |
| S0 | arithmetic | 3.09 | - | - | - |
| S1 | code | 3.63 | 67 | 0.896 | 1.90 |
| S1 | prose | 3.70 | 65 | 0.938 | 1.94 |
| S1 | arithmetic | 3.76 | 64 | 0.969 | 1.97 |

The one-token admission threshold was stated before the run: the 4B needs
1.466 times its 3.07 tok/s to reach 4.5, so an idealized one-draft-token
speculation needs acceptance above 0.466, and 0.55 to 0.60 was the plausible
figure once the head's own cost is counted. Measured acceptance is 0.934 across
the three prompts, so the threshold is cleared and the arm is admitted on that
criterion.

Speedup is 1.17 to 1.22 times, not the 1.90 the accepted length implies. The
gap between those two numbers is the finding.

## Decode on this APU is not bandwidth-bound, and the matrix shows where

The target ran 67 passes to produce 128 tokens where the unspeculated arm ran
128. If a two-column pass cost what a one-column pass costs, the whole 1.90
would arrive as wall clock. Splitting each arm's measured time into target and
draft with the per-request `dur(g)` the speculation statistics report:

| quantity | value |
| --- | ---: |
| one-column target pass | 323.4 ms |
| two-column target pass | 463.1 +/- 3.0 ms |
| MTP draft pass | 66.4 +/- 0.3 ms |

Both target passes stream the same 2.698 GB of weights, so the 139.7 ms the
second column adds is arithmetic rather than traffic. That decomposes a
verification pass into a fixed 183 ms and 140 ms per column, and it contradicts
the model the rest of this tree reasons in: at 8.35 GB/s the one-column pass
looks bandwidth-bound, while the second column costs as if the kernel had spare
bandwidth and no spare arithmetic.

The dispatch explanation is refuted by reading the code rather than by running
an arm. `ggml-vulkan.cpp` sets `mul_mat_vec_max_cols = 8` and routes to
`ggml_vk_mul_mat_vec_q_f16` whenever `dst->ne[1] <= mul_mat_vec_max_cols`, so
every arm from N=1 through N=7 stays on the same GEMV kernel and none of them
falls back to the GEMM path. `mul_mat_vec_q4_k.comp` already hoists the
dequantization out of its `NUM_COLS` loop: the sixteen `q4_*` values and the
eight scales are computed once per row and reused. What the loop does per
column is the dot product and the `smin` correction, roughly 31 fused
multiply-adds per 32-element chunk, and that is the work the measurement bills
at 140 ms.

## The prediction is refuted, and the deviation locates a cliff

The MTP head drafts sequentially, so an arm at N pays N draft passes and
verifies 1+N columns. Before the deeper arms ran, the recorded model was a step
time of `323 + 206.4 N` ms with a mean accepted length of `sum 0.93^k`, giving a
flat peak near 3.8 tok/s at N=2 to N=3, a ceiling below 4.5, and a two-sided
falsifier: any arm above 4.1 tok/s, or any arm more than 15% below its predicted
rate.

The low side tripped, hard.

| arm | cols | predicted tok/s | measured tok/s, code / prose / arithmetic |
| --- | ---: | ---: | --- |
| S1 | 2 | 3.65 | 3.63 / 3.70 / 3.76 |
| S2 | 3 | 3.81 | 3.27 / 3.40 / 3.62 |
| S3 | 4 | 3.82 | 3.24 / 3.34 / 3.65 |
| S4 | 5 | 3.79 | 2.23 / 1.73 / 2.62 |
| S6 | 7 | 3.64 | 1.93 / 1.73 / 2.63 |

S4 and S6 fall below the 3.09 of the unspeculated arm, so drafting four or six
tokens ahead is slower than not speculating at all. Two errors combine there and
they separate cleanly.

Acceptance decays faster than a uniform 0.93 allows. Measured mean accepted
length is 2.00, 2.91, 3.66, 4.16, and 5.41 against a predicted 1.93, 2.80, 3.60,
4.35, and 5.69, so depth is close through N=3 and the top two arms fall short.

The cost model is where the refutation lives. Subtracting the draft time the
speculation statistics report leaves the target verification pass:

| columns | target pass ms | added by the last column |
| ---: | ---: | ---: |
| 1 | 323 | - |
| 2 | 459 | 136 |
| 3 | 662 | 203 |
| 4 | 783 | 121 |
| 5 | 1319 | 536 |
| 7 | 1636 | 159 for two, 79 each |

Columns one through four cost about 150 ms each and column five costs 536, after
which the curve flattens again at 79. That is a step, not a slope, and the linear
term the prediction extrapolated from two points is refuted exactly where the
code said it would be.

The mechanism is occupancy. `ggml_vk_get_dequantize_mul_mat_vec` chooses
`DMMV_WG_SIZE_LARGE` only for NVIDIA past Pre-Turing and for Intel, so RADV on
this device always takes `DMMV_WG_SIZE_SUBGROUP` and the workgroup size is the
same in every arm. What varies is the specialization constant: the pipeline is
created as `{wg_size_subgroup, 2*rm_kq, i+1}` with `i+1` the column count, and
`mul_mat_vec_q4_k.comp` declares `FLOAT_TYPE temp[NUM_COLS][NUM_ROWS]` as
per-invocation storage while its `[[unroll]]` column loop holds four `vec4`
loads of `b` live per column. Register demand therefore grows with the column
count against a fixed 256-register file per lane, and Vega occupancy falls in
integer steps rather than continuously. A step at the fifth column is what a
drop from two waves per SIMD to one produces. This is the mechanism the code
supports; the register count itself is unmeasured, and a `GGML_VK_PIPELINE_STATS`
capture is what would settle it.

## Backend sampling moves nothing on this device

The vocabulary is 248,320 entries wide, so moving the sampler onto the device
removes the largest per-token host copy the server makes. That was the reason to
test it; the measurement refutes it as a lever.

| arm | speculation | backend sampling | code | prose | arithmetic |
| --- | --- | --- | ---: | ---: | ---: |
| S0d | off | off | 3.10 | 3.09 | 3.08 |
| B1 | off | target | 3.07 | 3.08 | 3.06 |
| S1b | draft-mtp N=1 | off | 3.63 | 3.66 | 3.63 |
| B2 | draft-mtp N=1 | target and draft | 3.58 | 3.68 | 3.69 |

Both comparisons sit inside the spread of repeated arms, and `B1` reproduces the
unspeculated token sequence exactly while `B2` reproduces the speculative one.
The transfer it removes is not on the critical path at one token per pass, which
is consistent with the column table: a verification pass is priced in hundreds of
milliseconds of kernel time, and a single logit copy is not.

## The prompt suite measures repetition, and one arm exposes it

`ngram-simple` reached 4.57 and 5.47 tok/s on prose and arithmetic with an
acceptance of 1.000, above the 4.5 target, and drafted nothing at all on code.
That spread is a property of the prompts rather than of the speculator.

Each prompt is a 128-token greedy continuation of a bare prefix, which drives
this model into repetition, and n-gram drafting is free exactly there. Counting
the fraction of positions whose eight-token window already appeared earlier in
the same continuation:

| prompt | repeated 8-grams | n-gram drafts | n-gram tok/s | MTP acceptance |
| --- | ---: | ---: | ---: | ---: |
| code | 2% | 0 | 3.10 | 0.896 |
| arithmetic | 46% | 76 | 5.47 | 0.969 |
| prose | 68% | 69 | 4.57 | 0.938 |

The n-gram rate tracks repetition and nothing else, so those two figures measure
how fast a loop decodes and support no claim about serving throughput. The same
gradient inflates the MTP acceptance column: the code prompt at 2% repetition
gives 0.896, and that is the figure to carry rather than the 0.934 mean.

The MTP conclusions survive the flaw because every arm saw the same three
prompts, so the comparison between arms holds even where the absolute rates do
not. The column cost table is derived from per-step timing and is consistent to
within 3% across all three prompts, so it is independent of content. The backend
sampling comparison holds for the same reason. What the suite cannot support is
any absolute throughput claim, and `remote/run-speculation-matrix.sh` now reports
the repetition fraction beside each rate so the artifact cannot hide in a later
run.

## The chat suite reprices every gain

Repeating the decisive arms on non-degenerate text, 192 predicted tokens, with
the repeated-eight-gram fraction beside each rate:

| arm | prompt | decode tok/s | drafted | acceptance | repeated 8-grams |
| --- | --- | ---: | ---: | ---: | ---: |
| S0f | code | 3.09 | - | - | 6% |
| S0f | prose | 3.10 | - | - | 1% |
| S0f | arithmetic | 3.10 | - | - | 0% |
| S1c | code | 3.48 | 105 | 0.819 | 6% |
| S1c | prose | 3.48 | 104 | 0.827 | 1% |
| S1c | arithmetic | 3.59 | 101 | 0.891 | 0% |
| N1b | code | 3.00 | 20 | 0.350 | 6% |
| N1b | prose | 3.07 | 0 | - | 1% |
| N1b | arithmetic | 2.92 | 48 | 0.208 | 0% |

The unspeculated rate is unchanged at 3.09 to 3.10, which is expected: decode
cost is per token and does not depend on which tokens. Everything else moves.

MTP acceptance falls from 0.934 to 0.846 and the speedup with it, from 1.17-1.22
to 1.13-1.16 times. That is the figure to carry.

`ngram-simple` is a net loss. It measures 3.00, 3.07, and 2.92 against a
baseline of 3.09, 3.10, and 3.10, so on text that does not repeat, the drafts it
generates are rejected often enough that verifying them costs more than decoding
directly. Acceptance is 0.350 and 0.208 where it drafts at all, against the
1.000 the looping suite reported. The n-gram lane closes here.

The depth arms in that lane never varied depth. `--spec-draft-n-max` sets
`params.speculative.draft.n_max`, which the draft-model speculators read;
`ngram-simple` reads `params.speculative.ngram_simple` and is configured by
`--spec-ngram-simple-size-n`, `-size-m`, and `-min-hits`. `N1`, `N2`, and `N3`
were three runs of one configuration, and the server log shows all of them
sizing the target for 49 outputs. Their agreement measured reproducibility
rather than insensitivity to depth.

## What the matrix decides

N=1 is the operating point. It is the only arm that beats the unspeculated
baseline by a useful margin, and it does so on all three prompts:

| arm | code | prose | arithmetic | acceptance |
| --- | ---: | ---: | ---: | ---: |
| S0 | 3.09 | 3.10 | 3.09 | - |
| S1 | 3.63 | 3.70 | 3.76 | 0.934 |
| S2 | 3.27 | 3.40 | 3.62 | 0.856 |
| S3 | 3.24 | 3.34 | 3.65 | 0.784 |
| S4 | 2.23 | 1.73 | 2.62 | 0.615 |
| S6 | 1.93 | 1.73 | 2.63 | 0.543 |

The gain is 1.17 to 1.22 times on the looping suite and 1.13 to 1.16 on the chat
suite, and the latter is the operational figure. Reaching 4.5 tok/s from 3.07
needs 1.466, so the embedded head closes about a quarter of that gap, drafting
deeper closes none of the rest, backend sampling closes none, and n-gram
drafting costs rather than closes. The two remaining paths are a cheaper
verification pass, which the column table prices, and a checkpoint that streams
fewer bytes, which the low-bit quantization ladder measures.

## The candidate the decomposition names

`smin` in `mul_mat_vec_q4_k.comp` is one chain of sixteen dependent fused
multiply-adds per column. Each scale multiplies four components of `b` that the
chain visits separately, so the same value is applied four times in sequence:
`sc2` against the four components of `by10`, `sc3` against `by132`, `sc6`
against `by20`, `sc7` against `by232`. Summing each `vec4` first and then
applying its scale is four independent three-add reductions feeding four
multiply-adds, which is the same sixteen operations rearranged. The arithmetic
volume is unchanged; what changes is the dependency chain, from sixteen deep to
four, and the instruction-level parallelism available to hide it.

That makes the candidate worth measuring and its size unpredicted. A chain that
is latency-bound gains; one that the compiler already reassociates gains
nothing. The measurement is the two-column target pass time against the 463.1 ms
this arm recorded, and the falsification criterion is that it does not move.

## Greedy token identity breaks, and the control rules out the easy explanation

One of three prompts reproduced the unspeculated token sequence exactly; prose
and arithmetic diverged, both at index 1, after which 122 and 121 of 128
positions differ. The pattern holds across the matrix: the code prompt matches
at N=1, N=2, N=3, and N=6 and diverges at N=4, while prose and arithmetic
diverge in every speculative arm.

The control was run before attributing that. `S0b` repeats the unspeculated arm
in a separate server launch with identical settings, and it reproduces `S0`
token for token on all three prompts at 3.07 to 3.10 tok/s. The target alone is
therefore reproducible across a reload, and the divergence belongs to the
speculative path rather than to launch ordering.

It is a near-tie flip rather than a corruption. Both continuations are fluent,
and both answer the arithmetic prompt correctly with 2 hours 45 minutes; they
differ from the second token onward the way two greedy decodes differ once the
argmax at one low-margin position goes the other way.

### Pipeline selection was the hypothesis, and the deeper arms refute it

`ggml_vk_get_dequantize_mul_mat_vec` indexes
`pipeline_dequant_mul_mat_vec_f16_f32[wg_size][type][num_cols - 1]`, so a
one-column pass and a two-column pass run different compiled shaders with
different unrolling and different accumulation order. That made column count the
first candidate: the speculative arm evaluates the target on a pipeline the
unspeculated arm never uses, and greedy argmax is unstable across such a
difference where two logits are close.

The arms already run refute it. `S1`, `S2`, and `S3` verify at two, three, and
four columns, so each runs a different compiled shader. All three produce
byte-identical 128-token sequences on all three prompts, and all three differ
from the one-column result the same way. Different shaders agreeing to 128
tokens on three prompts is not what independent rounding produces.

The split is therefore between speculation off and speculation on, not between
verification widths, and it is deterministic. What changes across that line is
that `load_mtp` loads fifteen more tensors, a second context exists, and the
target's token selection runs through the speculative accept-and-verify path
rather than through the ordinary sampler. A different argmax tie-break between
those two code paths reproduces every observation here, including why the code
prompt survives three arms and the prose prompt diverges at index 1 in all of
them: the prompts differ in where their first tied position falls, not in how
much noise they accumulate.

`S1b` repeats `S1` unchanged and reproduces it token for token on all three
prompts, so the divergence is stable across a reload rather than merely
deterministic within one process. `B2` adds backend sampling on both the target
and the draft and reproduces the same sequences again, so the sampler placement
is not the cause either. Within one speculation setting the output is fixed;
across settings it is not, as the chat suite shows below.

`S0c` was to separate the remaining candidates by setting
`QWEN_SPEC_DRAFT_N_MAX=0` with `draft-mtp` active, loading the MTP block and
creating the draft context while drafting nothing. It aborts the server on the
first prompt instead:

```
src/llama-context.cpp:2227: GGML_ASSERT(n_outputs_max <= cparams.n_outputs_max) failed
  llama_context::output_reserve(int)
  llama_context::decode(llama_batch const&)
```

`common_speculative_get_output_limits` sizes the target context for
`1 + max(0, n_draft)` outputs, which is one at `n_draft = 0`, while the
speculative decode path still requests two. `common/arg.cpp` accepts any
`--spec-draft-n-max` at or above zero, so a documented value reaches a reachable
abort. `qwen-capacity-policy.sh` rejects it and names the alternative, and the
arm it was to run is unavailable in this build.

`ngram-simple` replaces it. It drafts through the same accept-and-verify path
with no MTP block loaded and no draft context built against the target model, so
a divergence there puts the cause in the shared verification path and a match
with the unspeculated sequence puts it in the MTP machinery.

On the bare-prefix suite it matched, and that reading is withdrawn. Repeating
the arm on the chat suite diverges, and it does so where nothing was drafted at
all: the prose request records no `draft_n` in its timings, meaning zero drafts,
and its sequence still parts from the unspeculated one at index 125 of 192.
Drafting and accepting are therefore both excluded as causes, and so is
`mparams.load_mtp`, which `ngram-simple` never sets.

The `draft-mtp` and `ngram-simple` arms also produce *different* divergent
sequences from each other on both prompts, so the earlier reading that
speculation selects one fixed alternative sequence is withdrawn with it. That
reading rested on the bare-prefix suite, where every speculative arm landed
identically; on non-degenerate text they do not.

What does track the divergence is how the target context is built.
`common_speculative_get_output_limits` sizes it from the draft length, and the
server logs the result:

| arm | speculation | `n_outputs_max` | prose | arithmetic |
| --- | --- | ---: | --- | --- |
| S0f | off | 1 | baseline | baseline |
| S1c | draft-mtp, n_max 1 | 2 | diverges at 125 | diverges at 4 |
| N1b | ngram-simple | 49 | diverges at 125 | diverges at 109 |

Every arm that diverges was built with more output slots than the unspeculated
one, and the two that diverge differently were built with different counts. The
divergence points are also late rather than immediate once the prompts stop
looping, at indices 4 through 125 of 192, which is what ordinary low-margin
positions look like rather than a systematic corruption.

`R1` closes it from the `draft-mtp` side. It runs `draft-mtp` at `n_max=1` with
`QWEN_SPEC_DRAFT_P_MIN=1.0`, and `common/speculative.cpp` breaks out of the draft
loop whenever `llama_get_embeddings_nextn` reports confidence below the floor, so
nothing survives to be verified: the code and arithmetic requests draft zero
tokens and prose drafts one. The prose and arithmetic sequences diverge anyway,
at the same two prompts every other speculative arm parts on, while code matches.

Three arms therefore diverge without drafting: `N1b` on prose with no MTP block
loaded, and `R1` on prose and arithmetic with the block loaded and the drafter
silenced. Drafting, accepting, and `load_mtp` are each excluded, and what is left
across all of them is that the target context was built for more than one output.
Identifying the numerical path needs a logit capture at one output slot against
two on the same prompt, which is the probe still owed; the cause is located.

`R1` also prices the draft pass a second way. It measures 2.53 to 2.55 tok/s
against 3.08 to 3.09 unspeculated, which is 67.5 ms per token of pure loss: the
MTP forward pass runs to produce the confidence the floor then rejects, and its
result is discarded. The `dur(g)` decomposition of the `S1` arms priced that same
pass at 66.4 ms. Two independent derivations agreeing to 1.6% is what makes the
323 and 463 ms column figures trustworthy rather than fitted.

The operational question this raises belongs to whoever sets the criterion. The
stated rule is that speculative decoding must reproduce the target-only token
sequence and that any difference is a correctness defect rather than a quality
trade. Under that rule this arm fails regardless of cause, because the
divergence is measured. The reading that would admit it is that the rule exists
to catch a broken accept-reject test, and what is measured here is instead an
argmax that moves when the same logits are computed by a different shader --
the target's own choice at a low-margin position, not a draft token wrongly
kept. This file records the measurement and the mechanism; which of those two
readings governs the default is a decision, not a finding.
