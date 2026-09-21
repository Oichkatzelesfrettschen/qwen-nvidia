# What a resident session costs, what it retires under, and what a one-shot query was measuring

A bounded resident session and its one-shot control ran interleaved on the
RTX 4070 Ti through `scripts/admit-geometry-resident.sh`, both arms driven by
`scripts/geometry-resident-driver.py`, which takes the compute lease around
every request and holds none between them. `at-262144/` is three blocks of
four requests per arm at 262,144 rays and `at-1048576/` is two blocks of four
at the profile's ceiling of 1,048,576; both accepted at 8 of 8, every request
met the independent host reference on every ray, and both ledger rows stay
`execution_policy=refused` in the tree.

`retirement/` is a third capture, from `scripts/admit-geometry-retirement.sh`:
the ways a session ends, each reached on the card rather than against the test
fixture, with what owned the destruction recorded at each. It accepted at 37 of
37.

## The launch a one-shot query reports is mostly not the ray trace

**A launch and its synchronization cost 0.07 ms at 262,144 rays and 0.22 ms at
the ceiling once the pipeline has run, and the 2.4 ms a one-shot run reports is
first-use cost it pays again every query.** The first launch of each session
reads 2.435 and 2.445 ms at the ceiling and 2.304 to 2.367 at 262,144 rays.
Every launch after it in the same session reads 0.214 to 0.243 at the ceiling
and 0.065 to 0.070 below it. The twenty one-shot launches beside them read
2.294 to 2.558, because every one of them is a first launch.

This revises the strongest claim in `../geometry-launch-timing/README.md`. That
file reports `launch_ms` as the most stable number in the measurement, 2.418 to
2.447 over six runs, and reads the ray trace as 2.43 ms of a 319 ms query. The
stability was real and the attribution was not: every run it averaged was a
process's first launch on a fresh pipeline, so what held still was the cost of
warming one.

What the interval measures bounds what the finding can say. `launch_ms` is
taken around `optixLaunch` and the `cudaDeviceSynchronize` after it, on the
default stream, at `optix-ray-runtime.cpp:591`. It is a host-side interval
containing a device execution rather than a measurement of kernel time, and a
session reuses its CUDA context, its module, its pipeline and its shader
binding table together, against ray inputs that do not change between requests.
**So the finding is that first use and subsequent use differ by an order of
magnitude, and not that pipeline initialization alone accounts for the
difference.** The runtime runs under `CUDA_MODULE_LOADING=LAZY`, which NVIDIA
documents as deferring load work to first use; that is a candidate for part of
the 2.2 ms, not a share these runs assign. Separating the contributions wants a
measurement that varies one of them at a time.

## What residency buys, per request and per complete session

| | 262,144 rays | 1,048,576 rays |
| --- | ---: | ---: |
| one-shot, complete client latency | 260.06 ms, sd 13.04, n=12 | 350.00 ms, sd 16.27, n=8 |
| resident, complete client latency | 27.76 ms, sd 2.41, n=12 | 110.52 ms, sd 4.14, n=8 |
| session startup, once | 157.17 ms | 157.36 ms |
| session teardown, once | 7.99 ms | 10.41 ms |
| resident, startup and teardown amortized over four requests | 69.05 ms | 152.46 ms |

Complete client latency is the supervisor's own wall around a request: the
lease acquisition, the request, the reply and its validation. **A resident
request is 9.4 times cheaper than a one-shot query at 262,144 rays and 3.2
times cheaper at the ceiling.**

Those figures leave out the supervisor's own work outside a request, so they
are not what a session took. `summary.tsv` times each harness invocation whole,
and dividing that by the four requests it served gives the other boundary:

| | 262,144 rays | 1,048,576 rays |
| --- | ---: | ---: |
| one-shot, per request | 273.44 ms | 363.63 ms |
| resident, per request | 107.00 ms | 190.50 ms |
| ratio | 2.56 | 1.91 |

