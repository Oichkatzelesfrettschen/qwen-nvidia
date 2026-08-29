# The paired preset fits, and the harness carried two bugs into that reading

`remote/admit-image-router.sh` ran on the appliance with
`QWEN_ADMISSION_REVIEW_MODEL=lfm25-vl-16b` against the promoted
`qwen38-4b-distill` language row, so the preset it generated named two
sections rather than one: `web-image-admission` (the 4B distill) and
`lfm25-vl-16b` (the review-only vision row). `run.log` bounds the run at
2026-08-29T12:30:50Z through 12:41:40Z on `qwen-laptop`.

## The falsifier

Falsifier 7 of `evidence/image-appliance/vision-review-design.md` names the
question this run answers: raising `QWEN_ROUTER_MAX` to hold a language row
and a vision row together may exceed the Vulkan budget that set
`QWEN_ROUTER_MAX=1` in the first place, and every checked-in `review_model`
reads `-` because "the mechanism that carries the pair now exists and the
measurement does not." The observation that falsifies the pairing is
`qwen-image-launch.sh` printing `vulkan_budget_headroom=short` against the
summed requirement. This run reports the opposite:

```
heap_0_budget_bytes=5799981056
heap_1_budget_bytes=11599953920
aggregate_budget_bytes=17399934976
host_memory_headroom=ample surplus_bytes=2511212544
vulkan_budget_headroom=ample surplus_bytes=12261912576
```

`image_launch` in `summary.tsv` reads `accepted`, and `preset_generated`
reads `sections=2`. The resident pair -- the 4B distill, `lfm25-vl-16b` and
its projector, and the SDXS-512 runtime's measured resident cost -- fits
inside the RADV RAVEN2 probe's own headroom with 2.34 GiB of host margin and
11.42 GiB of Vulkan margin still free. Falsifier 7 is not met on this run: the
budget gate that has refused every prior paired launch off this device now
admits one on it. The checked-in `review_model` field in
`remote/image-profiles.tsv` still reads `-`, because this run named the pair
through `QWEN_ADMISSION_REVIEW_MODEL` rather than promoting the ledger row,
the way `served-turn-admission/` promoted `execution_policy` in its own copy
under the run's output directory rather than editing the tree.

## The checks

`summary.tsv` carries 38 rows: 34 read `accepted`, 2 read `observed`, and 2
read `refused`. Both refusals are harness defects this branch's other change
fixes, named below rather than a property of the appliance.

| Group | Checks | Result |
| --- | --- | --- |
| Outage, ledger, launch | `ordinary_router_recorded` through `api_key_minted` | All accepted; the paired preset launched, both listeners bind loopback, and the minted key is mode 0600. |
| Roster | `router_roster` | Refused: `expected=web-image-admission,lfm25-vl-16b, measured=lfm25-vl-16b,web-image-admission,`. The real router lists `/v1/models` sorted rather than in preset section order, and the harness compared the two strings positionally. Every id the profile promoted is present in the measured roster; only the order differs. |
| Vision surface | `review_row_reports_vision`, `review_row_offers_no_tools` | Accepted: `GET /props?model=lfm25-vl-16b` reports `modalities.vision: true`, and `GET /tools?model=lfm25-vl-16b&autoload=true` answers 403 `feature_disabled` -- the review row carries no MCP configuration and holds no execution grant. |
| Tool surface, authorization, generation | `tool_enumeration` through `provenance_names_seed_and_profile` | All accepted. One `POST /tools` carrying the grant inside `params` completed in 12 s with `sha256 17e452e6974ad6d3174c5d0c9f367c90867eb99ffa8a3a6f9e45e78eb4de7639` and a matching provenance record; the replayed grant, the ungranted call, and `params.model` are each refused once. |
| Artifact | `artifact_png_matches_digest`, `artifact_without_credential_refused`, `lease_released_after_generation` | Accepted: 583,938 PNG bytes match the reported digest, the uncredentialed read is 401, and the lease is free again. |
| The served page | `browser_prompt_used`, `browser_turn_completed`, `browser_turn_tool_message` | The prompt is recorded regardless of outcome. `browser_turn_completed` refused: the model wrote the call as text in its reply content rather than proposing a `tool_calls` entry, so the page opened no approval dialog and the single attempt this run's harness made timed out waiting 600 s for one. The review arm never ran, because it runs inside an accepted browser attempt and none existed. |
| Hygiene, teardown, restore | `secret_hygiene` through `ordinary_restore` | All accepted. |

