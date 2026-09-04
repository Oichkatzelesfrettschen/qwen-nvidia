# The saving is one constant, the cost is another, and they cross at forty tokens

The pinned alternating campaign the first reading called for has run on all
three runtime classes under clock lock at 2835 MHz, five pairs per length at
three prompt lengths, control and subject alternating order inside every pair
and both served concurrently from one binary that differs only by
`--backend-sampling` on the subject's argv. `paired-pinned/` carries the nine
rows and `reach/` the six-arm reachability probe.

Three things the first reading left open are closed, and two of them close
against what it said.

## The class split was sample size

The first reading measured per-token savings of 0.229 ms on the 0.8B against
0.098 and 0.091 ms on the 2B and 4B, named a vocabulary or logit-width
difference as the falsifier, and left the 2.4-times split unexplained. Reading
the GGUF headers refutes that falsifier outright: `qwen35-08b`,
`qwen38-2b-distill`, and `qwen38-4b-distill` all carry 248320 tokens, so the
copied logit row is 993280 bytes and the scanned candidate array 248320 entries
on every class.

The pinned campaign then dissolves the split. The per-token saving is a
constant:

| model | fixed request cost | per-token saving | breakeven | decode ratio | IQR | drift |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| qwen35-08b | 6.60 ms | 0.1665 ms | 40 tokens | 1.0592 | 0.0021 | 0.0001 |
| qwen38-2b-distill | 6.98 ms | 0.1681 ms | 42 tokens | 1.0437 | 0.0029 | 0.0001 |
| qwen38-4b-distill | 8.67 ms | 0.1589 ms | 55 tokens | 1.0213 | 0.0016 | 0.0007 |

0.1589 to 0.1681 ms is a 5.8% spread across three checkpoints that differ four
times over in weight count, which is what a host cost proportional to one
248320-entry logit row predicts and what the first reading's 2.4-times split
did not. Six requests per arm at one server start on an unpinned card produced
that split. `paired-unpinned/` is the same 2B campaign with the clock free, and
its `control_drift` reads 0.1699 against a 0.1551 inter-pair range where the
pinned run reads 0.0001 and 0.0029; both runs' observations are retained, so the
two operating states are comparable row by row. The anomaly was the
instrument, and no mechanism is needed to explain it.

The ratios still differ by class, because the same constant divides a different
token: 0.166 ms against the 0.8B's 2.8 ms token is 5.9% and against the 4B's
7.8 ms token is 2.1%.

## The flag also costs a fixed amount per request

The subject arm's prefill is slower at every length on every class, and the cost
does not scale with the prompt:

| model | 128 tokens | 512 tokens | 2048 tokens |
| --- | ---: | ---: | ---: |
| qwen35-08b | +6.74 ms | +6.60 ms | +6.11 ms |
| qwen38-2b-distill | +7.41 ms | +6.98 ms | +6.30 ms |
| qwen38-4b-distill | +7.80 ms | +8.75 ms | +8.67 ms |

A sixteen-fold change in prompt length moves it by under a millisecond and the
three classes do not agree on the direction: the 0.8B and 2B fall as the prompt
grows and the 4B rises, which is why the cost is stated as flat within about a
millisecond rather than as a trend. It is not a per-position cost, and it is not
paid once per server either: every observation here follows the harness's own
warm-up request at the same shape on the same process. It recurs per request.

The mechanism is unisolated. The leading hypothesis is the per-task arming at
`tools/server/server-context.cpp:1705`, where each accepted task calls
`llama_set_sampler` with the slot's chain and `llama_context::set_sampler`
(`src/llama-context.cpp:3811`) rebuilds the sampling nodes the forward graph
carries. Its falsifier is a request that reuses a slot's armed sampler: a
`cache_prompt` request or a second turn on one slot should pay the cost once
rather than again, and if it still pays per request the arming is not the site.
That arm is unrun.

## Cost and saving cross at forty generated tokens

The two constants give a rule rather than a rate. Whole-request gain at a
512-token prompt:

| model | 32 tokens | 64 | 128 | 256 | 512 |
| --- | ---: | ---: | ---: | ---: | ---: |
| qwen35-08b | -1.09% | +1.90% | +3.63% | +4.55% | +5.04% |
| qwen38-2b-distill | -1.00% | +1.31% | +2.65% | +3.38% | +3.76% |
| qwen38-4b-distill | -1.13% | +0.26% | +1.09% | +1.55% | +1.78% |

