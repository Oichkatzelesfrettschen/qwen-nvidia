# What a resident session costs, and what a one-shot query was measuring

A bounded resident session and its one-shot control ran interleaved on the
RTX 4070 Ti through `scripts/admit-geometry-resident.sh`, both arms driven by
`scripts/geometry-resident-driver.py`, which takes the compute lease around
every request and holds none between them. Two runs are retained: `at-262144/`
is three blocks of four requests per arm at 262,144 rays, `at-1048576/` is two
blocks of four at the profile's ceiling of 1,048,576. Both accepted at 8 of 8,
every request met the independent host reference on every ray, and both ledger
rows stay `execution_policy=refused` in the tree. An earlier pair of runs at
the same two counts, taken before the harness recorded the load a run carried,
produced the same figures to within their spread and is not retained.

## The launch a one-shot query reports is mostly not the ray trace

**A launch costs 0.30 ms in steady state, and the 2.5 ms a one-shot run reports
is first-launch cost it pays again every query.** The first launch of each
session reads 2.853 and 2.481 ms at the ceiling and 2.305, 2.304 and 2.386 at
262,144 rays. Every launch after it in the same session reads 0.282 to 0.315 at
the ceiling and 0.113 to 0.527 below it, with one at 1.065. The twenty one-shot
launches beside them read 2.299 to 2.953, because every one of them is a first
launch.

This revises the strongest claim in `../geometry-launch-timing/README.md`. That
file reports `launch_ms` as the most stable number in the measurement, 2.418 to
2.447 over six runs, and reads the ray trace as 2.43 ms of a 319 ms query. The
stability was real and the attribution was not: every run it averaged was a
process's first launch on a fresh pipeline, so what held still was the cost of
warming one. **The ray trace is about 0.3 ms at a million rays, and the 2.2 ms
beside it is paid once per pipeline.** A resident worker is the instrument that
separates them, because it is the only arrangement in which a second launch on
one pipeline exists.

## What residency buys, per request and per session

| | 262,144 rays | 1,048,576 rays |
| --- | ---: | ---: |
| one-shot, complete client latency | 303.19 ms, sd 11.63, n=12 | 399.83 ms, sd 9.62, n=8 |
| resident, complete client latency | 28.22 ms, sd 2.32, n=12 | 113.37 ms, sd 6.18, n=8 |
| session startup, once | 196.73 ms | 191.51 ms |
| session teardown, once | 10.61 ms | 9.10 ms |
| resident, amortized over four requests | 80.06 ms | 163.52 ms |

Complete client latency is the supervisor's own wall around a request: the
lease acquisition, the request, the reply and its validation. **A resident
request is 10.7 times cheaper than a one-shot query at 262,144 rays and 3.5
times cheaper at the ceiling**, and a four-request session including its
startup and its teardown is 3.8 and 2.4 times cheaper. The amortized figure is
the one a short session actually pays; quoting the warm request alone would
hide a startup that four requests are not many to divide.

The gap narrows as the query grows because what residency removes is fixed. The
setup stages are 192 to 197 ms whatever the ray count -- 63 percent of a
one-shot query at 262,144 rays and 49 percent at the ceiling -- while the host
reference that no residency removes grows with the rays.

## Residency is held without the lease, and the two readings differ

The driver reads the worker's device residency at a moment when it holds no
lease and has no request in flight, once after the session is ready and once
after its last request. Those readings are **214 MiB and 322 MiB** in every
session at 262,144 rays and **214 and 346** at the ceiling. The worker's own
accounting for the same moments is 4,008 bytes and 8,392,616 bytes, because it
counts what it asked `cudaMalloc` for and cannot count the CUDA context and the
OptiX module and pipeline the driver put beside it. Both readings are held
against the 512 MiB ceiling the profile row declares, and 346 is the peak.

**A sampler beside the run cannot decide this.** The first version of the
harness sampled the driver's compute-client list ten times a second and found
the worker with the lease free in one tick of forty-six, because the gap
between two requests is shorter than any interval it can sample at: the driver
returns from one request and enters the next in under a tenth of a millisecond.
That sampled count is retained as
`runtime_clients_observed_with_lease_free_sampled` and the run is accepted on
the driver's own reading instead, taken at a moment the driver can name.

## The reference share, corrected

**The reference is 87.0 percent of the validation stages, not the 95.5 percent
`../geometry-launch-timing/README.md` reports.** The correction is the digest.
`digest(results)` is FNV-1a over the packed per-ray results, and in the merged
runtime it ran after `wall_ms` was taken, in the statement that assembles the
JSON, so it fell inside neither the compare stage nor the wall the stages were
checked against. It now runs inside the compare stage. At the ceiling
`compare_ms` therefore reads 11.00 ms where the merged captures read 4.03, and
the roughly 7 ms between them is a byte-at-a-time hash over the eight megabytes
a million results occupy. That attribution is what moved rather than what was
measured; pricing it exactly would want a stage of its own.

The merged file's completeness claim goes with it. The stages summed to
`wall_ms` to three decimals because both ended before the digest began, so the
table was complete over the interval it measured while the process did about
seven more milliseconds of work after the clock stopped.

The conclusion step one drew survives the correction. The reference is 74.50 ms
of the 85.50 ms of validation at the ceiling and 18.47 of 21.27 at 262,144
rays; it is a function of the rays, the triangles and `t_max` alone; and it is
the largest reusable thing left in a resident request. The comparison and the
digest are functions of the device's answer and run per request by
construction.

## What a resident request still pays

Of the 113.37 ms a resident request costs the client at the ceiling: ray
generation 18.62, upload 4.58, launch 0.30, download 2.78, reference 74.50,
compare 11.00. **The reference is 66 percent of it.** Ray generation is another
16 percent and is constant for a fixed query set, so it caches beside the
reference under the same reuse key. Upload, launch, download and compare
together are 18.66 ms, and that is the floor this arrangement has without
changing what is verified.

## Conditions

`at-262144/` ran at host load 2.79 before and 2.73 after with the GPU at 34 and
27 percent; `at-1048576/` at 2.73 and 2.91 with the GPU at 26 and 28. These are
the quietest windows these measurements have had.
`scripts/qwen-exec-idle-priority.sh` runs the runtime at nice 19 with idle I/O
in both arms, so the arms are comparable to each other and to nothing measured
under another priority. The arms alternate block by block rather than running
in two batches, so a drift over the run reaches both.
`device-environment.tsv` carries the driver and device identity per run.

## What has not run

The reference cache itself. This change measures residency alone: the reference
is recomputed on every request in both arms, which is what makes the two
comparable. Caching it is the next change, and its reuse key has to name the
ordered geometry and transforms, the ordered ray bytes, the intersection limit
and the reference implementation's build identity, because a reference computed
for one simulation state would otherwise verify the next on the strength of an
unchanged scene name.

Also unrun on the card: a session serving different ray counts, two sessions
contending for the lease, a session ending on its idle timeout or its wall
bound, a session refusing a request against its memory ceiling, and any
co-residency with a language model or a PhysX job. Those retirement paths are
exercised against the fake worker in
`scripts/test-geometry-resident-driver.py` and have not been reached on the
device.
