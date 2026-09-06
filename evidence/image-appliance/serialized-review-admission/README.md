# The serialized generate-then-review sequence, and one promoted image tuple

`evidence/image-appliance/vision-review-calibration/` named `qwen35-2b` as
the reviewer the serialized sequence pairs, on eighteen arms with zero
schema departures, and measured that it brings the device back to its
pre-load occupancy within a second of unloading. This record runs the
sequence that calibration was designed against: one approved generation on
the CUDA image runtime, the artifact retained and the lease released, the
reviewer loaded by the router on its first request, and one review of the
artifact, all inside one served page turn, with the order and the device
occupancy measured rather than assumed. It is the record a promotion of one
image tuple rests on.

## What serializes the sequence

Nothing new. The router of the pinned llama-server loads a child on the
first request that names it and holds no preload option, so a review-only
section is absent from the device until a request names it. The page's
first such request is the `GET /props?model=` of `resolveVisionModel`,
which runs when an artifact card exists rather than at page load, so the
reviewer reaches the device once a generation has produced a card and
before the reader clicks Review; the generation's tool message lands
first, and the image service sends it after the artifact rename that ends
its lease. The sequence is therefore serialized by construction of the
parts, and what this record adds is the measurement: `admit-image-router.sh`
samples the driver's compute-client list, the lease's flock state, and
device-global memory through the page turn in a loop that sleeps a tenth of
a second and pays two driver queries per pass, so the cadence is a measured
property of the run rather than the sleep and the reader states it, and
`scripts/read-serialized-review-timeline.py` derives from those rows the
generation interval, the release, the reviewer child's first sample, and
the occupancy per phase. The language child is every server pid the first
sample lists, and the reviewer is the pid `ss` resolves from the port the
router logged for that child, so a language child restarted mid-run cannot
stand in for it.

## Preregistration

`admit-image-router.sh` runs on the RTX 4070 Ti with the CUDA `sd-cli`,
the `sdxs-512` bundle under `image-sdxs-512-a`, the 4B distill as the
language profile, and `qwen35-2b` as the review model, the ledger row
raised to validator-gated in a copy. Every check the retained CUDA runtime
admission stated holds again; these are the ones this record adds, stated
ahead of the run.

- `review_serialized_after_lease_release` accepts where the lease was
  observed held while the runtime ran, the reviewer child's first sample
  lies after the runtime's last sample and after the first free sample that
  follows it, and no sample in the reviewer's own window reads held or
  lists the runtime; a reviewer listed while the runtime is listed or the
  lease held refutes it, and a lease never seen held under the runtime
  leaves the order unproven rather than accepted. Each sample's lease state
  is read from every row it carries rather than from its closing tick, so a
  group the sampler's termination truncated still counts. The reviewer is
  the pid `ss` resolves from the port the router logged for that child, and
  a pid that fails to resolve refuses the arm on the device rather than
  falling back to whichever server pid appeared. Every interval this record
  states is a separation between observed samples at the measured cadence:
  the reviewer's first sample is the first one listing it as a compute
  client, which follows the router's spawn by the child's own start-up and
  the sampler's query latency.
- `review_residency` states the device-global peak during generation, the
  peak during review, the floor from the reviewer's first sample onward,
  and the cadence those figures were read at, with the desktop's own
  occupancy inside every figure and the count of samples the floor read; that floor is expected above the
  before-generation floor by the reviewer's model buffer, since the router
  keeps a loaded child resident until it evicts it, and that residency is
  the cost the record states rather than a refutation.
- The page renders `reviewed by qwen35-2b` with the declared constraints
  and the verdict stays out of `history`, as the paired-review checks
  already require.
- The offline harness test runs under the fixture runtime on the same
  host ahead of the device run and reports the timeline arm `observed`
  with `not_observed` on both sides, since a fixture opens no device
  context.

**Promotion.** Where every check accepts, `image-sdxs-512-a` moves to
`validator-gated` with `review_model` `qwen35-2b` and `validated_evidence`
naming this record, and stays the one promoted row; every other image row
stays refused. A refusal at any step keeps the row refused and the record
states the refusing arm.

## Run 05

