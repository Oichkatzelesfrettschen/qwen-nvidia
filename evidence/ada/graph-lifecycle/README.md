# The CUDA graph lifecycle under a mixed-service transition

`ggml_backend_cuda_graph_compute` in the pinned `ggml/src/ggml-cuda/ggml-cuda.cu`
keys its graph object from `cgraph->nodes[0]`, compares every node's
`ggml_tensor` bytes and source pointers, shapes, and strides against the
previous compute under that key, executes directly and resets warmup where
they differ, captures on the first compute after two agreeing ones, and
replays the executable while they keep agreeing. Every checkpoint this tree
serves passes through that decision once per ubatch, so what a served
transition costs in graph lifecycle is a property of the transition's
topology sequence, which nothing in this tree had measured.
`patches/llama-cuda-graph-lifecycle.patch` records that decision per compute
under `GGML_CUDA_GRAPH_LIFECYCLE`: a topology digest over graph structure and
dimensions with pointer values excluded, a pointer digest over the data
pointers the backend compares, the first node and category that moved, the
warmup state before and after, the action, the executable transition, the
host duration of the compute call, and the device span between two events
recorded on the compute stream around it. Closure `733d00ecf69f` is the
census closure's levers plus that patch, and it serves nothing.

## Preregistration

The workload is one state machine repeated with fixed prompts, fixed slot
identities, and one loaded server:

```text
T0  slot A decodes alone
T1  slot B enters with a 256-token uncached prefill while A stays live
T2  A and B decode together
T3  B finishes; A decodes alone again
```

`scripts/graph-lifecycle-transition-client.py` sends B after A has streamed
24 tokens, A decodes 128 tokens and B 32, six cycles per arm with cycle 0 the
warm-up that fills A's prompt cache, then the same six cycles with the slot
identities swapped as the permutation control. The denominator is the whole
mixed-service interval, A's request start to A's completion, summed over the
measured cycles. The floor is 5.1%.

Prediction, from the backend's key and comparison: one graph key serves every
topology, so T1 (a prefill graph beside a decode row) and T2 (a width-2
decode graph) each reset warmup and execute directly, T2 captures on its
second agreeing compute, and T3's return to the width-1 decode graph pays a
fresh direct execution and capture although its topology is the one T0 ran,
because the object holds one topology at a time. Recurrence across cycles is
therefore predicted and reuse is predicted absent. The batch-1 steady decode
already measured 60 replays against two captures and stays out of the
candidate claim.

Falsifiers: no row with `warmup_before=1` and `warmup_after=0` inside T1, T2,
or T3 refutes the reset; a `change_reason` of `pointer` rather than
`structure` at those rows attributes the reset to buffer movement rather than
topology; a topology digest that recurs in T0 and T3 and replays in T3
without a direct execution refutes the one-object reading; a lifecycle
fraction under the floor closes #43 whatever the recurrence.

Decision table:

```text
fraction < 0.051                          -> close, no implementation
fraction >= 0.051 and no digest recurs    -> close, nothing to prewarm
fraction >= 0.051 and a digest recurs     -> build topology-keyed prewarming
one (n_tokens, n_outputs) -> several digests -> refuse N-only cache keys
```

Reply identity is an observation beside the trace rather than a key: each
cycle's A and B reply digests are compared across cycles and across the two
arms.

## Result

`2b-run-02/` is the run the decision rests on, under closure `78385b190cb6`,
which reads n_tokens, n_outputs, and n_kv off graph structure; `2b-run-01/`
ran the same workload under `733d00ecf69f`, whose recorder looked those three
up by tensor name and found none, because `src/models/qwen35.cpp:151` renames
the embedding node to `model.input_embed`. Every lifecycle count agrees
between the two runs to within one row, and both read under the floor.

| run | closure | overhead measured ms | overhead bounded ms | denominator ms | fraction |
| --- | --- | ---: | ---: | ---: | ---: |
| 2b-run-01 | 733d00ecf69f | 147.957 | 126.129 | 7646.7 | 0.03584 |
| 2b-run-02 | 78385b190cb6 | 115.218 | 85.160 | 7107.5 | 0.02819 |

The five answers, from `2b-run-02/lifecycle-summary.txt`:

1. The transition resets warmup. Every measured cycle in both arms carries a
   reset in T0, T1, and T3 (five each per arm) and none in T2, where the
   width-2 decode graph had already been executed directly at the end of T1.
2. Every reset is structural: `change_reason=structure`,
   `change_categories=shape,data`, first at node `model.input_embed`, which is
   the n_tokens dimension of the graph's first node. No reset reads
   `pointer`, so buffer movement causes none of them.
3. Every topology recurs. Ten digests appear in the measured cycles and all
   ten appear in at least five. The width-1 decode digests `0fdbf3977c990123`
   and `0dfa7fc3533697c4` run in T0, T1, and T3 of every cycle, and the
   width-2 digest `d702fd6fe588b6cb` runs in every T2 of both arms.
4. A recurrence pays two direct executions, one capture, and one executable
   update at the median (thirty reset episodes, maximum five direct
   executions). The width-1 decode topology pays that price twice per cycle,
   once entering T0 and once returning at T3, although it is the topology
   the object held before T1: `cgraph->nodes[0]` keys one object, and the
   object holds one topology.
5. The lifecycle costs 2.82% of the mixed-service interval: 115 ms measured
   against the replay median of the same digest plus 85 ms bounded for the
   seven digests that never replay, over 7107 ms of A's request start to A's
   completion across ten measured cycles. The bound scales a never-replayed
   compute by the largest direct-over-replay excess any digest showed, 0.2654,
   so the true figure sits at or under 2.82%.

Same N maps to several digests: n_tokens 1, 2, and 4 each carry two topology
digests at n_outputs 1, because n_kv steps by 256 as A's context crosses a
padding boundary inside the cycle. An N-only cache key is refused on that
reading.

Reply identity: A's reply is `fa3c4e136c66` in every measured cycle of both
arms. B's reply is `6a479b4b751a` in every fixed-arm cycle and `1a2a7a3fbc0c`
in every permuted-arm cycle, reproducible inside each arm and different
between them. B's uncached prefill shares its batch with A's decode token,
and the permutation changes which slot's tokens come first in that joint
pass, which is the prefill-composition effect
`evidence/ada/concurrent-sequences/README-PRIMED.md` records; the trace adds
that the two arms run the same topology sequence, so the difference is
arithmetic order inside one graph shape rather than a different graph.

Decision: close #43 with no implementation. The cost is under the 5.1% floor
in both runs, so neither the recurrence nor the N-key refusal reaches an
implementation; both stay on record for the case a workload with more
transitions per second reopens it. The batch-1 steady decode stays out of the
claim as preregistered: T3 alone shows 340 replays against 5 captures.

The inferred MMVQ/MMQ split #108 left open is unconfirmed here: the trace
records graph decisions rather than kernel symbols, and the width-2 decode
topology is one digest whichever kernel family its mat-muls selected.
