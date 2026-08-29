# What a 16-bit representation costs on Raven2 Vulkan

RADV on this device reports `shaderFloat16 = true` and `shaderInt8 = true`, and
`vulkaninfo` names no bfloat16 extension at all: a case-insensitive search for
`bfloat` over the full report returns zero lines. F16 is therefore the 16-bit
format the device advertises, and BF16 is a separate question about whether
llama.cpp's scalar BF16 pipelines execute without the extension their coopmat
variants require.

Both publishers ship BF16 as their only 16-bit artifact.
`empero-ai/Qwen3.8-2B-Distill-GGUF` holds BF16, Q4_K_M, Q5_K_M, Q6_K, and Q8_0;
`bartowski/Qwen_Qwen3.5-0.8B-GGUF` holds bf16 and no f16 model file. Measuring
what the device advertises therefore means producing F16 on the appliance, which
is why `remote/build-llama-vulkan.sh` now builds `llama-quantize`. The tool
accepts F16 as type 1 and BF16 as type 32, and the conversion changes the value
type while preserving the layout: the 0.8B census reports 99.17% of bytes as
BF16 before and 99.17% as F16 after, at the same 1,505,783,040 streamed bytes
per token.

## What the file streams, which is what the ratio rests on

The census figure excludes the multi-token-prediction block an ordinary load
skips, so it is the quantity the device moves rather than the file size.

| artifact | streamed bytes per token | GiB per token |
| --- | ---: | ---: |
| Qwen3.8-2B Distill Q4_K_M | 1,263,435,008 | 1.177 |
| Qwen3.8-2B Distill F16 | 3,764,747,520 | 3.506 |
| Qwen3.5-0.8B Q8_0 | 800,881,920 | 0.746 |
| Qwen3.5-0.8B F16 | 1,505,783,040 | 1.402 |

Each checkpoint's own measured rate fixes its achieved streaming. The 2B Q4_K_M
decodes 9.19 tok/s in the seven-checkpoint sweep, which is 10.81 GiB tok/s; the
0.8B Q8_0 decodes 18.53 tok/s, which is 13.82. Those two differ by 27.8%, so a
prediction uses the checkpoint's own point rather than one device constant.

## Registered predictions

The arm is `remote/run-representation-arm.sh`, which runs control, subject,
subject, control through `llama-bench` at `-ngl 99 -t 2 -r 3 -p 512 -n 64 -b 128
-ub 32 -fa on -ctk q8_0 -ctv q4_0 -ot '.*=Vulkan0'`, samples clocks, temperature,
and VRAM and GTT occupancy across every arm, and refuses any arm whose own
diagnostics name a CPU buffer. The ratio is read from the paired means, because the same checkpoint
under identical flags spans up to 30.6% between sweeps in this tree and an
absolute band built across sweeps measures the sweep.

1. The 2B F16 decode ratio against its Q4_K_M control lands within 0.30 to 0.38.
   The streamed-byte ratio is 0.336, so a purely bandwidth-bound representation
   returns the inverse byte ratio. Falsified by a ratio outside that band, which
   would mean the value format costs something other than the bytes it moves.
2. The 2B F16 decodes below 9 tok/s, the admission floor stated for this size
   class. Falsified by 9 tok/s or more.
3. The 0.8B F16 decodes between 8.5 and 11.2 tok/s. Its centre is 9.85 from the
   Q8_0 point, and the band carries the 4% uncontrolled depth-0 spread this tree
   measures plus room for a format-trunk change. This is the arm whose outcome
   the fit leaves open: it straddles the floor rather than clearing or missing
   it. Falsified by a rate outside the band.
4. F16 achieves at least the GiB tok/s its own control achieves, because an F16
   weight is read and used where a quantized weight is read and unpacked. The 2B
   control is Q4_K_M and the 0.8B control is Q8_0, so the comparison is against
   each arm's own control rather than against one quantization family. Falsified
   by F16 achieving less, which would place the cost in the wider memory
   footprint rather than in the arithmetic.
5. Strict Vulkan placement passes for F16 on both checkpoints. Falsified by a
   `CPU buffer size` line in either the one-token pre-check or an arm's own
   diagnostics, which would make that rate a hybrid measurement rather than a
   device one. The per-arm check is what the ratio rests on: a pre-check proves
   placement is reachable rather than taken, and the 0.8B carries 34% of its
   streamed bytes in one tied embedding tensor.

## What this gate decides

A poor F16 result rejects F16 as an interactive serving representation on this
device. It rejects no model identity: a checkpoint whose weights are only
published as safetensors or BF16 can still be converted to a K-quant that
serves, and the conversion strategy is what this outcome selects.

## Results: Qwen3.8-2B Distill, F16 against Q4_K_M

