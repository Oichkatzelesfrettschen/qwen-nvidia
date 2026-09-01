# Filled-depth validation on the CUDA serving path

`scripts/probe-filled-depth.sh` is the text-row sibling of
`scripts/probe-depth-projector.sh`: llama-server standalone at the row's own
cache triple and submission geometry under strict CUDA0 placement with the
CPU fallback refused, a padding prompt converged into the asymmetric window
`DEPTH - 2% <= prompt_n <= DEPTH - 32` through `/tokenize` plus one
template-overhead probe, and a decode that must retrieve a passphrase
planted at the head of the fill, so the arm proves execution and long-range
attention rather than allocation alone.

Six arms, each at its registry ceiling under `q8_0`/`q4_0` cache, Flash
Attention on, batch 2048, ubatch 512, on the promoted 88681bf4d161 binary.
The qwenseer-2b arm gates the coding lane: the WebUI coding default
requires 32768 or deeper, and its validated 65536 covers that floor. The
qwen25-coder-7b arm first ran inside its own admission chain with no
`QWEN_PROBE_DEPTHS` override, so it filled the entry boilerplate ceiling
of 8192 rather than the row's declared `context_target`; `depth-8k-rca.md`
traces that circular default. The re-run at 32768 fills 32539 of 32768
and retrieves the needle, so the deep coder validates at 32768 -- the
depth Qwen Code's own 16-18k-token opening request needs -- and the 8192
row stays a valid earlier arm:

| model | depth | prompt_n | needle | health |
| --- | ---: | ---: | --- | --- |
| qwen38-2b-distill | 65536 | 65197 | retrieved | healthy |
| qwen35-08b | 65536 | 65197 | retrieved | healthy |
| qwen38-4b-distill | 32768 | 32577 | retrieved | healthy |
| qwen38-9b-distill | 24576 | 24415 | retrieved | healthy |
| qwenseer-2b | 65536 | 65197 | retrieved | healthy |
| qwen25-coder-7b | 32768 | 32539 | retrieved | healthy |

Each arm's directory holds its summary, its emitted ledger row, its raw
result fields, and the server log. The rows joined
`scripts/validated-tuples.tsv` as `validated` and the six `models.tsv`
rows now claim these depths in `validated_filled_depth`, which
`scripts/check-validated-tuples.sh` checks on every gate run
(`checked=6`). The prior host's geometry-versus-depth finding remains
prior-host comparison; only the 2048/512 geometry is measured here, so a
second geometry per class is the open extension.
