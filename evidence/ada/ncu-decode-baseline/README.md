# Preregistration: what a decode token spends, read from measured kernel traffic

Every capture in this tree is Nsight Systems, which times a kernel and cannot
say why it took that long. This arm is the first Nsight Compute campaign on
this device, and it runs against the production closure alone with no candidate
patch, because its purpose is to establish where a batch-1 decode token goes
before any optimization is chosen.

## The question, and what it replaces

Retained rates leave a gap between a decoded token and the time that model's
own bytes would take to stream at the DRAM roofline. That gap is roofline slack
under an assumed bandwidth rather than measured overhead, and the assumption
decides the shape: at 504 GB/s theoretical the slack reads 1567 us on the 0.8B
Q8_0, 1719 us on the 2B Q4_K_M, 3285 us on the 4B, and 3257 us on the 9B, which
looks like two clusters; recomputed near the 442.61 GB/s this device's own
bandwidth-bound smoke kernel achieved (`profiling-permission/`) the same rates
give approximately 1326, 1339, 2481, and 1589 us and the clustering dissolves,
leaving the 4B alone as anomalous. A structure that inverts on the choice of
divisor is a property of the divisor, so no fixed-against-per-layer overhead split is
inferred from it.

GGUF byte count is not DRAM traffic per decoded token in either direction. It
omits activation, KV, and temporary-buffer traffic and the cache behavior over
all of them, it includes file material that never streams as weights, and a
memory transaction moves a cache line rather than the useful payload, which is
why NVIDIA reports requested traffic apart from actual device traffic. The
token budget this arm produces is therefore reconstructed from measured
per-kernel DRAM bytes and measured per-kernel durations.

## Arms

The backend runs distinct regimes and mixing them into one aggregate profile
explains nothing, so each is profiled as its own arm by dominant kernel family
rather than by request.

1. `fixup-08b-q8` -- the ne11=17 prefill shape that produced the clean fixup
   measurement in `../mmq-stream-k-grid/phase-b-witness/`, profiling
   `mul_mat_q_stream_k_fixup` beside the `mul_mat_q` launches it follows. This
   arm exists to decide #102's implementation and comes first because that
   decision is blocked on it.
2. `decode-08b-q8` -- ordinary batch-1 decode, profiling `mul_mat_vec_q` at
   ncols=1, the attention and KV path, and the major fused kernels, each read
   separately.
3. `decode-2b-q4k` -- the same on the primary performance target, which carries
   Q4_K and Q6_K in one forward pass.

Class order follows the repository rule where the arms are comparable; the
0.8B leads here because it is the shape the fixup measurement already holds.

## Retained per exact symbol and shape

```text
duration                        registers per thread
launch count                    local-memory traffic
DRAM bytes read and written     shared memory
DRAM throughput                 theoretical occupancy
L2 traffic and hit rate         achieved occupancy
requested against actual        eligible warps per scheduler
  global traffic                issued warps per scheduler
SM throughput                   scheduler utilization
grid and block geometry         actionable warp stall states
launches per token
```

Sections: `SpeedOfLight`, `MemoryWorkloadAnalysis`, `LaunchStats`, `Occupancy`,
`SchedulerStats`, `WarpStateStats`. A stall reason is read only where the
schedulers are failing to issue, since a largest-counter ranking taken over
healthy issue rates names a queue that was never the constraint.

## What this decides, stated before it runs

#102 branches on this arm and on nothing else:

- launch or scheduler dominated: descriptor-batched fixup is the first
  candidate.
- memory-latency dominated: restructure the `tmp_last_tile` reads while
  preserving the reduction order.
- occupancy or register limited: cut resource pressure without touching
  arithmetic.
- kernel body already small and efficient: batching and graph-node
  consolidation are the only credible targets left.

