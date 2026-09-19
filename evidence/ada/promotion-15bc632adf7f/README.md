# Promotion of configuration 15bc632adf7f

The promoted tuple is the 88681bf4d161 serving closure with
`patches/llama-server-vulkan-workload-lease.patch` applied: architecture
89-real (cubin=187 ptx=0), CUDA backend alone, the AD104 MMVQ thresholds at
ten for Q6_K and sixteen for Q8_0, and llama-server as the fourth holder of
the compute lease beside `image-service.py`, `physics-service.py` and
`geometry-service.py`. The source is the pinned commit `f280b26983ad` with
the six production patches and the candidates `llama-vulkan-view-alias-deps`,
`llama-server-vulkan-workload-lease` and `llama-cuda-mmvq-crossover-ad104`
applied, source diff `76f4b8e888cd`, the identity
`../../lease-coverage/candidate-build-source-identity.tsv` records. The
closure was built on 2026-09-05 and is the subject
`../../lease-coverage/admission-preparation/` names; every reading below was
taken on the workstation on 2026-09-18 and 2026-09-19 with the desktop's
three graphics clients present and unchanged across each run.

## What the campaign read

Off-device, `scripts/test-load-lease-coverage.sh` reads the reach stage
accepted over the patched `server-context.cpp`, `scripts/test-vulkan-workload-lease.sh`
reads the path and patch halves accepted at patch digest `64cf5b75eeb1`, and
`scripts/test-closure-identity-token-count.py` passes.

On the device, in the order the preparation record names:

| Arm | Reading | Record |
| --- | --- | --- |
| served lease exclusion | admitted: the decode acquire waited 5897 ms behind a 6 s holder, released once every slot idled | `../../lease-coverage/device-admission/served-lease-15bc632adf7f.log` |
| load-path coverage | accepted, reach and served, projector required, seven served arms | `../../lease-coverage/device-admission/load-coverage-15bc632adf7f/` |
| companion vs candidate, qwen35-2b, projector loaded | identical, 12 of 12, controls identical | `../../lease-coverage/device-admission/identity-companion-vs-candidate-qwen35-2b/` |
| historical vs candidate, qwen35-2b, projector loaded | identical, 12 of 12 | `../../lease-coverage/device-admission/identity-historical-vs-candidate-qwen35-2b/` |
| companion vs candidate, qwen35-08b, mtp1 | identical, 12 of 12 | `../../lease-coverage/device-admission/identity-companion-vs-candidate-qwen35-08b/` |
| historical vs candidate, qwen35-08b, mtp1 | identical, 12 of 12 | `../../lease-coverage/device-admission/identity-historical-vs-candidate-qwen35-08b/` |
| router serving admission | accepted, nine of nine, router max 1, both children on CUDA0 | `serving-summary.tsv` |
| single-model session shutdown | orderly: `teardown_exclusion=orderly`, `session_retirement=completed`, `qwen-teardown.sh` exit 0 | `../../lease-coverage/device-admission/single-model-teardown-15bc632adf7f.log` |
| promotion gate | accepted: strict_cuda=passed, multimodal_cuda=passed, backend_set=cuda | `../../lease-coverage/device-admission/promotion-gate-15bc632adf7f.log` |
| everyday launch after promotion | `scripts/qwen-launch.sh default` with no override, teardown exit 0, orderly | `../../lease-coverage/device-admission/post-promotion-teardown.log` |

The router serving admission ran at `QWEN_ROUTER_MAX=1` because the registry
rows `qwen38-9b-distill` and `qwen25-coder-7b` carry `switch_policy
evict-first`, which the policy admits at capacity one alone; the 88681bf4d161
admission predates those rows and ran at two. Its `serving-summary.tsv`
records `resident_children 1:qwen35-08b` and `teardown accepted`, and the
session's drain record for that run reads `teardown_reading=not_held`: both
router children logged `vulkan workload lease teardown: held=yes`, and the
router parent, which loads no model and arms no lease, logged `held=no`, so
the single-model rule in `qwen-retire-server-child.sh` counts one `held=no`
and the exclusion stays unattributed in router mode. Attributing a router
session needs `patches/llama-router-orderly-retirement.patch`, which
`evidence/lease-coverage/runtime-drain-integration/` names as a separately
built closure; this promotion changes nothing there.

## What the campaign corrected

`scripts/test-vulkan-workload-lease.sh` read the first acquire line in the
server log, which under the extended patch is the load-path acquire with
`bound=deadline` and `waited_ms=0`, written while the lease was still free;
the first device run failed on `waited_ms=0 below 5000` while the reply had
waited the full hold. The check now reads the last acquire without that
suffix, the decode-path acquire the check is about, and the same run reads
`waited_ms=5897`.

`scripts/promote-llama-build.sh` refused the candidate for lacking
`artifact-manifest.tsv`. No script in the tree wrote one: the builder's
writer left with the import, and every closure built since carried none.
`scripts/write-artifact-manifest.sh` reproduces the 88681bf4d161 manifest byte
for byte from its build directory, the builder calls it after the artifact
check, and `scripts/test-write-artifact-manifest.sh` admits it; the candidate's
manifest was written with it before the gate ran.

## What stays open

The two image-review rows of the behavioral matrix are `not_run`: the
preparation record requires the schema-bearing reviewer request across all
three closures with exact token identifiers retained, and the tree carries
no harness that does that; `scripts/run-vision-review-control.sh` returns
verdicts, not identifiers. The capacity-one eviction arm served at router max
one inside the router admission, and its orderly attribution waits on the
orderly-retirement closure above. Telemetry restoration was not applicable:
no diagnostic listener answered on 18086 before or after the window.

A forced tool call, which graft's `--deep` pass records through and
`scripts/graft-consumer-env.sh` probes for, is answered by the 4B distill
and answered in prose by the 2B distill on this closure with `--jinja`
present, at 128 and 1024 tokens and with thinking disabled
(`../../lease-coverage/device-admission/probe-model-dependence.log`); the
probe's refusal names both the flag and the model.
