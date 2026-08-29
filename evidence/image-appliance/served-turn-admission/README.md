# One approved image turn through the served page

`remote/admit-image-router.sh` ran the merged image path on the appliance
against the pinned `sd-cli` and the real device: the promoted `llama-server`,
one router child serving `web-image-admission`, the approval broker, the image
MCP child, `image-service.py`, and the `stable-diffusion.cpp` runtime at commit
`de298c22` all executed, and both the curl replay and the served page drove the
same tool. `run.log` bounds the run at 2026-08-29T10:39:38Z through
10:42:38Z on the appliance.

## The falsifier

The run tests one claim: an approved turn reaches the network-free image
runtime through router, broker, MCP, and service while the model never holds
the authority over its own arguments. Any of five observations falsifies it.
A generation that completes without a grant, or with a grant already spent, or
with a grant naming another image profile, puts the authority in the caller
rather than in the approval. A `POST /tools` whose routing key survives into
the tool arguments puts the transport inside the argument set the schema
closes. A page request to any origin other than the router, the broker, and
the artifact listener reaches a surface the profile never authorized. Image
bytes or a grant token retained in the transcript put the artifact and the
authorization into every later request body. None was observed: rows 20 to 27
and 30 to 37 of `summary.tsv` record each refusal fired once and each
hygiene property held.

`summary.tsv` carries 41 rows: 40 read `accepted` and one reads `observed`.
`browser_prompt_used` is the observation, because the prompt text is what the
run recorded rather than a property it judged.

## The checks, in the order the harness ran them

| Group | Checks | What the group establishes |
| --- | --- | --- |
| Outage ownership | `ordinary_router_recorded`, `ordinary_teardown` | The harness records the ordinary router's server path, tears it down, and proves no residue before it claims the device. |
| Ledger and parameters | `image_ledger_promoted`, `image_runtime_present`, `image_parameters_written`, `preset_generated` | One `image-profiles.tsv` row moves to `validator-gated` in a copy under the output directory, `sd-cli` is present, `image-parameters.json` carries the row's own geometry and ceilings, and the generator emits one section. |
| Launch and listeners | `image_launch`, `artifact_listener_loopback`, `image_service_recorded`, `router_listener_loopback`, `api_key_minted`, `router_roster` | The deadline stack proves ordered, both listeners bind 127.0.0.1, the session records `image_service_pid=`, and the minted API key is mode 0600. |
| Tool surface | `tool_enumeration`, `web_tools_absent`, `tools_unknown_model_refused` | `GET /tools?model=` on the router port lists `image_generate_image` alone -- the `ui-mediated` language row emits the image server and no web server -- and an unknown model is answered 400. |
| Authorization | `broker_signs_image_profile`, `session_secret_issued`, `grant_issued`, `grant_wrong_image_profile_refused` | The broker signs for the launched image profile, issues one session secret, signs a 614-byte grant over seed 20260829, and refuses a foreign image profile at 400. |
| Generation | `generation_completed`, `result_carries_identity_alone` | One `POST /tools` carrying the grant inside `params` completed in 12 s with `sha256 17e452e6...` and a provenance route, and the reply carries status, digest, and route alone. |
| Refusals after the grant | `grant_replay_refused`, `generation_without_grant_refused`, `routing_key_outside_arguments` | The spent grant, the ungranted call, and `params.model` are each refused once; the routing key is rejected by name as an argument the tool does not read. |
| Artifact and provenance | `artifact_png_matches_digest`, `artifact_without_credential_refused`, `provenance_names_seed_and_profile`, `lease_released_after_generation` | 583,938 PNG bytes match the reported digest, the uncredentialed read is 401, the record names seed 20260829 and `image-sdxs-512-a`, and the Vulkan workload lease is free again. |
| The served page | `browser_prompt_used`, `browser_page_origin`, `browser_dialog_names_bound_seed`, `browser_grant_posted_once`, `browser_generation_via_router`, `browser_requests_stay_on_known_origins`, `browser_artifact_fetched`, `browser_transcript_carries_identity_alone` | Headless Chromium ran the same turn against the served `webui/index.html`: the dialog named the model's own seed 12345, one grant was posted, the generation named the model beside the tool on the router port, every request stayed on 127.0.0.1:8080, :8571, and :44911, the artifact was fetched once into a blob, and the retained tool message carries digest and route. |
| Hygiene | `secret_hygiene` | The API key, the grant, the session secret, and the prompt text are absent from process images, logs, session status, and provenance -- `served-provenance.json` records the prompt as `sha256:e7a8c5d5...` in the runtime argv it retains. |
| Teardown and restore | `image_teardown`, `image_residue_absent`, `absence_proved`, `ordinary_restore` | `image-teardown-check.sh` proves no service, no runtime, no partial artifact, and a free lease; both ports are free; the ordinary router serves again. |

## Timings

