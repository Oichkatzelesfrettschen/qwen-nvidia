# The 9B rejoins the router through a proven evict-first transition

`evidence/quarantine/qwen38-9b-distill-router-load.md` names its first
re-entry gate: an evict-before-load router mode that releases the outgoing
child and proves its allocations returned before the incoming child
allocates. `scripts/admit-evict-first-transition.sh` runs that proof on the
assembled chain: the router at `--models-max 1` serves a reply from the 2B
distill, then receives a request for the 9B while a 4 Hz roster poll and
`scripts/sample-transition-telemetry.sh` at 100 ms cadence watch the
transition.

Two runs carry the admission. The research-override run
(`research-*.tsv`) exposed the then-quarantined row on loopback; the plain
run (`transition-*.tsv`) followed the quarantine lift on the regenerated
preset. Both read identically:

- The roster poll shows the 2B at `unloaded` about 2.2 seconds before the
  9B enters `loading`, and the 9B reaches `loaded` with the 2B still
  unloaded, so the count-gated evict-then-load sequence in
  server-models.cpp (`ensure_model_ready` waiting on the victim child's
  exit before `try_claim` admits the load) held on the device.
- The framebuffer trough between the two plateaus is 1227-1228 MiB against
  a 1199 MiB desktop rest, so the 2B's allocations returned to within
  about 30 MiB of baseline before the 9B allocated: the overlap the
  quarantine record names as the trigger did not occur.
- The peak is 7578-7579 MiB against the 12282 MiB carve-out, and the 9B
  answered from its own id with a correct reply.

The kernel ring across both transition windows carries no NVRM line. The
`nv_gpu_ops.c:5077` chain does appear once in this boot's ring, 7.8 hours
before the admission during a single-process bench sweep that completed
and returned its rates -- the non-fatal variant the quarantine record
already documents as a code path rather than a cause.

The quarantine row is lifted on this gate, `scripts/models.tsv` carries
`switch_policy=evict-first` on the 9B row, and `qwen-capacity-policy.sh`
refuses any launch that would put the 9B on a roster wider than one. The
prior sweep's death at `--models-max 1` predates this llama.cpp pin; the
sequence measured here is the pinned tree's own.
