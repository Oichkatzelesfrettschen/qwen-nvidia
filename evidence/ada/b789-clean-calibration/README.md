# B7/B8/B9 clean-boot calibration: the crossover verdict per quant family

The matrix ran as the first project CUDA workload of the 2026-08-30 23:01
boot, ten arms in preregistered order with a closing control, kernel ring at
zero hazard signatures before and after, the compositor as the one resident
compute client (resident-compute-clients.txt). llama-bench
c51daa95fe2fc4086264e4694f0d7a10d1e8207184d3d6cdf2a01ed8538b6e4a, flags
`-ngl 99 -fa 1 -ctk q8_0 -ctv q4_0 -p N -n 128 -r 3 -t 6` through
cuda-runtime-env.sh on CUDA0.

## Per-token prefill efficiency (paired-mean prefill tok/s divided by ne11)

| quant | B7 (ne11=7) | B8 (ne11=8) | B9 (ne11=9) |
| --- | ---: | ---: | ---: |
| Q4_K | 75.1 MMVQ | 75.3 MMQ | 70.0 MMQ |
| Q5_K | 73.5 MMVQ | 77.5 MMQ | 69.2 MMQ |
| Q6_K | 69.8 MMVQ | 73.1 MMVQ | 57.0 MMQ |

The closing control repeated the opening arm at +5.1% prefill drift, and
within-arm pp spans reach 21.6%, so that drift is the comparison floor.

## Reading

The Q4_K and Q5_K crossovers at seven columns are correctly placed on AD104:
their first MMQ point is rate-neutral against the floor. The Q6_K move to MMQ
at nine columns costs 22% per token, four times the floor, so the preregistered
step landed in the opposite direction: MMVQ was the faster family at the point
the RTX 4090-tuned crossover abandons it. The forced-cuBLAS differential
(../b789-cublas-differential/) rules the third family out: dequant+GEMM runs at
roughly half the MMQ rate at every post-crossover point, and its Q6_K pp8 MMVQ
reading of 591 against this run's 585 is the cross-build control. The Nsight
arm (../b789-nsys-causality/) reads MMQ out of the executed symbols for b9-q6k,
so the 57.0 belongs to the kernel family rather than to a dispatch surprise.

## What stays open

Whether Q6_K MMVQ extended past eight columns beats MMQ's 57.0 per token is
unmeasured: the crossover is a compiled constant (mmvq.cu:295-306), so the
answer needs a threshold-shifted experimental build. The Q4_K and Q5_K B9
declines of 7% and 11% sit inside one to two floors and stay unresolved.
