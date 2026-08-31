# Evict-first admission for qwen25-coder-7b

`scripts/models.tsv` moves the 7B coder to `switch_policy=evict-first`, and
this run is the admission that the router transition it names holds on the
device: `scripts/admit-evict-first-transition.sh` at `QWEN_ROUTER_MAX=1`
serves one reply from the resident `qwen38-2b-distill`, requests
`qwen25-coder-7b`, and watches the transition through a 4 Hz roster poll and
the 100 ms telemetry sampler.

All seven checks accepted. The roster poll shows the sequence the policy
requires: the resident reads `unloaded` at 1788213669207 ms while the
successor still reads `loading`, and the successor reads `loaded` 1404 ms
later, so the victim child left the device before the 7B allocated.
Framebuffer trough 1255 MiB against the 1199-1225 MiB desktop rest, peak
6272 of 12282 MiB against the 11500 ceiling, and both models answered from
their own ids. Teardown proved absence.

The claim this narrows to: the 7B is the standalone deep coder, servable
through the router only as an evict-first successor at `QWEN_ROUTER_MAX=1`
and at its validated 8192 depth, alongside the qwenseer-2b fast coder whose
own 65536 filled-depth arm (`evidence/depth-validation-cuda/qwenseer-2b/`)
covers the coding lane's 32768 floor.
