# CUDA image runtime admission

## Claim

One approved image generation runs through the router on a CUDA-native
image runtime: stable-diffusion.cpp at the pinned commit built with
`SD_CUDA=ON` for SM89, every module placed on `cuda0`, behind the same
broker, grant, service, lease, and page path the Vulkan-era admission held
on the prior host.

## The runtime

`scripts/build-image-runtime-cuda.sh` compiles `sd-cli` from
`leejet/stable-diffusion.cpp` at `de298c225bed97c3f9026b73cd7b71e7879bd41b`
with the ggml gitlink `8e800cef2948046cc47f9db6090491c6128ca42c` read out of
the pinned tree, under `SD_CUDA=ON`, `CMAKE_CUDA_ARCHITECTURES=89-real`, and
`g++-15` as the host compiler, and prints the binary's SHA-256 as the
runtime identity; it executes nothing it built. The admission's sd-cli
template names `--backend` from `QWEN_IMAGE_BACKEND`, `cuda0` by default,
in place of the `vulkan0` the prior host's template carried, and the fake
runtime's `--list-devices` names `CUDA0`.

## Preregistration

`scripts/admit-image-router.sh` runs with the CUDA runtime, the
`sdxs-512` bundle, the 2B distill as the language profile, and the vision
review arm skipped. Written ahead of the first run on this host:

| check | holds when | refutes when |
| --- | --- | --- |
| runtime identity | the parameter file names the CUDA `sd-cli` and its digest equals the build record's | another path or digest |
| placement | the runtime's own log names `cuda0` for every module and no CPU fallback | a module on the CPU, or a refused `--backend` |
| generation | one `POST /tools` carrying the grant completes with a digest and a provenance route; the PNG read back hashes to that digest at the profile's dimensions | a refusal, a timeout, a dimension mismatch, or a digest mismatch |
| refusals | the replayed grant, the ungranted call, the out-of-schema argument, the foreign image profile, and the uncredentialed artifact read are each refused once | any of them admitted |
| page | the served page proposes, approves once, generates, and logs the grant posted once with every request on the router, broker, and artifact origins | a request elsewhere, or a second grant |
| teardown | no service, runtime, partial artifact, or held lease survives | residue |

The generation time is recorded and gates nothing; the prior host's
figures are Vulkan figures on other silicon and compare to nothing here.

## Runs

`run-01/` and `run-02/` are `scripts/admit-image-router.sh` on the device
with the CUDA `sd-cli` (SHA-256 `effce19d...7406f`, the build record's
digest), the `sdxs-512` bundle at placement `A`, and the review arm skipped.

| record | run 01 (2B distill) | run 02 (4B distill) |
| --- | --- | --- |
| checks | 31 accepted, 1 refused, 4 observed, 2 skipped | 38 accepted, 2 observed, 3 skipped |
| runtime argv | `--backend cuda0`, `--taesd`, steps 1, seed 20260829 | the same |
| curl generation | completed in 7 s wall, 5.42 s in the runtime, digest `8a551f9a...ad59b`, 584798 PNG bytes, nice 19 | completed in 2 s wall, 2.11 s in the runtime, the same digest and bytes |
| refusals | replayed grant, ungranted call, routing key in arguments, foreign image profile, uncredentialed artifact read, each refused once | the same |
| page turn | refused: the 2B answered `[An image of a fox in a snowy field]` in prose twice and proposed no call | accepted: one grant posted, the generation through `POST /tools` on the router, every request on the router, broker, and artifact origins, digest `d494b8a4...8afcf` at seed 42 in 1.31 s |
| teardown | clean | clean |

The runtime's provenance record names `--backend cuda0` on every module and
`exit_status 0`, and the same prompt at the same seed produced the same
PNG bytes across the two runs, 8a551f9a in both, so the CUDA runtime is
deterministic over one fixture at one seed. Run 01's page refusal is the
finding `scripts/image-profiles.tsv` already states for the 2B: its
`raw_tool_selection` grade reads 2 of 10 and it answers an image request
in prose, which is why an image-capable language profile names the 4B;
the curl arm passed on both runs, so the refusal is the language model's
and the runtime is admitted on both. The first generation of a fresh
process pays about 3 s more than the second, which is the runtime's
module load; a served figure needs the paired campaign the design names.

The retained directories hold the summaries, the request logs, the
provenance records, the two artifacts, and the page transcripts, with the
signing keys, the API key, and the broker's state removed before retention
and the home prefix scrubbed. `image-sdxs-512-a` stays `refused` in the
tree; the vision review arm against a CUDA runtime, the paired review
launch, and the promotion are separate transitions this record informs.
