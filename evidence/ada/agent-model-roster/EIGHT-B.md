# The 8B question, and the probe defect that had already answered it wrongly

`klear-agentforge-8b` was recorded as unable to call a tool. It can. The
broad screen's forced `record_probe` request caps the reply at 128 tokens,
and a model that reasons before it calls spends that budget on tokens the
call never reaches. The retained probe records the difference:
`klear-agentforge-8b` and `lfm25-8b-a1b` both refused with `finish_length`,
while `oxcoder-9b`, `swe-dev-7b`, `swe-agent-lm-7b`, `hammer21-3b` and
`phi4-mini` refused with an answer that carried no `tool_calls` at all.
Re-probed at 512 tokens on the same binary, the two `finish_length` rows
complete `record_probe(ok=true)` and the five prose rows still answer
`finish=stop` with no call. The cap was the whole difference for two rows
and nothing for the other five.

`scripts/graft-consumer-env.sh` now caps at 1024, takes
`QWEN_PROBE_MAX_TOKENS`, and refuses a truncated reply under its own
message, because a reply cut off mid-call is no evidence the model cannot
make one.

## No request in this campaign forced anything

The probe sent `tool_choice` as the OpenAI named-function object.
`tools/server/server-common.cpp` reads that field through
`json_value(body, "tool_choice", std::string("auto"))`, which catches the
type error an object raises and returns `"auto"`. Every server log captured
here carries the warning it emits doing so:

```text
Wrong type supplied for parameter 'tool_choice', using default value:
[json.exception.type_error.302] type must be string, but is object
```

So the column this campaign called `tool_call` records what each model did
when offered a tool, not what it did when required to use one. Re-probed
with `"tool_choice":"required"` against the same five rows that had answered
in prose:

| row | required | auto |
| --- | --- | --- |
| oxcoder-9b | records the call | no call |
| swe-dev-7b | runs past 8192 tokens, 40981 chars, no call | no call |
| swe-agent-lm-7b | runs past 8192 tokens, no answer in 600 s | no call |
| phi4-mini | no call | no call |
| hammer21-3b | no call | no call |

`oxcoder-9b` was never refusing; it was never asked. The two SWE rows change
behavior under the constraint and then fail to terminate: raising the cap to
8192 buys `swe-dev-7b` forty thousand characters of prose and no call, and
`swe-agent-lm-7b` no answer at all inside ten minutes. That is a third
outcome the campaign had no column for, and it is a worse failure than the
prose answer it was recorded as, not a better one. Only `phi4-mini` and
`hammer21-3b`, whose templates declare no tool input, are unchanged by the
constraint.

Both harnesses now send a string, and
`scripts/test-fixtures/fake-chat-tools-server.py` models the server's own
handling, so a probe that regresses to the object form fails the fixture
rather than reading voluntary calls as forced ones.

## What llama.cpp actually decides

b1935 derives the tool-call parser from the template rather than matching a
model name. `common/chat-auto-parser-generator.cpp` classifies a template
into `JSON_NATIVE`, `TAG_WITH_JSON` or `TAG_WITH_TAGGED`; failing that it
logs `Template seems to support tool calls, but failed to determine tool
format` and installs an epsilon parser, so the model answers in prose and
nothing reports a fault. That line appears in none of the seven server logs
captured here. Its absence rules out that one failure and establishes nothing
positive: parser construction is conditional on detected capability, so the
server reaches ordinary content parsing without ever arriving at the
diagnostic. Reading which parser was built, rather than which error was not
logged, needs a record the server does not yet emit here.

The gate chain is therefore three checks, in order, and the first two cost
no device time:

1. the GGUF header's `tools` and `tool_calls` flags, which
   `admit-candidate-static.py` reads over a range request;
2. the auto-parser's classification, which the server log reports by that
   ERROR or by its absence;
3. a reply cap above the reasoning preamble.

## klear-agentforge-8b measured

It is a Qwen3-8B fine-tune: `qwen3`, 36 blocks, 399 tensors, 32 heads over
8 KV heads at 128, 65536 context, 6.27 GiB at Q6_K. At 399 tensors its graph
budget is 3192 nodes, above the 2608 that already loads, so it is clear of
the abort that held the wave-two rows.

