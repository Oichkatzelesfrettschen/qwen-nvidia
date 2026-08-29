# stable-diffusion.cpp source pin and CLI audit

## Pinned commit

`leejet/stable-diffusion.cpp` at `de298c225bed97c3f9026b73cd7b71e7879bd41b`
("fix(ci): trigger builds for ggml updates", 2026-08-12), 16 days behind the
tip observed on 2026-08-28 and inside the 60-day admission window. Its parent
`fabe481212df498c3a51e933864e1c9ede603f4d` ("sync: update ggml (#1873)")
carries the same tree under `src/`, `examples/`, and `CMakeLists.txt` --
`git diff --stat fabe481 de298c2` touches only `.github/workflows/build.yml`
-- so `de298c2` is the first commit whose CI actually built the ggml bump
`fabe481` introduced, and every line reference below holds at either commit.
The pin sits twelve commits behind the `be0e344` tip (2026-08-27), which is
same-day and untested here.

## ggml submodule

`.gitmodules` names `ggml` at `https://github.com/leejet/ggml.git`.
`git ls-tree de298c2 ggml` reads the gitlink
`8e800cef2948046cc47f9db6090491c6128ca42c`
("ggml : support FP8 casts across compute backends", 2026-08-26).

A first `git submodule update --init` run against a checkout whose `HEAD` had
not yet moved to the pinned commit reads the gitlink of whatever commit `HEAD`
is actually on. That run reported `032b6997db4c9c75dc85d8d2bb2beec77b1231b0`,
which is the submodule pin at the `be0e344` tip, not at `de298c2`. The build
script below reads the gitlink from the pinned tree with `git ls-tree` rather
than trusting an ambient submodule checkout, which is what avoids repeating
that mismatch.

## CMake: SD_VULKAN enables GGML_VULKAN

`CMakeLists.txt:91` declares `option(SD_VULKAN "sd: vulkan backend" OFF)` and
`CMakeLists.txt:116-119`:

```cmake
if (SD_VULKAN)
    message("-- Use Vulkan as backend stable-diffusion")
    set(GGML_VULKAN ON)
endif ()
```

`-DSD_VULKAN=ON` is the switch; it sets the ggml build variable that compiles
the Vulkan backend rather than adding an independent flag ggml also reads.
`SD_BUILD_EXAMPLES` (`CMakeLists.txt:83`, on by default in a standalone
checkout) builds `sd-cli`; the project has no `SD_BUILD_SERVER` build option
at this commit (`CMakeLists.txt:98` is commented out), so `examples/server`
builds unconditionally under `SD_BUILD_EXAMPLES`.

## Device selection: a CLI flag, not an environment variable

`sd-cli` resolves its compute device through `--backend`, not through a
`GGML_VK_VISIBLE_DEVICES`-style variable -- `ggml/src/ggml-vulkan/ggml-vulkan.cpp`
(submodule `8e800cef2`) reads over a dozen `GGML_VK_*` environment variables
for pacing, allocation, and capability overrides (`GGML_VK_PREFER_HOST_MEMORY`,
`GGML_VK_DISABLE_COOPMAT`, `GGML_VK_MAX_NODES_PER_SUBMIT`, and others) and
names none for device enumeration or selection.

`--list-devices` (`examples/common/common.cpp:672-681`) is the device-name
authority:

```cpp
{"", "--list-devices",
 "list available ggml backend devices (one 'name<TAB>description' per line) and exit; "
 "the names are the device names accepted by --backend and --params-backend",
 [](int, const char**, int) {
     size_t device_list_size = sd_list_devices(nullptr, 0);
     ...
 }},
```

It calls `sd_list_devices` (`src/core/util.cpp:1004-1023`), which loads
backend modules if none are registered yet and prints each
`ggml_backend_dev_name(dev)` and `ggml_backend_dev_description(dev)` pair. On
a Vulkan build against one physical device this reads one line whose name is
`Vulkan0` and whose description names the reported device (`AMD Radeon
Graphics (RADV RAVEN2)` on this appliance's `vulkaninfo --summary` output,
per `remote/model-memory-preflight.sh:44`). The harness in this change reads
that line and requires the description to name RAVEN2/RADV rather than
hardcoding the device name `vulkan0`, since a description mismatch on a
differently-ordered device enumeration is the failure this check exists to
catch.

