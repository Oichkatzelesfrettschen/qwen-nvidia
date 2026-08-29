# SDXS-512 standalone campaign, first image generated on Raven2

`remote/run-image-standalone.sh` drove IDKiro/sdxs-512-0.9 through
`sd-cli` at `de298c22` (binary SHA-256
`4eb6d155c8b1e077de5613a7282410d78c2fc984e9c3aedf9287c0aa788817c8`) with the
model at `c332f05` (directory SHA-256
`bf0c567f5214a400f9f1b3f562d1b01f3266d7824e403977a9b900175529b7cc`), one prompt
("a red apple on a white table, product photography"), seed 42, 512x512, one
step, Euler, cfg 1.0, ICD pinned to RADV. Every arm below shares that identity,
which is what makes a difference between arms a placement result rather than a
different run.

## Falsifiers

**Standalone generation survives Raven2 with zero hazard.** Falsified by any
nonzero `ring_resets` or `gpu_faults`, a nonempty kernel delta, a nonzero
generation exit status, or a device-refusal control that accepts an
unresolvable backend name -- the last of which would mean the strict
device-selection proof itself failed, so a passing cold or warm arm could not
be read as strictly placed. Not falsified: `sdxs-512-a`, `sdxs-512-b`, and
`sdxs-512-c` each complete both arms at `exit_status=0`, each of the twelve
`*.dmesg.txt` files (six generation arms, three device-refusal controls run
before them) is empty, every `ring_resets` and `gpu_faults` cell reads `0`,
and every `device-refusal-control.log` records `new_sd_ctx_t failed` on the
salted, unresolvable backend name -- the control the harness runs before every
generation pair. `sdxs-512-a-resident-2b` and `sdxs-512-a-resident-4b` meet
the same criterion with the router holding a checkpoint resident and idle.

**A placement arm is compared inside one chain.** The repository's own
throughput doctrine reads a comparison inside one sweep, where both arms met
the same machine minutes apart, rather than across sweeps separated by
uncontrolled machine state. `binary_sha256` and `model_sha256` are identical
across all five directories here, so a difference in `total_generate_s`
between `sdxs-512-a`, `sdxs-512-b`, and `sdxs-512-c` reads as placement rather
than as a different binary, a different model, or queue position on a
different day. The two resident directories ran later, against the same
binary and model identity, and are read against the `sdxs-512-a` arm as the
same placement under a different residency condition rather than folded into
the A/B/C comparison itself.

## The three placement arms

`A` places the text encoder, the diffusion trunk, and the VAE decoder on
Vulkan. `B` moves the text encoder to the CPU. `C` moves the text encoder and
the VAE decoder to the CPU, leaving the diffusion trunk alone on Vulkan.

| Arm | run | text_encoder_s | diffusion_s | vae_s | total_generate_s | shell_wall_s | rss_peak_kib |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| A (te=Vulkan0,vae=Vulkan0,diffusion=Vulkan0) | cold | 1.61 | 3.82 | 2.11 | 7.55 | 9.020 | 458828 |
| A | warm | 1.40 | 3.82 | 2.11 | 7.35 | 9.022 | 485496 |
| B (te=cpu,vae=vulkan0,diffusion=vulkan0) | cold | 1.79 | 3.88 | 2.13 | 7.82 | 10.022 | 1487012 |
| B | warm | 1.79 | 3.89 | 2.11 | 7.81 | 10.025 | 1520984 |
| C (te=cpu,vae=cpu,diffusion=vulkan0) | cold | 1.81 | 3.89 | 15.49 | 21.21 | 23.066 | 2003572 |
| C | warm | 1.81 | 3.87 | 17.69 | 23.39 | 25.061 | 1974240 |

`diffusion_s` stays at 3.82-3.89 s across every arm because the diffusion
trunk runs on Vulkan in A, B, and C alike; only the component an arm actually
moves changes. `text_encoder_s` rises 0.18-0.41 s when the text encoder moves
to the CPU (B, C against A), a small delta against a component that streams
1.36 GB of weights. `vae_s` is what separates C from the other two: 2.11-2.13 s
on Vulkan (A, B) against 15.49-17.69 s on the CPU (C), a 7.3x-8.4x cost for
running the tiny autoencoder decode off the device. RSS peak scales with what
moved to the CPU: 448-474 MiB resident for A, 1.42-1.45 GiB for B, and
1.88-1.91 GiB for C, tracking the growing set of weights and activations the
host process holds.

## Determinism

`png_sha256` is identical between the cold and warm arm of each placement --
`a9491c82...` for A, `ebdc9719...` for B, `e58f82d9...` for C -- and differs
across placements. The pinned binary reproduces its output bytes exactly
across repeated invocations at fixed seed, steps, and backend string; moving a
component's execution from Vulkan to the CPU changes the output bytes, which
is expected floating-point non-associativity across execution paths rather
than a claim of numeric equivalence between them. Every PNG carries a red
apple on a white surface, matching the prompt.

