# Where an OptiX ray query spends its time

The runtime reported `wall_ms` and `launch_ms` and nothing between them, so a
resident worker could be argued for but not measured. It now reports one number
per stage, and the partition is complete over the interval it measures:
`stage_sum_ms` equals `runtime_wall_ms` to three decimals in every run below.

The interval ends before the process does. `digest(results)`, an FNV-1a over
the eight megabytes a million per-ray results occupy, ran in the statement that
assembles the JSON, after `wall_ms` was taken, so about seven milliseconds of
this runtime's work fell outside both the table and the wall it was checked
against. It runs inside the compare stage now, which moves `compare_ms` from
4.03 ms to 11.00 and the reference's share of validation from 95.5 percent to
87.0; `../geometry-resident-session/README.md` carries the corrected figures.

Measured on the RTX 4070 Ti at 1,048,576 rays over `cube-and-plane`, both arms
accepted at 28 of 28, retained under `warm/` and `cold/`. Protocol 2.

| stage | warm (ms) | cold (ms) |
| --- | --- | --- |
| scene | 22.113 | 21.902 |
| cuda_context | 135.953 | 118.646 |
| optix_context | 46.761 | 36.893 |
| accel | 0.170 | 0.169 |
| module | 0.316 | 33.518 |
| pipeline | 8.922 | 6.303 |
| sbt | 0.024 | 0.025 |
| upload | 3.036 | 2.978 |
| **launch** | **2.428** | **2.434** |
| download | 3.202 | 3.120 |
| validate | 88.719 | 88.303 |
| teardown | 7.831 | 7.769 |
| total | 319.475 | 322.060 |

**The ray trace is 2.43 ms of a 319 ms query, 0.76 percent.** Tracing a million
rays against this scene is the cheapest thing the process does. Upload, launch
and download together are 8.7 ms, so the device work in a query is under three
percent of it and everything else is process construction and host arithmetic.

That 2.43 ms is mostly not the ray trace. `../geometry-resident-session/README.md`
runs several launches against one pipeline and finds the second and later
launches at 0.28 to 0.32 ms, with the first at 2.5: **the trace is about 0.3 ms
and the 2.2 ms beside it is a pipeline's first launch, which a one-shot query
pays again every time.** Every run in this file is a first launch, which is why
none of them could separate the two.

**The disk cache governs the module stage and nothing else.** `module_ms` is
33.5 ms with the cache disabled and 0.32 ms with it enabled, a hundredfold, and
`order-series.tsv` shows it tracking the cache rather than the run order across
four alternating runs: 1.082, 32.576, 0.355, 32.840 ms for warm, cold, warm,
cold. `optix_host.h` states there is no in-memory cache, which is why a module
timing taken without pinning this measures run history rather than the runtime.

**The first launch on an idle card is not the cold cache.** The first pair run
in this session reported `cuda_context_ms` at 401.351 and `optix_context_ms` at
206.565 against 130.628 and 52.511 for the run that followed, and the
alternating series holds both stages at 97 to 140 ms and 37 to 48 ms whatever
the cache state. That 548 ms of apparent cache saving was first-touch driver
initialization, and attributing it to the cache would have been the
measurement's first false claim.

**`launch_ms` is the most stable number here**: 2.427, 2.418, 2.447, 2.419,
2.428 and 2.434 across six runs, a 1.2 percent spread, while the context stages
move by a fifth between repeats. What holds that still is a pipeline's first
launch rather than the trace: the resident measurement puts the second launch
on one pipeline at 0.28 to 0.32 ms, so a change claiming to make ray tracing
faster has a third of a millisecond to clear and this figure is the warm-up it
would leave alone.

**The cache location is declared rather than defaulted.** `optix_host.h` gives
the Linux default as `/var/tmp/OptixCache_<username>`, which names the account
and is a different directory for two callers, so a warm timing taken against it
depends on who ran it -- and the retained reply carried that account name past
both the harness scrub and the publication gate. The service sets
`OPTIX_CACHE_PATH`, which the header says takes precedence over the API, to one
location under the caller's home. The first run against a fresh location is a
populate rather than a hit and reported `module_ms` at 22.859; the retained warm
arm is the run after it.

## What this says about a resident worker

The stages a worker would keep are the CUDA context, the OptiX context, the
module, the pipeline, the shader binding table and the acceleration structure:
192.1 ms of the warm run's 319.5. Teardown's 7.8 ms goes with them. What stays
per query is the scene's ray generation at 22.1 ms, the upload at 3.0, the
launch at 2.4, the download at 3.2 and the host reference at 88.7.

So a resident worker turns a 319 ms query into roughly a 119 ms one, and
**89 ms of that remainder is the host reference intersection rather than
anything on the device.** The ray generation is another 22 ms and is constant
for a fixed query set, so it caches with a reuse key naming the scene, the
query set and the ray count. Validation does not: it is the check that the
device answer is right, and it runs per query by construction. A worker that
kept everything cacheable and left validation alone would spend three quarters
of each query in host arithmetic verifying an 8.5 ms device round trip.

That ordering is the finding, and it is what the next change has to answer
before any streams or events are worth adding: the reference intersection is
the cost, not the launch.

## The validation stage is now two stages, and the split is unmeasured

The retained `warm/` and `cold/` captures above report `validate_ms`, which
covered computing the reference answer, comparing the device result against it,
and accumulating the statistics. The reference is a function of the rays, the
triangles and `t_max` and of nothing the device produced, so it is now computed
into its own vector and timed as `reference_ms` apart from the `compare_ms`
that consumes it. That is what makes the first reusable for unchanged inputs
without weakening the second: every ray is still compared against an
independently computed answer, and nothing cached is a previous device result.