`--backend` (`examples/common/common.cpp:482-486`) takes a comma-separated
`module=device` list, e.g. `diffusion=cuda0&cuda1` or
`clip=cpu,vae=cuda0,diffusion=vulkan0`. `--params-backend` takes the same
grammar for where parameters are staged (`disk`, `cpu`, or per-module). The
accepted module keys, from the parser in
`src/core/ggml_extend_backend.cpp:55-76`, are wider than either help string
alone suggests:

| Canonical module | Accepted `--backend` keys |
| --- | --- |
| diffusion | `diffusion`, `model`, `unet`, `dit` |
| text encoder | `te`, `clip`, `text`, `textencoder`, `textencoders`, `conditioner`, `cond`, `llm`, `t5`, `t5xxl` |
| VAE | `vae`, `firststage`, `autoencoder`, `tae` |
| control net | `controlnet`, `control` |

`--clip-on-cpu` and `--vae-on-cpu` are marked deprecated in favor of
`--backend te=cpu` and `--backend vae=cpu` (`examples/common/common.cpp:549-556`)
but still set the same fields; `te=cpu` and `clip=cpu` are the same key.

## A device name that does not resolve refuses the run rather than falling back

`sd_backend_resolve_name` (`src/core/ggml_extend_backend.cpp:348-383`) matches
a requested name against the registered `ggml_backend_dev` list by exact name,
then by registry-name prefix; an unmatched name resolves to the empty string.
`SDBackendManager::init_cached_backend`
(`src/core/ggml_extend_backend.cpp:909-921`) treats that empty resolution as a
hard failure for anything but the default token:

```cpp
} else if (!is_default_backend_token(name)) {
    LOG_ERROR("backend '%s' was not found", name.c_str());
    return nullptr;
}
```

`StableDiffusionGGML::ensure_backend_pair` (`src/stable-diffusion.cpp:313-317`)
returns `false` when either half of a module's backend pair is `nullptr`, and
`StableDiffusionGGML::init` uses that return to abort model construction --
for example `src/stable-diffusion.cpp:1035-1037` on the text-encoder/diffusion
pair. `new_sd_ctx` (`src/stable-diffusion.cpp:3838-3856`) propagates that
`false` into a `nullptr` context, and `examples/cli/main.cpp:907-912`:

```cpp
SDCtxPtr sd_ctx(new_sd_ctx(&sd_ctx_params));
if (sd_ctx == nullptr) {
    LOG_INFO("new_sd_ctx_t failed");
    return 1;
}
```

turns that into a nonzero process exit. A run naming a device string absent
from `--list-devices` refuses rather than silently placing the module on
whatever backend inherits the request, and the harness in this change checks
`$?` for that refusal rather than grepping the log.

This chain proves device-selection refusal, not scheduler placement.
`GGML_VK_ALLOW_SYSMEM_FALLBACK` (`ggml-vulkan.cpp:6187` in the submodule) is a
separate mechanism: once a Vulkan backend has been resolved and initialized,
ggml's graph scheduler can still place an individual unsupported operator on
the CPU backend if one is registered in the same process, independent of which
device name the `--backend` flag named. `--offload-to-cpu`, `--max-vram`, and
`--stream-layers` (`examples/common/common.cpp:504,520,538`) name a further,
deliberate CPU-resident staging path for streaming weights that exceed the
device's budget. Proving zero CPU fallback under strict placement -- the way
`remote/test-strict-vulkan-placement.sh` does for llama.cpp -- requires
reading which backend actually executed each operator, which is out of scope
for this pin and named as an open question below.

## CLI flags

All references are `examples/common/common.cpp` unless noted; `-o`/`--output`
is in `examples/cli/main.cpp`.

