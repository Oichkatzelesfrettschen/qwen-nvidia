# Speculation across three runtime classes on the RTX 4070 Ti

## What was predicted

Speculation pays where decode is bound by the target's weight traffic and the
draft's proposals are usually accepted. The APU tree's draft economics rest on a
34 GB/s memory ceiling where a 2B target decodes at 9.19 tok/s; this device
holds about 500 GB/s and the same checkpoint decodes at 232.47. The prediction
registered before the sweep: an external draft's own forward passes and the
verification batch cost a larger share of a fast target's step here, so a
0.8B draft may lose against its baseline, and the loss should shrink as the
target grows.

The falsifier is directional rather than a band. A draft arm decoding at or
above its baseline on the 2B refutes the prediction; a draft arm winning on the
9B while losing on the 2B confirms the size dependence; a draft arm losing on
every class states that the mechanism is the draft path's per-call cost rather
than the target's weight traffic.

## Method

`remote/run-speculation-sweep.sh`, one llama-server per arm, target loaded at
`-ngl 99` with `q8_0`/`q4_0` KV, flash attention on, depth 8192, and the draft
at `--spec-draft-ngl 99`. Each arm answers the same three prompts -- prose
continuation, shell code, arithmetic reasoning -- at temperature 0 with 256
reply tokens and `cache_prompt` off, and reports the rate llama-server itself
timed. Every arm records device occupancy and the reply's distinct-4-gram
ratio.

The draft is on the device rather than the host: the arm's peak occupancy rises
by about 990 MiB over its baseline, which is the 0.8B Q8_0 file plus its cache.

## Result

Decode tok/s, mean over the three prompts, with the ratio against each target's
own baseline:

| arm | 2B distill | 4B distill | 9B distill |
| --- | ---: | ---: | ---: |
| baseline | 214.99 | 107.64 | 66.06 |
| draft-mtp, n=1 | 263.90 (1.23) | 152.68 (1.42) | 96.95 (1.47) |
| ngram-simple, n=4 | 294.25 (1.37) | 109.40 (1.02) | 66.85 (1.01) |
| draft-simple, 0.8B, n=2 | 80.73 (0.38) | 56.49 (0.52) | 44.56 (0.67) |
| draft-simple, 0.8B, n=4 | 89.77 (0.42) | 65.49 (0.61) | 49.77 (0.75) |
| draft-simple, 0.8B, n=8 | 87.96 (0.41) | 68.41 (0.64) | 50.89 (0.77) |

The prediction holds in direction and fails in magnitude. The external draft
loses on all three classes, and the loss shrinks monotonically with target size
exactly as predicted -- 0.42, 0.61, 0.75 at n=4 -- but it never crosses one,
where the arithmetic of the standalone rates says it should. The 0.8B decodes
at 312.74 tok/s alone, so four sequential drafts cost 12.8 ms and a 9B verify
step costs about 15 ms; at the measured mean accepted length of 2.5 to 3.9
tokens that predicts about 89 tok/s against the 66 baseline. The arm measures
49.77. Each draft forward inside the server therefore costs about 10 ms rather
than the 3.2 ms the standalone rate implies, and that per-call cost rather than
the target's weight traffic is what decides the arm. The mechanism is
unisolated; a profile of the draft context's launch path is the next probe.

The MTP head wins on every class and its advantage grows with target size:
1.23, 1.42, 1.47. It drafts one token at 0.80 to 0.93 acceptance against the
external draft's 0.24 to 0.85, costs 150 to 470 MiB rather than a resident
second model, and runs in place against the target's own trunk, so it pays no
second model's launch overhead. This is the block `qwen35.nextn_predict_layers`
declares and an ordinary load skips.

The n-gram arm reports the sweep's one methodological finding rather than a
speedup. Its 2B mean of 294.25 comes entirely from the prose prompt at 459.5
tok/s, whose reply carries a distinct-4-gram ratio of 0.235: a greedy 256-token
continuation entered a loop, and a loop is what an n-gram drafter predicts
perfectly. The code and math prompts, at ratios of 0.99, sit at 216.1 and 207.2
against a 219.1 and 220.2 baseline. Read per prompt, `ngram-simple` is baseline
on this workload and the degeneracy column is what separates the two readings.

Prefill falls in every speculation arm -- 1756 to 1075 tok/s on the 2B -- which
is expected: the draft context prefills the same prompt beside the target.

## What this decides

A serving profile pairs a target with its own MTP head rather than with a
resident 0.8B draft. The 2B+0.8B and 4B+0.8B pairings this campaign set out to
measure are refuted as throughput configurations on this device, and the same
0.8B remains the fast-text serving row it already is.

## What stays open

The 10 ms per draft forward is measured and unattributed. Whether it is CUDA
graph capture skipped for the draft context, per-call synchronisation, or
sampling on the host is what a Nsight Systems trace of one draft arm answers,
and a draft path that reached its standalone rate would put the 9B pairing at
about 1.35 rather than 0.75.

`--spec-type draft-eagle3` and the remaining `ngram-*` variants are unmeasured.
The MTP arm ran at `--spec-draft-n-max 1`, which is the head's own depth; no
arm varied it.
