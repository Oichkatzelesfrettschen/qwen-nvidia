# Runtime-class throughput: three unmeasured classes against three in-sweep anchors

`evidence/model-admission/static-admission.md` collapses fourteen load-admitted
candidates into four runtime classes by architecture, embedding width,
feed-forward width, and head counts. One class holds a measured reference at the
format its members publish and three do not. This sweep measures those three,
each beside anchors measured in the same queue, because the same checkpoint
under identical flags spans up to 30.6% on this machine between sweeps and a
comparison is only readable within one.

## Subjects and anchors

Streamed bytes come from `remote/gguf-tensor-census.py`, which is what
`run-bandwidth-ladder.sh` reads rather than the file size, since an ordinary
load skips the multi-token-prediction block.

| role | checkpoint | class | streamed bytes/token |
| --- | --- | --- | ---: |
| anchor | Qwen3.8-4B Distill Q4_K_M | qwen35 / 3072 / 9728 | 2,698,000,000 |
| anchor | Qwen3.8-2B Distill Q4_K_M | qwen35 / 2048 / 6144 / 8 / 2 | 1,263,435,008 |
| anchor | Qwen3.5-0.8B Q8_0 | qwen35 / 1024 / 3584 / 8 / 2 | 800,881,920 |
| subject | Qwen3.5-0.8B Q4_K_M (bartowski) | qwen35 / 1024 / 3584 / 8 / 2 | 546,905,344 |
| subject | Qwen3-Zero-Coder-Reasoning-0.8B Q4_K_M | qwen3 / 1024 / 3072 / 16 / 8 | 477,341,696 |
| subject | Qwen2-VL-2B-Instruct-Platinum Q4_K_M | qwen2vl / 1536 / 8960 / 12 / 2 | 980,097,536 |

The class of eight rows at 2048/6144 already holds its reference and contributes
one anchor rather than a second subject: those eight span 0.83% in streamed
bytes, which is below the roughly 4% of uncontrolled spread this machine carries
on a repeated depth-0 rate, so a second arm inside that class measures queue
position.

Three anchors rather than one, because the sweep-level offset is the term that
made every absolute band in the retained seven-checkpoint sweep read low. The 4B
distill is the low-variance member of that sweep at 0.3% forward against
reverse, where the 2B distill and the 0.8B Q8_0 spanned 7.2 and 7.5%, so the
offset estimate rests on the quietest row rather than on the two noisiest.

The 0.8B Q8_0 anchor and the 0.8B Q4_K_M subject are the same checkpoint in two
value formats. `universal-candidate-ladder.md` names that pair as the arm its
own Q8_0 finding needs: "Separating them needs a Q8_0 and a Q4_K_M of the same
checkpoint in one sweep." The bartowski conversion supplies it, so this sweep
closes a registered open question as a by-product of the class work.

## Registered before the sweep runs

A prediction band on this machine states a ratio against a checkpoint measured
in the same sweep. Every band below is a decode ratio `R` against the Qwen3.8-2B
Distill arm of this sweep, and the achieved-rate ratio it implies follows from
`R = (achieved_subject / achieved_2B) x (streamed_2B / streamed_subject)`.

### The 0.8B format pair discriminates size against format

Two accounts predict opposite outcomes and the arm separates them.

The size account reads the retained sweep's ordering, where achieved GB/s rises
as the trunk shrinks across the 4B, 3B, and 2B classes. At 0.547 GB against the
Q8_0's 0.801 GB, it predicts the Q4_K_M exceeds the Q8_0's achieved rate, which
was 1.278 times the 2B distill's in the retained sweep.

The format account reads the unpacking cost. Q4_K decodes hierarchical
super-block scales where Q8_0 applies one scale multiply, and the retained
sweep's Q4_K trunk reached 11.6 to 12.5 GB/s against Q8_0's 14.84. It predicts
the Q4_K_M lands in the Q4_K trunk band, at roughly the 2B distill's achieved
rate with a small rise for the smaller trunk.

```text
size account:      R above 2.95   (achieved ratio above 1.28)
format account:    R 2.31 to 2.54 (achieved ratio 1.00 to 1.10)
discriminator:     R below 2.70 supports format
                   R above 2.95 supports size
                   between 2.70 and 2.95 resolves neither
falsifier:         R outside 2.0 to 3.6
```

### Deep and narrow tests the per-dispatch account

Qwen3-Zero-Coder-Reasoning-0.8B runs 42 blocks at 1024 embedding width against
the 0.8B class's 24, which is 1.75 times the dispatch count at 87% of the bytes.
The retained sweep inferred a per-layer or per-dispatch cost from LFM2 breaking
the size ordering, and this row tests that account inside the Qwen family at one
value format.

```text
prediction:  achieved_zero-coder is below achieved_bartowski, both in this sweep
             R 2.0 to 2.6 (achieved ratio 0.76 to 0.98 against the 2B distill)
falsifier:   achieved_zero-coder at or above achieved_bartowski, which refutes
             the per-dispatch account at this scale and returns the LFM2
             anomaly to the operator-mix explanation alone
             R outside 1.6 to 3.1
```

### The first qwen2vl arm on this device carries the widest band

Qwen2-VL-2B-Instruct-Platinum runs 28 blocks of full attention at 12 heads over
2 KV heads, against the Qwen3.5 hybrid's 3:1 pattern, and no `qwen2vl` operator
has run here.

```text
prediction:  R 1.22 to 1.48 (achieved ratio 0.95 to 1.15)
falsifier:   R outside 1.0 to 1.8
```

### The anchor pair controls the sweep itself

The retained seven-checkpoint sweep put the 4B distill at 0.3634 of the 2B
distill's decode. If this sweep reproduces that ratio within 5%, its ordering
carries no term the retained sweep lacked and the subject ratios read directly.

```text
prediction:  4B/2B decode ratio 0.345 to 0.382
falsifier:   outside that band, which makes every subject ratio conditional on a
             checkpoint-ordering term this sweep introduced
```

## Acceptance criterion, stated before the numbers

The retained sweep ran at one-minute load average 3.5 to 4.6 and produced
forward-against-reverse spans of 0.3% to 7.5%, which it called quiet. A
checkpoint whose two passes span more than 8% here reports its position in the
queue rather than the checkpoint, and that arm is re-run rather than read.

## What this sweep leaves unmeasured

The `qwen2vl` arm runs under `llama-bench`, which loads the language model
alone, so the figure is text-trunk throughput and carries nothing about image
encoding.

The two 9B rows admitted statically -- `qwen35-9b-defiant-fable` at IQ2_M and
`qwen38-9b-distill` at Q4_K_M -- are absent from the appliance and from the
one-token load sweep. Each needs a fetch and a strict Vulkan load before a
throughput arm, and the IQ2_M would be this tree's first IQ-family measurement,
which is a finding of its own rather than a rider on this one.

A rate admits a row to the throughput stage and promotes nothing.
`remote/models.tsv` carries twenty-two fields per row, including a validated
filled depth, a submission geometry, a tier, and the two tool columns, and a
promotion also needs a `download-*.sh` carrying the publisher digest.