| Purpose | Flag | Line |
| --- | --- | --- |
| Model file (single checkpoint or diffusers directory) | `-m`, `--model` | 336-340 |
| Output path | `-o`, `--output` | `examples/cli/main.cpp:66-70` |
| Prompt | `-p`, `--prompt` | 925-929 |
| Negative prompt | `-n`, `--negative-prompt` | 930-934 |
| Height | `-H`, `--height` | 1027-1030 |
| Width | `-W`, `--width` | 1031-1034 |
| Steps | `--steps` | 1035-1038 |
| Seed | `-s`, `--seed` | 1559-1562 |
| Sampler | `--sampling-method` | 1564-1567 |
| Scheduler | `--scheduler` | 1574-1577 |
| CFG scale | `--cfg-scale` | 1095-1098 |
| Device/module placement | `--backend` | 481-485 |
| Parameter staging placement | `--params-backend` | 486-490 |
| Control net on CPU (deprecated) | `--control-net-cpu` | 545-548 |
| Text encoder on CPU (deprecated) | `--clip-on-cpu` | 549-552 |
| VAE on CPU (deprecated) | `--vae-on-cpu` | 553-556 |
| Flash attention, every module | `--fa` | 557-560 |
| Flash attention, diffusion model only | `--diffusion-fa` | 561-564 |
| VAE file | `--vae` | 400-404 |
| LoRA search directory | `--lora-model-dir` | 445-449 |
| List backend devices and exit | `--list-devices` | 672-681 |

`--output` accepts a plain path; `examples/cli/main.cpp:511` applies a
format-specifier regex (`%` placeholders for batch numbering) to it, so a
pinned single-image path must carry no `%` character.

## LCM-LoRA loading

`docs/lcm.md` states the mechanism directly:

```sh
./bin/sd-cli -m ../models/v1-5-pruned-emaonly.safetensors \
    -p "a lovely cat<lora:lcm-lora-sdv1-5:1>" \
    --steps 4 --lora-model-dir ../models -v --cfg-scale 1
```

`SDGenerationParams::extract_and_remove_lora`
(`examples/common/common.cpp:2120-2154`) matches `<lora:NAME:WEIGHT>` inside
the prompt with the regex `<lora:([^:>]+):([^>]+)>`, strips it from the
prompt text, and resolves `NAME` to `lora_model_dir / NAME` (extension
inferred, `.safetensors` first). A pinned LCM-LoRA fetch must therefore name
its destination file so `<lora:lcm-lora-sdv1-5:1>` resolves against
`--lora-model-dir`, i.e. the file lands as
`$HOME/models/image/lcm-lora-sd15/lcm-lora-sdv1-5.safetensors`.

## Model file formats

`ModelLoader::init_from_file` (`src/model_loader.cpp:230-249`) dispatches on
directory-vs-file and file content rather than extension:

```cpp
if (is_directory(file_path)) {
    return init_from_diffusers_file(file_path, prefix);   // a diffusers export
} else if (is_gguf_file(file_path)) {
    return init_from_gguf_file(file_path, prefix);         // GGUF magic
} else if (ends_with(file_path, ".json")) {
    return init_from_safetensors_index_file(file_path, prefix);  // sharded safetensors index
} else if (is_safetensors_file(file_path)) {
    return init_from_safetensors_file(file_path, prefix);  // safetensors header
} else if (is_torch_zip_file(file_path)) {
    return init_from_torch_zip_file(file_path, prefix);    // modern .ckpt/.pt (zip pickle)
} else if (init_from_torch_legacy_file(file_path, prefix)) {
    return true;                                            // legacy pickle .ckpt/.pt
}
```

A directory path loads the diffusers layout, which
`init_from_diffusers_file` (`src/model_loader.cpp:427-430`) resolves against
three fixed relative paths: `unet/diffusion_pytorch_model.safetensors`,
`vae/diffusion_pytorch_model.safetensors`, `text_encoder/model.safetensors`
(and `text_encoder_2/model.safetensors` for a second text encoder). SDXS-512's
publisher ships exactly that layout, so the SDXS-512 fetcher below preserves
those three relative paths under its destination directory rather than
flattening them.

## Artifact pin table

Every revision is the repository's default-branch `sha` at fetch time
(`GET /api/models/{repo}`); every digest and byte count is the file's Git LFS
object (`GET /api/models/{repo}/tree/{revision}?recursive=1`, `lfs.oid` /
`lfs.size`), read the way `remote/fetch-candidate-artifact.sh` reads a
candidate GGUF. `sd_turbo.safetensors`, `v1-5-pruned-emaonly.safetensors`,
`vae-ft-mse-840000-ema-pruned.safetensors`, and
`pytorch_lora_weights.safetensors` are each single merged files; the SDXS-512
row is a diffusers export and needs three files at fixed relative paths.

