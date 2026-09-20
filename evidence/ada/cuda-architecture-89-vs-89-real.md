# CMAKE_CUDA_ARCHITECTURES 89 against 89-real, decomposed

`scripts/build-llama-cuda.sh` defaults `QWEN_CUDA_ARCHITECTURES` to `89`, and
`scripts/serving-closures.tsv` names `89-real` as the arm every served closure
carries. Two closures, `efa48befa03b` and `1f88e8fca5ef`, were promoted at the
default before anything read the arm at promotion. This note takes the two
values apart layer by layer -- what each asks the compiler for, what lands in
the library, what the driver does with it, and what the device measures -- so
the choice rests on the layer that differs rather than on the name.

## What CMake asks nvcc for

CMake's `CUDA_ARCHITECTURES` property maps a bare number to real and virtual
code and a `-real` suffix to real code alone. `build.ninja` in the two trees
records the flag each value became:

| value | flag |
| --- | --- |
| `89` | `--generate-code=arch=compute_89,code=[compute_89,sm_89]` |
| `89-real` | `--generate-code=arch=compute_89,code=[sm_89]` |

`sm_89` is SASS for the Ada streaming multiprocessor, loadable as it stands.
`compute_89` is PTX, virtual-ISA text the driver compiles at load time when no
SASS in the fatbin matches the device. Every kernel passes through the same
`compute_89` front end in both arms; the arms differ in whether the PTX is
kept in the output.

## What lands in the library

Every number here is `stat`, `readelf -S`, `cuobjdump --list-elf` and
`cuobjdump --list-ptx` over the retained trees under `build-qwen-cuda-*`.

| configuration | arch | nvcc | libggml-cuda.so bytes | .nv_fatbin bytes | .text bytes | cubins | PTX |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| 192d0663a533 | 89-real | 13.4.59 | 58,477,336 | 24,770,592 | 17,837,123 | 187 | 0 |
| de074f9738b8 | 89-real | 13.4.59 | 58,477,336 | 24,770,592 | 17,837,123 | 187 | 0 |
| 15bc632adf7f | 89-real | 13.3.73 | 58,907,536 | 25,198,456 | 17,837,123 | 187 | 0 |
| 1f88e8fca5ef | 89 | 13.4.59 | 88,615,704 | 54,909,584 | 17,837,123 | 187 | 187 |
| efa48befa03b | 89 | 13.4.59 | 88,615,704 | 54,909,584 | 17,837,123 | 187 | 187 |

Three facts fall out of the table. `.text` is the same 17,837,123 bytes in
every tree, so the architecture value moves device code alone and the host
side of the backend is byte-for-byte the same work; `192d0663a533` differs
from `de074f9738b8` by a server patch that touches no ggml object, and its
CUDA library is identical to the byte. The cubin count is 187 in
every tree, so the arm adds no kernel and removes none. The 30,138,992-byte
difference between the two arms under one compiler is the 187 PTX images:
`cuobjdump -xptx all` extracts 384,554,461 bytes of PTX text from the `89`
library, held in the fatbin under the `compression=size` the configuration
record names. Between the two `89-real` trees the compiler moved from
13.3.73 to 13.4.59 and the patch series changed, so the 427,864 bytes their
SASS differs by is attributed to neither.

## What the driver does with it

The CUDA runtime loads the cubin whose SM matches the device when the fatbin
holds one and compiles PTX only when it holds none for that device (CUDA C++
Programming Guide, "Binary Compatibility" and "Just-in-Time Compilation"). The
RTX 4070 Ti is SM 8.9, both arms hold `sm_89`, so the driver reads the cubin
in both and the PTX in neither. `cuda-ptx-code-selection-compiler-falsification.md`
found that `CUDA_FORCE_PTX_JIT=1` ran the zero-PTX binaries unchanged on
driver 610.57.04, so that variable decides nothing here; the measurement
below does. The extra 30 MB is file: mapped when the library loads, and read
only if the driver reaches for PTX, which on this device it has no reason to.

## What the device measures

`llama-bench` on `Qwen3-4B-Instruct-2507-Q8_0`, `-ngl 99 -p 512 -n 128 -r 3`,
the two binaries alternated in one machine state:

| binary | arch | pp512 t/s | tg128 t/s |
| --- | --- | ---: | ---: |
| 1f88e8fca5ef | 89 | 10166.48 +- 562.49 | 97.02 +- 0.07 |
| de074f9738b8 | 89-real | 10164.49 +- 577.82 | 97.03 +- 0.12 |
| 1f88e8fca5ef | 89 | 10112.95 +- 588.73 | 97.03 +- 0.09 |
| de074f9738b8 | 89-real | 10087.96 +- 527.59 | 97.02 +- 0.06 |

Generation agrees to two decimals and prompt processing sits inside its own
spread. The three-file summarize screen through llama-server, read from the
server's own `timings` as prompt_ms plus predicted_ms, gives 11896, 11167
and 11551 ms on `de074f9738b8` against 11261, 11263 and 11009 on
`1f88e8fca5ef`: 2.6 percent apart on the mean with overlapping ranges, which
three readings cannot separate and the bench says is not the arm.

## What each arm is for

`89` keeps PTX that `cuobjdump -xptx` can read, which the dispatch census and
the PTX falsification note both depended on, and that a device newer than
SM 8.9 could compile at load. It costs 30 MB of file. That is the diagnostic
closure's role, and `572951d25562` carries it.

`89-real` emits a payload whose identity the ledger states (`ptx_images=0`)
and the builder's payload check verifies (`89-real unexpectedly carries N PTX
payloads` is a build failure). It is 30 MB smaller and compiles nothing at
load. That is the serving role on a pinned SM 8.9 device.

Neither arm buys throughput, and a serving decision made on that ground
would be made on nothing.

## The gate that was missing

The builder verified that the payload matched the arm it was asked for, and
the promoter never read the arm, so a closure built at the default passed
every promotion gate with a payload the ledger said a served closure lacks.
`scripts/promote-llama-build.sh` now reads `arch` from the build's
`build-configuration.tsv` and holds it against the `architecture` of the
ledger's promoted row; `QWEN_PROMOTION_ARCHITECTURE` names another arm on
purpose. `scripts/test-promote-llama-build.sh` calibrates it three ways: a
record naming `89` is refused by name, the same record promotes when the
variable names `89`, and a build with no record is refused ahead of every
device smoke. The builder's default stays `89`, because its comment names
the reason -- an inspectable closure -- and the promotion gate now holds the
boundary the default had crossed.

Recorded 2026-09-20.