| gate | result |
| --- | --- |
| three-file screen | 8.55, 10.92, 12.92 s -- 10.8 s per file |
| forced tool probe | completes at 512 and at 1024 |
| six contracts | 3/6 |
| record_symbols at 2048 | 2/3, one file cut off |
| record_symbols at 6144 | 3/3, every id exact, every crux in range, nothing invented |

That is the strongest structured-output result measured, with one scope
limit worth stating: `admit-record-symbols.sh` takes its target ids by
parsing symbol names out of `graft skeleton`'s human-readable output, so
"every id exact" means the model returned the labels the request supplied,
not that it matched graft's persistent graph ids. Binding the gate to the
wiring checkpoint's own nodes, and dropping targets whose skeleton span is
known wrong, is what would let this rank models against each other rather
than establish that each one copies its input faithfully.

It is also the slowest usable row:
2.9 times the incumbent per file, and 73 s for the three symbol files. Its
contract score sits below `phi4-mini` at 5/6 and `qwen3-4b-instruct-2507` at
6/6, both of which run at about a third of its wall time.

## External 8B candidates, read from their headers

Audited over range reads at pinned revisions, no download:

| repository | arch | tensors | template bytes | tools | GiB |
| --- | --- | ---: | ---: | --- | ---: |
| NousResearch/Hermes-3-Llama-3.1-8B-GGUF | llama | 292 | 291 | no | 6.14 |
| bartowski/Hermes-3-Llama-3.1-8B-GGUF | llama | 292 | 209 | no | 6.14 |
| bartowski/DeepSeek-R1-Distill-Llama-8B-GGUF | llama | 292 | 2237 | no | 6.14 |
| bartowski/Meta-Llama-3.1-8B-Instruct-GGUF | llama | 292 | 4614 | yes | 6.14 |
| Salesforce/Llama-xLAM-2-8b-fc-r-gguf | llama | 292 | 2777 | yes | 6.14 |
| bartowski/nvidia_Llama-3.1-Nemotron-Nano-8B-v1-GGUF | llama | 292 | 2004 | yes | 6.14 |
| Qwen/Qwen3-8B-GGUF | qwen3 | 399 | 4100 | yes | 6.26 |
| unsloth/DeepSeek-R1-0528-Qwen3-8B-GGUF | qwen3 | 399 | 5265 | yes | 6.26 |

Both published Hermes-3 GGUF builds ship a stub template of a few hundred
bytes carrying no tool support, which disqualifies the checkpoint most
associated with tool calling on the strength of its packaging alone.
`DeepSeek-R1-Distill-Llama-8B` renders `tool_calls` for assistant history and
accepts no `tools` input, so it cannot be given a tool either. The distill
that does qualify is `DeepSeek-R1-0528-Qwen3-8B`, which is a Qwen3-8B.

Every `llama` row sits at 292 tensors, which is 2336 nodes in the default
graph lane, and that number predicts nothing. The budget is a capacity
heuristic over tensor count; what has to fit is the entry count the scheduler
actually reaches, which depends on the architecture's graph shape, the
placement, the copies and the outputs. `lfm2moe` failing at 2048 and
`smollm3` loading at 2608 are two different architectures reaching different
demands, not two samples of one threshold, so no interval between them is
resolved and none of these rows inherits a verdict from them. Every `llama`
row here is unmeasured under `--override-tensor '.*=CUDA0'`, and the way to
settle one is to run it. An architecture joins the list
`patches/llama-sched-graph-budget.patch` carries when it is measured to
abort, which is the rule that patch's own comment states.

Device budget at Q6_K with q8_0 KV, on 11.99 GiB with the desktop holding
about 2.3: a 36-block Qwen3-8B spends 78,336 bytes per token of cache, so
16384 costs 1.20 GiB and 32768 costs 2.39. Weights plus cache plus compute
buffers land near 7.9 GiB at 16384 and near 9.1 at 32768, which is why
16384 is the row default and 32768 the ceiling.

Recorded 2026-09-20.