A reply under forty tokens is slower with the flag on. Above it the gain climbs
toward the decode ratio and reaches it only as the fixed cost amortizes.

**No default moves.** On decode alone the 0.8B clears the 5.1% floor at all
three lengths, 1.0571 to 1.0592 with an inter-pair range under 0.4% and a
control drift under 0.2%, which is the tightest paired reading this tree holds.
On the whole request it clears nothing: 5.04% at five hundred generated tokens
is the best figure any class reaches at any length measured, and the appliance's
`fast-text` default is the class whose replies are shortest. Promoting a flag
that costs a percent on a short reply to buy five on a long one is a scheduling
decision about reply length rather than a device measurement, and this record
makes the trade explicit instead of resolving it.

Token and content digests agree between the arms at every length on every class,
nine rows with no divergence, which repeats the first reading's identity result
under the pinned campaign.

## Which requests the flag reaches

Three gates take the server default away per request, and the six-arm probe in
`reach/` predicted each one and read what the server did. All six agree.

| request shape | gate | reaches backend sampling |
| --- | --- | --- |
| `/completion`, plain | none | yes |
| `/completion` with `n_probs` | `need_pre_sample_logits` | no, silently |
| chat, `enable_thinking` true | none | yes |
| chat, the Web UI's thinking-off body | none | yes |
| chat with `reasoning_budget_tokens` | reasoning budget | no, warned |
| chat with `response_format` JSON schema | grammar | no, warned |

The first reading named the Web UI's structured output and the vision review's
JSON schema as the paths to check, and predicted that a thinking-off turn would
lose the flag. The vision review does lose it: `scripts/image-review.py` sends
`response_format`, the server converts it through `json_schema_to_grammar`, and
`common/sampling.cpp:415` disables backend sampling on the grammar. The
thinking-off turn does not. `webui/index.html:2505` sends `reasoning_budget: 0`
beside its `chat_template_kwargs`, and this server registers that field as
`reasoning_budget_tokens` (`tools/server/server-schema.cpp:383`) with no alias,
so the key is ignored: the `chat-thinking-off-webui` arm read
`reasoning budget: tokens=-1` and answered "Blue." with no reasoning content
while the thinking-on arm produced a reasoning span, so the template argument is
what turns reasoning off and the second field changes nothing. The page's own
comment already calls that field a fallback "on builds that read the OpenAI-side
field instead"; on this build it is inert rather than redundant.

The third gate is the one no reading can see. `server-context.cpp:1697`
computes `need_pre_sample_logits` from `n_probs > 0 && !post_sampling_probs` and
clears `use_backend_sampling` at line 1702 with no log line, while
`server-task.cpp:84` echoes `task.params.sampling.backend_sampling` -- the value
the request asked for, not the value the slot used. `llama_context` prints
`setting backend sampler` once at context creation rather than per request.
Positive evidence that a given request sampled on the device therefore does not
exist: the arming line proves the server was launched with the flag, and the two
warnings prove a request lost it. `scripts/probe-mmvq-tail-logit-margin.sh`
sends `n_probs: 4` and takes this gate.

## What this campaign is not

Every observation ran under the ownership lock with the state latch clear and
the SM clock pinned at 2835 MHz, and the desktop held its standing client set
throughout. `run-mmvq-width-request-tails.sh` admits its observations through
the ownership authority and the latch rather than through
`scripts/gpu-quiescence-gate.sh`, which `run-mmvq-paired-crossover.sh` carries;
the clock lock is what holds the operating state here, and the drift and range
figures beside every row are what state a reader checks.

The requests are single-turn `/completion` at temperature 0 with `top_k` 1 and
`cache_prompt` false, one sequence at a time, so the forty-token crossover is
measured for an uncached single-turn request and states nothing about any other
shape. A served conversation reuses the slot and its prefix, and if the fixed
cost attaches to per-task arming rather than to the prefill it may be paid once
per slot there rather than once per turn, which moves the crossover as well as
the mechanism. That is the same unrun arm the section above names, and it bounds
the rule rather than only its explanation.
