# One page session generates an image and reviews it, and the review costs more than the generation

`remote/admit-image-router.sh` ran the paired image path on the appliance with
`QWEN_ADMISSION_REVIEW_MODEL=lfm25-vl-16b` against the promoted
`qwen38-4b-distill` language row. `run.log` bounds the run at
2026-08-29T13:53:31Z through 13:57:18Z on `qwen-laptop`, after PRs #69, #70,
and #71 repaired the roster comparison, the reply attribution, and the page's
default row. `admit_image_router` reads `accepted`, and `remote/image-profiles.tsv`
now carries `review_model=lfm25-vl-16b` on `image-sdxs-512-a` because of it.

## The deviation

Falsifier 4 of `evidence/image-appliance/vision-review-design.md` is met: "a
review whose wall time exceeds the generation's makes a correction loop cost
three generations plus three reviews." The review took 19.44 s against the
generation's 11.62 s, a ratio of 1.67.

Both remedies that falsifier names are unavailable on this measurement.
Moving the default vision row has nowhere to go: `lfm25-vl-16b` decodes at
15.87 tok/s in `remote/models.tsv` where the other two projector-validated
rows read 9.43 and slower, so it is already the fastest reviewer the roster
offers. Lowering the reply budget reaches 4.67 s of the 19.44: the reply is 78
tokens at 16.48 tok/s, and the other 14.77 s is prompt evaluation of the
570-token multimodal prompt, of which the two 128-token image batches alone
decoded in 1.245 s and 1.665 s. A zero-token reply would still cost 14.77 s,
above the 11.62 s the image took. The review's cost is the image the reviewer
reads rather than the verdict it writes, which is the term the falsifier's
remedies do not reach.

The consequence is a bound on the correction loop rather than on the review.
One review after one generation costs 1.67 generations; the design's own cap
of two approved corrections makes the worst case three generations plus three
reviews, about 93 s of device time against 35 s of generation. No correction
ran here, so what a correction's own review costs is unmeasured. The registry
rate reproduces: 16.48 tok/s decode against the row's recorded 15.87 is 3.8%
apart, inside the roughly 4% this machine carries on identical flags.

## The falsifier the run answers

One page session carries an approved generation and a vision review of that
same artifact, with the language model holding no authority over its own
arguments and the reviewer holding no tools. Four observations refute it.
A generation that completes without a grant, with a spent grant, or with a
grant naming another image profile puts the authority in the caller rather
than in the approval. A `POST /tools` whose routing key survives into the tool
arguments puts the transport inside the argument set the schema closes. A
review request carrying a `tools` key offers the reviewer an executable
surface the design withholds. A verdict retained in `history` puts
image-derived text into every later chat request. None was observed:
`grant_replay_refused`, `generation_without_grant_refused`,
`grant_wrong_image_profile_refused`, and `routing_key_outside_arguments` each
fired once, `browser_review_offers_no_tools` reads `posts=1 tools_key=0`, and
`browser_review_stays_out_of_history` reads that the transcript carries no
verdict text.

`summary.tsv` carries 48 rows: 45 read `accepted` and 3 read `observed`.
The three observations are `browser_prompt_used`, `browser_attempt_1_result`,
and `browser_review_verdict`, which record what the run produced rather than
judge a property. No row reads `refused` or `skipped`.

## The budget

The pair fits, and the line the launch prints says by how much:

```
image_launch budget artifacts_mib=3908 runtime_mib=480 required_mib=4388 sections=2
host_memory_headroom=ample surplus_bytes=2563063808
vulkan_budget_headroom=ample surplus_bytes=12261912576
```

`artifacts_mib=3908` is the 4B distill, `lfm25-vl-16b`, and its projector
summed; `runtime_mib=480` is the SDXS-512 runtime's measured resident cost.
The RADV RAVEN2 probe answers the 4388 MiB requirement with 11.42 GiB of
Vulkan margin and 2.39 GiB of host margin still free, and the subsequent load
of both sections is the fit test that report does not perform. Falsifier 7 of
the design -- a two-section preset that does not fit -- is unmet a second time,
and the second observation it named, "the second load failing after an ample
report", is also unmet: both sections served requests in this run, the
language child on internal port 51841 and the review child on 49219.

## The review verdict

`lfm25-vl-16b` returned one constraint and passed it:

```
pass prompt_subject: A red apple on a white table, product photography.
composition change required: no
```

The page derives `prompt_subject` from the prompt the human approved and adds
`negative_prompt_absent` only where the approval carried a negative prompt, so
`constraints=1` is the whole declared list rather than a truncated one. The
verdict asked for no regeneration and the card said so, which is why no
correction ran and the cap stayed untested on the appliance.