## Placement finding

Arm A is fastest in both `total_generate_s` (7.55/7.35 s) and shell wall time
(9.0 s). Arm B costs 3.6-6.3% more total generation time, paid almost entirely
in the text encoder. Arm C costs 2.8-3.2x more, paid almost entirely in the
VAE decoder running on the CPU: `vae_s` alone exceeds arm A's entire
`total_generate_s`. The dominant cost in this campaign is which component
runs off the device, not a cross-device synchronization tax the way the LLM
placement ladder in `CLAUDE.md` describes it -- here the CPU-side decode
itself is the slow part, not the traffic between the two sides. Arm A is
selected as the served placement.

## warm equals cold

`total_generate_s` differs by 0.20 s (A), 0.01 s (B), and -2.18 s (C, within
this campaign's per-arm noise) between cold and warm, and `png_sha256` is
identical within each placement regardless. Each arm launches a fresh `sd-cli`
process with no state carried from the previous invocation --
`QWEN_IMAGE_ALLOW_LLAMA_RESIDENT` is unset and `run-image-standalone.sh` starts
one child per label -- so "warm" here means a second cold start immediately
following the first, not a resident process serving a second request. Model
residency between generations is unmeasured by this campaign and is the next
lever; the two resident-router directories below measure a different kind of
residency (an idle LLM checkpoint sharing the device) rather than this one
(the image runtime itself staying loaded).

## Probe forms

`probe-forms/form-A.log` confirms `--model DIR --taesd VAE` as the working
invocation shape: the diffusers directory loader opens the checkpoint,
`vae/diffusion_pytorch_model.safetensors` is read through `--taesd` as a Tiny
AutoEncoder rather than through the directory's own `vae/` slot, and
generation completes in 7.57 s producing `a9491c82...` -- the same bytes as
placement A's cold and warm arms, confirming form-A and arm A ran the
identical configuration. `probe-forms/form-B.log` shows the refused form:
`--diffusion-model` pointed directly at the bare `unet/diffusion_pytorch_model.safetensors`
file fails at `stable-diffusion.cpp:902` with `get sd version from file
failed: ''`, because that entry point expects a checkpoint carrying its own
version metadata and a bare diffusers-format U-Net names none.

## Three harness defects this campaign exposed

1. `model file is missing` when `MODEL_PATH` named a diffusers directory
   rather than a single file -- `sd-cli --model` accepts either, and the
   harness's own precondition rejected the directory form before ever
   invoking the runtime. Fixed in PR #53 (`image-standalone-diffusers`).
2. `--backend` handed a device description instead of a device name --
   `--list-devices` interleaves a `name<TAB>description` line on stdout with
   ggml's own device banner on stderr carrying the same description text, and
   reading both streams together matched the banner first. Fixed in PR #54
   (`image-standalone-device-name`, "read the device listing from stdout
   alone").
3. The Tiny AutoEncoder refused as a full VAE -- SDXS-512 ships a TAE in its
   `vae/` slot, and the metadata check in that loading path refuses a tiny
   decoder there. `sd-cli` reads it correctly only through `--taesd`. Fixed in
   PR #55 (`image-standalone-taesd`, "pass a Tiny AutoEncoder through
   `--taesd`").

## Co-residency with the LLM router

`sdxs-512-a-resident-2b` and `sdxs-512-a-resident-4b` run placement A
(`te=Vulkan0,vae=Vulkan0,diffusion=Vulkan0`) under
`QWEN_IMAGE_ALLOW_LLAMA_RESIDENT=1`, with the ordinary router holding the 2B
distill and then the 4B distill loaded and idle, no teardown between the image
run and the router's own resident state. Neither directory retains a PNG; the
digest alone is the record, per the coordinator's scope for this addendum.

| Resident checkpoint | run | text_encoder_s | diffusion_s | vae_s | total_generate_s | mem_available_min_kib | rss_peak_kib |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 2B distill | cold | 1.66 | 4.06 | 3.24 | 8.98 | 8545520 | 480136 |
| 2B distill | warm | 1.62 | 4.00 | 3.54 | 9.18 | 8326524 | 481380 |
| 4B distill | cold | 1.92 | 4.05 | 3.47 | 9.46 | 6382132 | 487308 |
| 4B distill | warm | 1.65 | 4.05 | 3.53 | 9.25 | 6932780 | 457000 |

Both `ring_resets` and `gpu_faults` read 0 in all four arms, and all four
`*.dmesg.txt` files are empty, so co-residency introduces no hazard this
campaign can detect. Every PNG digest in both directories equals
`a9491c82599937f9dd5320be4642366a35689c4794f450bb772fa298646ce143`, the
standalone arm A digest, so a resident LLM checkpoint changes the timing of
the image generation and not its output.

Against the standalone arm A baseline (7.55/7.35 s), the resident arms cost
1.43-1.83 s more (8.98-9.46 s against 7.55-7.35 s), landing almost entirely in
`vae_s`: 3.24-3.54 s resident against 2.11 s standalone, a 1.1-1.4 s
increase, with `text_encoder_s` and `diffusion_s` within their own
standalone-arm spread. `mem_available_min_kib` is lower here than in the
`sdxs-512-a` directory above (7.94-8.15 GiB free with the 2B resident,
6.09-6.61 GiB with the 4B resident) because the appliance also carried a
16.5 GiB qemu virtual machine throughout this addendum's arms, which the
`sdxs-512-a`/`b`/`c` directories did not; the floors here describe that
machine state rather than what the appliance alone leaves free. `/health`
answered before and after each of the four arms, and a chat completion driven
against the resident checkpoint afterward decoded at 9.41 tok/s (2B) and
3.32 tok/s (4B), so the router served correctly once the image process exited
in every case. Co-residency at placement A is healthy at both checkpoint
sizes measured, at a decoder-phase cost of about 1.1-1.4 s. The next levers
this addendum leaves open: keeping the image runtime itself resident across
jobs instead of reloading `sd-cli` per generation, and the shared
`~/qwen-webui-state/vulkan-workload.lock` lease `CLAUDE.md` names as the
mechanism that will eventually serialize image and LLM device work rather
than leaving them merely observed to coexist.

## PNG digests

| Path | png_sha256 | Retained |
| --- | --- | --- |
| `sdxs-512-a/cold.png` | `a9491c82599937f9dd5320be4642366a35689c4794f450bb772fa298646ce143` | binary, this directory |
| `sdxs-512-a/warm.png` | `a9491c82599937f9dd5320be4642366a35689c4794f450bb772fa298646ce143` | digest only, identical to cold |
| `sdxs-512-b/cold.png` | `ebdc9719e375e2c7b50d6498c88ae33589f8e7fa9bca0f3812e83e163c649618` | digest only |
| `sdxs-512-b/warm.png` | `ebdc9719e375e2c7b50d6498c88ae33589f8e7fa9bca0f3812e83e163c649618` | digest only, identical to cold |
| `sdxs-512-c/cold.png` | `e58f82d979980d8da4f3be0c61d5b7b3cba4319fb66778ac2d242704523eb3f3` | digest only |
| `sdxs-512-c/warm.png` | `e58f82d979980d8da4f3be0c61d5b7b3cba4319fb66778ac2d242704523eb3f3` | digest only, identical to cold |
| `probe-forms/form-A.png` | `a9491c82599937f9dd5320be4642366a35689c4794f450bb772fa298646ce143` | digest only, identical to placement A |
| `sdxs-512-a-resident-2b/cold.png` | `a9491c82599937f9dd5320be4642366a35689c4794f450bb772fa298646ce143` | digest only, identical to placement A |
| `sdxs-512-a-resident-2b/warm.png` | `a9491c82599937f9dd5320be4642366a35689c4794f450bb772fa298646ce143` | digest only, identical to placement A |
| `sdxs-512-a-resident-4b/cold.png` | `a9491c82599937f9dd5320be4642366a35689c4794f450bb772fa298646ce143` | digest only, identical to placement A |
| `sdxs-512-a-resident-4b/warm.png` | `a9491c82599937f9dd5320be4642366a35689c4794f450bb772fa298646ce143` | digest only, identical to placement A |

`ARTIFACTS.md` retains a PNG under `evidence/` as an ordinary Git binary
(`evidence/benchmarks/bands.png` is the existing precedent), and this
directory follows that treatment for exactly one file, `sdxs-512-a/cold.png`,
as the reference image for the served placement. Every other generation in
this campaign is retained as a digest and log set alone; the digest above is
each retired PNG's full provenance.

## Retained files

Each of `sdxs-512-a`, `sdxs-512-b`, `sdxs-512-c`, `sdxs-512-a-resident-2b`,
and `sdxs-512-a-resident-4b` carries `summary.tsv` (the harness's own TSV, one
row per arm), `cold.log`/`warm.log` (the `sd-cli` stdout/stderr each arm
captured), `cold.dmesg.txt`/`warm.dmesg.txt` (the kernel log delta over each
arm's run, empty in every case here), `cold.gpu-clocks.tsv`/`warm.gpu-clocks.tsv`
(the `sample-gpu-clocks.sh` samples backing `mclk_modal_mhz`,
`temp_millidegrees_max`, `vram_used_bytes`, and `gtt_used_bytes`),
`cold.proc-poll.tsv`/`warm.proc-poll.tsv` (the RSS/PSS/MemAvailable/SwapFree
poll backing the memory columns), and `device-refusal-control.log` (the
strict-selection control this campaign's falsifier above reads). `probe-forms/`
carries `form-A.log`/`form-A.png` and `form-B.log`, the two invocation shapes
that established `--model DIR --taesd VAE` ahead of the harness's own defaults.
Every `/home/eirikr` path in every retained file reads `$HOME` per the
repository's sanitization rule; no private hostname or MAC address appears in
this campaign's output.
