# The universal-candidate ladder: census first, predictions registered, then device time

Four checkpoints entered the tree to answer whether one model under 4B can serve
arithmetic, chat, coding, vision, and tool calling on this appliance. Each is
pinned by repository, revision, byte count, and SHA-256, and all seven artifacts
verified on fetch.

| checkpoint | file | bytes | projector |
| --- | --- | ---: | --- |
| Qwen3.5-0.8B Q8_0 | `Qwen3.5-0.8B-Q8_0.gguf` | 833,592,096 | text-only |
| Qwen3.5-2B Q4_K_M | `Qwen3.5-2B-Q4_K_M.gguf` | 1,396,198,496 | `mmproj-Qwen3.5-2B-f16.gguf` |
| LFM2.5-VL-1.6B Q4_K_M | `LFM2.5-VL-1.6B-Q4_K_M.gguf` | 730,896,256 | `mmproj-LFM2.5-VL-1.6b-Q8_0.gguf` |
| Ministral-3-3B Q4_K_M | `Ministral-3-3B-Instruct-Q4_K_M.gguf` | 2,146,498,528 | `mmproj-Ministral-3-3B-Instruct-f16.gguf` |

Each projector lands in its checkpoint's own directory, which is where
`remote/select-projector.sh` searches, and each directory holds exactly one
`mmproj*.gguf`, so the sole-candidate branch resolves it.

## The build loads all four, read from the file rather than assumed

`remote/gguf-tensor-census.py` reads the header and index through the first
tens of MiB, so architecture and layout answer the admission question before any
device time.

| checkpoint | architecture | blocks | attention | streamed bytes/token |
| --- | --- | ---: | --- | ---: |
| Qwen3.5-0.8B | `qwen35` | 25 | 3:1 hybrid, 8 heads over 2 KV heads, head dim 256 | 800,881,920 |
| Qwen3.5-2B | `qwen35` | 25 | 3:1 hybrid, 8 heads over 2 KV heads, head dim 256 | 1,320,574,208 |
| LFM2.5-VL-1.6B | `lfm2` | 16 | short convolution, `shortconv.l_cache` 3, 32 heads | 728,509,440 |
| Ministral-3-3B | `mistral3` | 26 | dense, 32 heads over 8 KV heads, head dim 128 | 2,138,615,808 |

`qwen35`, `lfm2`, and `mistral3` are all present at the pinned build `f280b26`,
so each loads unchanged. Both Qwen rows declare `nextn_predict_layers` 1 inside
their 25 blocks, so 24 transformer layers run and the multi-token-prediction
block is skipped unless `--spec-type draft-mtp` loads it, exactly as the 2B and
4B distills behave. The two Qwen rows carry the same chat template,
`273d8e0e...` at 7,755 bytes.

Ministral declares `rope.scaling.type yarn` with factor 16 over an original
context length of 16384, so its 262,144 declared context is a scaled window
rather than a trained one, and any depth claim on it is a separate measurement.
Its vocabulary is 131,072 against LFM2's 65,536. All four tie their embeddings,
so each reads the vocabulary once for the lookup and once for the projection.

## KV cost per token of context, derived from the header

`q8_0` K and `q4_0` V are 34 and 18 bytes per 32 elements, so the per-token cost
is `kv_layers x kv_heads x head_dim x 52/32`. Two measured rows fix this formula
against served logs elsewhere in this tree, which makes these derivations rather
than estimates:

| checkpoint | KV layers | bytes/token | at 24576 |
| --- | ---: | ---: | ---: |
| Qwen3.5-0.8B | 6 of 24 | 4,992 | 117.0 MiB |
| Qwen3.5-2B | 6 of 24 | 4,992 | 117.0 MiB |
| Qwen3.8-4B Distill, for comparison | 8 of 32 | 13,312 | 312.0 MiB |
| **Ministral-3-3B** | **26 of 26** | **43,264** | **1014.0 MiB** |
| LFM2.5-VL-1.6B | underived | underived | underived |

**Ministral is the Nanbeige shape again.** Dense full attention on every layer
costs 8.67 times the two Qwen hybrids per token of context and 3.25 times the
deployed 4B, so its context tax grows where an agent workload lives even if its
weight stream is smaller than the 4B's. Nanbeige reached that position through a
loop and Ministral reaches it through density; the consequence for this machine
is the same and it is the reason parameter count misranks here.

LFM2 publishes no `attention.head_count_kv` and carries `shortconv.l_cache`, so
its cache layout is a short-convolution state rather than a per-layer KV cache
of the shape this formula covers. It is read from a served log rather than
derived, and the row stays `underived` until then.