`run-05/` is the retained run on the RTX 4070 Ti under driver 610.57.04 and
CUDA 13.3, the operator's telemetry server stopped for the window and the
ordinary desktop as the client set. Four runs precede it. Run 01 refused at
the preset: the review section takes the reviewer's registry tuple, and
`qwen35-2b` carried no validated projector-loaded row at its 65536
interactive depth, a depth whose pairing with the 4B, the projector, and the
image runtime exceeds the carve-out in any case. The registry now names
16384 as that row's interactive depth under the unchanged 65536 ceiling, and
`evidence/depth-validation-32k-projector/qwen35-2b/` validates 8192, 16384,
and 32768 with the projector loaded. Run 02 refused the timeline arm with
`reviewer=not_observed`: the harness's own `GET /props?model=` read ahead of
the page turn had loaded the reviewer child, so it stood in the first sample
and no new pid could appear; that read now follows the page turn and a
roster-tag read precedes it. Runs 03 and 04 accepted every arm, and four
review passes over the harness then closed sixteen findings against them:
the reviewer is the pid resolved from the router's own spawn port and an
unresolved pid refuses the arm, the lease has to read held in every sample
the runtime appears in, each sample's lease state is read from all its rows
so a truncated group still counts, the pre-generation floor takes the
samples before the runtime's first, the tools refusal reads
`feature_disabled` in the body beside the 403, the image authority matches
whole tokens on one accepted promotion row and requires the run's own
terminal accept and the ledger row's geometry in the parameters the service
ran under, the registry requires a projector arm's own control and health
columns, and the sampler's cadence is measured rather than claimed. Run 05
repeats the whole admission on that form: 52 rows, 46 accepted, 5 observed,
one skipped by `QWEN_ADMISSION_RESTORE=0`, none refused, with the fixture
harness test passing on the same host ahead of it.

| arm | outcome |
| --- | --- |
| review row tagged `vision-review` on the roster, read without a load | accepted: `tags=review-only,vision-review` |
| approved generation through the router | accepted: 5 s over the curl replay |
| lease released after the generation | accepted |
| page turn | accepted on the first attempt: the 4B proposed the call, one grant, one artifact |
| reviewer child pid resolved | observed: port 46859, pid from `ss` |
| reviewer loaded after the release | accepted: first sample 0.135 s after the first free sample following the runtime's last, 47 samples against the runtime's 8, the lease held in all 8 generation samples, and no held sample and no runtime sample inside the reviewer's window |
| review rendered | accepted: `reviewed by qwen35-2b`, one constraint, verdict pass, out of `history` |
| props and tools of the review row, after the turn | accepted: vision reported, tools refused 403 `feature_disabled` |
| teardown | accepted: no server, service, runtime, partial artifact, or held lease |

**Residency**, device-global with the desktop's own occupancy inside every
figure, read at the sampler's measured 7.39 Hz:

| phase | device memory |
| --- | ---: |
| before the generation, language child resident | 4744 MiB |
| during the generation, peak | 7725 MiB |
| during the review, peak | 7325 MiB |
| floor from the reviewer's first sample onward, 47 samples | 4779 MiB |

Each phase adds one process of about the same size to the same resident
language child: the image runtime peaks at 2968 MiB as a compute client and
the reviewer at 2566 MiB. The floor is the trough between them rather than a
residual, since the reviewer's first sample is the first one listing it as a
compute client and the runtime's memory is already returned by then, with
the reviewer's own weights arriving over the samples that follow. What the
sequence leaves behind is the reviewer's 2566 MiB, which the router keeps
resident until it evicts the child.

The artifact digest matches run 04's byte for byte at the same seed and
prompt, across two server launches and two closure loads.

**What this settles.** The serialized sequence holds on the served page
as the parts construct it and as the sampler measured it: the runtime
holds the lease alone, the reviewer reaches the device only after the
release, and the review reads the retained artifact. `image-sdxs-512-a`
moves to `validator-gated` with `review_model` `qwen35-2b` and this
record as its `validated_evidence`, the one promoted image row; every
other image row stays refused, and every physics and geometry row stays
refused.

**What it leaves open.** A second review in one session finds the
reviewer already resident, so its cost is the review alone; a session
whose language child is evicted for the reviewer is the bound-one router
shape this record did not run. The reviewer's residency past its reply is
the router's policy rather than the lane's, and an eviction after review is
a router change. The sampler stops with the page turn, so how long that
residency lasts is unmeasured here.
