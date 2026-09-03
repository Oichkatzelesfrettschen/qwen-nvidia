# What the counters say: decode is at the roofline, and the fixup stalls on memory

Three arms ran on the promoted closure `88681bf4d161` with no candidate patch,
under the owner lock with the appliance stopped, the kernel ring at 44
signatures before and after, and the same three desktop clients throughout.
`run-01/` holds the fixup arm and `run-02/` the two decode arms.

Two of the campaign's preregistered branches are decided, and both land on the
side the source reading argued against.

## The fixup is memory-latency bound, not launch bound

`mul_mat_q_stream_k_fixup<Q8_0, 24>` carries 150 of the 186 launches Phase B
counted and 65% of its fixup time. Medians over 14 profiled launches:

| counter | width 24 | width 32 |
| --- | ---: | ---: |
| stall long_scoreboard, inst/issue | 11.85 | 0.35 |
| stall wait, inst/issue | 3.05 | 3.36 |
| L2 hit rate | 25.1% | 39.0% |
| DRAM throughput | 33.3% | 3.2% |
| DRAM rate | 162.0 GB/s | 15.5 GB/s |
| issue active | 9.3% | 20.7% |
| achieved occupancy | 17.0% | 24.0% |
| registers per thread | 39 | 40 |
| waves per multiprocessor | 0.33 | 0.33 |

`long_scoreboard` is waiting on global memory, and at 11.85 instructions per
issue it dominates the width-24 class by nearly four times its next stall. That
class reads `tmp_last_tile[bidx*(J*I) + j*I + i]` over descending `bidx` with a
25.1% L2 hit rate, the lowest of any kernel measured here, so the reduction
walks a stride the cache does not hold.

The width-32 class carries a different bottleneck entirely: `long_scoreboard`
nearly vanishes at 0.35 while `wait` leads at 3.36, which is execution
dependency on work too small to hide it. That the two classes are limited by
different things is the counterpart of Phase B's finding that they moved in
opposite directions when the fixup was removed.

Neither class is resource-limited. 39 and 40 registers per thread leave
occupancy free, and B19's reading that a high register count alone is not
spilling holds in the other direction here as well: a low count is not
headroom being used.

**#102 takes the memory-latency branch.** The first candidate restructures the
`tmp_last_tile` access for locality while preserving the per-output partial-sum
order, rather than batching descriptors. Descriptor batching addresses the
0.33-wave launch geometry both classes share, which is real but secondary: the
class holding two thirds of the time is stalled inside the kernel rather than
waiting to start it.

## Decode already runs at the sustainable roofline

`mul_mat_vec_q` at ncols=1, medians per symbol:

| arm | symbol | DRAM rate | DRAM % | duration | occupancy | waves |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 0.8B Q8_0 | `<Q8_0,1,0>` | 340.7 GB/s | 69.7% | 6.59 us | 53.6% | 2.13 |
| 0.8B Q8_0 | `<Q8_0,1,1>` | 405.5 GB/s | 82.8% | 14.64 us | 71.7% | 3.84 |
| 2B Q4_K_M | `<Q4_K,1,0>` | 192.9 GB/s | 39.5% | 5.07 us | 71.2% | 1.78 |
| 2B Q4_K_M | `<Q4_K,1,1>` | 444.7 GB/s | 90.6% | 32.38 us | 66.4% | 11.38 |
| 2B Q4_K_M | `<Q6_K,1,0>` | 435.8 GB/s | 88.8% | 24.62 us | 90.6% | 8.53 |
| 2B Q4_K_M | `<Q6_K,1,1>` | 432.1 GB/s | 88.0% | 24.61 us | 74.7% | 3.41 |

The isolated bandwidth-bound reference kernel in `profiling-permission/`
achieved 442.61 GB/s on this device. The 2B's Q4_K weight-carrying launch reads
444.68 GB/s and its Q6_K launches 432 to 436 GB/s, so the kernels that move the
weights are at that ceiling rather than near it. The 0.8B reaches 82.8% of peak
on its larger launch.

This settles the campaign's wider branch by its own preregistered falsifier: a
decode kernel already at sustainable DRAM throughput leaves the remaining
per-token slack in launch, submission, and synchronization rather than in
bandwidth, and no kernel change reaches it. **#43 shape-bucketed graph
prewarming and #44 GPU-side sampling are the targets; a mat-vec kernel rewrite
is not.**

The launches that fall short are the small ones. `<Q4_K,1,0>` at 1.78 waves
reads 39.5% and `<Q8_0,1,0>` at 2.13 waves reads 69.7%, against 88 to 91% for
the launches above 3.4 waves. Work too small to fill the device is the shape
that recurs across every arm here, the fixup's 0.33 waves included.

## What these numbers are not

`ncu` serializes and replays each kernel, so no duration here is a rate and none
belongs in a rate comparison. The width-24 fixup reads 4.78 us median under the
profiler against the 2.49 us per launch Phase B's Nsight Systems capture
implies, and that difference is the profiler.

The DRAM percentages are of `gpu__dram_throughput` peak at the clock each launch
ran at, and the desktop client set held three graphics clients throughout, which
is this host's standing covariate rather than a controlled condition.

Sample counts are 14, 14, 6, and 6 launches for the fixup arm's four symbols and
3 to 28 for the decode symbols. The width-24 `long_scoreboard` spread is 6.09 to
19.08 against a 0.35 median in the width-32 class, so the classes separate by
far more than either varies.

`profiler_device_minor=4324` with the ordinary account reading the capability
node; `RmProfilingAdminOnly` stayed 1 and no process ran as root.

The `closure` line in `run-01/summary.tsv` and `run-02/summary.tsv` carries
`28266b1589d5...`, which is the SHA-256 of the `llama-bench` executable rather
than the configuration digest that names the build directory. Both arms ran
`build-appliance-current`, which resolves to `build-qwen-cuda-88681bf4d161`, the
promoted closure every other record in this tree names. `run-ncu-kernel-baseline.sh`
now prints the configuration digest as `closure` and the executable digest as
`bench_binary_sha256`, so a later arm's summary is greppable by the id the rest
of the tree uses; these two retained summaries keep the field as written.

## A later arm corrected the #102 branch above

`../mmq-fixup-pipeline/` took the memory-latency branch this file selected,
implemented it, and measured 1.3% of the `long_scoreboard` it targeted with
identity and compute-sanitizer both clean. In that capture the stall
anti-correlates with the duration across the J=24 launches, so it reports
idleness rather than cost, and the 0.33-wave launch geometry this file called
secondary is the constraint. The measurements here stand as taken; the branch
ordering they set does not.
