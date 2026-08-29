# Qwen3.5-4B Serialized Vulkan Web Request

The real `Qwen3.5-4B-Q4_K_M.gguf` model completed one authenticated
OpenAI-compatible request through the Raven2 Web server. The request used a
34-token prompt, generated 16 tokens, and ran with CPU 0, nice 19, idle I/O,
LOW Vulkan queue priority, serialized Vulkan submissions, a 60% model duty
target, and the aggregate 75% GPU abort guard.

| Measurement | Result |
| --- | ---: |
| HTTP wall time | 31.103794 s |
| Prompt rate | 3.7939 tok/s |
| Decode rate | 0.6775 tok/s |
| GPU busy samples | 31 |
| Mean aggregate GPU busy | 49.65% |
| Maximum aggregate GPU busy | 72% |
| Model Vulkan buffer | 2,603.50 MiB |
| Vulkan context allocation | 102 MiB |
| Vulkan compute allocation | 7 MiB |

The 60% duty target inserts 40% idle time relative to the same serialized
submission stream. Removing only that sleep predicts 6.3232 prompt tok/s and
1.1291 decode tok/s. Those values retain fence serialization and are arithmetic
counterfactuals, not an executed profile.

The retained unpaced 32K run processed its first 512 prompt tokens at 26.04
tok/s with larger 512/128 batch settings. The serialized 60% Web profile reaches
14.6% of that prefill rate. After dividing out the duty sleep, the remaining
serialized, 128/32-batch, short-prompt profile reaches 24.3% of the earlier
rate. Prompt length and batch size differ, so that residual cannot be assigned
to serialization alone.

A standalone async-versus-serialized comparison remains unmeasured. The native
async path previously reached 97% aggregate GPU busy during warmup, which
violates the desktop guard. An admitted comparison needs a second mechanism
that holds aggregate GPU busy below 75% without fence serialization; otherwise
the comparison deliberately recreates the responsiveness failure.

The response ended at its 16-token limit while still emitting hidden reasoning,
so it contains no user-visible answer. This run admits the transport and timing
path, not response quality or daily usability.

Retained files:

- `request.metrics` contains client wall time and HTTP status.
- `response.json` contains exact server token counts and timings.
- `server.log` contains model placement, pacing activation, and server timings.
- `telemetry.log` contains the one-second resource samples.

`PRE_SANITIZATION_SHA256SUMS` records the remote server log hash before the
retained copy replaces the home path and masked API-key suffix. The exact raw
log remains on the laptop.
