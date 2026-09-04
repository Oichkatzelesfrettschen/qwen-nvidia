# Does the Q6_K threshold belong at ten when the columns are decoding sequences

`../mmvq-crossover-ad104/` set `GGML_CUDA_ADA_MMVQ_Q6_K_MAX_BATCH_SIZE` to ten
by measuring Q6_K at `ne11` seven through twelve with llama-bench `-p N`, which
issues one mat-mul of N columns in isolation and reads MMVQ ahead through ten.
`../concurrent-sequences/` establishes that the regime actually producing
`ne11 > 1` on this appliance is N decoding sequences, where the same column count
arrives with N separate KV caches and a flash-attention pass over N sequences
beside it, and its served rate at the Q6_K crossing is consistent with MMQ
leading earlier than ten. That reading rests on one model's derivative against an
uncalibrated second model. This arm compares one model with itself.

## The two closures differ in one integer, and the difference is inert almost everywhere

The control is the promoted closure `88681bf4d161` at `Q6_K_MAX = 10`. The
subject is built by `QWEN_CUDA_MMVQ_Q6K_MAX=7` and is identical in every other
configuration field, which the build digest carries.

`ggml_cuda_should_use_mmvq` reads the threshold only to compare it against
`ne11`, so the two closures dispatch identically outside a narrow band:

| ne11 | control | subject | where it occurs |
| --- | --- | --- | --- |
| 1 to 7 | MMVQ | MMVQ | one to seven decoding slots |
| **8, 9, 10** | **MMVQ** | **MMQ** | eight to ten decoding slots |
| 11 and above | MMQ | MMQ | eleven or more slots, and all prefill |

Prefill runs at ubatch 512, far above either threshold, so both closures already
send it to MMQ and the change reaches no prefill pass. The blast radius is
exactly concurrent decode at eight, nine, or ten slots, which is the regime under
test.

That makes levels 7 and 11 null controls the arm carries itself. Two closures
that differ measurably where they dispatch identically are measuring the harness
rather than the threshold, and the run is refused on that reading before its
subject levels are believed.

## What is measured

`run-concurrent-sequence-sweep.sh` with `QWEN_CONCURRENCY_SUBJECT` naming the
second closure. Both servers are resident at once on adjacent ports, each at
`--parallel N` and `N * 4096` of context, and every repeat runs both bursts with
the order alternating -- control first on odd repeats, subject first on even --
so drift inside the pair and order bias cancel the way the MMVQ width campaigns
already require. Levels are 7, 8, 9, 10, and 11 with four repeats each, the SM
clock pinned at 2835 MHz.

The verdict reads the median of the per-repeat aggregate-throughput ratio,
subject over control, at each level.

## Preregistered decision rule

**Promotion requires both clauses at every one of levels 8, 9, and 10.**

1. The median aggregate ratio clears 1.051, the same 5.1% floor
   `../mmvq-q8-b17-b20/` set and the same floor the fan-out and graph-loop
   levers were refuted against. The floor is not lowered after seeing a result.
2. Exact greedy token identity holds against the control at every level,
   compared over `return_tokens` id arrays request by request. MMQ reorders
   floating-point accumulation by construction, which is why
   `../mmq-stream-k-grid/phase-c-identity/` rejected tiling threshold 80 and why
   the MMVQ nineteen-column candidate was rejected on identity while ahead on
   rate. A throughput win that changes a served reply is not a win.

The identity comparison requires `return_tokens` to be present and non-empty in
every response and the run fails outright otherwise, because an absent field
reads as one empty list on both closures and reports an agreement it never made.

## Falsifiers, stated before the run

1. **The null controls move.** Levels 7 or 11 differ by more than the
   burst-to-burst spread the single-closure sweep measured at 0.08% to 1.97%.
   The two closures dispatch identically there, so a difference is the harness or
   the device, and every subject level is unreadable until it is explained.
2. **No gain in the band.** The median ratio at 8, 9, and 10 sits inside the
   spread, which says the llama-bench threshold transfers to the served regime
   and that `../concurrent-sequences/`'s cross-model reading was the artifact of
   comparing two uncalibrated trajectories. This is the outcome the existing
   threshold predicts.
3. **A gain under the floor.** The band moves in the subject's favor without
   reaching 5.1%. The threshold is then measurably misplaced and not worth a
   closure, which is the same verdict the fan-out and graph-loop levers took.
4. **A gain that changes the reply.** Clause 1 passes and clause 2 fails. The
   candidate is rejected and the record names it on a rejected line beside the
   MMVQ nineteen-column patch, since exact identity is the gate this tree does
   not trade away for rate.
5. **The gain runs the wrong way.** MMVQ at eight to ten is measurably better in
   the served regime than the llama-bench arms found. That would argue the
   threshold belongs above ten rather than below it, and it is a result rather
   than a failure.

## Discipline

One model, the 2B distill, because the question is a threshold for one
quantization type and the 0.8B is Q8_0 which this threshold does not govern. Both
closures under the owner lock in one campaign, the quiescence gate applied per
observation, `device-environment.tsv` recording the stack, and the desktop client
set held as this host's standing covariate. The subject closure is a candidate
and reaches no promotion path unless this arm passes both clauses.
