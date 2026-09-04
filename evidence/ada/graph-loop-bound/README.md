# The host round trip is 140 microseconds, and that is all a graph loop can take

A bounded autoregressive graph loop executes several tokens per host round trip
by putting the loop body and its exit test on the device, so what it can buy is
the time a token spends outside device execution between one graph launch and
the next. `../decode-node-trace/run-02/` already partitioned that token, and the
answer is a constant.

## The term a loop removes

Graph granularity is the reading that reproduces the served token, so it is the
one the bound is computed from. Its idle splits in two, and only one half is
outside the replay:

| term | 2B | 0.8B |
| --- | ---: | ---: |
| median span | 4261.2 us | 3062.2 us |
| device busy | 3998.6 us | 2775.8 us |
| idle between device rows | 91.2 us | 100.7 us |
| **idle outside device work** | **139.1 us** | **140.0 us** |

`idle_between_device_rows` falls inside the stretch the device rows occupy: it
is the gap between kernels of one replay, and a loop that launched the same
replay several times over would launch the same gaps with it.
`idle_outside_device_work` is the time before the first device row of a token
and after its last, which is the host round trip and the only term a loop
removes.

139.1 and 140.0 microseconds across two checkpoints whose tokens differ by 39%
in duration is what makes it a host cost rather than a model property. Against
each class's own token:

| model | round trip | decode token | ceiling |
| --- | ---: | ---: | ---: |
| qwen35-08b | 140.0 us | 3062.2 us | **4.57%** |
| qwen38-2b-distill | 139.1 us | 4261.2 us | **3.26%** |
| qwen38-4b-distill | unmeasured | 8807.5 us, registry | under 1.6% |

The first two denominators are the graph-granularity spans those captures
measured, which sit above each class's registry token; the 4B ran no node-trace
arm, so its row divides the measured constant by the registry figure instead and
is not comparable to the two above it at the third decimal. What it states is
the ordering: at 139 to 140 microseconds the ceiling on a token twice the 2B's
is about 1.6%, and the round trip would have to more than triple against both
measured classes to reach the floor.

Every one is under the 5.1% promotion floor, and each is the ceiling at an
unbounded loop length. A loop of N tokens removes N-1 of every N round trips, so
a four-token loop reaches three quarters of a number already below the floor.

## The regime the ceiling is measured in

`tools/llama-bench/llama-bench.cpp` calls `llama_decode`, `llama_synchronize`,
and `std::rand()`, so the partition above ran with no sampler on the host at
all. That is the regime a device-side loop operates in by construction, which is
what makes 140 microseconds the right ceiling for it rather than an
underestimate.

It also means the loop cannot be credited with what backend sampling buys.
`../backend-sampling/` measures 0.166 ms per generated token for moving sampling
off the host, against a served path where the host runs the full chain. Adding
that to the 140 microseconds here would describe a served round trip of about
306 microseconds without backend sampling, but the two figures come from
different harnesses on different request paths and their sum is an inference
rather than a measurement. What the two do establish jointly is the ordering: a
device-side loop requires device-side sampling, so backend sampling's saving is
taken first and the loop is left with the residual, which is the 140 microseconds
measured here.

## Two structural obstacles beside the ceiling

The pinned tree carries no conditional-graph support. `cudaGraphConditional`,
`cudaGraphSetConditional`, and conditional handles appear nowhere under
`ggml/src/ggml-cuda/`, so the loop is a new graph execution model in ggml rather
than a flag on the existing capture at `ggml-cuda.cu:2581-2597`.

The five stop conditions the task names do not all survive the prerequisite.
A device-side loop needs the sampled token on the device, which is
`--backend-sampling`; `common/sampling.cpp:415` disables backend sampling
whenever the request built a grammar, so grammar completion cannot be a stop
condition of a loop that exists only when no grammar does. EOS, cancellation,
and a stream watermark are expressible as device-side predicates; a tool
boundary is a string match against a decoded reply and is not.

## Verdict

**The lever is refuted on its ceiling.** 1.59% to 4.57% of a decode token, all
under the floor, before a line of the loop is written and before the bounded
loop's own N-1 over N discount. No implementation follows.

Reopening needs the round trip to grow or the token to shrink. A concurrent
served workload with several sequences in flight changes what the host does
between launches and is unmeasured here, and it is the same regime
`../decode-node-trace/` demoted graph prewarming to and `../projection-fan-out/`
named as the one that recomputes its own bound. Three refutations now point at
one missing arm, and running it is worth more than any of the three levers it
would re-open.

## What this bound is not

The partition ran under llama-bench at batch 1 with no sampler, one sequence,
and no speculation. A speculative arm accepts several tokens per host round trip
already, which is a different amortization of the same 140 microseconds and
would be double-counted by a loop layered on it. `../speculation-runtime-classes.md`
holds this device's speculation measurements and no arm here combines the two.

`device-environment.tsv` records the driver, CUDA runtime, and kernel this
reading is bound to. The partition it reads was taken before this tree recorded
that block, so the stack under which `../decode-node-trace/run-02/` ran is
stated by the retained record's own date rather than by a block inside it.
