# Artifact retention policy

| Surface | Retention class | Repository treatment | Replay authority |
| --- | --- | --- | --- |
| Setup scripts, tests, policies, and tracker | canonical generator or synthesized truth surface | ordinary Git | tracked source |
| Device measurement, quarantine, and lease records | raw exact-target evidence | ordinary Git under `evidence/` | `evidence/SHA256SUMS` |
| `llama-server`, `llama-cli`, `llama-mtmd-cli`, `llama-bench`, `llama-quantize` | derived regenerable | excluded from Git and LFS | `scripts/build-llama-cuda.sh`, byte sizes and SHA-256 values once a build on this host records them |
| Qwen3.5-4B, Qwen3.8-9B Distill, and Qwen3.8-27B GGUFs | external reproducible dependencies | excluded from Git and LFS | pinned Hugging Face revisions, byte sizes, and SHA-256 values |
| llama.cpp source | external canonical source plus local patch series | pinned commit plus a production patch series, four candidate patches, and one rejected patch | `scripts/verify-llama-patch-series.sh` |
| llama.cpp build tree | derived regenerable | excluded | `scripts/build-llama-cuda.sh` |
| View-metadata incremental patch | superseded retain | `patches/superseded/` | folded into `llama-no-cpu-fallback.patch` |
| Fallback Web UI | adapted source asset | ordinary Git under `webui/` | qwen-lab 1.5.0 source plus this repository's policy tests |
| Prior-host evidence conclusions | retained comparative summary | ordinary Git under `evidence/legacy/raven2/` | raw originals in the `qwen-apu` repository at the commit `README.md` names |
| Generated image artifacts | raw exact-target evidence, one binary per admission, when produced | ordinary Git under `evidence/image-appliance/` | `evidence/SHA256SUMS`, and the profile, seed, and runtime the provenance record beside it names |

`scripts/refresh-evidence-manifest.sh` regenerates `evidence/SHA256SUMS` from
the tracked `benchmarks/` and `evidence/` trees, and `--check` exits non-zero
on drift. A surface it omits is retained without a replay authority.

The Git copies replace the private hostname with `qwen-laptop`, the
machine-local home prefix with `$HOME`, and network MAC addresses with
`<mac>`.

`evidence/legacy/raven2/` retains one README stating what the prior host was
and one table of individual conclusions worth carrying forward from it. About
1,300 raw files carrying full prior-host measurement detail are deleted from
this repository, because their authoritative copies remain in `qwen-apu` at
the commit `evidence/legacy/raven2/README.md` names. No script under
`scripts/` reads `evidence/legacy/raven2/comparative-findings.tsv`, and no row
in it sets a default in this tree; a default here changes only when a
measurement under `evidence/ada/` moves it.

## Exact artifacts

`scripts/build-llama-cuda.sh` regenerates `llama-server`, `llama-cli`,
`llama-mtmd-cli`, `llama-bench`, and `llama-quantize` from the pinned
llama.cpp commit with CUDA and Vulkan in one binary at `sm_89`. No build
produced on this host has had its artifact identity -- byte count and
SHA-256 -- recorded here yet, so this file carries no binary hash row until
that recording happens.

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `Qwen3.5-4B-Q4_K_M.gguf` | 2,740,937,888 | `00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4` |
| `Qwen3.8-9B-Q4_K_M.gguf` | 5,780,090,176 | `df13d66021cef676f82be74053220fd75af6bf2a6a7fb77f5222ab9e50744a7a` |
| `Qwen3.8-2B-BF16.gguf` | 3,897,387,392 | `44763f3d83f0a1a3ee63334b60916705dc565d796cb0f2b8c320414c57f4ac48` |
| `Qwen3.5-0.8B-bf16.gguf` | 1,557,662,528 | `ad1549eedc613064971dcbbbfab6c9b7990984d1c9ab38f792c6f2ec1207bbc2` |

The two F16 checkpoints carry no row above, because neither publisher ships
one. The generator is the replay authority for a derived file, and each has a
named one:

```sh
scripts/derive-qwen38-2b-distill-f16.sh   # Qwen3.8-2B-F16.gguf
scripts/derive-qwen35-08b-f16.sh          # Qwen3.5-0.8B-F16.gguf
```

