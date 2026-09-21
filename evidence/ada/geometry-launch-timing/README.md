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

## What has not run

The resident worker itself, its explicit streams and events, its reusable
allocations and its reuse key. This change measures the ground they have to
gain. Both rows in `scripts/geometry-profiles.tsv` stay
`execution_policy=refused`; the harness raises its own copy for one run and
records both readings.
