# Task tracker

This file states this repository's open work on the current host: an AMD
Ryzen 5 5600X3D workstation carrying one NVIDIA GeForce RTX 4070 Ti, served
through the CUDA backend with Vulkan as the fallback the same binary reaches.
The settled operating configuration lives in `README.md`, repository doctrine
lives in `CLAUDE.md`, and `evidence/ada/` holds this host's own measurements.

## Depth validation

No depth-validation campaign has run on this host. Every `scripts/models.tsv`
row reads `-` in `validated_filled_depth`, and `scripts/validated-tuples.tsv`
holds no row. The prior host's depth prober was removed as driver-pinned, so
a CUDA depth prober does not exist yet; one must be written for this device's
CUDA and Vulkan backends before a 32K validation campaign can run.

## Graded quality suite

`evidence/quality-roster-cuda/` grades all twenty-three servable rows in one
withheld-image sweep on this host's CUDA serving path, with
`lfm25-12b-thinking` re-run at a 4096-token budget as its own condition. The
code category places `qwenseer-2b` at 9 of 10 near 232 tok/s, which moved
the fast-coding role to it; the 4B Q5_K_M and Q6_K rungs hold 10 of 10 in
the deeper tier. Open work here is incremental: a new registry row takes
one graded arm inside its own sweep rather than a roster rerun.

## Image lane

`scripts/image-profiles.tsv` carries every profile at `execution_policy=refused`,
so `scripts/build-web-presets.sh` emits no image MCP configuration from the
checked-in ledger. The image runtime, build, and standalone harnesses that
depended on the prior host's driver were removed. Admitting an image profile
on this host requires a Vulkan-capable image runtime built for this device,
a `scripts/image-profiles.tsv` row moved to `validator-gated`, and a fresh
admission run before any profile serves.

## CUDA runtime levers

`evidence/ada/cuda-runtime-levers.md` measures CUDA graphs, kernel fusion,
programmatic dependent launch, and the `GGML_CUDA_FORCE_MMQ` build arm on the
2B distill alone. The 0.8B and 4B classes have not run through the same
lever sweep, so no lever default is confirmed to hold across the three
runtime classes `CLAUDE.md` defines.
