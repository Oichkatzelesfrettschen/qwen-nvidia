# smollm3-3b

The chat template renders no tool_calls branch, which admit-candidate-static.py reads from the GGUF header before any download. The row completes no forced record_probe call and never calls record_symbols, so it produces no graph input.

Recorded 2026-09-19. The measurements are in
evidence/ada/agent-model-roster/WAVE2.md.
