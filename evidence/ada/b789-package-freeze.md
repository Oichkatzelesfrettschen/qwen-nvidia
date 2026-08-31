# Package freeze ahead of the B7/B8/B9 calibration reboot

Captured 2026-08-31T03:30:58Z, boot of 2026-08-30 11:33:53 local. This boot
carried two concurrent AUR builds, a system upgrade of about 230 packages,
and a Transformer Engine installation, so it holds the package verification
while the calibration matrix waits for the next reboot and runs there as the
first project CUDA workload.

## Calibration authority

| Component | Value |
| --- | --- |
| kernel package / running | linux-cachyos 7.2.2 / 7.2.2-1-cachyos |
| NVIDIA kernel package | linux-cachyos-nvidia-open 7.2.2-1 |
| nvidia-utils | 610.57.04-1 |
| loaded driver (modinfo, nvidia-smi) | 610.57.04, srcversion E3EB66762FE230BFDEFB25D |
| cuda | 13.3.1-1 |
| cudnn | 9.25.1.1-1.1 (moved from 9.25.0.15 in the system upgrade) |
| tensorrt | 11.2.1.2-1 |
| python-pytorch-opt-cuda | 2.13.0-6 |

The upgrade left kernel, NVIDIA module, nvidia-utils, and the CUDA toolkit at
the versions the matrix was preregistered against. llama-bench links none of
the moved libraries.

## Matrix and binary identity

| Artifact | SHA-256 |
| --- | --- |
| $HOME/src/llama.cpp-qwen-nvidia/build-qwen-cuda-sm89/bin/llama-bench | c51daa95fe2fc4086264e4694f0d7a10d1e8207184d3d6cdf2a01ed8538b6e4a |
| scripts/ad104-b789-matrix.tsv | 49aced683204cdd02dfb26b26e3bea368b966ac43aaed3296a0ed438ad5a47aa |

The binary digest equals the digest every matrix row pins.
`run-ad104-b789-calibration.sh --validate` reported
`matrix_validation=accepted failures=0` against this state.

## New packages retained

| Package | Version | Disposition |
| --- | --- | --- |
| nvcomp | 5.3.0.16-1 | kept, optional CUDA data-pipeline facility |
| python-transformer-engine | 2.15-1 | kept, verified below |
| python-einops | 0.9.0dev-2 | kept, hard dependency of transformer-engine |
| python-onnxscript | 0.7.0-1 | kept, hard dependency of transformer-engine |
| python-onnx-ir | 0.2.1-1.1 | kept, dependency of onnxscript |
| python-tensorrt-llm | not built | status=not-built, deferred |

## Transformer Engine verification

The package check() was skipped at build time, so the installed tree was
verified directly on this boot. `pacman -Qkk` reports 0 altered files of 909.
`libtransformer_engine.so` names cublas, cudart, cublasLt, and cudnn in
DT_NEEDED and reaches nvrtc through dlopen; ldconfig resolves libnvrtc.so.13.
One CUDA smoke ran: import succeeded, torch 2.13.0 against CUDA 13.3
recognized SM 8.9, a bf16 te.Linear(1024, 1024) forward on the RTX 4070 Ti
returned a finite (16, 1024) bf16 tensor, nvidia-smi read 1760 MiB / 50 C
afterward, and the kernel ring holds only the driver load line with no Xid or
hazard signature. transformer_engine reports version 2.15.0+42b840051.
result: verified

## Conclusion

package_freeze=accepted
reboot_required=yes
