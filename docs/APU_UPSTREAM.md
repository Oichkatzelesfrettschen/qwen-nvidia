# Relationship to qwen-apu

## Remote

`Oichkatzelesfrettschen/qwen-apu` is the upstream repository, reachable here
as the git remote `apu-upstream`. Its fetch URL names the GitHub repository and
its push URL is set to `DISABLED_no_push`, so `git push apu-upstream` fails
before it reaches the network, and `remote.pushDefault` is `origin`. The
upstream `main` branch is never merged into this tree.

## History boundary

This repository's history begins at a parentless commit,
`014df039cbc5f9e387811dbbb1b8d6d2e433a233`, whose tree equals the tree of
`qwen-apu` commit `55d8c73268d8c6496e77baaad732e1aea7a6183b`. The 456 commits
that produced that tree -- every Raven2 measurement, patch iteration, and
evidence file behind it -- live in `qwen-apu` alone; this tree carries the
tree state without the commit-by-commit path that reached it.

## What the remote is for

Fetch `apu-upstream` to inspect old evidence, cherry-pick a portable fix,
compare an implementation against its Raven2 predecessor, or recover a raw
record this tree's isolation pass dropped. It is not a source of merges,
rebases, or a shared branch.

## Evidence-class rule

Every measurement taken on Raven2 -- decode and prefill rates, memory-bandwidth
figures, RADV Vulkan submission-profile comparisons, ROCm/HIP results -- is
prior-host evidence: `performance_authority=none` and
`current_defaults_authority=none` on this host. A Raven2 rate never enters a
CUDA prediction band, and a CUDA default here is set only by a measurement
taken on this host's own hardware, in `evidence/ada/`.

## Scope cut: capabilities with no CUDA counterpart yet

The isolation pass removed these scripts from `scripts/` rather than porting
them to CUDA. Each name below identifies the capability by its Raven2-era
script; none of these paths exist in this tree, and the capability does not
exist on this host until someone writes a CUDA-side equivalent:

- **Depth-validation probing** -- `probe-depth-wedge.sh`, `run-depth-chain.sh`.
  No CUDA depth prober exists yet, so a 32K-depth campaign on this host needs
  one written first; the checked-in `validated_filled_depth` figures and the
  32K depth-validation evidence in this tree are Raven2 results.
- **The Vulkan submission-trace campaign** -- `run-trace-campaign.sh`.
- **The standalone image generation lane** -- `run-image-standalone.sh`,
  `build-stable-diffusion-vulkan.sh`.
- **The ROCm/HIP backend matrix** -- `run-rocm-vulkan-matrix.sh`,
  `build-llama-dual.sh`.
- **DPM governor measurement** -- `measure-dpm-force.sh`.
- **Host bandwidth and bench-repeatability harnesses** --
  `run-bandwidth-ladder.sh`, `measure-bench-repeatability.sh`.
- **The value-representation arm** -- `run-representation-arm.sh`.
- **The KV-cache/flash-attention factorial** -- `run-kv-cache-factorial.sh`.

Fetch `apu-upstream` to read a script's prior-host source before writing its
CUDA equivalent. None of these capabilities has a retained `evidence/ada/`
record,
and none backs a default stated in `README.md` or `CLAUDE.md`.
