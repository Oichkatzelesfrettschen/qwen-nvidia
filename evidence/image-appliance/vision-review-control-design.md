# The image-withheld and image-swapped control of the vision review

This is a design registered before any run. It states the hypothesis, the arm
order, the falsifiers, and the command that produces the evidence. Every result
column stays empty until a run fills it, and no number here is predicted.

## The claim under test

`evidence/image-appliance/vision-review-grammar-run/` measures four reviews in
which every `hard_constraints` array parsed and every named constraint passed:
2/2 on each of four rows, over two artifacts and two vision checkpoints. That
result establishes reply shape. `response_format` carries a JSON schema,
`common/chat.cpp:3673,3802` compiles it with `json_schema_to_grammar`, and the
grammar bounds every sampled token, so a 4/4 verdict states that the model
answered inside the schema.

What the grammar cannot state is where the answer came from. A passing verdict
is equally consistent with three sources: the pixels of the artifact, the
constraint descriptions the caller wrote, and the shape of a question whose
easiest completion is agreement. The review is worth its 19.44 s of device time
(`evidence/image-appliance/paired-review-admission/`) only under the first, so
the hypothesis this design registers is that the verdict is caused by the image.

## The four arms

`remote/run-vision-review-control.sh` runs them in this order, each through
`remote/image-review.py` against one router and one artifact listener:

| Arm | `--image-mode` | Image the request carries |
| --- | --- | --- |
| `01-real` | `real` | artifact A, the reviewed one |
| `02-withheld` | `withheld` | the multipart text part alone |
| `03-swapped` | `swapped` | artifact B, under A's prompt hash and constraints |
| `04-real-closing` | `real` | artifact A again |

Every other request field is identical across the four: the same model, the same
constraint declaration, the same prompt hash, temperature 0, `top_k` 1, seed 1,
400 reply tokens, thinking off, the same `response_format` schema, `cache_prompt`
false, and no `tools` key. The withheld arm keeps the content a list holding the text part, so
image presence is the single changed dimension, which is the convention
`remote/run-quality-suite.py` already applies to its graded vision rows. The
reviewed artifact is read and hashed over its own route in all three modes, so
`artifact_digest_mismatch` and the rest of `fetch_artifact_png`'s refusals hold
for a control arm and the record's `artifact_sha256` stays a verified claim.

The closing control exists because the three control arms sit at different
positions in one request sequence. The request is greedy -- temperature 0,
`top_k` 1, seed 1 -- and this tree measures greedy decoding on this backend as
deterministic within a fixed sequence, so sampling noise is not what separates
arm 1 from arm 4. What separates them is the three requests in between, and that
effect is measured here already: `arith-05` answers 37 cold and 23 warm, one
unrelated 300-token predecessor leaves it at 37, and the standing reading is
that a one-row or two-row difference reports position in a sequence rather than
capability. Arms 2 and 3 arrive at positions 2 and 3 of that same sequence, so a
difference between either and arm 1 is confounded with position on arrival. Arm
4 un-confounds it: its agreement with arm 1 licenses reading arms 2 and 3 as
image effects, and it is the one arm whose value carries that license rather
than a measurement of its own.

The prompt cache is what would break that reading, so every arm sends
`cache_prompt` false. The four requests share their system instruction and text
part as a prefix and differ in the image part that follows, so a warm prefix
would let arms 2 through 4 skip the prefill arm 1 paid. With the cache off, each
arm meets the server the way the first one did.

Wall time is a second, independent reading of the same question.
`evidence/image-appliance/paired-review-admission/` attributes 14.77 s of a
19.44 s review to prompt evaluation of the 570-token multimodal prompt, so a
withheld arm carrying no image tokens lands far below the three arms that carry
them. The reading rests on `cache_prompt` false: the withheld prompt is a strict
prefix of the other three, so a warm cache would make its prefill nearly free
whatever the image tokens cost and the field would report the cache rather than
the request. A withheld `wall_seconds` near the real arms' reports that the image did
not leave the request, whatever the verdict says, and `summary.tsv` already
carries the field.

## Falsifiers

1. **The withheld arm passes every constraint it cannot see.** The request
   carries the constraint text and no pixels. A verdict that still marks each
   constraint passed reports the model answering from the constraint
   descriptions, its world knowledge, or the shape of the question, and the
   visual grounding the review claims is refuted for that row. The summary TSV
   settles this one: `passed` on `02-withheld` equal to `passed` on `01-real` is
   the observation.
