# Backend sampling exists, holds token identity on all three classes, and pays on the smallest

`--backend-sampling` is not a feature to build. This tree already implements
device-side sampling as graph nodes: `llm_graph_context::build_sampling`
(`src/llama-graph.cpp:3711-3813`) splices `ggml_argmax` for greedy,
`ggml_top_k`, and a `ggml_soft_max` / `ggml_cumsum` inverse-CDF draw into the
forward pass, with a `backend_apply` for temperature, top-p, min-p, penalties,
and logit bias beside them. The flag is off by default
(`common_params_sampling::backend_sampling = false`, `common/common.h:295`) and
`QWEN_BACKEND_SAMPLING=1` already carries it through
`qwen-capacity-policy.sh:1112`. The draft side already defaults it on
(`common/common.h:331`), so every MTP speculation arm this tree has run used
device sampling on the draft while the target sampled on the host.

What it removes from the per-token path is two things. `needs_raw_logits`
(`src/llama-context.cpp:1618-1633`) is true with no backend sampler armed, so
`llama_context::decode` issues a 993280-byte device-to-host copy of the
248320-entry logit row per token (`src/llama-context.cpp:1873`); and
`common_sampler_sample` then builds a `llama_token_data` per vocabulary entry
and walks a chain whose every member scans or partially sorts that array
(`common/sampling.cpp:607-646`). At temperature 0 there is no short circuit:
`llama_sampler_temp_impl` masks every logit but the maximum to `-INFINITY`
(`src/llama-sampler.cpp:271-284`) and the chain-ending `dist` sampler still
runs its cumulative-sum draw over the collapsed distribution.

## Identity holds on all three classes

`run-closure-identity-ab.sh` ran the promoted closure `88681bf4d161` against
itself, control and subject differing by `--backend-sampling` alone, in the
repository's runtime-class order. Each run is control, subject, control again
over six state-carrying prompts at 256 greedy tokens:

| model | subject divergences | control divergences | placement |
| --- | ---: | ---: | --- |
| qwen38-2b-distill | 0 | 0 | same |
| qwen35-08b | 0 | 0 | same |
| qwen38-4b-distill | 0 | 0 | same |

Eighteen prompt comparisons, no divergence, every closing control agreeing with
its opening arm. The subject arm's own log carries `llama_context: setting
backend sampler for seq_id 0`, and neither control arm carries it, so the flag
reached the arm it was meant to and the identity is a result rather than an
artifact of an ignored argument.

Device `ggml_argmax` and a host scan for the maximum logit agree except on
exact ties, and no tie arose across these eighteen replies. That is what the
gate measures; it does not promise the two never disagree.

## The rate splits by class

Read from llama.cpp's own `eval time` lines in each arm's server log rather
than from stream timing, six 256-token generations per arm, the two control
arms bracketing the subject so drift is visible:

| model | control tok/s | subject tok/s | delta | control drift |
| --- | ---: | ---: | ---: | ---: |
| qwen35-08b Q8_0 | 295.02 | 316.37 | +7.24% | -0.25% |
| qwen38-2b-distill Q4_K_M | 225.28 | 230.38 | +2.26% | -0.64% |
| qwen38-4b-distill Q4_K_M | 112.32 | 113.48 | +1.03% | -1.08% |

The 4B's gain is inside its own control drift and states nothing. The 2B's
exceeds its drift and falls short of the 5.1% promotion floor this tree set in
`../mmvq-q8-b17-b20/`. The 0.8B clears that floor at 7.24% against a 0.25%
drift, which makes backend sampling a candidate for that class's profile rather
than a tree-wide default -- the disposition the repository's runtime-class rule
already names for a win on one class alone.

Per token the saving is 0.229, 0.098, and 0.091 ms. A cost removed from the
host path should be roughly fixed per token, and the 2B and 4B agree with each
other at about 0.09 ms while the 0.8B saves 2.4 times that. The mechanism as
described does not predict the 0.8B's extra 0.13 ms and this record does not
explain it. Its falsifier is a vocabulary or logit-width difference between the
Qwen3.5 0.8B and the Qwen3.8 distills, which would change the copied bytes and
the scanned array together; that comparison is unrun.

## What this measurement is not

Six requests per arm and one server start per arm is a smaller sample than the
pinned alternating campaign `run-mmvq-paired-crossover.sh` requires, and no
quiescence gate admitted these observations. The result is a candidate reading
that justifies a campaign, not a promotion. `--backend-sampling` therefore
changes no default here.

`common/sampling.cpp:391-399` disables backend sampling automatically when a
grammar or a reasoning budget is active, so an admission has to state which
requests it reaches. The Web UI's structured-output paths and the vision
review's JSON schema are the ones to check first.

## Where the ceiling comes from

`../decode-node-trace/` partitioned a decode token and found it 90.6 to 93.8%
device-busy, with host computation outside every CUDA call at 0.8 to 1.2%. That
partition ran under llama-bench, which samples nothing
(`tools/llama-bench/llama-bench.cpp:2143-2162` calls `llama_decode`,
`llama_synchronize`, and `std::rand()`), so it bounded the submission path
rather than the sampler. The served arms here are what measures the sampler,
and the two agree in scale: what backend sampling removes is a fraction of a
token that is otherwise almost entirely device execution.
