# What the served KV cache policy costs, and what it buys

`remote/qwen-capacity-policy.sh` serves every checkpoint with `--flash-attn on
--cache-type-k q8_0 --cache-type-v q4_0` while `llama-bench` defaults to an f16
cache with flash attention resolved to `auto`. Comparing a rate from one against
a rate from the other changes four things at once, and
`evidence/model-admission/nanbeige42-3b-admission.md` did exactly that: it
recorded 3.31 tok/s from llama-bench against 3.07 tok/s served and assigned the
7.2% difference to the cache policy. That assignment is the claim this file
tests.

`remote/run-kv-cache-factorial.sh` crosses cache type against flash attention
inside llama-bench alone, so the harness is held fixed and the two mechanisms
separate. `QWEN_CACHE_TYPE_K`, `QWEN_CACHE_TYPE_V`, and `QWEN_FLASH_ATTN` now
override the registry row through `qwen-capacity-policy.sh`, so the served path
runs the same cells and the residual between the two harnesses is measured
rather than absorbed.

## Registered before the run

The five cells are `q8_0/q4_0` with flash attention on and off, `q8_0/f16` with
it off, and `f16/f16` with it on and off. `q8_0/q4_0` with flash attention off
is expected to be refused, which makes the discriminating pairs `f16/f16 fa on`
against `q8_0/q4_0 fa on` for cache traffic with the kernel held, and `f16/f16
fa on` against `f16/f16 fa off` for the kernel with traffic held. `q8_0/f16 fa
off` recovers a quantized-K point outside the flash-attention path.

1. **The cache policy causes the 7.2% gap.** At depth 0 the `f16/f16` cell
   exceeds the `q8_0/q4_0` cell by about 7%. The falsifier is the two agreeing
   within their spread, which assigns the gap to the harness instead and makes
   the Nanbeige file's sentence wrong in the direction it was already softened.

2. **Quantization wins at depth.** At 16384 the `q8_0/q4_0` cell exceeds the
   `f16/f16` cell, because a cache holding 2.4 times fewer bytes is 2.4 times
   less traffic per token and depth is where cache traffic dominates. The
   falsifier is f16 matching or beating it, which would leave the served policy
   justified by capacity alone.

3. **f16 at 16384 completes on the 4B.** It measured 2.69 tok/s there during the
   Nanbeige ladder. A compute-ring timeout at that depth is a result supporting
   the quantized policy rather than a failed run, and the harness counts amdgpu
   ring-reset lines around every cell so a recovered wedge is attributed to the
   arm that caused it.

Depth 0 repeats three times; each deeper rung repeats once, because a rung
reprocesses its whole prefix before every repetition and 16384 tokens of prefill
cost about 12 minutes each. A single-repetition rate carries no spread, and the
summary records the repetition count beside the rate.

## The 16384 cell wedged the ring under the served cache triple

`d16384-kq8_0-vq4_0-faon` aborted with `vk::Queue::submit: ErrorDeviceLost`
after RADV reported `The CS has been cancelled because the context is lost`.
The kernel reset `comp_1.3.0` and the device recovered; the following cells ran.
Unlike the Nanbeige wedge, the driver produced a coredump, and it names more
than a timeout:

```
Ring timed out details
IP Type: 1 Ring Name: comp_1.3.0

[gfxhub] Page fault observed
Faulty page starting at address: 0x0000000000000000
Protection fault status register: 0x0
```

`evidence/model-admission/amdgpu-coredump-d16384-served-cache.txt` retains the
fault report and the graphics IP register dump. The gfxhub page fault is
reported with a zero faulty address and a zero protection-fault status, and
`mmGDS_PROTECTION_FAULT` and `mmGDS_VM_PROTECTION_FAULT` read 0x0fc00007 and
0x0fc00113. Whether the zero address is a null access or an uncaptured field is
not decidable from this dump, so the recorded fact is that the driver reported a
page fault rather than a duration alone.

**The depth and the submission size are confounded, and this is the decisive
open question.** llama-bench prefills a depth rung at its own batch defaults
while `qwen-capacity-policy.sh` serves with `--batch-size 128 --ubatch-size 32`,
which is two orders of magnitude smaller per submission and is the reason those
settings exist. Both wedges this tree has recorded were found under llama-bench
at its defaults, at 16384 tokens, and neither has been separated from the other.
`remote/probe-depth-wedge.sh` repeats the wedge at the harness defaults and then
at the served batch settings with everything else held. A completion at the
served batch attributes the wedge to submission size and leaves the served depth
ceiling standing. A wedge at the served batch attributes it to the depth and
puts the 24576 interactive default for this checkpoint in question, which is the
outcome that changes a shipped default rather than a measurement method.

Until that runs, the registry keeps its ceilings: the wedge is established under
llama-bench and unestablished under the served path, and lowering a ceiling on a
harness artifact would be the same error as raising one on scaled arithmetic.

## Results

