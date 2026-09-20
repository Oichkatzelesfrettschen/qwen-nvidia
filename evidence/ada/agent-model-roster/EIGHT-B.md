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

## What llama.cpp actually decides

b1935 derives the tool-call parser from the template rather than matching a
model name. `common/chat-auto-parser-generator.cpp` classifies a template
into `JSON_NATIVE`, `TAG_WITH_JSON` or `TAG_WITH_TAGGED`; failing that it
logs `Template seems to support tool calls, but failed to determine tool
format` and installs an epsilon parser, so the model answers in prose and
nothing reports a fault. That line appeared in none of the seven server logs
captured here, so no row in this roster fails at classification. The five
prose rows fail earlier: their packaged templates declare no tool input, so
no parser is attempted.

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

It is the cleanest recorder measured. It is also the slowest usable row:
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
graph lane. `lfm2moe` aborted at 2048 and `smollm3` loads at 2608, so 2336
falls inside the interval the measurements do not resolve: a Llama 8B under
`--override-tensor '.*=CUDA0'` may abort exactly the way the wave-two rows
did. The fix would be one more enum in the list
`patches/llama-sched-graph-budget.patch` already carries, at the cost of a
rebuild. The `qwen3` rows at 399 tensors carry no such risk.

Device budget at Q6_K with q8_0 KV, on 11.99 GiB with the desktop holding
about 2.3: a 36-block Qwen3-8B spends 78,336 bytes per token of cache, so
16384 costs 1.20 GiB and 32768 costs 2.39. Weights plus cache plus compute
buffers land near 7.9 GiB at 16384 and near 9.1 at 32768, which is why
16384 is the row default and 32768 the ceiling.

Recorded 2026-09-20.
