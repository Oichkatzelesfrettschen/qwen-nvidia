# Calibrating the vision reviewer against declared fixtures

A review verdict decides whether a generated artifact is retained, corrected,
or promoted, so the reviewer's pass, fail, and uncertain have to carry a
measured meaning ahead of the first artifact they judge. This record
calibrates each candidate reviewer through the review path the served page
uses: `scripts/image-service.py`'s artifact listener answering
`GET /artifacts/<sha256>.png` under the Web UI credential, llama-server
standalone at the reviewer's registry tuple with its own projector on
CUDA0, and `scripts/image-review.py` posting one tool-free request per arm
with the grammar-bounded schema.

The verdict schema now states a constraint in three words. `pass` and
`fail` state what the image shows; `uncertain` states that the image did
not let the model decide, an answer of its own rather than a pass by
default or a fail by caution. An uncertain constraint admits no correction
and counts against a promotion. Every verdict is bound beyond the artifact
digest, the prompt hash, and the model id: `--binding` fields carry the
reviewer's projector digest, model digest, serving tuple, and the server
closure digest onto the record and the audit line, beside a digest of the
constraint list, so a verdict read later names the exact reviewer and
request that produced it.

## Fixtures and constraints

The fixtures are two drawings whose content `scripts/generate-quality-images.py`
declares. Artifact A is `bars.png`: four bars labeled APR, MAY, JUN, JUL
with JUN the tallest at 150 and the axis maximum stated. Artifact B is
`shapes.png`: a circle, a square, and a triangle, and no bar chart. Three
constraints are declared against A and A alone meets them:

| constraint | description | A | B |
| --- | --- | --- | --- |
| `four_bars` | the image is a bar chart holding exactly four bars | met | not met |
| `tallest_jun` | the tallest bar is the one labeled JUN | met | not met |
| `axis_150` | the vertical axis or the tallest bar is marked 150 | met | not met |

`scripts/run-vision-review-calibration.sh` runs six arms per repeat, every
arm with the prompt cache off and the bindings stated:

| arm | request | expected reading | what the other reading says |
| --- | --- | --- | --- |
| correct | A | `grounded_pass`: every constraint pass | a fail is a false fail; an uncertain is the reviewer declining a declared fact |
| violating | B under A's constraints | `discriminated`: at least one fail | `false_pass` refutes discrimination; the reviewer passes what is absent |
| withheld | A's request without the image part | `withheld_declined`: a fail or an uncertain | `ungrounded_pass` refutes grounding; the verdict comes from the text |
| swapped | A's request carrying B's bytes | `follows_pixels`: at least one fail | `follows_text` reports the verdict following the constraint text over the pixels |
| absent | a digest no artifact holds | `refused_as_expected`: the read refuses ahead of the model | a review of an absent artifact refutes the identity check |
| closing | A again | `grounded_pass` | a drift from the opening arm inside one repeat |

A reply outside the schema refuses with its code and is counted as
`malformed_replies` rather than retried, since how often a reviewer leaves
the schema is part of what is calibrated. `scripts/admit-vision-review-calibration.sh`
runs the six arms three times per reviewer, lfm25-vl-450m first and
qwen35-2b second, under the owner lock, and samples device memory at one row
per second through each reviewer's load, arms, and unload.

## Preregistration

- **Grounding.** A reviewer is grounded where every withheld arm reads
  `withheld_declined` and every swapped arm reads `follows_pixels`. One
  `ungrounded_pass` or `follows_text` refutes it for that reviewer.
- **Discrimination.** A reviewer discriminates where every violating arm
  reads `discriminated` and every correct arm reads `grounded_pass`. A
  `false_pass` or a `false_fail` refutes it; an `uncertain` on a declared
  fact is recorded as the reviewer's own limit rather than as either.
- **Identity.** Every absent arm refuses at the read with
  `artifact_http_error`; a verdict over an absent artifact refutes the
  identity check and is a harness defect rather than a model finding.
- **Schema.** The count of malformed replies per reviewer is stated; a
  reviewer above one malformed reply in eighteen arms is unfit to gate a
  promotion at the 400-token budget.
