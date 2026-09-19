# Agent-model roster: nine coding-agent checkpoints beside the 4B distill

The summarize roster in `evidence/ada/summarize-roster/` chose
`qwen38-4b-distill` for graft's deep pass from the rows the registry
already held. This directory admits nine checkpoints post-trained for
coding-agent work, so graft's own summarize request and the forced
tool-call probe measure them against that control in one campaign, under
one binary and one launch configuration. Each row enters at tier
`candidate`, role `agent-code`, context default 16384 and ceiling 32768,
switch policy `standalone-only`, on a pinned publisher revision, a Git LFS
digest the fetch script verifies, and a static header read. The router
never serves a `standalone-only` row, so the nine are launchable by
`qwen-launch.sh` for admission and absent from the router picker until a
router transition of their own is measured; the three 9B rows in
particular cannot share the device pairwise, since two Q6_K tensor sets
alone total 13.0 GB against 12 GiB.

## Rows and sources

| id | artifact | publisher revision | quantization | bytes | lineage |
| --- | --- | --- | --- | ---: | --- |
| oxcoder-9b | sizzlebop/OxCoder-9B-GGUF | 468132cf1e1f | Q6_K | 7359267840 | OrionLLM/OxCoder-9B, Qwen3.5-9B post-trained on agent trajectories |
| ornith15-9b | AtomicChat/Ornith-1.5-9B-GGUF | 8fc2368e7794 | Q6_K | 7359259392 | ornith-ai/Ornith-1.5-9B, Qwen3.5-9B agentic RL |
| qwen3-4b-instruct-2507 | unsloth/Qwen3-4B-Instruct-2507-GGUF | a06e946bb6b6 | Q8_0 | 4280405600 | Qwen/Qwen3-4B-Instruct-2507, documented non-thinking control |
| qwable-9b-fable5 | empero-ai/Qwable-9B-Claude-Fable-5-GGUF | 176c101fb7e8 | Q6_K | 7359259360 | empero-ai/Qwable-9B-Claude-Fable-5, Qwen3.5-9B on agent traces |
| klear-agentforge-8b | mradermacher/Klear-AgentForge-8B-GGUF | 0626423882f5 | Q6_K | 6725899392 | Kwai-Klear/Klear-AgentForge-8B, Qwen3-8B multi-turn RL |
| hammer21-3b | mradermacher/Hammer2.1-3b-GGUF | 4b0e6fc41ca1 | f16 | 6177201728 | MadeAgents/Hammer2.1-3b, Qwen2.5-Coder-3B function calling |
| granite40-micro | ibm-granite/granite-4.0-micro-GGUF | ec48475f0c81 | bf16 | 6809656768 | ibm-granite/granite-4.0-micro, dense 3B outside the Qwen family |
| swe-dev-7b | mradermacher/SWE-Dev-7B-GGUF | caf88960ca32 | Q6_K | 6254199104 | zai-org/SWE-Dev-7B, Qwen2.5-Coder-7B |
| swe-agent-lm-7b | mradermacher/SWE-agent-LM-7B-GGUF | eb7aaf78639f | Q6_K | 6254199680 | SWE-bench/SWE-agent-LM-7B, Qwen2.5-Coder-7B on SWE-agent trajectories |

These precisions are the fidelity screen, not a speed claim: Q6_K is the
highest precision a 12 GiB device carries for a 9B beside a 32768-token
cache, the 4B control serves Q8_0, and the two 3B rows serve the
sixteen-bit conversion their publishers ship. A 3B at f16 moves more
bytes per token than the 4B at Q4_K_M, so a lower-precision rung is
measured for whichever rows pass the screen, not ahead of it. Hammer's
publisher ships no BF16 GGUF; f16 is the highest precision available.
TIGER-Lab/FIM-7B has no GGUF conversion on Hugging Face, so it is absent
until a local convert_hf_to_gguf.py run from its safetensors exists.

## Static admission

