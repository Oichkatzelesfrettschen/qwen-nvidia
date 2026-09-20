# Promotion of configuration 192d0663a533

The serving closure carrying `patches/llama-server-tool-choice-object.patch`.
`tools/server/server-common.cpp` at f280b269 reads `tool_choice` through
`json_value(body, "tool_choice", std::string("auto"))`, which catches the
type error the OpenAI named-function object raises and returns `"auto"`, so
a client that forced one tool forced nothing and the server logged a
warning. The patch resolves that object to the tool list narrowed to the
named function under `"required"`, which is what the grammar enforces, and
refuses a name the request offers no tool for with a 400.

Built at `QWEN_CUDA_ARCHITECTURES=89-real`, the serving arm:
`cuda_payload=verified arch=89-real cubin=187 ptx=0`. Its CUDA library is
byte-identical to `de074f9738b8`'s; the patch touches the server alone.
`scripts/promote-llama-build.sh` read the arm off `build-configuration.tsv`
against the ledger's promoted row for the first time at this promotion.

Verified before promotion on the closure's own `llama-server` with
`Qwen3.8-4B-Q4_K_M` under `--jinja`, one tool offered:

| tool_choice | status | result |
| --- | --- | --- |
| `{"type":"function","function":{"name":"record_probe"}}` | 200 | `record_probe({"ok":true})`, `finish_reason=tool_calls` |
| `"required"` | 200 | the same call |
| `{"type":"function","function":{"name":"absent_tool"}}` | 400 | `tool_choice names a function the request offers no tool for` |
| `{"type":"function"}` | 400 | `tool_choice object must carry type "function" and function.name` |

The server log carries no `Wrong type supplied for parameter 'tool_choice'`
line across those requests. graft 0.18.0's installed adapter
(`dist/ai/llm/openai.js`), driven against the same server with a
`responseFormat` of kind `tool`, receives the call it asked for; against the
recording endpoint it sends the object form with one tool offered, which is
the request every prior closure read as `auto`.

`promotion.log` carries the gate: `strict_cuda=passed multimodal_cuda=passed
backend_set=cuda`. `serving-summary.tsv`, `device-lines.txt`, `teardown.log`
and the reply files are the router admission run through
`scripts/admit-cuda-router-serving.sh` after promotion, with the verdict
that rejects an unobserved placement or a teardown that returned residue.
Its `serving_device` row attributes a CUDA0 placement to each of the two
children by pid, and its teardown is two rows: `teardown` accepted on the
survivor checks (`torn down: no server, tmux session, ...; port 8080 free`),
and `teardown_exclusion` skipped by name, because the router parent never
holds the compute lease its children take, so its destroy reads `held=no`
and the drain record closes with `teardown_exclusion=not_established
teardown_reading=not_held`. Every promotion since `15bc632adf7f` read the
same thing and recorded `teardown accepted` over it, because the admission
dropped the teardown's exit status; the proof for router children is the
`llama-router-orderly-retirement.patch` lane.

`build-configuration.tsv` is the digest's own input record and
`artifact-manifest.tsv` the closure hashes promotion re-verified.
`build-payload.txt` is the architecture verdict.

Recorded 2026-09-20.