Both call `scripts/derive-f16-artifact.sh`, which runs the pinned BF16 fetch,
converts with `llama-quantize` at type F16, and admits the result on two
properties measured against the just-verified source: the streamed byte count
per token is unchanged, since the value type is the only thing the conversion
may change, and no tensor remains BF16. The 0.8B streams 1,505,783,040 bytes
per token and the 2B streams 3,764,747,520, each identical to its source. Of
each file's bytes, 99.17% and 99.66% are reported as BF16 before the
conversion and as F16 after; the remainder is the F32 tensors the recipe
keeps and the metadata block.

A derived artifact carries no digest row because its bytes depend on the
converter rather than on a publisher's revision, so the same two checks run
on an artifact already in place. A stale, truncated, or hand-converted file
under the artifact name is refused and left where it is rather than served
on its existence alone; removing it is what authorizes a fresh derivation.

The vision fixtures under `scripts/quality-images/` are committed rather than
regenerated, because deflate is not reproducible across hosts: zlib 1.3 on
the appliance re-encodes 7 of the 8 to different bytes than the workstation
wrote, with identical pixels. `scripts/generate-quality-images.py --check`
therefore decodes both sides and compares pixels, which is the claim a
fixture makes; inflate is fully specified where deflate leaves the match
search to the implementation.

`benchmarks/models/qwen38-27b-files.tsv` is the replay authority for the four
external Qwen3.8-27B benchmark files. Those 9.83 GB through 14.25 GB files
stay outside Git LFS.

GitHub bills Git LFS storage and bandwidth to the account owning the
repository, public or private alike, against a free allowance of 1 GB of
each. The five regenerable executables are excluded from Git and LFS for
that reason, and the manifest above carries their identity instead once a
build records it. `scripts/build-llama-cuda.sh` regenerates them from the
pinned commit and patch series, `scripts/verify-llama-patch-series.sh`
confirms the source reproduces, and `scripts/verify-runtime-artifacts.sh`
compares a rebuild against recorded byte counts and SHA-256 values once they
exist. Pass it the directory holding the rebuilt binaries.

The llama.cpp source commit is `f280b26983ad0fdb705a0d9ebf0503e76f2899b0`.
`scripts/verify-llama-patch-series.sh` applies, in order,
`patches/llama-vulkan-low-priority.patch`,
`patches/llama-no-cpu-fallback.patch`,
`patches/llama-vulkan-duty-cycle.patch`,
`patches/llama-vulkan-runtime-submit-limit.patch`,
`patches/llama-vulkan-submit-trace.patch`, and
`patches/llama-router-tools-proxy.patch`, then checks the seven resulting
modified source files byte for byte against their admitted hashes. The last
patch registers `/tools` on a router that holds no tools of its own as a
proxy to the child the request selects, so the fixed router port serves the
route the fallback UI targets.

Four further patches are candidates rather than members of the production
series: `patches/llama-vulkan-view-alias-deps.patch`,
`patches/llama-server-vulkan-workload-lease.patch`,
`patches/llama-cuda-mmvq-crossover-ad104.patch`, and
`patches/llama-cuda-dispatch-census.patch`. Passing
`QWEN_LLAMA_CANDIDATE_PATCHES=1` to `scripts/verify-llama-patch-series.sh`
applies them in that order after every production digest is checked and prints
the post-apply digest of each file they rewrite; omitting the variable leaves
the production digests as the whole check.

`patches/llama-cuda-mmvq-ncols-19.patch` is a third class: a rejected patch,
retained as the diff a closed campaign was measured on.
`evidence/ada/mmvq-q8-b17-b20/` records four passed gates and a failed
exact-token-identity gate, so the same script names it on a `rejected_patch=`
line, applies it to no tree by default, and moves no digest into the
production check. Setting `QWEN_LLAMA_REJECTED_PATCHES=1` beside
`QWEN_LLAMA_CANDIDATE_PATCHES=1` runs `apply --check` on it, which proves the
diff still lands against the pinned commit and writes nothing.

The retained llama.cpp executables and derived source patches carry the
upstream MIT terms in `licenses/llama.cpp-LICENSE`. The external GGUF model
repository declares Apache-2.0 in its pinned Hugging Face model metadata.
The adapted single-file Web UI carries its source MIT terms in
`licenses/qwen-lab-LICENSE`.

## Records derived from a remote partial fetch

`scripts/admit-candidate-static.py` reads a candidate GGUF's metadata block
and tensor index over an HTTP range request against a pinned Hugging Face
revision, so a static-admission row's provenance is the repository, the
revision, and the artifact name it carries rather than a file this tree
holds; reproducing a row is a claim about the remote revision staying
reachable rather than about a retained file. No static-admission record is
retained in this repository at present.
