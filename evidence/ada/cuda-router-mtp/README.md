# The multi-token-prediction head reaches a router child

`evidence/ada/speculation-runtime-classes.md` measures the MTP head at 1.23,
1.42, and 1.47 of baseline on the 2B, 4B, and 9B distills through a standalone
llama-server, and every appliance launch until this run printed
`speculation spec_type=off`. Whether the setting survives the router was open:
`server-models.cpp` ends its preset assembly with `preset.merge(base_preset)`
and `common_preset::merge` overwrites, which is documented in this tree for
`--ctx-size` and was unverified for the speculation flags.

`QWEN_SPEC_TYPE=draft-mtp scripts/admit-cuda-router-serving.sh` answers it. The
child's own argv carries `--spec-type draft-mtp`, and the discriminator that
`evidence/ada/speculation-runtime-classes.md` established holds: an ordinary
load reports each prediction-block tensor as `model has unused tensor ... --
ignoring`, and this run's server log carries none of those lines where the
run without the setting carries 15 per child. The head is loaded in the child
that executes the graphs.

Nine checks, none rejected. Both children answered `Oslo` from CUDA0 and both
were resident together at 5625 MiB of device memory, against 5307 MiB for the
same pair without the setting: the two prediction blocks cost about 318 MiB,
consistent with the 37,767,168 bytes the 2B's block carries plus the draft
context each child allocates.

## What this does not establish

The rate. This run drives one three-token reply per model, which proves the
route rather than the throughput, and the 1.23 to 1.47 figures come from the
standalone harness. A served-throughput arm under the router is unrun.

`scripts/models.tsv` carries no speculation fields, so the setting reaches the
server through the environment rather than through the registry, and every
child gets it or none does. A per-row setting is what would let the 0.8B serve
without a head it may not carry while the distills use theirs.
