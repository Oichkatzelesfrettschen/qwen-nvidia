# Image appliance design and first-campaign falsifiers

The HP 14-dk1xxx laptop is the image appliance: an AMD Athlon Silver 3050U,
Raven2 gfx902, two Zen+ cores at 2.3 GHz, two Vega compute units, 29 GiB of
shared DDR4, Mesa RADV. It is the development target, the benchmark authority,
and the delivery machine at once, so every ceiling, prediction, and requirement
in the image lane comes from measurements taken on it. A result from another GPU
describes another machine and stays out of this tree.

Nothing in this document is a measurement. No image has been generated on the
appliance, so every quantity below is either a bound this lane imposes or a
prediction registered with the observation that would refute it.

## The milestone and the state machine

One approved 512x512 image is generated locally by a pinned native Vulkan
runtime, its provenance is retained, it appears in the qwen-apu fallback Web UI,
and the ordinary LLM router comes back cleanly afterwards. The later shape is
bounded generation, a vision review of the result, and at most two approved
corrections.

One Vulkan workload runs at a time, and the sequence returns to idle between
each:

```text
idle -> LM request -> idle -> image request -> idle -> vision review -> idle
```

The order of proof follows that machine. The first campaign is standalone with
the router torn down: `qwen-teardown.sh`, prove no llama process survives, run
the pinned runtime, generate, capture telemetry, exit, prove the image process
is gone, `qwen-launch.sh`. LLM residency tests follow only after that campaign
passes, and a shared Vulkan workload lease at
`~/qwen-webui-state/vulkan-workload.lock` follows only after residency. In that
lease the kernel lock file descriptor is the authority and the text status file
is an observation of it, it covers active GPU work alone, and the child doing
the work holds it -- never the router parent and never an idle loaded model.

## Three files because there are three claims

A file, a bundle, and a served shape are separate claims, and merging them loses
a distinction the runtime acts on.

`remote/image-artifacts.tsv` holds a byte sequence a publisher offers:
repository, revision, filename, SHA-256, byte count, licence, component type,
and the fetch script that pins it. Identity here is the digest, and the row says
nothing about what the file is for.

`remote/image-models.tsv` holds a bundle: the set of artifacts that produce one
image together, with the architecture, the trained resolution, and the
publisher's own sampling recipe. The split earns itself immediately -- the SD
1.5 diffusion checkpoint appears in two bundles, once with the VAE packaged
inside it as `sd15-base` and once with `sd-vae-ft-mse` as a separate decoder in
`sd15-lcm-v1`, over the identical trunk bytes. A registry with one row per file
states that pairing nowhere, and a registry with one row per bundle downloads
the trunk twice.

`remote/image-profiles.tsv` holds a served shape: one bundle at one placement
arm with a request geometry and the bounds that admit it. Several profiles reach
one bundle the way several web profiles reach one checkpoint, because the arm
and the step count are what a campaign varies while the bundle stays fixed.

The three component slots carry three tokens rather than one. An artifact id
names a separate file; `packaged` states that the diffusion artifact carries the
component inside itself, which is what a single-file Stable Diffusion checkpoint
does with its CLIP encoder and its VAE; `-` states that the bundle omits the
component. A single `-` for the first two merges cases the placement arms
distinguish: arm B runs the text encoder on the CPU and arm C runs the VAE there
too, so `remote/image-registry.sh` requires the arm's components to be named,
and a bundle that omits one has no arm to place it on.

`remote/image-quarantine.tsv` carries model and profile scopes for the same
reason `remote/quarantine.tsv` does: "this bundle cannot run here" and "this arm
at this size does not retire" are different claims that steer different later
choices. It holds a header and no rows, because no image subject has failed yet.

## What the registries admit today

Every profile reads `execution_policy=refused`, so the ledger admits shapes and
authorizes nothing; no generation executes against a checked-in row. Every
bundle reads `tier=candidate`: the architecture, resolution, and recipe are read
from the publisher, and quality and throughput stay unqualified while no device
failure exists. Every artifact leaves revision, SHA-256, and byte count at `-`,
and those three move together, so the pin lane makes one atomic edit per file
and a partial pin is refused rather than trusted. The fetch-script column is
validated by name shape rather than by an executable path, which is where these
registries diverge from `remote/models.tsv`: a served checkpoint's downloader
exists because the checkpoint is on the machine, and an image row states an
admitted source before any byte has crossed the network.

`remote/image-registry.sh` validates all four files whole on every query and
answers from the rows validation returned, so a caller reading one profile
cannot act on a ledger a sibling row has made unsafe to read, and a file
replaced between validation and the answer cannot separate semantic admission
from the rows acted upon.

## The model funnel