Faithfulness is not established by this row. The image is a red apple on a
white surface and the verdict says so, but falsifier 3's image-withheld
control -- the same review with the image parts removed and the multipart text
retained -- did not run, so a verdict answering from the constraint text alone
would read identically here. That control remains the way to separate them.

## The checks, in the eleven phases the harness runs them in

| Phase | Checks | Result |
| --- | --- | --- |
| 1. The ordinary router, as found | `ordinary_router_recorded`, `ordinary_teardown` | Accepted. The harness records the ordinary router's server path, tears it down, and proves no residue before it claims the device. |
| 2. Test inputs | `image_ledger_promoted`, `image_runtime_present`, `image_parameters_written`, `preset_generated` | Accepted. One ledger row moves to `validator-gated` with `review_model=lfm25-vl-16b` in a copy under the output directory, `sd-cli` is present, and the generator emits `sections=2`. |
| 3. Launch the image router | `image_launch`, `artifact_listener_loopback`, `image_service_recorded`, `router_listener_loopback`, `api_key_minted` | Accepted. The deadline stack proves ordered at runtime 300 s, service 330 s, MCP 360 s, proxy 3600 s, and page 660 s; the router binds 127.0.0.1:8080 and the artifact listener 127.0.0.1:53147; the minted key is mode 0600. |
| 4. Roster, vision surface, tool surface | `router_roster`, `review_row_reports_vision`, `review_row_offers_no_tools`, `tool_enumeration`, `web_tools_absent`, `tools_unknown_model_refused` | Accepted. The roster compares as a set and records `measured_order=lfm25-vl-16b,web-image-admission,`; `GET /props?model=lfm25-vl-16b` reports a vision modality and `GET /tools` for the same id answers 403 `feature_disabled`; the language row lists `image_generate_image` alone; an unknown model is 400. |
| 5. Broker session and one grant | `broker_signs_image_profile`, `session_secret_issued`, `grant_issued`, `grant_wrong_image_profile_refused` | Accepted. The broker signs for `image-sdxs-512-a`, issues one session secret, signs a 614-byte grant over seed 20260829, and refuses a foreign image profile at 400. |
| 6. One generation and the refusals after it | `generation_completed`, `result_carries_identity_alone`, `grant_replay_refused`, `generation_without_grant_refused`, `routing_key_outside_arguments` | Accepted. The curl replay completed in 12 s with `sha256 17e452e6...`; the reply carries status, digest, and route alone; the spent grant, the ungranted call, and `params.model` are each refused once, the last by name as an argument the tool does not read. |
| 7. The artifact | `artifact_png_matches_digest`, `artifact_without_credential_refused`, `provenance_names_seed_and_profile`, `lease_released_after_generation` | Accepted. 583,938 PNG bytes match the reported digest, the uncredentialed read is 401, the record names seed 20260829 and `image-sdxs-512-a`, and the Vulkan workload lease is free again. |
| 8. The served page, generation and review | `browser_prompt_used`, `browser_attempt_1_result`, `browser_page_origin`, `browser_dialog_names_bound_seed`, `browser_grant_posted_once`, `browser_generation_via_router`, `browser_requests_stay_on_known_origins`, `browser_artifact_fetched`, `browser_transcript_carries_identity_alone`, `browser_review_rendered`, `browser_review_verdict`, `browser_review_stays_out_of_history`, `browser_review_offers_no_tools` | Ten accepted and three observed, on the first attempt. `browser_prompt_used`, `browser_attempt_1_result`, and `browser_review_verdict` record what the run produced. The page selected `web-image-admission` -- the driver's `--model` and the row that offers tools -- proposed a schema-valid call inside every bound, showed its own seed 12345 before approval, posted one grant, generated through the router, fetched the artifact into a blob, then rendered `reviewed by lfm25-vl-16b constraints=1` on the card. Every request named `http://127.0.0.1:8080`, `:8571`, or `:53147`. |
| 9. Secret hygiene | `secret_hygiene` | Accepted. The API key, the grant, the session secret, and the prompt text are absent from process images, logs, session status, and provenance; the runtime argv retains the prompt as `sha256:c59aebad...`. |
| 10. Teardown and absence | `image_teardown`, `image_residue_absent`, `absence_proved` | Accepted. No server, tmux session, probe, broker, image service, or router snapshot survives; `image-teardown-check.sh` proves no service, no runtime, no partial artifact, and a free lease; both ports are free. |
| 11. Restore the ordinary router | `ordinary_restore` | Accepted. The ordinary router serves again at 13:57:18Z. |

## The timing of each phase