## Registered before the sweep runs

Achieved streaming rate is `decode tok/s x streamed bytes per token`. The
measured band on this machine is a Q4_K or Q6_K trunk reaching about 8.1 to 10.4
GB/s, rising as the checkpoint shrinks -- the 2B distill reaches 10.41 GB/s at
1.263 GB per token where the 4B reaches 8.11 at 2.698 -- while a Q5_K trunk
reaches 5.9 and a Q2_K/Q3_K trunk 5.5.

| checkpoint | predicted GB/s | predicted decode tok/s | falsifier |
| --- | --- | ---: | --- |
| Qwen3.5-2B Q4_K_M | 10.0 to 10.8 | 7.6 to 8.2 | outside 6.5 to 9.5 |
| Qwen3.5-0.8B Q8_0 | 10.4 to 12.5 | 13.0 to 15.6 | below 9.0 tok/s |
| LFM2.5-VL-1.6B Q4_K_M | 8.0 to 12.0 | 11.0 to 16.5 | outside 8.0 to 20.0 |
| Ministral-3-3B Q4_K_M | 8.1 to 9.0 | 3.8 to 4.2 | outside 3.2 to 5.0 |

The Qwen3.5-2B band is the narrowest because it is the closest analogue in the
tree: same architecture family, same 3:1 hybrid, same head shape, and a byte
count 4.5% above the 2B distill's. A rate outside it says the distill's
advantage is not architectural.

The 0.8B carries the widest upside because `Q8_0` is a bulk format this machine
has never measured at trunk scale. It reconstructs a weight with one scale
multiply against Q4_K's hierarchical super-block scales, so the unpacking-cost
account predicts it joins the fast group or beats it. **The falsifier is
one-sided at 9.0 tok/s**: below that, `Q8_0` fails to reach even the Q4_K band
and the two observed streaming groups need a third member.

LFM2 carries the widest band in both directions because no `lfm2` operator has
run on this device. A short convolution is a different kernel from attention and
its Vulkan implementation is unmeasured here.

Ministral's band assumes it joins the Q4_K trunk group at its byte count. Its
weight stream is 20.7% below the 4B distill's, so the prediction is that it
decodes faster than the deployed default while costing 3.25 times as much per
token of context -- the two halves point opposite ways and the sweep measures
only the first.

## Protocol

One sweep holds all seven servable checkpoints, because the same checkpoint
under identical flags spans up to 30.6% on this machine across sweeps and a
comparison is only readable within one. `remote/run-bandwidth-ladder.sh` runs a
forward pass over the model order and a reverse pass over it, so every
checkpoint takes an early slot and a late one, at `nice 19` with idle I/O and
the priority read back from `/proc` rather than restated. `QWEN_BENCH_PREFILL`
adds a `pp512` row to each arm so both halves come from one queue position.

## Results

Fourteen arms, seven checkpoints, forward and reverse passes, `nice 19` read back
from `/proc` on every arm, `mclk` at 933 throughout, die temperature 76 to 89 C,
one-minute load average 3.5 to 4.6. Paired means of the two passes:

| checkpoint | streamed/token | decode tok/s | prefill tok/s | achieved GB/s | decode against the 4B distill |
| --- | ---: | ---: | ---: | ---: | ---: |
| Qwen3.5-0.8B Q8_0 | 0.801 GB | **18.53** | **161.69** | **14.84** | 5.55x |
| LFM2.5-VL-1.6B Q4_K_M | 0.729 GB | 15.87 | 93.15 | 11.56 | 4.75x |
| Qwen3.5-2B Q4_K_M | 1.321 GB | 9.43 | 60.72 | 12.45 | 2.82x |
| Qwen3.8-2B Distill Q4_K_M | 1.263 GB | 9.19 | 63.85 | 11.61 | 2.75x |
| Ministral-3-3B Q4_K_M | 2.139 GB | 4.66 | 31.14 | 9.96 | 1.40x |
| Qwen3.8-4B Distill Q4_K_M | 2.698 GB | 3.34 | 22.40 | 9.01 | 1.00x |
| Qwen3.5-4B base Q4_K_M | 2.730 GB | 3.11 | 21.88 | 8.48 | 0.93x |

Forward against reverse spans 0.3% on both 4B rows, 1.5% on Ministral, 4.3 to
4.7% on LFM2 and Qwen3.5-2B, and 7.2 to 7.5% on the 2B distill and the 0.8B.
This was a quiet sweep by the standard of the 30.6% this tree has measured under
desktop load.

## The registered bands read low, and the reason is the bands rather than the models