| artifact_id | repository | revision | filename | bytes | sha256 | license |
| --- | --- | --- | --- | ---: | --- | --- |
| sdxs-512 (text encoder) | IDKiro/sdxs-512-0.9 | c332f05f60eb4b453de513be52c2a18c48d8cfe6 | text_encoder/model.safetensors | 1361597018 | cce6febb0b6d876ee5eb24af35e27e764eb4f9b1d0b7c026c8c3333d4cfc916c | openrail++ |
| sdxs-512 (unet) | IDKiro/sdxs-512-0.9 | c332f05f60eb4b453de513be52c2a18c48d8cfe6 | unet/diffusion_pytorch_model.safetensors | 1312752864 | c2afb7dbea11b64d0bfbc4d1a45854aa65408b8a74a732438225d3f2ec85c71c | openrail++ |
| sdxs-512 (vae) | IDKiro/sdxs-512-0.9 | c332f05f60eb4b453de513be52c2a18c48d8cfe6 | vae/diffusion_pytorch_model.safetensors | 9793292 | d7956d561b1efbd861ad9b03fd8f01510f9e87eddc07bdfd20837009433f6ee5 | openrail++ |
| sd15-base | stable-diffusion-v1-5/stable-diffusion-v1-5 | 451f4fe16113bff5a5d2269ed5ad43b0592e9a14 | v1-5-pruned-emaonly.safetensors | 4265146304 | 6ce0161689b3853acaa03779ec93eafe75a02f4ced659bee03f50797806fa2fa | creativeml-openrail-m |
| sd15-vae | stabilityai/sd-vae-ft-mse-original | 629b3ad3030ce36e15e70c5db7d91df0d60c627f | vae-ft-mse-840000-ema-pruned.safetensors | 334641190 | 735e4c3a447a3255760d7f86845f09f937809baa529c17370d83e4c3758f3c75 | mit |
| lcm-lora-sd15 | latent-consistency/lcm-lora-sdv1-5 | cf2fced511dbe7e26c8d1d397e728fbab875db4b | pytorch_lora_weights.safetensors | 134621556 | 8f90d840e075ff588a58e22c6586e2ae9a6f7922996ee6649a7f01072333afe4 | openrail++ |
| sd-turbo | stabilityai/sd-turbo | b261bac6fd2cf515557d5d0707481eafa0485ec2 | sd_turbo.safetensors | 5214561328 | 3f067a1b943cf162f2b8f8588f6cf5824bd5b4c7d1d88d87164b9ca123616549 | Stability AI Community License (revenue-capped, non-SPDX; `LICENSE.md` in the repository) |

`runwayml/stable-diffusion-v1-5` is the historically cited SD 1.5 source; the
repository is gone from Hugging Face and `stable-diffusion-v1-5/stable-diffusion-v1-5`
is the maintained mirror carrying the same weights and the
`creativeml-openrail-m` license, confirmed live against the API above.

## Open questions

- No arm here proves zero-CPU-fallback scheduler placement for
  stable-diffusion.cpp the way `test-strict-vulkan-placement.sh` proves it for
  llama.cpp. `--list-devices` plus an explicit `--backend
  te=vulkan0,vae=vulkan0,diffusion=vulkan0` proves the three modules resolve
  to the named Vulkan device and that an unresolvable name refuses the run;
  it does not prove the graph scheduler placed every individual operator on
  that device rather than falling back per-op under
  `GGML_VK_ALLOW_SYSMEM_FALLBACK` or an unsupported-op path. That proof needs
  a live run against the device and belongs to the laptop-side admission
  lane, not this workstation-side pin.
- The brief's four registries (`remote/image-artifacts.tsv`,
  `remote/image-models.tsv`, `remote/image-profiles.tsv`,
  `remote/image-quarantine.tsv`) are not created by this change. The fetch
  scripts below use the `remote/download-*.sh` pinning discipline directly;
  wiring them into a registry is deferred to whichever change introduces the
  four TSVs.
- SDXS-512 also has a `vae_large/diffusion_pytorch_model.safetensors` sibling
  (334641190 bytes, unused by the three-path diffusers loader) and a
  `dreamshaper` variant (`IDKiro/sdxs-512-dreamshaper`) under a different
  license; this pin takes the base `sdxs-512-0.9` repository only.
- SD-Turbo's `sd_turbo.safetensors` (5.21 GB) is the merged single-file
  checkpoint; the repository also ships an unmerged diffusers export under
  the same revision, unused here.