- **Residency.** The sampler states the device memory held during the arms
  and the memory after unload; a reviewer whose after-unload occupancy stays
  above the pre-load value by more than the sampler's row-to-row spread has
  left something resident, and the serialized generate-then-review sequence
  is designed against these rows.
- **Fitness.** A reviewer passes calibration where grounding,
  discrimination, and identity all hold with zero malformed replies; the
  first reviewer to pass is the one the serialized review sequence names.
  A reviewer that fails stays a candidate with its readings retained.

Two identical PNGs produced by one seed are repeatability evidence for that
seed alone and say nothing about a reviewer; no artifact generation runs in
this record.

## Run 02

`run-02/` is the retained run on the RTX 4070 Ti under driver 610.57.04
and CUDA 13.3, with the operator's telemetry server stopped for the window
and the compositor, a browser, and Discord recorded as the client set
(`ownership.txt`). Run 01 refused before any arm: the listener's control
socket under an evidence path exceeded the AF_UNIX bound, and the state
now lives under the runtime directory. Both reviewers loaded from the
promoted closure (`summary.tsv` carries the server, model, and projector
digests, and every verdict record carries them as bindings), three repeats
each, eighteen arms per reviewer, zero malformed replies and zero
transport failures on both.

| reviewer | correct | violating | withheld | swapped | absent | closing |
| --- | --- | --- | --- | --- | --- | --- |
| lfm25-vl-450m | uncertain 3/3 (2 pass, 1 uncertain) | uncertain 3/3 (2 pass, 1 uncertain) | ungrounded_pass 3/3 | uncertain 3/3 | refused 3/3 | uncertain 3/3 |
| qwen35-2b | grounded_pass 3/3 | discriminated 3/3 (1 fail, 2 uncertain) | withheld_declined 3/3 (2 pass, 1 fail) | follows_pixels 3/3 | refused 3/3 | grounded_pass 3/3 |

**lfm25-vl-450m fails calibration.** Its observations restate the
constraint text in every arm (`The image is a bar chart holding exactly
four bars` over the shapes drawing and over no image at all), the withheld
arm passes all three constraints it cannot see, and the violating and
swapped arms read two passes and one uncertain, the same verdict the
correct arm reads. Grounding and discrimination are both refuted; the
identity check and the schema hold, at 0.2 s per review.

**qwen35-2b passes every preregistered reading.** The correct and closing
arms pass all three constraints with observations naming the four bars,
the JUN label, and the 150 mark; the violating and swapped arms fail
`four_bars` naming the three shapes and read the two bar-dependent
constraints uncertain, with a regeneration proposal that names the
missing bars; the withheld arm declines through a fail on `tallest_jun`.
Its verdicts are identical across the three repeats at about 1 s per
review.

One detail the preregistered rule admits and the record states: with the
image withheld, the 2B passes `four_bars` and `axis_150` from the
constraint text and fails `tallest_jun` on an invented label, so two of
its three constraints are answerable from text alone. The rule counts one
fail or uncertain as a declined arm, and it stands as registered; a
stricter rule requiring every withheld constraint to read uncertain was
not preregistered and is recorded here as the next calibration's
candidate, since a reviewer that confabulates a pass on a withheld image
is a reviewer whose pass on a real image carries that much less.

**Residency.** The sampler's rows (`clocks.tsv` per reviewer, device
memory device-global with the desktop's own 1800 MiB resident):

| reviewer | model buffer | peak during arms | after unload | load | unload |
| --- | ---: | ---: | ---: | ---: | ---: |
| lfm25-vl-450m | 216 MiB | 2911 MiB | 1800 MiB | 2 s | 1 s |
| qwen35-2b | 1259 MiB | 4749 MiB | 1800 MiB | 2 s | 1 s |

Both reviewers return the device to its pre-load occupancy within one
second of the unload, so a serialized generate-then-review sequence pays
about two seconds to bring the 2B up after the image runtime leaves and
holds about 2.9 GiB over the desktop while it reviews.

**What this settles.** qwen35-2b is the reviewer the serialized review
sequence names, on the strength of eighteen arms with zero schema
departures; lfm25-vl-450m is unfit to gate anything and stays a candidate
with its readings retained. The serialized sequence itself, its ledger
form, and a promotion of one image tuple are the next transition and are
not claimed here.
