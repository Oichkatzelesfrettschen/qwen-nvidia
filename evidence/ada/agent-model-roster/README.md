# Agent-model roster: nine coding-agent checkpoints beside the 4B distill

The summarize roster in `evidence/ada/summarize-roster/` chose
`qwen38-4b-distill` for graft's deep pass from the rows the registry
already held. This directory admits nine checkpoints post-trained for
coding-agent work, so the same three-file summarize probe and the same
forced tool-call probe measure them against that control. Each row enters
at tier `candidate`, role `agent-code`, context default 16384 and ceiling
32768, on a pinned publisher revision, a Git LFS digest the fetch script
verifies, and a static header read; the device arms follow below.

## Rows and sources

| id | artifact | publisher revision | quantization | bytes | lineage |
| --- | --- | --- | --- | ---: | --- |
| oxcoder-9b | sizzlebop/OxCoder-9B-GGUF | 468132cf1e1f | Q6_K | 7359267840 | OrionLLM/OxCoder-9B, Qwen3.5-9B post-trained on agent trajectories |
| ornith15-9b | AtomicChat/Ornith-1.5-9B-GGUF | 8fc2368e7794 | Q6_K | 7359259392 | ornith-ai/Ornith-1.5-9B, Qwen3.5-9B agentic RL |
| qwen3-4b-instruct-2507 | unsloth/Qwen3-4B-Instruct-2507-GGUF | a06e946bb6b6 | Q8_0 | 4280405600 | Qwen/Qwen3-4B-Instruct-2507, non-thinking control |
| qwable-9b-fable5 | empero-ai/Qwable-9B-Claude-Fable-5-GGUF | 176c101fb7e8 | Q6_K | 7359259360 | empero-ai/Qwable-9B-Claude-Fable-5, Qwen3.5-9B on agent traces |
| klear-agentforge-8b | mradermacher/Klear-AgentForge-8B-GGUF | 0626423882f5 | Q6_K | 6725899392 | Kwai-Klear/Klear-AgentForge-8B, Qwen3-8B multi-turn RL |
| hammer21-3b | mradermacher/Hammer2.1-3b-GGUF | 4b0e6fc41ca1 | f16 | 6177201728 | MadeAgents/Hammer2.1-3b, Qwen2.5-Coder-3B function calling |
| granite40-micro | ibm-granite/granite-4.0-micro-GGUF | ec48475f0c81 | bf16 | 6809656768 | ibm-granite/granite-4.0-micro, dense 3B control outside the Qwen family |
| swe-dev-7b | mradermacher/SWE-Dev-7B-GGUF | caf88960ca32 | Q6_K | 6254199104 | zai-org/SWE-Dev-7B, Qwen2.5-Coder-7B |
| swe-agent-lm-7b | mradermacher/SWE-agent-LM-7B-GGUF | eb7aaf78639f | Q6_K | 6254199680 | SWE-bench/SWE-agent-LM-7B, Qwen2.5-Coder-7B on SWE-agent trajectories |

Q6_K is the precision a 12 GiB device carries for a 9B with room for a
32768-token cache; the 4B control serves Q8_0 and the two 3B rows serve
the sixteen-bit conversion their publishers ship, since a 3B at full
precision costs less device memory than a 9B at Q6_K. Hammer's publisher
ships no BF16 GGUF; the f16 conversion is the highest precision available
as a GGUF. TIGER-Lab/FIM-7B has no GGUF conversion on Hugging Face at all,
so it is absent here and enters only after a local convert_hf_to_gguf.py
run from its safetensors.

## Static admission

`scripts/admit-candidate-static.py` read each header over an HTTP range
request; `static/*.json` carries the full record and `static/summary.tsv`
the columns that decide the roster's shape.

- The three 9B rows are one architecture fingerprint,
  `qwen35/block_count=32/embedding_length=4096/.../attention.head_count_kv=4`,
  and one vocabulary (`tokens_sha256` equal), so they compare as
  post-training alone. OxCoder carries a 16289-byte chat template of its
  own; Ornith and Qwable carry the same 7756-byte template, byte for
  byte.
- `enable_thinking` is true on the three 9B rows and false on the other
  six. `QWEN_CHAT_REASONING_BUDGET=8192` binds the thought block on the
  three and is inert on the six, so a `finish=length` on a non-thinking
  row is content overrun and nothing else.
- Hammer2.1's template declares `tools` and no `tool_calls` rendering.
  `scripts/graft-consumer-env.sh` forces a tool call and reads
  `tool_calls` back, so the probe is predicted to refuse this row; the
  roster records the outcome as the finding.
- SWE-Dev-7B and SWE-agent-LM-7B share one template and one vocabulary:
  both are Qwen2.5-Coder-7B post-trainings, and their native context is
  32768, the registry ceiling exactly.
- granite-4.0-micro is the only row outside the Qwen tokenizer family
  (`tokenizer_pre=dbrx`, 100352 tokens).

## Device arms

The strict CUDA0 placement load (`scripts/test-strict-cuda-placement.sh`,
results under `strict/`) and the summarize roster
(`scripts/admit-summarize-roster.sh` with `QWEN_ROSTER_IDS` naming these
nine rows, results in `roster.tsv` and `roster.tsv.*.txt`) run after the
detached graft deep build releases the device. Until those files exist the
device arms read `not run`, and every row stays at `validated_filled_depth
-` with its rate fields at `-`.
