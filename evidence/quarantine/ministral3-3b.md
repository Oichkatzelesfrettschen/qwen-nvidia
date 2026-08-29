# Quarantined model: Ministral-3-3B-Instruct

```text
id              ministral3-3b
scope           model
subject         ministral3-3b
model file      Ministral-3-3B-Instruct-GGUF/Ministral-3-3B-Instruct-Q4_K_M.gguf
failure class   graph-assert-abort
tuple           unbounded; the abort follows the spawn context rather than any flag
first evidence  evidence/model-admission/universal-candidate-ladder.md
latest evidence evidence/model-admission/universal-candidate-ladder.md
```

The checkpoint decodes 4.66 tok/s and prefills 31.14, which is 39.5% and 39.0%
above the deployed 4B distill measured in the same sweep. It is quarantined
because the path this appliance serves through kills it.

## The failure

A request naming `ministral3-3b` returns HTTP 500 with `model
name=ministral3-3b failed to load`. The spawned child reaches the end of model
loading, reserves its graph, and aborts during warmup:

```text
sched_reserve:    Vulkan0 compute buffer size =     5.20 MiB
sched_reserve: graph nodes  = 1150
sched_reserve: graph splits = 1
cmn init: llama threadpool init, n_threads = 1
cmn common_init_: warming up the model with an empty run
ggml/src/ggml-impl.h:318: fatal error
instance name=ministral3-3b exited with status 1
```

`ggml-impl.h:318` is the `GGML_ABORT("fatal error")` that closes
`ggml_hash_find_or_insert` under the comment `visited all hash table entries ->
not found`. The abort is in graph hash lookup, not in a Vulkan submission: no
ring reset, no page fault, no `VK_ERROR_DEVICE_LOST`, and the device serves the
next request normally. The class is `graph-assert-abort` for that reason, and it
is a distinct failure from the two compute-ring wedges this tree records.

## Where it does not fail

Four for four in the router, zero for four outside it.

| path | argv | environment | result |
| --- | --- | --- | --- |
| `llama-cli`, text only | `-c 4096 -b 128 -ub 32` | inherited | answers correctly |
| `llama-cli`, with projector | same plus `--mmproj` | inherited | answers correctly |
| `llama-cli`, served cache triple, `-t 1` | `q8_0`/`q4_0`, FA on, `-c 8192` | inherited | ok |
| standalone `llama-server` | the served flag set | inherited | listens |
| standalone `llama-server` | the served flag set | `GGML_VK_MAX_NODES_PER_SUBMIT=16` | listens |
| standalone `llama-server` | **the router child argv verbatim** | inherited | listens, `graph nodes = 1150` |
| standalone `llama-server` | **the router child argv verbatim** | **the router's environment verbatim** | listens, `graph nodes = 1150` |
| **router child** | the same argv | the same environment | **abort, 4 of 4** |

The last two rows are the isolation. The standalone process was given the
child's argument list read back from the router's own spawn log -- including
`--webui`, `--path`, `--tags`, `--swa-checkpoints 0`, `--parallel 1`,
`--threads 1`, `--override-tensor .*=Vulkan0`, and the cache triple -- and the
four variables the router process actually holds, read from `/proc/<pid>/environ`:
`GGML_VK_LOW_PRIORITY`, `GGML_VK_MAX_NODES_PER_SUBMIT`, `VK_DRIVER_FILES`, and
`VK_ICD_FILENAMES`. It reserved the identical 1,150-node graph and listened.

Eviction is ruled out. The first three aborts followed `evicting idle LRU
name=qwen35-2b`; the fourth was taken against a freshly launched router with
Ministral as its first load and no eviction, and it aborted the same way.

**What remains uncontrolled is the spawn context itself**: the child is created
by a parent process that has already initialised a Vulkan instance and loaded
clip metadata for every vision preset. Nothing in this tree explains how that
changes a graph hash table in a separate process, and asserting a mechanism from
here would be conjecture. The recorded fact is the correlation and its four
negative controls.

`mistral3` is the only architecture in the roster that does this. The three
other candidates fetched alongside it -- `qwen35` at 0.8B and 2B and `lfm2` at
1.6B -- each loaded through the router and answered on the first request.

## Re-entry gate

Ministral returns from `quarantine` to `candidate` when a router child loads it
and answers, twice, with zero aborts. Nothing else is required of it: its rate
is measured, its architecture is present at the pinned build, its projector
pairs, and its census is complete.

The instrumentation registered in
`evidence/quarantine/qwen38-4b-distill-d16384-b2048-ub512.md` is what would name
the operation. For this failure the useful addition is narrower: a graph-node
count and hash-table capacity logged at reserve and again at warmup, on both the
standalone and the spawned path, since the abort says the table filled and the
reserve says the graph is the same size in both.

## What is not claimed

That Ministral is unsafe. The abort leaves the device intact, the router
recovers, and every subsequent request to another model succeeds. This is a
quarantine because the appliance has no validated served tuple for this
checkpoint, not because running it endangers the machine.

That its architecture is at fault. `mistral3` loads, reserves, and generates
correctly on three separate paths on this device.
