# Raising the MMVQ kernel column ceiling to 20

## Invariant

`MMVQ_KERNEL_MAX_NCOLS`, the `mul_mat_vec_q_switch_ncols_dst` case list, and the
two `static_assert` bounds on `GGML_CUDA_ADA_MMVQ_Q6_K_MAX_BATCH_SIZE` and
`GGML_CUDA_ADA_MMVQ_Q8_0_MAX_BATCH_SIZE` are one claim: every value the
thresholds may name is an instantiated column count. Moving the constant alone
widens what the asserts admit and leaves `GGML_ABORT("fatal error")` on a
reachable dispatch path, so the constant and the case list move together.

## The edits

`mmvq.cuh` sets `MMVQ_KERNEL_MAX_NCOLS` to 20. The threshold defaults stay at 8
and `MMVQ_MAX_BATCH_SIZE` stays at 8, so dispatch on every other path is
unchanged and the wider ceiling is reachable only by a build naming a larger
threshold. `mmvq.cu` gains cases 17 through 20 in
`mul_mat_vec_q_switch_ncols_dst`, each a copy of the case 16 body with its own
`constexpr int c_ncols_dst`, so `GGML_ASSERT(ncols_dst <=
MMVQ_KERNEL_MAX_NCOLS)` admits nothing the switch cannot instantiate.

`calc_nwarps` returns 2 for 17 through 20 on the generic table and
`calc_rows_per_block` returns 2 for the same counts, which is the geometry
column 16 already runs. Ada resolves to `MMVQ_PARAMETERS_GENERIC`, since
`get_device_table_id` selects `MMVQ_PARAMETERS_TURING` only below
`GGML_CUDA_CC_AMPERE`. `blocks_per_iter` is `vdr * nwarps * warp_size / qi` and
carries no `ncols_dst` term, so nwarps at 2 keeps the K loop trip count and the
two-warp reduction tree exactly those of column 16 and the only change is the
column extent of `tmp`, `tmp_gate`, and the shared buffers. The nwarps step
from 4 to 2 happens at column 5 and has been flat since, so the value is
inherited rather than extrapolated from a progression.

## Falsifiers

`mul_mat_vec_q` declares `float tmp[ncols_dst][rows_per_cuda_block]` and
`float tmp_gate[...]` per thread. At 20 by 2 that is 80 accumulator floats per
thread against 64 at column 16, past the point where nvcc under
`__launch_bounds__(nwarps*warp_size, 1)` spills to local memory, which turns a
wider column count into slower arithmetic. `nvcc -Xptxas -v` register and
`lmem` counts for the column-16 and column-20 instantiations of one type settle
it; that read has not run.

The shared buffers are bounded by arithmetic. `tmp_shared` is `[nwarps-1][ncols_dst][rows_per_cuda_block][warp_size]`, so at
nwarps 2, columns 20, rows 2, and warp size 32 it is 1280 floats, 5120 bytes,
and the fusion gate buffer doubles the block to 10240 bytes against the 48 KiB
static per-block limit. The wider ceiling does not overflow shared memory.

## Staged measurement

Arms B17 through B20 pair a stock threshold-16 build against a threshold-20
build of this patch, one arm per column count, each arm measured forward and
again in reverse with a closing control, the mirrored order
`run-cuda-baseline-sweep.sh` applies. Each arm reads the executed kernel family
from the Nsight symbol the way `run-ad104-path-audit.sh` does, so a threshold
that raised the ceiling without moving dispatch shows an unchanged symbol
rather than a null rate difference. Promotion takes the greatest B whose paired
MMVQ gain exceeds the registered 0.7% build-to-build drift floor while the arm
reproduces the control build's output tokens exactly; a B that gains inside the
floor, or that moves a token, promotes nothing.