Every figure below comes from a log this directory retains rather than from a
wall clock the harness kept.

| Phase | Span | Source |
| --- | --- | --- |
| Whole run | 13:53:31Z to 13:57:18Z, 3 m 47 s | `run.log` |
| Launch to `state=running` | 2 s, 13:53:31Z to 13:53:33Z | `image-launch.log`; the readiness wait for `/health` follows and carries no timestamp of its own |
| Curl-replayed generation | 11.612 s runtime, 11.62 s total, of which `sd-cli`'s own `generate_image` is 9.65 s | `provenance.json`, `image-service.log` |
| Page turn, proposal | 79.74 s: 731 prompt tokens at 18.70 tok/s (39.10 s), 113 generated at 2.76 tok/s (40.64 s) | `image-server.log`, child port 51841 |
| Page generation | 9.72 s in `generate_image` at seed 12345 | `image-service.log` |
| Page turn, closing reply | 65.90 s: 155 prompt tokens at 17.50 tok/s (8.86 s), 157 generated at 2.73 tok/s (57.04 s) | `image-server.log` |
| Review | 19.44 s: 570 prompt tokens at 38.60 tok/s (14.77 s, including image batches of 1.245 s and 1.665 s), 78 generated at 16.48 tok/s (4.67 s) | `image-server.log`, child port 49219 |

The language model rather than the image runtime or the reviewer sets the
session's length. The two chat turns cost 145.6 s against the generation's
11.6 s and the review's 19.4 s, so the 4B distill is 82% of the device time
this page session spent. Nothing approached a deadline: the longest single
call is 79.74 s against the page's 660 s bound and the router's 3600 s proxy.

## The page arm of the vision-review design is closed

`vision-review-design.md` stated the page arm as one phase that becomes
available where the budget admits the pair: set `review_model` to
`lfm25-vl-16b` on `image-sdxs-512-a`, run `remote/admit-image-router.sh` with
`QWEN_ADMISSION_REVIEW_MODEL` naming the same row, and drive the generation
and the review through one page in one session. That is this run, and
`remote/image-profiles.tsv` now ships the value. What closes is the page
arm: one session, two resident checkpoints, an approved generation, and a
parsed verdict rendered on the artifact card.

Three of the design's questions stay open and none of them is a page-arm
question. The image-withheld control of falsifier 3 did not run, so verdict
faithfulness is unestablished. Falsifier 5, whether a correction converges,
and falsifier 6, whether the lineage cap holds on the appliance, both require
a verdict that asks to regenerate, and this one passed; they remain proven
against the stub in `remote/web-mcp/test-fallback-page-image.py` and unrun on
the device. Falsifier 4 is met and recorded above.

## What is retained here

`summary.tsv`, `run.log`, `image-launch.log`, `image-server.log`,
`image-service.log`, `image-session.status`, `ordinary-session.status`,
`ordinary-restore.log`, `ordinary-teardown.log`, `image-teardown.log`,
`image-teardown-check.log`, `build-web-presets.log`, `image-parameters.json`,
`image-profiles.tsv`, `web-profiles.tsv`, `web-presets.ini`, `tools.json`,
`generate-response.json`, `provenance.json`, `browser-turn-1.json`,
`browser-turn.json` -- the accepted attempt again under the canonical name,
identical field for field except that its request bodies are parsed objects
where the attempt record keeps them as the strings the page sent --
`browser-turn-1.err`, and `http/` (38 request, response,
and header captures) are sanitized Git copies: the private hostname reads
`qwen-laptop`, the machine-local home prefix reads `$HOME`, every grant's
signature segment is replaced by its byte length as `<signature:N>`, and the
session secret is replaced the same way as `<secret:N>`, following
`served-turn-admission/`. The grant claim payloads are retained, since what
the authorization binds is the evidence.

No PNG bytes are retained here. The curl replay's artifact is 583,938 bytes at
`sha256 17e452e6974ad6d3174c5d0c9f367c90867eb99ffa8a3a6f9e45e78eb4de7639`,
byte-identical to `evidence/image-appliance/served-turn-admission/artifact.png`
and to `evidence/image-appliance/paired-review-launch/artifact.png`;
`http/14-artifact-png.response` carries that identity line in place of a fourth
copy. Three runs of the same prompt at seed 20260829 across three launches
produced one digest, which extends the two-point reproduction
`served-turn-admission/` recorded to three and holds across a launch that
served a second resident checkpoint. The page turn's own artifact stays on the
appliance: `sha256 7c6b7565059771e7e68d467afeae10233204915659c22728442467552e9e6fe3`
at seed 12345, the same digest the served page produced in
`served-turn-admission/`, and the image the review read.