The repository retains the reported tables and derived conclusions but lacks
the per-arm bench CSV, placement log, clock series, and generated representation
summary for both historical sweeps. The values below remain historical reported
observations. The absent raw bundle prevents an independent replay audit of the
arm-level figures. Future runs use `remote/run-representation-arm.sh`, which
requires matching architecture dimensions, tokenizer identity, and tensor
layout before measuring different tensor types; the header check does not prove
numeric tensor-value equality.

| position | role | artifact | prefill tok/s | decode tok/s | mclk | sclk max | temp C | VRAM | GTT |
| ---: | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | control | Q4_K_M | 53.12 | 10.03 | 1067 | 1100 | 76 | 1.73 GB | 0.63 GB |
| 2 | subject | F16 | 54.65 | 4.94 | 1067 | 1100 | 83 | 2.11 GB | 2.75 GB |
| 3 | subject | F16 | 54.88 | 4.99 | 1067 | 1100 | 82 | 2.11 GB | 2.75 GB |
| 4 | control | Q4_K_M | 53.09 | 10.00 | 1067 | 1100 | 77 | 1.73 GB | 0.63 GB |

Paired means: decode 10.02 against 4.96, a ratio of 0.496; prefill 53.11
against 54.77, a ratio of 1.031. Achieved streaming is 11.78 GiB tok/s for the
control and 17.41 for the subject. The two control arms differ by 0.3% and the
two subject arms by 1.0%, against the 30.6% this tree measures between sweeps,
so the ABBA order delivered what it was run for. Every arm selected 1067 MHz
memory and peaked at 1100 MHz shader, so no clock state orders these rows.

### Prediction 1 is falsified, and the deviation is the result

The registered band was 0.30 to 0.38, taken from the streamed-byte ratio of
0.336 on the assumption that a value format costs what it moves. The measured
ratio is 0.496. F16 streams 2.980 times the bytes and costs 2.020 times the
decode, so a third of the byte penalty is returned. Both decode figures here and
in the 0.8B section invert the harness's own paired-mean ratio rather than a
hand-recomputed one: 1 / 0.496 and 1 / 0.778.

Achieved streaming names where it comes from: 17.41 GiB tok/s against 11.78, a
47.8% difference on matched reported checkpoint variants, the same device, and
the same flags. The retained repository lacks the raw arms and a weight-level
identity witness. That
difference is the cost of unpacking a K-quant, measured directly rather than
inferred from the trunk groupings this tree had recorded, and it is larger than
those groupings implied. `evidence/decode-bound-analysis.md` reads a Q4_K trunk
and a Q6_K trunk near 8.1 GB/s against a Q5_K trunk near 5.9 and orders them by
kernel rather than by bit width; F16 is a fourth trunk above all three, and it
reaches that position by having no reconstruction kernel at all.

### Prefill rises where decode falls

F16 prefills 3.1% faster than Q4_K_M while moving three times the bytes. The
control arms differ by 0.06% and the subject arms by 0.4%, so 3.1% sits well
outside the spread of either pair. Prefill submits 512 tokens at once and is
bound by the matrix multiply; decode submits one and is bound by the weight
stream. Removing the dequantization step therefore helps the first directly and
is overwhelmed in the second by the bytes it costs. The two phases move in
opposite directions on the same change, which separates their bounds on this
device without a separate experiment.

### What the memory columns show

The F16 checkpoint holds 2.75 GB in GTT against the control's 0.63 GB, with
VRAM rising only from 1.73 to 2.11 GB. The 3.6 GiB of weights do not fit the
VRAM carveout, so the device reads most of them across the host memory
interface. Die temperature runs 6 C higher on the F16 arms, at 82 to 83 C.

### The other four predictions

2 holds: 4.96 tok/s is below the 9 tok/s admission floor, by a factor of 1.8.
4 holds by a wide margin: 17.41 against 11.78 GiB tok/s.
5 holds: every arm placed all weights on Vulkan0, checked per arm by the owner
of each nonzero model buffer line rather than by the presence of the word CPU.
3 is answered by the 0.8B arm below, and falsified there.

### What this decides

F16 is rejected as a serving representation for the 2B on the stated floor.
It is rejected at 0.496 rather than at the 0.336 the byte count alone predicts,
which changes what the rest of the ladder is worth measuring: a rung's decode
cost is its byte count divided by the bandwidth its kernel achieves, and those
two terms move in opposite directions as bit width rises. Q8_0 at 1.934 GiB
sits between the two measured points on both terms and is the rung this result
makes worth a measurement rather than an extrapolation.


## Results: Qwen3.5-0.8B, F16 against Q8_0

| position | role | artifact | prefill tok/s | decode tok/s | mclk | temp C | VRAM | GTT |
| ---: | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | control | Q8_0 | 138.99 | 20.19 | 1067 | 73 | 1.27 GB | 0.63 GB |
| 2 | subject | F16 | 147.71 | 15.67 | 1067 | 74 | 1.97 GB | 0.63 GB |
| 3 | subject | F16 | 147.53 | 15.68 | 1067 | 73 | 1.97 GB | 0.63 GB |
| 4 | control | Q8_0 | 138.80 | 20.11 | 1067 | 72 | 1.28 GB | 0.65 GB |

