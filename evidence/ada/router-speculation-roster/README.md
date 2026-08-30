# Per-row speculation reaches the child, and the swap-in guard did not

`scripts/admit-router-speculation-roster.sh` drives every servable row of a
running router once and reads back what the registry claimed about it. Nine
checks, none rejected, fifteen of fifteen rows answered.

## What each check reads

`roster_matches_registry` compares `GET /v1/models` against
`model-registry.sh servable-ids`. Eight servable ids are absent from the roster
because their artifacts are unfetched on this host, which the check reports;
a roster id the registry does not call servable is the failure.

`child_argv_matches_profile` reads `/proc/PID/cmdline` of the child whose
`--alias` names the row rather than the registry field or the generated preset.
That is where an overwritten section setting shows its absence:
`server-models.cpp` ends preset assembly with `preset.merge(base_preset)` and
`common_preset::merge` overwrites, which is the mechanism a global setting used
to reach every child through. Four rows carry `--spec-type draft-mtp`
(`qwen35-08b`, `qwen38-2b-distill`, `qwen38-4b-distill`, `qwenseer-2b`) and
eleven carry no speculation argument at all.

`prediction_block_loaded` reads the server log rather than occupancy. An
ordinary load reports each prediction-block tensor as `model has unused tensor
... -- ignoring` and an MTP load reports none; every speculating row loaded with
zero such lines. Occupancy cannot settle it, since the 2B's block is 37,767,168
bytes.

`occupancy_inside_carve_out` samples framebuffer and BAR1 occupancy at 0.2 s
across the whole admission, 153 samples. The peak observed is 5268 MiB of
framebuffer and 5287 MiB of BAR1 against a 12282 MiB carve-out. That figure is
**maximum observed framebuffer occupancy at the sampler interval**, not the
allocation a switch demanded: `nvidia-smi` reads the framebuffer counter alone,
misses a spike shorter than 0.2 s, and counts none of the driver-managed system
memory `evidence/quarantine/qwen38-9b-distill-router-load.md` records the
refusal in.

`mutation_refused` copies the registry, moves the first `mtp_layers=0` row to
`speculation_profile=mtp1`, and requires `build-router-presets.sh` to refuse it
by that reason rather than emit a preset a child would fail to load.
`qwen38-2b-uncensored` is the row the copy mutated.

## The finding is the guard, not the speculation

The first run of this admission ended at the fourteenth row with the server
gone, exit status 0, no NVRM line in the ring, and the 4B child's own memory
breakdown reporting 6606 MiB free. `telemetry.log` names what happened:

```text
abort_utc=2026-08-30T05:14:23Z reason=swapin_rate_breached
```

`monitor-qwen-runtime.sh` terminates the server when host swap-in exceeds
67108864 bytes in a one-second sample. The sample that tripped it read 83075072
bytes with `mem_available_kib=23617300` -- 23.6 GB free.

Two facts are measured. This host swaps to zram at priority 100 ahead of a 72
GiB file, and 23.6 GB of memory was available at the abort. The rate is
therefore consistent with predominantly zram decompression, which loading
fifteen checkpoints in sequence drives at rates a disk never reaches; it does
not prove it. `/proc/vmstat`'s `pswpin` is an aggregate across swap areas and
names no source device, and swap priority decides where a page is written
rather than where a later page-in reads from. Per-zram counters under
`/sys/block/zram*/mm_stat` and the backing device's own diskstats are what
would settle it, and no arm here reads them.

The policy rests on the second fact alone: a swap-in rate with 23 GB available
is not a thrash signature whichever device served the pages.

That retires a longer-standing misreading. Several server stops this session
were recorded as unexplained clean exits and attributed to the process tree
being reaped at the end of a long tool call. They were this guard: it sends
SIGTERM, llama-server leaves through its own `cleaning up before exit` handler
with status 0, and the session records `stopped_component=server`. The
attribution was wrong and the telemetry line was there to read.

The rate now terminates only where free memory has also fallen under
`swapin_headroom_mem_available_kib`, 8 GiB by default and well above the 4 GiB
reserve that terminates on its own. A breach above that headroom is reported
once and observed. The memory reserve, the affinity check, and the nice check
are unchanged.

## What this does not establish

A rate. Each row answers one short prompt, which proves the route and the
loaded prediction block rather than throughput. The served MTP A/B for
`qwen35-08b` and `qwenseer-2b` is what would move their
`speculation_evidence` off `capability-only`, and it is unrun.

The switch peak. The sampler's 0.2 s interval is a `nvidia-smi` process per
sample, which is the floor this host's CLI reaches; the 10 to 20 ms sampling a
transient allocation would need is not available through it. What the refused
pool is remains open.

## Falsifiers

- A speculating row whose child argv carries no `--spec-type` refutes the
  per-row emission.
- A speculating row whose load prints `model has unused tensor` refutes the
  prediction block reaching the child.
- A non-speculating row whose child argv carries `--spec-type` refutes the
  section boundary.
- A mutated registry that generates a preset refutes the capability gate.
- An observed occupancy peak at or above the carve-out refutes the roster's
  admission.
