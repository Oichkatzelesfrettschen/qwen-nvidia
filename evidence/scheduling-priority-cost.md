# The nice 19 guard shows no directional decode cost under desktop load

The appliance runs its inference process at nice 19 with the I/O class at idle,
so the desktop keeps the two Zen+ cores whenever it wants them. The tree has
asserted that guard is free on one comparison, 2.86 tok/s unconstrained against
2.87 tok/s served, and that comparison was taken on a quiet machine. That run
has little sensitivity to a contention-mediated cost, so it cannot establish
the claim under the desktop load the guard exists to serve.

## The measurement

`remote/run-bandwidth-ladder.sh` sweeps Qwen3.8-4B-Distill Q4_K_M twelve times
with the priority alternating arm by arm, six times forward as 19, 0 and six
times reverse as 0, 19. Adjacent arms meet the same machine about seventy
seconds apart, which is what the pairing buys: the same checkpoint measured in
blocks five arms apart spans 20% of its mean, and here it spans 8.9%.

The nice column is read from `/proc/<pid>/stat` after the command name becomes
`llama-bench`, so it reports the priority the kernel gave the arm. All twelve
arms verified: six at 19 and six at 0. Load average ran between 4.90 and 6.95
throughout, `mclk` at 933 MHz in every arm.

| pair | nice 19 | nice 0 | difference |
| ---: | ---: | ---: | ---: |
| 1 | 3.07 | 2.94 | -4.2% |
| 2 | 3.06 | 3.09 | +1.0% |
| 3 | 2.85 | 2.99 | +4.9% |
| 4 | 3.12 | 2.85 | -8.7% |
| 5 | 3.08 | 3.11 | +1.0% |
| 6 | 3.07 | 3.07 | 0.0% |

## The run resolves direction, not equivalence

The paired mean difference is -0.0333 tok/s, 1.10% in favour of nice 19, against
two negative pairs, three positive pairs, and one exact zero. Direction changes
three times across the sequence. The largest single pair differs by 8.7%, eight
times the mean, and it points the opposite way to the pair that follows it.

A nominal two-sided 95% paired t interval for `nice 0 - nice 19` spans -0.185 to
+0.118 tok/s, or -6.1% to +3.9% of the mean nice 19 rate. Six sequential pairs
do not justify the independence assumption behind that interval, so it is a
descriptive uncertainty bound rather than a population interval. **This run
resolves no directional decode cost. It does not establish equivalence or a
zero cost.** A confirmatory equivalence run predefines the acceptable effect
margin, randomizes priority order within each pair, and collects enough pairs
for both one-sided bounds to land inside that margin.

The mechanism the unresolved direction is consistent with is that decode waits
on the Vulkan queue rather than on the host cores. `llama-bench` runs two
threads that submit work and wait for it, so raising their claim on a contended
core changes when a submission is enqueued and not when the two Vega compute
units finish it.
The falsifier is a workload that puts the host on the critical path: a CPU-only
placement or a prefill-dominated arm can produce a stable directional effect,
and neither has been measured at both priorities.

## What the first attempt measured

The first run of this comparison measured nothing and reported a 26% priority
effect. `remote/run-bandwidth-ladder.sh` passed the arm priority into the arm
label, the progress line, and the summary column while invoking `llama-bench`
through a hardcoded `nice -n 19`, so all twenty arms ran at nice 19 and the two
priority blocks differed by position alone. `~/qwen-bandwidth-ladder` on the
appliance carries `COLUMN-DEFECT.txt`, and its column now reads the block index.

The priority column remains an observation of the child rather than a
restatement of the request, so an invocation that drops the parameter reports
the value it actually got. The current harness no longer exposes the historical
nice-0 comparison: it accepts nice 19 alone and uses absolute `renice` before
executing the census and benchmark. This removes caller-relative drift while
preserving these rows as historical evidence. The hazard is real on the
workstation, where an interactive shell at nice -4 turns relative `nice -n 19`
into nice 15.
