# Releasing a checkpoint's page cache after its load

`run-01/` is one run of `../../../scripts/probe-page-cache-release.sh` on
the promoted closure with the 9B distill as model A and the 2B distill as
model B, three arms in sequence: a control, the advised arm, and a closing
control. Each arm loads A standalone on CUDA0, answers one request, stops it,
loads B the same way, then loads A again; the advised arm issues
`posix_fadvise(POSIX_FADV_DONTNEED)` over the whole 9B file between the first
A load and the B load. `steps.tsv` carries the reading after every step and
`summary.tsv` the derived rows. `/proc/sys/vm/drop_caches` was never written.

## What the advice does

Before the run the 9B was fully resident in the page cache, 1411155 pages of
1411155 (5.4 GiB), with the serving process holding one mapping of the file
while it served and none after it exited. The advice dropped every page in
0.180 s and `Cached` fell by 5.64 GB, with the 2B's 320353 pages untouched.

## What it costs and buys

| step | control-1 | advise | control-2 |
| --- | ---: | ---: | ---: |
| B load to healthy | 0.621 s | 0.622 s | 1.890 s |
| B first request | 0.088 s | 0.087 s | 0.162 s |
| A reload to healthy | 1.166 s | 17.144 s | 1.295 s |
| A reload sectors read | 0 | 23278968 | 40136 |
| A reload major faults | 1 | 139020 | 6060 |

The next model's load and first request are unchanged by the advice: the 2B
was cached in both arms and reads the same 0.62 s and 0.09 s. What the advice
buys is host memory, 5.6 GB of reclaimable cache turned free at once, and
what it costs is the reload: the 9B's next load took 17.1 s where the warm
reload took 1.2 s, through 139020 major faults on the mmap and 11.9 GB read
from the NVMe volume, about twice the file's size.

Two observations sit beside that cost and are recorded without a mechanism.
The cold reload left only 695249 of the 9B's pages resident and evicted the
2B's pages entirely, with `MemAvailable` above 19 GB throughout, so the
reload itself displaced cache it had just filled; the closing control's A
load then read 3.3 GB and took 5.3 s, and its B load read 1.4 GB and took
1.9 s, which is the same displacement paid a second time. And the cold
reload moved 11.9 GB through a 4 KiB-fault mmap path in 17 s, about 700
MB/s on a volume that reads sequentially several times faster; `llama-mmap.cpp`
issues `POSIX_MADV_WILLNEED` over the mapping ahead of the copy, so a
readahead and the copy's own faults both read the file, which is consistent
with the twofold volume and unmeasured. A `--no-mmap` load from cold is the
arm that would separate the fault path from the device.

## What this decides

The advice is a tool for a host under memory pressure rather than a default:
on this workstation with 19 GB available after every load, the cache costs
nothing to keep and the 9B's warm reload is what a model switch back to it
pays. No launch script adopts it. A follow-up arm loads from cold with
`--no-mmap` and with the file pre-read sequentially, which is where the
model-switch latency of a displaced checkpoint would actually move.
