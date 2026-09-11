# The stale local llama.cpp-cuda flags are not admitted

A workstation cleanup found one standalone AUR checkout at base
`c3e10c5c98dae7e28592a35a7a8fc8175fe5c82a` with a 20-line uncommitted
`PKGBUILD` addition. A fetch resolved AUR master to
`be3761e6f248f1653fbf91b7a90c62bee28ff013`, 600 commits ahead. The modified
file, base file, and fetched-origin file have separate hashes in
`source-identity.tsv`. The exact raw diff is private because it contains a
workstation-local path and unsupported performance prose; the public row binds
its SHA-256 and the digest of its private retention manifest.

The diff does not qualify an AUR change. It hardcodes an SM89 architecture into
a package whose current metadata serves x86_64, armv7h, and aarch64; current AUR
packaging already exposes `LLAMA_BUILD_EXTRA_ARGS` for an operator-specific
configuration. `GGML_CUDA_V12` is absent from the newer cached llama.cpp source
and the qwen-nvidia pin. The global fast-math flags, strip workaround, and
performance prose carry no current reproducer or measurement tuple.

Platform-specific llama.cpp patches and replay evidence belong to the
repository that owns the matching backend: qwen-nvidia owns CUDA and NVIDIA
work, while qwen-apu owns Vulkan work. Useful SM89 targeting is
therefore carried by qwen-nvidia rather than by the AUR package or qwen-apu,
and is already implemented through `scripts/build-llama-cuda.sh`.
`evidence/ada/cuda-ptx-code-selection-compiler-falsification.md` records why
the serving closure uses `89-real`, while `evidence/ada/cuda-runtime-levers.md`
keeps dispatch claims tied to measured binaries and controls. Those records do
not validate the stale package's claimed 10-15 percent gain or its free-form
FORCE_CUBLAS figures.

`decision.tsv` records six separate refusals. The decision retires this local
package proposal alone: it makes no general claim against architecture-specific
CUDA builds or measured compiler experiments.

```text
aur_publication=not_run
package_build=not_run
device_execution=not_run
performance_result=not_established
decision=negative-admission
```