Rates re-derived from the retained per-cell tables. Depth 0 repeats three times
and carries a spread; each deeper rung repeats once and carries none.

| depth | K | V | flash attn | decode tok/s | retained from its own d0 |
| ---: | --- | --- | --- | ---: | ---: |
| 0 | q8_0 | q4_0 | on | 3.03 +/- 0.04 | 1.000 |
| 0 | q8_0 | q4_0 | off | refused | - |
| 0 | q8_0 | f16 | off | 2.48 +/- 0.06 | 1.000 |
| 0 | f16 | f16 | on | 3.09 +/- 0.00 | 1.000 |
| 0 | f16 | f16 | off | 3.08 +/- 0.00 | 1.000 |
| 4096 | q8_0 | q4_0 | on | 2.81 | 0.927 |
| 4096 | q8_0 | f16 | off | 0.88 | 0.355 |
| 4096 | f16 | f16 | on | 2.94 | 0.951 |
| 4096 | f16 | f16 | off | 2.99 | 0.971 |
| 16384 | q8_0 | q4_0 | on | ring wedged | - |
| 16384 | q8_0 | f16 | off | 1.43 | 0.577 |
| 16384 | f16 | f16 | on | 2.66 | 0.861 |
| 16384 | f16 | f16 | off | 2.32 | 0.753 |

### Prediction 1 is falsified

The served triple measures 3.03 against f16's 3.09 at depth 0, a 1.9% cost where
about 7% was registered, and the two overlap within the 0.04 spread on the first
of them. The 7.2% the Nanbeige file assigned to the cache policy is not the cache
policy. That file's sentence is already softened to name four simultaneous
changes; this narrows which of the four it was not.

### Prediction 2 is falsified where it could be measured

Quantization was predicted to win at depth because it moves 2.4 times fewer
cache bytes. At 4096 the served triple retains 0.927 against f16's 0.951 with
the same kernel, so it loses at depth by more than it loses at zero, and it does
so in the direction opposite the prediction. At 16384 it did not complete.

The served policy costs rate at every depth it completed. What it buys is
memory, and the size of that purchase is smaller than a reading of the carve-out
suggests. The coredump reports `real vram size: 2147483648` beside `gtt size:
15723495424`: the first is the amdgpu VRAM carve-out and the second is the GTT
aperture, and a UMA device allocates from both out of the same 29 GiB of DDR4.
The 24576 allocation this tree already measured is 2,974 MiB, larger than the
carve-out, so the carve-out is demonstrably not the ceiling. A q8_0/q4_0 cache
holds about 2.4 times fewer bytes than f16 and that headroom is real, but which
depths f16 can actually reach on this machine is unmeasured, and the capacity
argument for the served policy rests on that measurement rather than on the
2 GiB figure.

### Flash attention is neutral shallow and decisive deep

| depth | f16 fa on | f16 fa off | fa gain |
| ---: | ---: | ---: | ---: |
| 0 | 3.09 | 3.08 | +0.3% |
| 4096 | 2.94 | 2.99 | -1.7% |
| 16384 | 2.66 | 2.32 | +14.7% |

The fused kernel avoids materializing the attention matrix, and the size of what
it avoids scales with depth, so its cost at zero depth and its gain at 16384 are
the same mechanism seen at two ends. `--flash-attn on` earns its place in the
served policy on the 16384 column rather than on the shallow ones.

### Prediction 3 is falsified, and by the served configuration

f16 at 16384 was expected to be the cell most likely to wedge; both f16 cells
completed and the served triple wedged. The failure and the coredump are
recorded above.

Two facts bound what that wedge supports. It happened once, so it is not
established as reproducible. And it happened under llama-bench at its batch
defaults, where the served path submits at `--batch-size 128 --ubatch-size 32`,
so depth and submission size stay confounded. `remote/probe-depth-wedge.sh`
separates them.

### What this run does not carry

The clock sampler landed after this run started and rsyncing a script a running
shell is reading corrupts it, so no cell here records the `pp_dpm_mclk` step it
ran at. Every rate in the table is therefore uncontrolled for a covariate whose
top two steps span 12.6%.

The `q8_0/f16 fa off` arm is non-monotonic: 2.48, then 0.88, then 1.43. Decode
rising with depth contradicts every other cell, both deep rungs are single
measurements, and the flags are confirmed in both tables. That arm is unfit to
carry a mechanism claim until it is repeated, so the magnitude of what the fused
path absorbs stays unmeasured. What the refused cell establishes is narrower and
holds: a quantized V cache requires the fused path on this backend.

The 4B's depth-0 f16 rate is 3.31 in the Nanbeige ladder and 3.08 here on the
same build and file, while the same pair agrees to 1.1% at 16384, 2.69 against
2.66. A deep rung is preceded by a prefill of about thirteen minutes that settles
the part before decode begins; a depth-0 rung begins decoding immediately after
load, in whatever state the preceding work left. That is a hypothesis with a
test, and `remote/measure-bench-repeatability.sh` is it.
