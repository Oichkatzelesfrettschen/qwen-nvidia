# The assembled chain serves after the directory rename

`evidence/ada/cuda-router-serving/` admitted this chain while the scripts lived
under `remote/`. Between that run and this one the directory became `scripts/`,
`monitor-qwen-runtime.sh` stopped branching its expected scheduling policy on
the backend, six launchers stopped defaulting to a retired profile name, and
the Vulkan fallback wrapper was rewritten. Each of those edits sits on a link
the chain resolves at run time, and a fixture server exercises none of them, so
the chain is re-admitted rather than assumed.

`scripts/admit-cuda-router-serving.sh` launches in router mode at
`QWEN_ROUTER_MAX=2`, asks two models for one reply each, reads back the
placement line and memory breakdown each child prints, and tears the appliance
down. Nine checks, none rejected.

| check | result |
| --- | --- |
| launch | accepted, router_max=2 |
| health | accepted, waited 0s |
| roster | accepted, 7 ids |
| reply qwen38-2b-distill | accepted, answered Oslo |
| reply qwen35-08b | accepted, answered Oslo |
| resident children | 2, qwen35-08b and qwen38-2b-distill |
| device memory | 4053 MiB |
| teardown | accepted, no residue, port 8080 free |
| serving device | accepted, both children on CUDA0 |

Device memory reads 4053 MiB against the 5307 MiB the earlier run recorded for
the same pair. The compositor's own occupancy differs between the two runs --
`nvidia-smi` reported 1182 MiB resident before this launch -- and the figure is
whole-device rather than per-process, so the two are not a paired comparison
and neither bounds the other.

## What this does not establish

A rate. Each model answers one three-token prompt, which proves the route and
the placement rather than the throughput. `evidence/ada/baseline-sweep-02/`
carries the rates.
