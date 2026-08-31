# Filled-depth validation on the CUDA serving path

`scripts/probe-filled-depth.sh` is the text-row sibling of
`scripts/probe-depth-projector.sh`: llama-server standalone at the row's own
cache triple and submission geometry under strict CUDA0 placement with the
CPU fallback refused, a padding prompt converged into the asymmetric window
`DEPTH - 2% <= prompt_n <= DEPTH - 32` through `/tokenize` plus one
template-overhead probe, and a decode that must retrieve a passphrase
planted at the head of the fill, so the arm proves execution and long-range
attention rather than allocation alone.

Four arms, one per runtime class, each at its registry ceiling under
`q8_0`/`q4_0` cache, Flash Attention on, batch 2048, ubatch 512, on the
promoted 88681bf4d161 binary:

| model | depth | prompt_n | needle | health |
| --- | ---: | ---: | --- | --- |
| qwen38-2b-distill | 65536 | 65197 | retrieved | healthy |
| qwen35-08b | 65536 | 65197 | retrieved | healthy |
| qwen38-4b-distill | 32768 | 32577 | retrieved | healthy |
| qwen38-9b-distill | 24576 | 24415 | retrieved | healthy |

Each arm's directory holds its summary, its emitted ledger row, its raw
result fields, and the server log. The rows joined
`scripts/validated-tuples.tsv` as `validated` and the four `models.tsv`
rows now claim these depths in `validated_filled_depth`, which is the first
state `scripts/check-validated-tuples.sh` has had rows to check on this
host (`checked=4`). The prior host's geometry-versus-depth finding remains
prior-host comparison; only the 2048/512 geometry is measured here, so a
second geometry per class is the open extension.