`scripts/admit-candidate-static.py` read each header over an HTTP range
request; `static/*.json` carries the full record and `static/summary.tsv`
the columns that shape the roster. The four template columns are
spelling searches over the template source (`enable_thinking`, `<think>`,
`tools`, `tool_calls`); they state whether the template mentions the
identifier and nothing about the rendered prompt or the model's behavior.

- The three 9B rows share one architecture fingerprint,
  `qwen35/block_count=32/embedding_length=4096/.../attention.head_count_kv=4`,
  and one vocabulary (`tokens_sha256` equal). Ornith and Qwable carry the
  same 7756-byte chat template byte for byte; OxCoder carries a 16289-byte
  template of its own, whose rendered token count is measured by the
  roster's `prompt_tokens` column rather than inferred from its size.
  Equal fingerprints narrow the comparison to delivered configurations
  (template, converter, tensor types, post-training) and do not isolate
  post-training alone.
- `enable_thinking` is spelled in the three 9B templates and absent from
  the other six. Whether `QWEN_CHAT_REASONING_BUDGET` binds anything on a
  row is a runtime fact the roster's `reasoning_chars` column reports.
  Qwen3-4B-Instruct-2507 is documented non-thinking by its publisher and
  its template still spells `<think>`; Klear spells `<think>` without
  `enable_thinking`.
- Hammer2.1's template spells `tools` and never `tool_calls`. Its card
  describes a JSON-array call format with its own parser, so its
  compatibility with llama-server's tool-call parser and with graft's
  request shape is unverified until the probe and a tool-result
  continuation run; a refused probe is an integration finding, not a
  verdict on the model's function selection.
- SWE-Dev-7B and SWE-agent-LM-7B share one template and one vocabulary:
  both are Qwen2.5-Coder-7B post-trainings with a native context of
  32768, the registry ceiling exactly.
- granite-4.0-micro is the only row outside the Qwen tokenizer family
  (`tokenizer_pre=dbrx`, 100352 tokens).
- Every row declares `nextn_layers=0`: none carries an MTP head, so the
  4B control's `mtp1` profile has no counterpart on any challenger.

## Device arms

`campaign-runner.sh` is the runner, retained here with its selection and
order. It waits for all nine fetch scripts to verify, then for the
detached graft deep build to exit, and refuses to start when either
condition or `sudo` (which the hazard watchdog needs) is missing.

1. `scripts/test-strict-cuda-placement.sh` on each new row: two CPU
   refusals and one CUDA0 load at a 128-token context answering a
   fixed-seed completion twice, results under `strict/`. This is the
   first gate; it exercises no template, no tool schema, no filled
   sequence, and not the 2048/512 batch geometry, so a pass admits the
   artifact as a load subject and nothing more.
2. `scripts/admit-summarize-roster.sh` over the nine rows and the
   `qwen38-4b-distill` control with every `QWEN_SPEC_*` variable unset:
   the checkpoint comparison, `roster.tsv`. Each request is graft's own
   summarize prompt and 24000-character clip at a 32768 reply cap (the
   installed graft's cap), with the full answer retained as
   `roster.tsv.<id>.<file>.json`, wall time in milliseconds, the HTTP
   status, and an outcome column that separates `stop`, `capped`,
   `context_exhausted` (prompt plus completion at the context size),
   `http`, `body`, `transport_*` and `launch_failed`. The `tool_call`
   column is the repaired probe: one completed `record_probe` call with
   `ok=true`, not the presence of the field name.
3. The control alone under `QWEN_SPEC_TYPE=draft-mtp` with one drafted
   token: the deployment comparison, `roster-4b-mtp.tsv`.

Until those files exist the device arms read `not run`, every row stays at
`validated_filled_depth -` with its rate fields at `-`, and the PR that
carries this directory stays a draft. A row that passes the screen still
needs a filled-depth arm at its cache, batch, template and request
configuration before its ceiling stands, and a router transition
measurement before its switch policy changes from `standalone-only`.