Paired means: decode 20.15 against 15.68, a ratio of 0.778; prefill 138.90
against 147.62, a ratio of 1.063. Achieved streaming is 15.03 GiB tok/s for the
control and 21.98 for the subject. The subject arms differ by 0.06% and the
control arms by 0.4%.

### Prediction 3 is falsified upward

The registered band was 8.5 to 11.2 tok/s, centred on 9.85. The measured rate is
15.68, which clears the 9 tok/s admission floor by 74% and clears the 12 tok/s
preference as well.

The band was built by holding the control's achieved streaming constant and
dividing by the subject's bytes. The 2B arm had already shown that F16 does not
hold it constant, and the stated reason for expecting a smaller gain here was
that Q8_0 unpacking is cheaper than Q4_K unpacking. That reasoning is refuted:

| checkpoint | control | control achieved | F16 achieved | gain |
| --- | --- | ---: | ---: | ---: |
| Qwen3.8-2B Distill | Q4_K_M | 11.78 | 17.41 | 47.8% |
| Qwen3.5-0.8B | Q8_0 | 15.03 | 21.98 | 46.2% |

F16 gains the same 46 to 48% over a four-bit K-quant and over an eight-bit
block quant. A gain that tracked the reconstruction each format needs would
differ between those two, so what F16 removes is not a cost proportional to the
control's complexity. `ggml-vulkan.cpp` builds dedicated F16 matmul and
matrix-vector pipelines beside the dequantize-then-multiply path every quantized
type takes, and the device reports `shaderFloat16 = true`, which is the
candidate mechanism. It is unisolated here and recorded as an effect: this arm
varies the value format and reads the rate, and a kernel attribution needs an
arm that varies the pipeline at a fixed format.

### The gain survives a GTT spill

The 2B F16 holds 2.75 GB in GTT against its control's 0.63 GB, so most of its
weights are read across the host memory interface; the 0.8B F16 fits VRAM at
1.97 GB and spills nothing. The two carry the same 46 to 48% gain regardless, so
the advantage is a property of the format's kernel rather than of where the
weights sit.

### What this decides

The 0.8B admits F16 as a serving representation. It is the highest-precision
artifact the publisher offers, it decodes 15.68 tok/s against a 9 tok/s floor
and a 12 tok/s preference, and it places every weight on Vulkan0. The 2B does
not, at 4.96 tok/s.

Between them the ladder is no longer a byte count. A rung's decode rate is its
byte count divided by the bandwidth its kernel achieves, and those two terms
move in opposite directions as precision rises. The 0.8B Q8_0 rung is 46% slower
per byte than the F16 rung above it, which is why 1.88 times the bytes cost only
1.29 times the decode. The rungs between Q4_K_M and F16 on both checkpoints are
now worth measuring rather than interpolating, since neither endpoint predicts
them.

## What F16 buys in quality on the 0.8B: nothing this suite resolves

Both reported representations of the matched checkpoint were graded in one
sweep, thinking off, a
1024-token budget, the 55 text rows the `NN/55` scale names.

| arm | total | arithmetic | code | format | long_context | screen | termination | word_problem |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Q8_0 | 33/55 | 5/10 | 7/10 | 6/10 | 5/5 | 4/5 | 5/5 | 1/10 |
| F16 | 32/55 | 5/10 | 5/10 | 6/10 | 5/5 | 4/5 | 5/5 | 2/10 |

The Q8_0 arm reproduces the 33 of 55 already recorded for it from an earlier and
separate sweep, which is what makes the pair readable: the comparator landed on
its own recorded score before the subject was read against it. Both arms
completed every row, truncated none, and emitted no empty answer.

One row separates them, and it separates them in both directions: F16 loses two
code rows and gains one word_problem row while five categories are identical.
This tree's own rule is that a one-row or two-row difference reports position in
a request sequence rather than capability, and a difference that changes sign
between categories is what that looks like. The result is therefore no
measurable quality difference rather than a measured tie, and the falsifier for
any future claim of one is a margin declared in advance with two one-sided
bounds inside it.

That is the expected direction. Q8_0 reconstruction error on these weights is
small enough that a 55-row graded suite has no resolution to see it, and the
measurement says so rather than inventing a gap.

### The consequence for serving

Q8_0 dominates F16 on everything this sweep measures. It decodes 18.53 against
15.68, streams 0.746 GiB per token against 1.402, and grades one row higher
inside the noise. Nothing here recommends paying 88% more bytes per token.

What the sweep does not measure is the use the precision was wanted for. Its
categories are arithmetic, code, format, long context, screen, termination, and
word problems; none of them grades prose. A creative comparison needs
continuation fidelity, character voice, scene coherence, stylistic diversity,
and freedom from assistant boilerplate, judged blind and pairwise, and no such
arm has run. The F16 row therefore stays `candidate` with its graded total
recorded and the question it was admitted for still open.
