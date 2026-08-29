# Qwen3.8-4B Distill Against the Qwen3.5-4B Base

`empero-ai/Qwen3.8-4B-Distill` is a full-parameter distillation of Qwen3.8
2.4T A95B into the Qwen3.5-4B architecture, so the pinned llama.cpp build that
already loads Qwen3.5-4B loads it without a rebuild. Both checkpoints travel
`remote/compare-model-candidate.sh`, which drives the guarded launch path, one
chat request with reasoning suppressed, one with reasoning enabled, and a
teardown that captures the per-device memory breakdown llama-server prints as
it releases the context. A difference between two runs is therefore a
difference between two models.

Artifact pinning lives in `remote/download-qwen38-4b-distill-q4km.sh`:
revision `391fc7d103e3942a408def3e4f51c2f85d464417`, 2,783,446,304 bytes,
SHA-256 `dec96e8cf2e11b613bb46513dec485377f9ca5a351e71712ee0e244f287c6790`,
matching the repository's published `SHA256SUMS`.

## Measured

The base carries a projector and the distill does not, so the base runs twice:
once as deployed and once with the projector withheld. Only the text-only
column is a like-for-like comparison against the distill.

| Property | base, vision | base, text-only | distill |
| --- | ---: | ---: | ---: |
| Weight bytes | 2,740,937,888 | 2,740,937,888 | 2,783,446,304 |
| Prefill tok/s, 32-token prompt | 17.70 | 18.10 | 17.80 |
| Decode tok/s over a 301 or 227 token span | 2.537 | 2.563 | 2.721 |
| Vulkan0 `self` | 2,974 MiB | 2,974 MiB | 2,943 MiB |
| Vulkan0 `unaccounted` | 2,102 MiB | 1,218 MiB | 1,257 MiB |
| Vision modality reported by `/props` | true | false | false |
| Probe frames inside one 60 Hz budget | 99.87% | -- | 99.96% |

All three answered "9.9 is larger than 9.11" correctly with reasoning in
either state.

The projector costs 1.0% of decode, so the distill's 6.2% advantage over the
base measured text-only is a property of the checkpoint rather than of the
vision encoder's absence. It also costs no itemized Vulkan memory: `self` is
2,974 MiB with the projector and without it, since the CLIP context allocates
outside the model buffer llama-server itemizes. The cost appears as an
884 MiB rise in `unaccounted` between two runs whose `self` figures are
identical, which agrees with the 672 MB projector file plus the 223 MiB
compute reservation the vision path prints at load. Vision therefore places
the deployed configuration at roughly 3,858 MiB against the 4,608 MiB
preflight gate, which is the confirmation that gate never had.

## The chat template survives the distillation

`chat_template_kwargs.enable_thinking` still gates the `<think>` span in the
distill: the suppressed request returned no `reasoning_content` and the enabled
request returned one. The WebUI reasoning toggle therefore keeps working across
the swap. A distillation that shipped its own template could have dropped that
gating while every throughput figure stayed identical, so this is checked
directly rather than inferred from the model card.

## The distill is text-only

The `empero-ai/Qwen3.8-4B-Distill-GGUF` repository publishes five quantizations
and no projector, and `/props` reports `vision: false` under the distill. A
projector encodes images into the embedding space of the checkpoint that
exported it; a foreign projector of matching dimensions loads without error and
places image tokens where the language model does not read them, which is a
wrong answer rather than a failure. `remote/qwen-launch.sh` searches for the
projector in the model's own directory, so a checkpoint published without one
runs text-only instead of borrowing another model's.

## Reasoning span across five prompts

`remote/reasoning-span-probe.sh` drives five fixed prompts with reasoning
enabled and a 2,048-token ceiling. One deterministic generation reports what a
model does with one sentence; five report how long it reasons.

| Prompt | base tokens | distill tokens |
| --- | ---: | ---: |
| Decimal comparison | 540 | 227 |
| Elapsed time between two clock readings | 1,109 | 632 |
| Percentage discount | 502 | 359 |
| Capital of Australia, with a reason | 2,048 | 568 |
| 17 percent of 350 | 675 | 325 |
| **Total** | **4,874** | **2,111** |
| **Wall clock for the set** | **1,997.2 s** | **737.0 s** |
| Mean decode tok/s | 2.455 | 2.887 |

The distill reasons shorter on every prompt and finishes the set in 12.3
minutes against 33.3, a 2.71-fold reduction in wall clock. Its higher mean
decode rate is not independent of that: a shorter span keeps the KV cache
shallower for most of the generation, so part of the 17.6% rate difference is
an effect of the token count rather than a separate advantage. The isolated
rate comparison over matched spans is the 2.563 against 2.721 measured above.

Four answers are identical and correct in both models. The fifth is not: the
base spent its entire 2,048-token budget inside the reasoning span and emitted
**no answer at all** after 830 seconds, while the distill answered correctly in
568 tokens. On a machine where a token costs 0.4 seconds, a reasoning span that
fails to terminate is a failure to answer, and this set found one in five
prompts.

## Quality is the publisher's measurement, not this repository's

The model card reports mmlu CoT 0.354 to 0.553 and gsm8k_cot 0.850 to 0.785
against the base. That is a trade, not an upgrade, and it lands on opposite
sides of a homework workload. This hardware cannot settle it: at 2.7 decode
tok/s with a 227-token reasoning span, one gsm8k item costs roughly 90 seconds,
and separating 0.850 from 0.785 at conventional significance needs several
hundred items per model -- a run of about a day per checkpoint. A 20-item or
60-item sample has a standard error wider than the 6.5-point difference it
would be asked to resolve, so it would report noise as a verdict.

Three of the five prompts above are arithmetic and both models answered all
three correctly, which is consistent with parity and far too small to weigh
against a 6.5-point published difference.

The base model remains the default. The distill is available by argument:

```sh
QWEN_MODEL_PATH=$HOME/models/Qwen3.8-4B-Distill-GGUF/Qwen3.8-4B-Q4_K_M.gguf \
    remote/qwen-launch.sh
```
