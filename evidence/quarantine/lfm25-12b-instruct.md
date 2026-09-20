# lfm25-12b-instruct

The chat template renders no tool_calls branch, which admit-candidate-static.py reads from the GGUF header before any download. The row completes no forced record_probe call and never calls record_symbols, so it produces no graph input.

A template failure carries no device observation, so it names no failure
class in scripts/quarantine.tsv and the row is held out of the picker by
its registry tier and its standalone-only switch policy, the way
hammer21-3b is. This record stays as the evidence behind that tier.

Recorded 2026-09-19, moved out of the quarantine registry 2026-09-20. The
measurements are in evidence/ada/agent-model-roster/WAVE2.md.
