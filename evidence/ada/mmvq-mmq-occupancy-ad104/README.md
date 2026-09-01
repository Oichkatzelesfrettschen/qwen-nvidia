# Q8_0 MMVQ and MMQ at sixteen columns: occupancy and path totals

Two paired Nsight captures and three Nsight Compute records measure what the
Q8_0 dispatch threshold decides between at sixteen columns. `occupancy.tsv`
carries the per-kernel launch properties, `path-totals.tsv` the per-family
kernel time each arm spent, and `raw-records.sha256` the digests of the raw
reports, which this tree does not retain.

## Provisional status

The raw reports these exports derive from were captured from an ordinary
interactive shell, so each embedded that shell's whole environment, and the
credentials in it are why `scripts/exec-profiler-clean-env.sh` and
`scripts/check-tracked-artifacts.py` now exist. The numbers are unaffected by
the container that carried them -- kernel timing does not depend on the
environment string beside it -- but the arm is recorded as provisional and
task #68 repeats it under the clean wrapper before any kernel policy moves.

## The paired path totals

Both arms ran the same workload and issued the same 186 quantized mat-mul
launches, differing only in which family dispatch selected, so the totals
compare directly.

| arm | mat-mul | fixup | combined |
| --- | ---: | ---: | ---: |
| MMVQ ncols=16 | 2060.9 us | -- | 2060.9 us |
| MMQ ncols=16 | 1940.6 us | 550.1 us | 2490.7 us |

MMVQ finishes the path 17.3% faster, which is the direction the promoted
Q8_0 threshold of sixteen already encodes, and this arm corroborates that
threshold rather than moving it.

The stream-K fixup is the mechanism worth naming: 550.1 us is 22.1% of what
the MMQ arm spends, and it exceeds the 429.8 us margin by which MMVQ wins the
whole path. MMQ's mat-mul kernel alone is 5.8% faster than MMVQ's; the fixup
passes are what reverse the outcome. A discriminator that avoids the fixup
where the tile topology allows it is therefore the change with a measured
case behind it, which is what task #68 tests.

## What the occupancy records establish, and what they do not

Register pressure rises with the column count: the Q8_0 MMVQ kernel takes
114 registers per thread at twelve columns and 136 at sixteen, which lowers
the register-limited occupancy from 8 blocks to 6 and the peak warps per
active cycle from 33.3% to 25.0%. The MMQ kernel at sixteen columns spends
42.0 KiB of dynamic shared memory per block, which limits it to 2 blocks per
SM, and it sustains 15.1% of peak SM throughput against MMVQ's 72.7%.

The single-launch durations in `occupancy.tsv` are not a head-to-head
comparison and must not be read as one. Nsight Compute profiled one launch
per arm and those launches carry different problem shapes -- grid 3072 for
MMVQ against grid 60 for MMQ -- so the 27.456 us and 22.848 us figures
describe different work. Read as a comparison they would invert the
threshold decision that `path-totals.tsv` supports.

## Falsifier and the confidence this arm carries

Both captures ran the identical `mul_mat_vec_q` single-column kernel as an
unintended control: 664.3 us in the MMQ arm against 591.2 us in the MMVQ
arm, a 12.4% spread on work that did not change. The 17.3% path difference
exceeds that spread by a factor of 1.4, so a single paired capture supports
the direction rather than the magnitude, and the repeat arm under the clean
wrapper is what would settle it. A repeat in which MMVQ's advantage falls
inside the control spread refutes this arm; one in which the fixup share
falls well below 22% removes the case for the discriminator.
