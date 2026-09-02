# Phase A: the patch is inert at its default

The stream-K grid patch makes `mmq.cuh:1436`'s efficiency threshold a
build-configured value and leaves 90 as its default, so a closure built at 90
has to behave exactly like the unpatched control. A difference here would mean
the patch changes behavior where it changes no value, which is a defect in the
patch rather than a property of the grid, and the preregistration ends the
campaign on it.

Closure `93938392c92a` at 90 against the promoted `88681bf4d161` on
`qwen38-2b-distill` Q4_K at its registry tuple: context 65536, batch 2048,
ubatch 512, `q8_0`/`q4_0`, Flash Attention on. Both halves ran under the
top-level GPU owner lock with the same three desktop clients resident
throughout -- `kwin_wayland`, the Discord GPU process, and the Microsoft Edge
GPU process -- and the client set is identical at the open and the close of
each half.

## The launch record

`../phase-a-path-audit/` carries one Nsight-profiled prefill per arm at
`ne11` 17, read out of `CUPTI_ACTIVITY_KIND_KERNEL`.

| arm | MMQ | FIXUP | MMVQ | distinct symbols |
| --- | ---: | ---: | ---: | --- |
| `sk-control-2b-q4k` | 186 | 186 | 164 | 3 / 3 / 4 |
| `sk-null-2b-q4k` | 186 | 186 | 164 | 3 / 3 / 4 |
| `sk-close-2b-q4k` | 186 | 186 | 164 | 3 / 3 / 4 |

The counts decide this, not the families. `run-ad104-path-audit.sh:268-277`
admits a FIXUP row under an `MMQ` expectation, because `mmq.cuh:1463` reaches
the reduction only from the call that already launched `mul_mat_q`, so all
three arms read `agrees` whether or not the fixup ran. A null that moved 186
fixup launches to zero would have passed the verdict column and failed the
count column, which is why both are retained.

The Q4_K mat-mul demangles to
`mul_mat_q<(ggml_type)12, (int)24, (bool)0>` and its reduction to
`mul_mat_q_stream_k_fixup<(ggml_type)12, (int)24, (bool)0>`, the identical
template arguments the pairing at `mmq.cuh:1463` produces.

## The token record

`../phase-a-token-identity/` runs `scripts/run-closure-identity-ab.sh` over six
state-carrying prompts at 256 predicted tokens, temperature 0, `top_k` 1, seed
1, `ignore_eos`, `cache_prompt` off, hashed over the `return_tokens` array with
its length asserted equal to `n_predict` before hashing.

All eighteen arm-prompt digests agree. Each of the six prompts produces one
digest shared by `control-open`, `subject`, and `control-close`, so the null is
identical to the control and the control is identical to itself across the
subject arm.

Placement is the same across all three arms at
`b30ada0b80b8c5097b9ce8a5ec98f2627b1a45981ffbfa9a0f9eefa37b2ccbcf`, the digest
of the three `CUDA0` buffer lines: model 1204.91 MiB, KV 312.00 MiB, compute
220.28 MiB, with no CPU buffer line in any load. That comparison exists because
`--fit` decides placement per load from observed free VRAM and the desktop
moves that figure between two loads on this host, so a drifted control reads as
divergent and a drifted subject reads as identical.

The kernel ring was read through `sudo -n dmesg` before and after and carries
zero hazard signatures at each read.

## Verdict

`closure_identity=identical subject_divergences=0 control_divergences=0
refusals=0`, and `arms=3 differing=0 observations=30`. The patch is inert at
90 by both the launch record and the token record, so the campaign continues.

Phase A establishes that the patch changes nothing when its value changes
nothing. It says nothing about threshold 80, whose whole mechanism is to change
the grid and therefore the summation order on the shapes it flips.
