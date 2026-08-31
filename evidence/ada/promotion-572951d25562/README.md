# Promotion of configuration 572951d25562

The promoted tuple: architecture 89 with its full PTX complement
(cuda_payload=verified cubin=187 ptx=187), CUDA and Vulkan backends, NCCL
off, graphs on, all served flash-attention quant pairs, VMM on, compression
size, native host, LTO off, and the AD104 MMVQ thresholds at ten for Q6_K
and twelve for Q8_0 through patches/llama-cuda-mmvq-crossover-ad104.patch.
Each value stands on its own measurement: the thresholds on
../mmvq-crossover-ad104/, the compression, LTO, and module-loading defaults
on ../build-ladder/, the PTX-bearing default on
../cuda-ptx-code-selection-compiler-falsification.md, and NCCL off on the
single-device audit finding that the collective path never executes here.

`promote-llama-build.sh` accepted the preset with the strict Vulkan
one-token check and the multimodal smoke passing and swung
build-appliance-current to it. The dispatch spot-checks on the threshold
sibling read Q6_K at 73.0 per token on MMVQ at nine columns and 65.6 on MMQ
at eleven, and Q8_0 at 211.2 on MMVQ at twelve and 185.6 on MMQ at thirteen,
so each knob reaches its own type alone. The serve pairs read 2B
15067/230.9, 0.8B 23004/308.1, and 4B 6669/113.4 against registered
14748/231.4, 22770/310.5, and 6703/113.5, inside the floors with decode
unregressed. `admit-cuda-router-serving.sh` then ran the assembled chain on
the promoted binary: nine checks, none rejected, both children answering
from CUDA0 at 5371 MiB resident, clean teardown (serving-summary.tsv).
