# The assembled launch chain serves two checkpoints from CUDA

`remote/admit-cuda-router-serving.sh` ran the whole chain once on this host:
preflight, capacity policy, `cuda-runtime-env.sh`, the router exec guard, two
router children, and the teardown. Nine checks, none rejected.

| check | result | detail |
| --- | --- | --- |
| launch | accepted | router_max=2 |
| health | accepted | answered on the first poll |
| roster | accepted | `GET /v1/models` returned 7 ids |
| reply qwen38-2b-distill | accepted | served=qwen38-2b-distill, 3 tokens, `Oslo` |
| reply qwen35-08b | accepted | served=qwen35-08b, 3 tokens, `Oslo` |
| resident_children | observed | 2: qwen35-08b, qwen38-2b-distill |
| device_memory | observed | 5307 MiB used, desktop included |
| teardown | accepted | no server, session, probe, broker, service, or snapshot; port free |
| serving_device | accepted | both children allocated on CUDA0 |

The device check is why the script exists. The promoted binary carries both
backends and `common_param` enumerates CUDA0 and Vulkan0 for the same card, so
a child that names neither picks one by enumeration order: before
`qwen-capacity-policy.sh` derived `--device` from `QWEN_SERVING_BACKEND`, a
router child allocated 1441 MiB on Vulkan0 while every measurement setting the
defaults ran on CUDA0. The check reads the placement line each child prints
while loading and the memory breakdown it prints while unwinding, and it
ignores the enumeration line, which names an available backend rather than an
allocation.

Two children at 1441 and 870 MiB against a 12 GiB carve-out is what makes the
co-resident pairings the campaign asked about ordinary rather than tight: the
2B with the 0.8B, the 4B with the 0.8B, and the 9B with the 0.8B all fit behind
one picker at `QWEN_ROUTER_MAX=2`. That is a different claim from drafting,
which `evidence/ada/speculation-runtime-classes.md` refutes for the same pairs.

## What the run does not establish

One reply of three tokens per model exercises the route rather than the
quality, the depth, or the throughput of either child. The graded suite and the
depth arms are unrun on this host, so `remote/models.tsv` still carries `-` in
`validated_filled_depth` for every row and `remote/validated-tuples.tsv` holds
no `cuda` row.

The appliance's own lifetime is bounded by the invoking process group here:
`qwen-launch.sh` returns as soon as the session reports ready, and the tmux
session it started is a child of that group, so an interactive launch ends when
its shell does. The admission script stays in the foreground for the whole run
for that reason.