**Between those two boundaries the honest statement is that residency is worth
between 1.9 and 9.4 times depending on what the number is asked to cover.** The
gap between them is the supervisor: an interpreter start, the runtime's
SHA-256, two residency probes, the lease checks and the record writes, 38 ms
per request in the resident arm and 13 ms in the control. That is measurement
scaffolding, and a service would pay neither in this form; it is reported
because dividing a session's own wall by its requests is the only figure here
that leaves nothing out.

The gap narrows as the query grows because what residency removes is fixed. The
setup stages are 157 ms whatever the ray count, while the host reference that
no residency removes grows with the rays.

## Residency is held without the lease, and three readings differ

The driver reads the worker's device residency at a moment when it holds no
lease and has no request in flight, once after the session is ready and once
after its last request. Those readings are **214 MiB and 322 MiB** in every
session at 262,144 rays and **214 and 346** at the ceiling. The worker's own
accounting for the same moments is 4,008 bytes and **8,392,616 bytes at 262,144
rays and 33,558,440 -- 32 MiB -- at the ceiling**, because it counts what it
asked `cudaMalloc` for and cannot count the CUDA context and the OptiX module
and pipeline the driver put beside it. The allowance the row declares is held
against all three.

None of the three is an instantaneous maximum. The driver's are taken at the
two moments it can name; the worker's is its own figure as of its latest line;
`residency-during.tsv` is a ten-hertz capture, and the largest value it caught
is the largest it caught. **A sampler beside the run cannot decide the claim
this arrangement rests on.** The first version of the harness sampled the
driver's compute-client list and the lease ten times a second and found the
worker with the lease free in one tick of forty-six, because the gap between
two requests is shorter than any interval it can sample at: the driver returns
from one request and enters the next in under a tenth of a millisecond. That
sampled count is retained as
`runtime_clients_observed_with_lease_free_sampled` and the run is accepted on
the driver's own reading instead.

A reading the probe cannot supply ends the session. The allowance is enforced
by that reading and by nothing else, so a run continuing without one would be a
run admitted against an allowance nothing tested; `retirement/`'s
`residency-unread` arm is that path on the card, with a probe that fails where
a real session holds real device state.

## Every way a session ends, and what owned the destruction

Destroying device state is compute: it frees allocations and tears down an
acceleration structure, a pipeline and a context. A session ending on the
supervisor's word ends while the supervisor holds the compute lease. A session
ending on a bound of its own reaches that moment while the supervisor holds
nothing, so the worker announces the retirement it wants and waits for the
shutdown line the supervisor sends holding the lease. The worker acquires no
lease itself, so a supervisor holding one never waits on a child that wants one.

| arm | reason the worker cited | supervisor authorized | workers after | lease after |
| --- | --- | --- | --- | --- |
| shutdown | `shutdown` | yes | 0 | free |
| request-limit | `request_limit` | yes | 0 | free |
| idle-timeout | `idle_timeout` | yes | 0 | free |
| session-limit | `session_limit` | yes | 0 | free |
| residency-unread | run ended, worker destroyed under a lease taken to do it | n-a | 0 | free |
| residency-over | run ended, worker destroyed under a lease taken to do it | n-a | 0 | free |

`geometry-cube-orbit-a-retire` and `geometry-cube-orbit-a-wall` exist for this:
the measurement row serves sixteen requests over three hundred seconds, so a
run that measures what residency costs retires on the supervisor's word and
never on its own.

### The emergency path, and the deadline that makes the bounds reachable

A supervisor that never answers would leave a worker holding device memory for
as long as it lives, so the wait for authorization is bounded by
`geometry_protocol.RETIREMENT_AUTHORIZATION_S`, thirty seconds, which the build
compiles into the binary and which the driver refuses to be slower than. Past
it the worker destroys unauthorized and says so on stderr and in its retired
line.