The deadline stack is ordered from the value each layer is configured with:
runtime 300 s, `image-service.py` 330 s, the emitted `timeout_ms` 360 s, the
router proxy 3600 s from llama-server's own default, and the page 660 s.
Nothing approached a bound. The curl-replayed generation completed in 12 s
wall. The page turn's own record in `served-provenance.json` reads
`runtime_seconds` 11.31 against `total_seconds` 11.317, so the service's
framing costs 7 ms against the runtime's own span, and the run held
`memavailable_minimum_kib` at 6,909,556 with `swap_delta_kib` 0 and
`children_maxrss_kib` 501,584.

The language model rather than the diffusion runtime sets the turn's length.
`browser-turn.json` records 19.6 tok/s prefill and 3.3 tok/s decode over 113
generated tokens in 71.3 s to reach the tool call, then 138 tokens in 50.0 s
to close, against the 11.3 s the image itself cost. A 512x512 single-step
SDXS generation is a sixth of the turn.

## Determinism

Two runs of the same prompt against the 4B reproduced the same proposal
object and the same artifact digest, so the tool-call path is reproducible at
a fixed seed on this backend. That is a two-point observation on one prompt
and one profile; it establishes reproduction rather than a rate, and the
4% depth-0 spread this machine carries on throughput has no bearing on a
digest.

The seed is the model's own. `served-provenance.json` reads `seed` 12345 and
the dialog displayed 12345 before the approval, so the grant is signed over
the value the user saw. The two artifacts this record names come from two
different requests rather than one repeated: the curl replay generated
`17e452e6...` from `a fox in a snowy field` at the harness's seed 20260829,
and the page generated `7c6b7565...` from the model's own proposal at seed
12345. `provenance.json` and `served-provenance.json` carry different
`prompt_sha256` values, so neither digest bears on the other.

## Model behavior, and what the registry takes from it

The `raw_tool_selection` grade orders the two distills the way the turn does.
The 4B distill proposed a schema-valid call on the explicit prompt in every
run, and on the plain `Draw ...` prompt in one run of two. Its proposal
`{"prompt":"a red apple on a white table, product photography","seed":12345,
"width":512,"height":512,"steps":1,"profile_id":"image-sdxs-512-a"}` sits
inside every bound the listing states, so the schema's stated ceilings reached
the model and the model proposed under them.

The 2B distill answered the same request in prose inside its 512-token budget
and emitted no call. Its registry `raw_tool_selection` reads 2/10, so the
behavior is the grade rather than a surprise.

The consequence for `remote/web-profiles.tsv` is that an image-capable
language profile names the 4B. `web-image-admission` in this run carried
`qwen38-4b-distill`, and the 2B is refused for that role until a graded arm
moves its tool-selection row. Selection is what the image lane needs from the
language model; execution stays with the service behind the grant, so the
grade bounds usefulness rather than safety.

## The defect chain

Seven earlier runs on this same chain each failed on one mechanism, and each
repair is what the accepted run rests on.

| PR | The defect | The mechanism it fixed |
| --- | --- | --- |
| #57 | The broker bound `image_profile` to the language profile | `authorize-broker.py` takes `--image-profile` beside `--profile`, so `enforce_image_authorization` compares two distinct claims. |
| #58 | Teardown counted the harness's own shells as residue | The absence proof reads the recorded pids and start times rather than a process-name match. |
| #59 | The tool was looked for under its bare name | `server_mcp_tool` serves each wrapped tool as `<server>_<tool>`, so the router lists `image_generate_image`. |
| #60 | `sd-cli` appended `.png` to the partial name | The service writes `<job>.part.png` and renames to `<sha256>.png`, so the validated file is the one the digest names. |
| #61 | The page never retained the model's reply | `webui/index.html` retains the reply whether or not the approval dialog opened. |
| #62 | The 4B proposed 1024x768 at 30 steps under an invented profile, and the page left the refused turn open | The tool schema states the profile's own bounds and its `profile_id` enum, and every failure after the approval answers the call with a tool message and ends the turn. |
| #63 | The seed check assumed a page-generated seed | The grant binds the seed the dialog displayed, whichever side proposed it, so a model-proposed seed is admitted and shown before approval. |

## What is retained here

`artifact.png` is the one retained binary: 583,938 bytes,
`sha256 17e452e6974ad6d3174c5d0c9f367c90867eb99ffa8a3a6f9e45e78eb4de7639`,
the artifact the curl replay generated and read back from
`a fox in a snowy field`. It shows a red fox facing the camera on snow among
bare branches. `http/12-artifact-png.response` captured the same bytes, so
that capture keeps its identity line alone rather than a second copy.

The page turn's artifact is recorded by identity and its bytes stay on the
appliance: 495,828 bytes,
`sha256 7c6b7565059771e7e68d467afeae10233204915659c22728442467552e9e6fe3`,
a red apple on a white surface from the model's own prompt, with
`served-provenance.json` carrying its full record.

`http/5-session.response` and every grant signature are replaced by their
byte length, because the session secret and the signature authorize a page
against a broker rather than describing what the run proved; the grant's own
claim payload is retained, since what the authorization binds is the evidence.
The private hostname reads `qwen-laptop` and the machine-local home prefix
reads `$HOME` throughout.