Three of the four predictions fell below the measurement and the fourth sat at
its top. No falsifier was met, so nothing here is refuted, and the pattern is
the finding.

| checkpoint | predicted decode | measured | verdict |
| --- | --- | ---: | --- |
| Qwen3.5-2B | 7.6 to 8.2 | 9.43 | above the band, inside the falsifier |
| Qwen3.5-0.8B | 13.0 to 15.6 | 18.53 | 19% above the band; the one-sided falsifier at 9.0 stands unmet |
| LFM2.5-VL-1.6B | 11.0 to 16.5 | 15.87 | inside |
| Ministral-3-3B | 3.8 to 4.2 | 4.66 | above the band, inside the falsifier |

**The bands were built across sweeps and measured the sweep.** Each was derived
from the four-block means in `evidence/decode-bound-analysis.md`, where the 2B
distill reaches 10.41 GB/s and the 4B reaches 8.11. In this sweep the same two
checkpoints reach 11.61 and 9.01, which is 11.5% and 11.1% higher. Applying that
offset to each prediction moves Qwen3.5-2B's band to 8.5 to 9.1, the 0.8B's to
14.5 to 17.4, and Ministral's to 4.2 to 4.7, and the measurements then land
inside or adjacent to all three.

The consequence is a rule rather than a correction: **a prediction band for this
machine states a ratio against a checkpoint measured in the same sweep, not an
absolute rate.** An absolute band carries the sweep-level offset as an
uncontrolled term, and here that term was larger than every effect the
predictions were trying to resolve.

## Q8_0 is a third streaming group, above the Q4_K trunk

`evidence/decode-bound-analysis.md` records two groups among the 4B quants: a
Q4_K trunk and a Q6_K trunk both near 8.1 GB/s, a Q5_K trunk at 5.9, and a
Q2_K/Q3_K trunk at 5.5. The 0.8B Q8_0 reaches 14.84 GB/s, the highest rate this
device has produced, and it does so at 62.6% of the 2B distill's byte count
rather than at a comparable one.

The two terms are not separable from one arm. Achieved rate rises as the
checkpoint shrinks across this whole sweep, so part of the 0.8B's lead is size
and part is format. Separating them needs a Q8_0 and a Q4_K_M of the same
checkpoint in one sweep.

`evidence/model-admission/runtime-class-throughput.md` supplies that arm from
this checkpoint rather than from `Qwen3.5-2B`, because `bartowski` publishes a
Q4_K_M rung of Qwen3.5-0.8B and the two formats then share a trunk, a block
count, and a chat template. They decode at 15.31 and 15.17 tok/s at 0.801 and
0.547 GB per token, so the Q8_0 streams 46.4% more bytes at a decode rate
0.9% apart, inside the within-arm deviations, which leaves the direction
unresolved and refutes the 23 to 48% Q4_K_M advantage both accounts predicted.

That sweep reads the Q8_0 at 12.27 GB/s where this one reads 14.84, and the
difference is the sweep rather than the checkpoint. The same re-run measured the
4B distill 10.6% below this sweep and the 2B distill 16.4% below it, which is
the direction a size-dependent term would take and, at two sweeps, is not
separable from their own scatter, so the single scalar offset proposed below
stands unconfirmed. Both figures stand as within-sweep measurements and neither
transfers.

## Size orders achieved rate, and one row breaks it

| streamed/token | achieved GB/s |
| ---: | ---: |
| 0.729 GB (LFM2) | 11.56 |
| 0.801 GB (0.8B) | 14.84 |
| 1.263 GB (2B distill) | 11.61 |
| 1.321 GB (Qwen3.5-2B) | 12.45 |
| 2.139 GB (Ministral) | 9.96 |
| 2.698 GB (4B distill) | 9.01 |
| 2.730 GB (4B base) | 8.48 |

Descending byte count raises achieved rate across the 4B, 3B, and 2B classes,
which rules out a fixed device bandwidth ceiling and points at a per-layer or
per-dispatch cost that a smaller trunk amortizes better. **LFM2 breaks the
ordering**: it is the smallest weight stream in the sweep and achieves less than
both 2B-class checkpoints. Its 16 short-convolution blocks are a different
operator set from the Qwen hybrid's, and this is the first `lfm2` measurement on
this device, so the reading is that the operator mix rather than the byte count
sets its rate.

## Qwen3.5-2B against the deployed 2B distill: unresolved

These two are the closest pair in the tree -- same architecture, same 3:1
hybrid, same head shape, same KV cost per token of context, byte counts 4.5%
apart. Within this sweep:

