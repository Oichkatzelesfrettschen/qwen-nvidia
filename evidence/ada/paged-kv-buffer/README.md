
## Result

`2b-run-01/` admits P1 on the 2B under closure `9a1c6a42dc40`, which is the
pinned tree with the crossover patch and this patch alone; the subject arm is
that closure's own binary under `LLAMA_KV_PAGED_BUFFER=1`.

| record | reading |
| --- | --- |
| granularity minimum, recommended | 2097152, 2097152 bytes; probe in 0 of 3 client samples |
| batch-1 tokens | 12 of 12 arms identical (subject and closing control against the opening control) |
| slot-0 state files | 12 of 12 byte-identical, 21.9 to 22.1 MB each; digests retained, bytes removed |
| placement fingerprint | one value across the three arms |
| kv_logical_bytes | 327155712 |
| kv_virtual_reserved_bytes | 327155712 |
| kv_physical_mapped_bytes | 327155712 |
| kv_alignment_padding_bytes | 0 |
| memory_saved_bytes | 0, by construction |
| tensors in the paged buffer | 12: K and V of layers 3, 7, 11, 15, 19, 23; no recurrent tensor |
| recurrent store | `CUDA0 RS buffer size` line present in every arm, default path |
| primed width 1 | replies identical in 4 of 4 bursts, delivered ratio 1.0000 |
| primed width 3 | replies identical in 4 of 4 bursts, delivered ratio 0.9997 |
| kernel ring, client set | 0 hazard lines; the desktop compositor and one browser GPU process across every arm |

Every K row is 544 bytes and every V row 288, so a 2 MiB unit holds 3855.06
K rows or 7281.78 V rows: rows cross unit boundaries, and a sparse mapping
maps units rather than cells. The tensors are 17 and 9 units each, which is
why the padding reads zero at this depth; another depth or checkpoint pays
under one unit per tensor.

`graph-lifecycle-control/` and `graph-lifecycle-paged/` run
`scripts/run-graph-lifecycle-trace.sh` on closure `26f6a050cea8`, which
layers the census and lifecycle recorders on this patch, once with the
default KV buffer and once under `LLAMA_KV_PAGED_BUFFER=1`, over identical
prompt token arrays. Both arms record 35 warmup resets, every one
`structure` at `model.input_embed` with categories `shape,data`, and zero
rows whose change is a pointer alone; both read ten recurring topology
digests, the same episode medians of two direct executions, one capture,
and one update, and reply digests `c7c786b61660`, `191b3084c056`, and
`95c3695e7d2d` in the same arms. The lifecycle fraction reads 0.02234 under
the paged buffer against 0.02284 under the default. The reply digests differ
from `evidence/ada/graph-lifecycle/2b-run-02/` because the passage the
harness cuts its prompts from is this repository's own doctrine file, which
grew between the two runs; the control and paged arms here read one
passage, as the retained token arrays show.

P1 is admitted as a buffer mechanism and stays off for serving. What it
leaves open, in order of what P2 must answer before any unmap: which mapped
units may be absent while attention reads views padded to 256 rows past the
live cells; whether attention touches masked rows; what the physical
live-range unit is against a 2 MiB unit that neither row size divides; how
page reference counts follow `seq_rm`, `seq_cp`, K-shift, and stream copy;
how a state restore commits its destination units before it writes; and when
`cuMemUnmap` may run relative to queued CUDA work. Prefix sharing waits until
allocation, free, and recycling are exact.