2. **The swapped arm's observations agree with A rather than with B.** The
   request carries B's pixels alone. An observation describing A restates
   falsifier 1 through a second route, and one describing B while the `passed`
   counts stay at A's value reports that the constraints are loose enough for
   two different images to satisfy them, which is a finding about the
   declaration rather than about the model. Agreement between an observation and
   an image is a judgment no field states, so a reader settles this one against
   the retained `.verdict.json` and `.raw` files; the script reports counts and
   flags and grades no prose.
3. **The opening and closing real arms disagree.** The two carry identical
   requests under greedy decoding, so agreement is the expected observation and
   is what licenses reading arms 2 and 3 as image effects. A `passed` count or a
   verdict that moves between `01-real` and `04-real-closing` reports that the
   four-arm run measures sequence position, and arms 2 and 3 then state nothing
   about the image. The remedy runs one condition per fresh server state, or
   mirrors the arm order the way a throughput sweep here does; adding arms
   inside one sequence adds positions rather than removing the term.
4. **An arm refuses.** A refusal carries its code on the audit line and the
   summary reports `passed=-` with `status=refused:CODE`. A control arm that
   refuses where the real arm parsed is itself the finding: the two differ by
   the image alone, so a refusal that tracks image presence reports the reply
   shape depending on the pixels. A `swap_`-prefixed code is excluded from that
   reading, since it names the swap artifact's own read failing on the listener
   rather than anything the model did.

Falsifiers 1, 3, and the wall-time reading are read from `summary.tsv`.
Falsifier 2 is read by a person against the retained replies. Falsifier 4 is
read from either.

## The command on the appliance

The run needs one paired launch, which serves the language section and the
review-only vision section `image-sdxs-512-a`'s `review_model` names, and two
artifacts already generated through that lane. `qwen-image-launch.sh` binds the
router to 127.0.0.1:8080 and the artifact listener to the port
`image-service.py` chose, which `qwen-webui-session.sh` records on its
`image_service_identity` line:

```sh
artifact_origin=$(sed -n 's/^image_service_identity .*listener=//p' \
    "$HOME/qwen-webui-state/session.status" | sed -n '1p')

~/qwen-laptop-setup/remote/run-vision-review-control.sh \
    http://127.0.0.1:8080 "$artifact_origin" lfm25-vl-16b \
    "$ARTIFACT_A_SHA256" "$ARTIFACT_B_SHA256" "$PROMPT_HASH_A" \
    "$HOME/qwen-webui-state/vision-review-control" \
    --api-key-file "$HOME/qwen-webui-state/api.key" \
    --constraint 'prompt_subject=the image shows the subject the prompt named' \
    --constraint 'background_plain=the background is plain and uncluttered'
```

`qwen-webui-session.sh` derives both paths in the command above from its own
state directory: `api.key` at line 25 and `session.status` beside it, under the
`$HOME/qwen-webui-state` default at line 14. `QWEN_API_KEY` carries the same
credential where a caller prefers the environment.

`ARTIFACT_A_SHA256` and `PROMPT_HASH_A` come from A's own
`GET /artifacts/<sha>.json` provenance record, so the review binds the prompt
hash the image grant was signed over. `ARTIFACT_B_SHA256` names a second
artifact of a visibly different subject, since a swap between two images of the
same subject tests nothing the constraints can separate.

`run-vision-review-control.sh` removes an arm's whole file set before that arm
runs, so a re-run into a used directory cannot pair this run's refusal with the
previous run's verdict record.

The output directory retains four `.stdout` audit lines, four `.stderr` files,
four `.verdict.json` records, four `.raw` replies, `audit.log`, and
`summary.tsv`. That set plus a sanitized chain note is what an evidence
directory beside this file carries once the run happens.

## What this design does not measure

The arms run one vision checkpoint. `evidence/image-appliance/vision-review-design.md`
names `qwen35-2b` as the control row inside one sweep, and repeating the four
arms against it measures whether a withheld-arm result belongs to the review
path or to one checkpoint. The four arms also run one constraint declaration; a
declaration loose enough for any image to satisfy produces the same summary as a
model ignoring the pixels, and only falsifier 2's reading of the observations
separates them.