The wider branch, between kernel work and #43 shape-bucketed graphs with #44
GPU-side sampling, waits on this arm plus one node-level Nsight Systems decode
trace taken with `--cuda-graph-trace=node`, which partitions a token into GPU
kernel execution, GPU idle gaps between graph nodes, CUDA API and graph-launch
host time, host computation between submissions, and synchronization
boundaries.

## Falsifiers

The fixup kernel launches over the grid the MMQ kernel used and returns
immediately from every block that had no data, wrote the beginning of a tile,
or did not write the last partial, so a full-device grid carries a sliver of
useful work. That shape is consistent with launch and scheduling dominance and
equally consistent with a few blocks stalling on `tmp_last_tile` while the rest
of the device idles. An arm that reports high scheduler utilization and low
memory throughput refutes the second; an arm that reports long scoreboard
stalls on the working blocks refutes the first. Either way the source alone
cannot decide it, which is why this measurement precedes the implementation.

If the decode kernels already sit near sustainable DRAM throughput, the
remaining slack is launch and synchronization rather than bandwidth and no
kernel change addresses it.

## Preconditions this arm needs

Profiling permission is resolved and the resolution corrects a reading this
record first carried. `RmProfilingAdminOnly` reads 1 in
`/proc/driver/nvidia/params`, which on driver 610 reports the state of the
legacy registry key alone and says nothing about a capability grant, so it is
not sufficient grounds to refuse the campaign. The R610 capability system is
what decides it: `/proc/driver/nvidia-caps/sys-minors` names `profiler-device`
at minor 4324, `nvidia-modprobe -f` creates the node, read permission on
`/dev/nvidia-caps/nvidia-cap4324` grants the capability, and writing
`DeviceFileModify: 0` to the capability's proc entry keeps a later NVIDIA
user-space tool from recreating the node over that permission state.

The grant is narrow by construction. `profiler-device` alone carries the ACL
and already subsumes `profiler-context`; `profiler-context` at 4325 and
`trace-device` at 4326 stay root-only, since Nsight Systems tracing already
works and a tracing capability is a separate authority admitted separately if
an experiment ever needs it. The legacy key stays at 1, so no other local user
gains counter access and the global restriction is unchanged.

The functional proof is the authority rather than the file mode, because a
permission bit states configuration while a collection states capability.
`profiling-permission/` retains it: uid 1000 running `ncu` as an ordinary user
against an ordinary-user CUDA binary completed nine replay passes and collected
`SpeedOfLight` and `MemoryWorkloadAnalysis` with `ERR_NVGPUCTRPERM` absent.
`profiling_permission=accepted`,
`permission_source=nvidia-profiler-device-capability`.

The smoke also answers a question this arm was going to carry as an assumption.
Its kernel is bandwidth-bound by construction -- 8.75% SM throughput against
90.20% DRAM throughput -- and it achieved 442.61 GB/s. The sustainable figure
this record contrasts against the 504 GB/s theoretical is therefore measured on
this device rather than borrowed, under the desktop client set this host always
carries, from a single isolated kernel that `ncu` serialized. A decode kernel
reaching a fraction of 442.61 GB/s is the comparison the arms below make.

No reboot precedes the first window. Neither
`NVreg_RestrictProfilingToAdminUsers=0` nor `sudo ncu` is used: the first
widens the grant to every local user and needs a module reload, and the second
would run the profiled `llama-*` process as root, contaminating process
ownership, output ownership, and the GPU-client classification that
`scripts/gpu-workloads.tsv` enforces, which is the ordinary-user serving
condition these arms exist to characterize. The capability grant is temporary
until it is packaged as a boot-time oneshot resolving the minor dynamically
from `sys-minors` and applying the ACL to a dedicated group, and this record
names the packaging as unrun.

`ncu` serializes and replays kernels, so its timings are not rates. The arm
runs under the GPU owner lock as its own campaign, never inside a rate arm, and
its numbers never enter a rate comparison. `ncu --version` reads 2026.2.1.0 and
all six sections above are present in its section list.

Nothing is measured yet.