```text
decode   Qwen3.5-2B 9.43   Qwen3.8-2B Distill 9.19    2.6% apart
prefill  Qwen3.5-2B 60.72  Qwen3.8-2B Distill 63.85   5.2% apart, the other way
```

Forward against reverse spans 4.7% and 7.2% for these same two rows, so both
differences sit inside the spread of a single checkpoint measured twice.
**Neither leads on rate and the pair is unresolved.** What separates them is
what the distillation did to the answers, which is a quality measurement and has
not run.

## Ministral decodes 39.5% above the deployed default and costs 3.25x per token of depth

4.66 against 3.34 tok/s, paired within the sweep, and 31.14 against 22.40 on
prefill. Its weight stream is 20.7% smaller, which is where that goes.

Against it, dense full attention on all 26 layers costs 43,264 bytes of cache
per token of context against the 4B distill's 13,312, so a Ministral context is
3.25 times the traffic and 3.25 times the footprint at the same depth. The
crossover depth where its faster weight stream is cancelled by its heavier cache
read is derivable from these two numbers and is a served measurement rather than
an arithmetic claim, because the shallow rate here is measured against a
near-empty cache.

That is the same shape Nanbeige4.2-3B presented and it arrives by a different
route: Nanbeige pays it through a loop that gives every one of 44 slots a KV
index, Ministral through density. Neither is disqualifying on this evidence and
both make depth the axis that decides.

## Served admission: three of four answer, one aborts

A bench arm proves a checkpoint decodes. It does not prove the guarded server
path loads it, so each candidate took one request through the router at its
registry tuple -- 8192 context, `q8_0`/`q4_0`, Flash Attention on, batch 128,
ubatch 32 -- and the projector `remote/select-projector.sh` resolved from the
checkpoint's own directory.

| checkpoint | projector resolved | loads | answers `17 x 24` |
| --- | --- | --- | --- |
| Qwen3.5-0.8B Q8_0 | text-only | yes | **48, wrong** |
| Qwen3.5-2B Q4_K_M | `mmproj-Qwen3.5-2B-f16.gguf` | yes | 408, correct |
| LFM2.5-VL-1.6B Q4_K_M | `mmproj-LFM2.5-VL-1.6b-Q8_0.gguf` | yes | 408, correct |
| Ministral-3-3B Q4_K_M | `mmproj-Ministral-3-3B-Instruct-f16.gguf` | **no** | n/a |

**Ministral aborts as a router child and runs everywhere else.** Four attempts,
four aborts at `ggml-impl.h:318` during warmup, against zero failures from
`llama-cli` and from a standalone `llama-server` given the child's argument list
and environment verbatim. It is quarantined at model scope with the isolation
table in `evidence/quarantine/ministral3-3b.md`. The device is untouched by the
abort and the router serves the next request normally.

**The two Qwen3.5 rows answer nothing at 48 tokens with thinking left on.** Both
returned an empty string and stopped at the cap, which is the failure this tree
already recorded for the Qwen3.5-4B base at 2048 tokens: the reasoning trace
consumes the budget and no answer follows. Setting
`chat_template_kwargs.enable_thinking` to false and raising the cap to 128
produced an answer from both immediately. The gate on these checkpoints is the
token budget against the trace length, not the arithmetic.

**Qwen3.5-0.8B answers 48 for 17 x 24 with thinking disabled.** That is the
elementary-arithmetic failure the roster already separates `fast-text` from
`balanced-text` over, and it appears here at a smaller size and a higher rate.
The 2B answered correctly on the same prompt under the same settings. One prompt
grades nothing; it is recorded because it is the first quality signal from this
ladder and it points the graded suite at arithmetic first.

LFM2.5-VL-1.6B answered correctly at 48 tokens with no template argument, since
it emits no reasoning trace.

## Standing after this pass

| checkpoint | tier | why |
| --- | --- | --- |
| Qwen3.5-0.8B Q8_0 | candidate | loads, serves, fastest decode measured on this device; arithmetic unqualified and one prompt already wrong |
| Qwen3.5-2B Q4_K_M | candidate | loads, serves, indistinguishable from the deployed 2B distill on rate; quality unqualified |
| LFM2.5-VL-1.6B Q4_K_M | candidate | loads, serves, 4.75x the 4B distill's decode; quality and vision unqualified |
| Ministral-3-3B Q4_K_M | quarantine | aborts as a router child, four of four |

None is promoted. `candidate` claims basic admission and no device failure under
the admitted tuple, which is exactly what three of them now hold. Promotion
needs the graded suite, and for the two vision rows it needs an image through
the projector, neither of which has run.