SDXS-512 runs first at 512x512, batch 1, minimal steps, fixed seed, and fixed
prompt, because a one-step distilled trunk puts the smallest possible graph on
the device and any failure it produces is a property of the runtime rather than
of the workload. SD 1.5 with the LCM LoRA at about four steps follows, then
plain SD 1.5 as the quality control that the distilled rungs are read against,
with SD-Turbo as the alternate. SDXL, FLUX, ControlNet, video, upscalers,
multiple LoRAs, inpainting, and any batch above one stay out of first admission.

## Placement arms

Arm A runs the text encoder, the diffusion trunk, and the VAE on Vulkan. Arm B
runs the text encoder on the CPU with diffusion and VAE on Vulkan. Arm C runs
the text encoder and the VAE on the CPU with diffusion alone on Vulkan. The
laptop decides between them by measurement. The language ladder is the reason
three arms exist rather than one answer: every tested hybrid placement lost to
full Vulkan there, because a split adds synchronization and activation transfers
while both sides draw on the one DDR4 controller. Whether a diffusion graph,
whose text encoder runs once per image rather than once per token, repeats that
result is unmeasured, and arm B against arm A on `sdxs-512` is the comparison
that answers it.

## Falsifiers for the first standalone campaign

Each of these is registered before the campaign runs. Meeting one is the
finding, and the campaign record states it as such rather than retrying.

- The selected Vulkan device string names `llvmpipe` or `lavapipe`. The campaign
  measures a software rasterizer and no result about Raven2 exists.
- The runtime selects a device implicitly rather than from the explicit RADV
  RAVEN2 selection the build and launch record names.
- The runtime's own placement report shows any component on the CPU that the
  profile's placement arm assigns to Vulkan. A silent CPU fallback produces an
  image and measures the host.
- An image process survives the campaign's exit check. The state machine
  requires the device idle before `qwen-launch.sh` runs.
- The post-campaign LLM control fails after `qwen-launch.sh`. A control that
  fails after a run is persistent corruption rather than one rejected graph, and
  it moves the profile to `remote/image-quarantine.tsv` with
  `post-reset-control-failure`.
- The kernel log records a nonzero count of ring resets, VM faults, or device
  loss across the run window, read from the same hazard watcher the LLM lane
  uses.
- Total wall time for one 512x512 image exceeds the 300 s runtime hard bound the
  profile carries. The service, MCP, router, and browser deadlines stack above
  it at 330, 360, 600, and 660 s, so a stalled run is ended by the process that
  owns it rather than abandoned by the layer above.

Two fixed-seed runs of one profile are predicted to produce a bit-identical PNG
SHA-256. That is a prediction with a falsifier rather than an assertion: a
differing digest under an identical prompt, seed, geometry, sampler, step count,
binary, and model digest establishes that this runtime's Vulkan path is not
bit-reproducible on this device, which changes what a provenance record can
claim about a retained image.

The campaign records no throughput expectation. The LLM lane measures the same
checkpoint under identical flags spanning 30.6% between sweeps on this machine,
and a first image run carries no comparison arm at all, so a single generation
time is a bound rather than a rate.

## Provenance and the interfaces above the registry

An image is identified by its own SHA-256. `remote/image-service.py` accepts a
signed request on a Unix socket, acquires the workload lease, spawns the pinned
runtime, writes a `.part` file, validates the PNG, hashes it, renames it
atomically to `<sha256>.png`, writes a provenance JSON beside it, and releases
the lease. A caller supplies no filesystem path. Artifacts live under
`~/qwen-webui-state/images/artifacts/` and are read over 127.0.0.1 HTTP as
completed immutable files alone, through `GET /artifacts/<sha256>.png`,
`/artifacts/<sha256>.json`, and `/health`, each requiring the same session
credential the Web UI already carries. The hash identifies the bytes; the
credential authenticates the reader.

Authorization is separate from the web grant. Context `qwen-image-generate-v1`
binds the language profile, the image profile, the prompt hash, the
negative-prompt hash, the seed, the aspect, the maximum dimensions, the maximum
step count, the conversation generation, an expiry, and a single-use nonce.
Where the model omits a seed, the trusted UI generates and displays it before
approval, so randomness is fixed before authorization rather than chosen after
it.

`remote/image-protocol.md` freezes the request and response shape those layers
exchange at `protocol_version=1`, and `remote/image_protocol.py` is the checker
it requires the service and MCP lanes to import rather than restate. Neither
lane exists in this tree yet, so that is the contract they are built against.

## Vision review

The review runs after the projector-loaded vision tuples pass, with zero
executable tools, treating text visible inside the image as untrusted, and
answering in one structured object:

```json
{"hard_constraints": [{"name": "", "passed": false, "observation": ""}],
 "composition_change_required": false, "prompt_delta": "", "regenerate": false}
```

Regeneration is automatic only for a named hard-constraint failure, which keeps
a correction traceable to the constraint that demanded it.