`drip-lines.jsonl` is that path driven deliberately, and it is also the test of the
reader's deadline. The binary ran with an idle interval of six seconds and a
wall bound of eight while a sender fed it one byte of an unfinished request
line every second for thirty. **It announced `idle_timeout` at session age
6.235 s**, then waited out its authorization window with nothing answering,
retired at 30.834 s with `"authorized":false`, and left
`optix_runtime=emergency reason=retirement_unauthorized` on stderr. A reader
that renewed a relative timeout on each byte would have reached neither: a byte
every second resets a six-second wait forever, and session age is checked only
between requests, so the session would have run as long as the drip did.
`read_line` recomputes what is left of one absolute deadline each time round
instead.

## The reference share, corrected

**The reference is 87.1 percent of the validation stages at the ceiling, not
the 95.5 percent `../geometry-launch-timing/README.md` reports.** The
correction is the digest. `digest(results)` is FNV-1a over the packed per-ray
results, and in the merged runtime it ran after `wall_ms` was taken, in the
statement that assembles the JSON, so it fell inside neither the compare stage
nor the wall the stages were checked against. It now runs inside the compare
stage. At the ceiling `compare_ms` therefore reads 10.90 ms where the merged
captures read 4.03, and the roughly 7 ms between them is a byte-at-a-time hash
over the eight megabytes a million results occupy. That attribution is what
moved rather than what was measured; pricing it exactly would want a stage of
its own.

The merged file's completeness claim goes with it. The stages summed to
`wall_ms` to three decimals because both ended before the digest began, so the
table was complete over the interval it measured while the process did about
seven more milliseconds of work after the clock stopped.

The conclusion step one drew survives the correction, and the enlarged interval
does not make the reference less reusable: it is 73.85 ms of the 84.75 ms of
validation at the ceiling and 18.60 of 21.32 at 262,144 rays; it is a function
of the rays, the triangles and `t_max` alone; and it is the largest reusable
thing left in a resident request. The comparison and the digest are functions
of the device's answer and run per request by construction.

## What a resident request still pays

Of the 110.52 ms a resident request costs the client at the ceiling: ray
generation 18.44, upload 2.16, launch 0.78, download 1.51, reference 73.85,
compare 10.90. **The reference is 67 percent of it.** Ray generation is another
17 percent and is constant for a fixed query set, so it caches beside the
reference under the same reuse key. Upload, launch, download and compare
together are 15.35 ms, and that is the floor this arrangement has without
changing what is verified.

## Conditions

`at-262144/` ran at host load 1.28 before and 1.42 after with the GPU at 9 and
13 percent; `at-1048576/` at 1.38 and 1.43 with the GPU at 9 and 7;
`retirement/` at 12.01 and 8.30, which its checks do not depend on because none
of them is a timing beside another run's.
`scripts/qwen-exec-idle-priority.sh` runs the runtime at nice 19 with idle I/O
in both arms, so the arms are comparable to each other and to nothing measured
under another priority. The arms alternate block by block rather than running
in two batches, so a drift over the run reaches both.
`device-environment.tsv` carries the driver and device identity per run.

## What has not run

The reference cache itself. These runs measure residency alone: the reference
is recomputed on every request in both arms, which is what makes the two
comparable. Caching it is the next change, and its reuse key has to name the
ordered geometry and transforms, the ordered ray bytes, the intersection limit
and the reference implementation's build identity, because a reference computed
for one simulation state would otherwise verify the next on the strength of an
unchanged scene name.

**The worker's own memory ceiling cannot fire under any row this ledger
admits.** Its check compares what it has asked `cudaMalloc` for against the
row's allowance, and that figure reaches 33,558,440 bytes at the ceiling ray
count, 32 MiB. Any allowance under 214 MiB fails at the first residency reading
instead, because the CUDA context alone is that large before a request runs.
There is therefore no allowance at which a session starts and the worker's own
check refuses a request: the two accountings differ by an order of magnitude
and the driver's reading sets the floor. `budget_exceeded` is exercised against
the fake worker in `scripts/test-geometry-resident-driver.py` and is
unreachable on the card. Making it bind would mean holding the driver's reading
against the allowance per request rather than per idle moment, which is a
change to what the allowance means and is not made here.

Also unrun on the card: a session serving different ray counts, two sessions
contending for the lease, and any co-residency with a language model or a
PhysX job.
