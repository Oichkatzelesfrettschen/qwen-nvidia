# Where an OptiX ray query spends its time

The runtime reported `wall_ms` and `launch_ms` and nothing between them, so a
resident worker could be argued for but not measured. It now reports one number
per stage, and the partition is complete: `stage_sum_ms` equals
`runtime_wall_ms` to three decimals in every run below, so no time hides
outside the table.

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
move by a fifth between repeats. A change that claims to make ray tracing
faster has a quiet baseline to clear.

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

**The reference is 95.4 percent of the stage.** Thirteen runs across a host
load average of 7.4 to 24 give that share a mean of 95.42 percent with a
standard deviation of 0.49 and a range of 94.77 to 96.18.
`reference-split.tsv` retains eleven of them with the load each one saw.

The share is what holds. The absolute timings do not, and not in the direction
starvation would predict: `reference_ms` correlates with host load at **-0.84**,
averaging 86.84 ms at load 7.5 and 79.16 ms at load 24, an 11.6 percent range
over the whole set. It runs faster on a busier machine.

| load band | runs | `reference_ms` | `compare_ms` | reference share |
| --- | --- | --- | --- | --- |
| 7.4 to 7.6 | 4 | 86.84 | 4.28 | 95.3% |
| 15 to 18 | 7 | 81.48 | 3.88 | 95.5% |
| 24 | 2 | 79.16 | 3.61 | 95.6% |

The mechanism is a hypothesis rather than a finding: the governor reads
`performance` with boost enabled, so a sustained multi-core load plausibly
holds the package at a clock a lightly loaded machine lets fall, while a
nice-19 process contributes little to whatever the hardware uses to decide.

The harness now samples `/proc/cpuinfo` core frequencies for the same interval
it samples the compute clients, and records the mean across cores and the peak
any core reached. Three runs at load 15 report a mean of 4107 to 4329 MHz
against a peak of 4347 to 4382, with `reference_ms` at 78.723 to 81.379 --
the high-load band's timings at a near-boost clock, which is what the
hypothesis predicts for that end.

**The other end is not measured.** The host has not returned below load 14
since the instrument existed, so there is no low-load clock sample to compare
against, and the hypothesis stands unsettled rather than supported. What the
instrument does buy immediately is that a future arm comparison carries the
clock each arm ran at, so an arm that happened to run during load cannot claim
its advantage silently. The sample count also travels: a 320 ms run at a
0.1 second interval yields about five samples, which bounds what the mean is
worth.

What this does settle is which numbers survive the host. The setup stages do
not: over the same runs `cuda_context_ms` spans 132.131 to 4757.229 ms, a
factor of 36, and they queue behind driver work and idle-class I/O. The ratio
between two host loops running back to back in one process does, because
whatever the clock is, it is the same clock for both.

The one departure is a `compare_ms` of 21.929 on the first run against a freshly
allocated reference vector, against 3.4 to 4.8 on every later run. Eight megabytes
of first-touch page faults land in that stage, and they land there once.

The merged captures report 88.719 ms of combined `validate_ms` against 84.812 ms
for the two stages summed here. The difference is the materialized vector: the
reference used to be computed inside the comparison loop and consumed
immediately, and it is now written to memory and read back.

So caching the reference removes between 79 and 87 ms of the roughly 119 ms a
resident worker would leave per query, depending on what the host is doing, and
the comparison it protects costs about 4 ms. Ray generation at 22 ms caches
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