**The reference is 95.5 percent of the stage as these runs measured it, and
87.0 percent once the digest is inside the comparison they were measured
against.** The seventeen runs that retain both columns -- eleven in `reference-split.tsv` and six in `clock-samples.tsv`
-- give that share a mean of 95.46 percent with a standard deviation of 0.45
and a range of 94.77 to 96.18. It is the only thing about these two stages that
has held still. The two runs at load 24 enter the `reference_ms` set below and
not this one, because their `compare_ms` was not captured.

`reference_ms` is 82.00 ms with a standard deviation of 3.37 over nineteen runs
and a range of 77.285 to 88.597, and **what moves it is not established.** Host
load does not: the correlation is -0.11 once one batch of four consecutive runs
is set aside, and that batch is the whole of the -0.43 the full set shows.

| load band | runs | `reference_ms` mean | min | max |
| --- | --- | --- | --- | --- |
| 4.1 to 4.2 | 3 | 80.62 | 77.29 | 85.28 |
| 7.4 to 7.6 | 4 | 86.84 | 84.72 | 88.60 |
| 15 to 18 | 10 | 81.05 | 78.72 | 85.48 |
| 24 | 2 | 79.16 | 79.03 | 79.29 |

The load-7.5 batch sits above every other band including the quieter one below
it, so it is an anomaly in those four runs rather than a point on a trend. What
was different about that window is unknown.

The clock hypothesis is refuted rather than unsettled. `clock-samples.tsv`
carries the package frequency each run was given: 4107 to 4329 MHz mean across
cores at load 15, and 4210 to 4284 at load 4, with peaks of 4345 to 4382 in
both. The clock is the same at both ends, so it does not explain a timing
difference between them -- and there is less of a difference to explain than
the earlier reading of this file claimed.

The sampler reads the mean and maximum across all cores from `/proc/cpuinfo`
every tenth of a second for the length of the request, so what it bounds is the
band the package sat in while the run happened. It does not name the frequency
the thread computing the reference was given, and an 80 ms stage fits between
two samples, so a stage time divided by one of these means is not a cycle
count. Refuting a package-wide difference between two load bands is the claim
it was built for and the only one it carries.

That leaves the absolute timing varying by 14 percent for reasons this
instrument set does not reach, and the share stable at 95.5 through three
revisions of the explanation. The share is what step one needed and what a
projection should rest on; the absolute is not.

The setup stages remain the ones the host genuinely does take: over the same
runs `cuda_context_ms` spans 132.131 to 4757.229 ms, a factor of 36, queueing
behind driver work and idle-class I/O. The reference and the comparison run
back to back in one process, which is why their ratio survives whatever the
machine is doing to their absolute cost.

The one departure is a `compare_ms` of 21.929 on the first run against a freshly
allocated reference vector, against 3.4 to 4.8 on every later run, and it is
unexplained. First touch of the reference vector is not the cause: the vector is
constructed and every entry written inside the reference span, so its eight
megabytes of faults are charged to `reference_ms` and cannot land in the
comparison. The comparison's own allocation is `primitive_hits`, one counter
per triangle.

Materializing the reference costs something the retained captures do not
measure. The merged combined `validate_ms` is 88.719 ms and the two stages here
sum to 84.812, but those are different runs, the split total is the lower of
the two, and both sit inside the 14 percent the absolute moves by on this host,
so that subtraction isolates nothing. What the change does is write a
`RayResult` per ray to memory and read it back, eight megabytes per million
rays, where the reference used to be consumed in register. On fourteen
triangles the traffic is small; it scales with the ray count, and a paired
measurement is what would price it.

A resident worker has since run: `../geometry-resident-session/README.md`
measures the query it leaves at 113.37 ms rather than the 119 projected here,
with the reference at 74.50 of it.

So caching the reference removes about 82 ms of the roughly 119 ms a resident
worker would leave per query, with a 77 to 89 ms range this instrument set does
not account for, and the comparison it protects costs about 4 ms. Ray generation at 22 ms caches
beside it for a fixed query set. What survives both is upload, launch, download
and compare: on the order of 13 ms. That is a projection from one-shot
measurements and a resident implementation has not run.

A reuse key for the reference has to name the mathematical inputs -- ordered
geometry and transforms, ordered ray bytes, the intersection limit, and the
reference implementation's build identity -- rather than the scene and query
names. Once PhysX supplies the transforms, a reference computed for one
simulation state would otherwise verify the next state on the strength of an
unchanged scene name.

## The conditions these timings belong to

`scripts/qwen-exec-idle-priority.sh` runs the runtime at nice 19 with idle I/O
and verifies both before it execs, so every stage here is a measurement of this
host under the load it carried as much as of the runtime. The effect is not
small. Repeating the pair at load average 24, with a GPG daemon at 94 percent
of a core and the desktop holding the GPU at 68 percent, took the warm run's
stage sum from 319 ms to 9864 ms: `cuda_context_ms` 4757 against 136,
`optix_context_ms` 3294 against 47, `pipeline_ms` 1581 against 9. `launch_ms`
moved from 2.428 to 2.653, 9 percent, because the launch is the one stage the
host scheduler does not own.

Those runs are discarded rather than retained. The harness now records the
one-minute load average and the GPU utilization either side of every run in
both lanes, so a contaminated run reads as contaminated rather than as a slow
one. A load threshold is not imposed: what counts as quiet is a judgment about
the host, and the record is what lets a reader make it.

Changing the priority is its own paired comparison against the same scene,
reference implementation and runtime. It is not bundled into a claim about a
resident worker.

## What has not run

The resident worker itself, its explicit streams and events, its reusable
allocations and its reuse key. This change measures the ground they have to
gain. Both rows in `scripts/geometry-profiles.tsv` stay
`execution_policy=refused`; the harness raises its own copy for one run and
records both readings.