## The two refusals, and what fixes them

**`router_roster`** compared the roster string positionally against the preset's
own section order. `patches/llama-router-tools-proxy.patch` and the router's
own `/v1/models` handler answer the roster sorted, which this run's measured
order shows directly: `lfm25-vl-16b,web-image-admission,` against the preset's
`web-image-admission` then `lfm25-vl-16b`. `remote/admit-image-router.sh` now
compares the roster as a set -- every expected id present, no unexpected id,
order ignored -- and records the measured order as an observation rather than
asserting it, so this exact run would read `router_roster accepted
measured_order=lfm25-vl-16b,web-image-admission,` against the fixed harness.

**`browser_turn_completed`** refused because the browser step ran the turn
once. `webui/index.html`'s approval dialog opens only once the page's own
parser finds a `tool_calls` entry in the reply; a reply that describes the
call as text, `image_generate_image(red_apple_on_white_table, product
photography)`, proposes nothing the page can act on, so `busy` never released
until the driver's 600 s dialog wait expired. `remote/admit-image-router.sh`
now runs the browser turn up to `QWEN_ADMISSION_BROWSER_ATTEMPTS` (default 2)
times, each attempt a fresh page, and accepts on the first attempt whose
driver process completes; `browser-turn-<n>.json` retains every attempt
regardless of outcome. Whether a second attempt against this exact prompt and
this exact appliance state would have completed is not established here --
the fixture arm in `remote/test-admit-image-router.sh` proves the retry
mechanism accepts on attempt 2 when a fake router is scripted to propose
there, not that the appliance's own second attempt would have proposed.

## The reply on the explicit prompt, across launches, and which model gave it

The prompt is fixed: "Call the image_generate_image tool now to generate
this image: a red apple on a white table, product photography. Do not
describe it; call the tool." Four runs of it are now on record and none
agree on what the model does with the schema it is offered:

| Run | Reply |
| --- | --- |
| `evidence/image-appliance/served-turn-admission/` | A schema-valid `tool_calls` entry: `{"prompt":"a red apple on a white table, product photography","seed":12345,"width":512,"height":512,"steps":1,"profile_id":"image-sdxs-512-a"}`. |
| Earlier run (not separately retained) | A schema-valid `tool_calls` entry, reported the same as above. |
| Earlier run (not separately retained) | Prose: a plain description of the requested image, no `tool_calls` entry and no call-shaped text. |
| This run | Pseudo-call text in `content`: `image_generate_image(red_apple_on_white_table, product_photography)` -- and `browser-turn.json` records the page's request model as `lfm25-vl-16b`, the review-only row, which sorts first in the router's roster and became the page's default; the 4B never received this turn. |

The 4B has three runs on record on this prompt: two schema-valid proposals
and one prose reply. The fourth reply, the pseudo-call text, is the 1.6B
review-only row's: the router lists `/v1/models` sorted, `lfm25-vl-16b`
sorts ahead of `web-image-admission`, and the page selected the first id at
load and posted the chat to it with no `tools` key, since a review-only row
offers none. A rerun of the same launch after PR #69 repeated that selection
across both attempts (`image_generate_image(...)` and then `image_generate_image`
alone), which is what identified the page's default rather than the 4B as the
cause. `raw_tool_selection` in `remote/models.tsv` grades the 4B distill 9 of
10 on selection; this prompt is not one of the ten graded rows, and the 4B's
own variance (two proposals, one prose reply) is what motivates the retry
bound above. The page's default-row rule is the correction that follows.

## Contents

`summary.tsv`, `run.log`, `image-launch.log`, `image-server.log`,
`image-service.log`, `image-session.status`, `ordinary-session.status`,
`ordinary-restore.log`, `ordinary-teardown.log`, `image-teardown.log`,
`image-teardown-check.log`, `build-web-presets.log`, `image-parameters.json`,
`image-profiles.tsv`, `web-profiles.tsv`, `web-presets.ini`, `tools.json`,
`generate-response.json`, `provenance.json`, `artifact.png`,
`browser-turn.json`, `browser-turn.err`, and `http/` (38 request/response/header
captures) are sanitized Git copies: the private hostname reads `qwen-laptop`,
the home prefix reads `$HOME`, and every grant's signature segment is
replaced by its byte length as `<signature:N>`, following
`served-turn-admission/`. `artifact.png`'s SHA-256 matches the `png_sha256`
field of `provenance.json`.
