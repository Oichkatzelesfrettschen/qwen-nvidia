# Memory-clock state and depth-0 repeatability

Two rates for the same cell -- Qwen3.8-4B Distill Q4_K_M, full Vulkan offload,
`-ngl 99 -t 2 -r 3 -p 0 -n 64` on one build and one file -- disagreed by 7.5%:
3.31 tok/s in the Nanbeige depth ladder against 3.08 in the KV cache factorial.
That is larger than every effect the factorial set out to resolve, so it had to
be settled before either could be read.

## The disagreement is state, and it is worth about 4%

`remote/measure-bench-repeatability.sh` runs the ladder's flag set and the
factorial's, hot and then again after ten minutes idle.

| arm | flags | decode tok/s | peak C | modal mclk |
| --- | --- | ---: | ---: | ---: |
| ladder-flags | none passed | 3.20 +/- 0.02 | 85 | 933 |
| hot-f16-fa-off | `-ctk f16 -ctv f16 -fa off` | 3.11 +/- 0.03 | 89 | 933 |
| hot-f16-fa-auto | `-ctk f16 -ctv f16` | 3.18 +/- 0.01 | 90 | 933 |
| cold-f16-fa-off | `-ctk f16 -ctv f16 -fa off` | 3.24 +/- 0.01 | 84 | 933 |
| cold-ladder-flags | none passed | 3.27 +/- 0.00 | 85 | 933 |

Identical flags measure 3.11 hot and 3.24 cold, a 4.2% spread on nothing but
elapsed idle time. The ladder's 3.31 sits 1.2% from the cold repeat of its own
flag set, so an idle machine reproduces the ladder and a loaded one reproduces
the factorial.

Passing `-ctk f16 -ctv f16` changes nothing: 3.20 against 3.18 with the flags
otherwise equal, which is the control working. In the cold block the two flag
settings differ by 0.9% where hot they differed by 2.9%, so the flag effect an
earlier reading took for real is inside the state gradient.

**Consequence.** A depth-0 rate on this part carries about 4% of uncontrolled
spread. Two such rates are comparable when they were measured inside one window
and are not comparable across sessions. Every depth-0 figure in this tree
predates that finding. Deep rungs are less exposed: a 16384 rung is preceded by
about thirteen minutes of prefill that settles the part before decode begins,
and the ladder and the factorial agree to 1.1% there, 2.69 against 2.66.

## Neither clock ladder explains it

`remote/sample-gpu-clocks.sh` recorded the DPM state through every arm above.
`pp_dpm_mclk` reported step 2, 933 MHz, in all five, and `sclk` peaked at
1100 MHz in all five, cold arms at 84 C included. The covariate the sampler was
added to control is constant across the spread it was meant to explain, so it
does not explain it. The sampler stays because a constant that is recorded is a
constant that is known.

## Memory is trained at DDR4-2133; the reported steps are dynamic FCLK

| property | value | source |
| --- | --- | --- |
| modules | 2 x 16 GiB Crucial, dual-rank | DMI |
| rated | 2133 MT/s | both SPD EEPROMs |
| channels | 2, both populated | kernel and DMI |
| trained | 2133.33 MT/s | both UMC `0x50200` values |
| timings | 15-15-15-36, tRP 15, tRC 51 | both UMC timing pairs |
| peak | 34.13 GB/s | 2 x 8 bytes x 2133.33 MT/s |

For DDR4, bits 7:0 of UMC register `0x50200` encode the ratio as value/3, with a
200 MT/s multiplier. Both channel values have `0x20` in that field, so the
trained rate is `(32 / 3) x 200 = 2133.33 MT/s`. Both channels also report
`0x0f0f240f` at `0x50204` and `0x000f0033` at `0x50208`, which decode to
15-15-15-36, tRP 15, and tRC 51. That is the DDR4-2133 timing profile in both
CRC-valid SPD EEPROMs. The installed four-rank population is not being derated
to DDR4-1866, and firmware F.69 is not capping it at that rate.

The apparent contradiction came from treating `pp_dpm_mclk` as a direct DRAM
clock oracle. In the kernel's SMU10 implementation, the `PP_MCLK` display path
calls `PPSMC_MSG_GetFclkFrequency`; it reports the dynamic fabric clock through
a legacy memory-clock filename. The selected 933 MHz state is therefore a
fabric power state, not the UMC training result. The retained Vulkan telemetry
also contains 1067 MHz selected states, directly falsifying the earlier claim
that the highest entry was unreachable. Governor experiments can move or pin
dynamic clocks but cannot change the UMC training registers.

`dmidecode` prints `Configured Memory Speed: 2400 MT/s` for both DIMMs. That
exceeds the modules' own SPD rating and the measured UMC rate, so SMBIOS is not
an operating-clock oracle on this firmware.

## The global high governor buys nothing

`remote/measure-dpm-force.sh` alternates `auto` and `high` rather than running a
block of each, because the 4.2% state spread above exceeds the effect being
looked for. The `high` setting can move SCLK, FCLK, and other device power
domains together, so this comparison measures a global governor intervention
and does not isolate a memory-clock effect. The harness records both SCLK and
the legacy `pp_dpm_mclk` FCLK surface, and the original level is restored from
an EXIT trap.

| round | level | decode tok/s |
| ---: | --- | ---: |
| 1 | auto | 3.23 +/- 0.06 |
| 1 | high | 3.23 +/- 0.05 |
| 2 | auto | 3.27 +/- 0.00 |
| 2 | high | 3.22 +/- 0.07 |

The two settings are indistinguishable, which follows from what the ladders do:
the fabric already reaches its 1067 MHz state under real Vulkan loads and
`sclk` already reaches 1100 MHz under `auto`. The governor is not a useful
throughput lever on this machine and the appliance keeps `auto`.

## Where the ceiling is not

Host sequential read measures 15.44 GB/s on two threads, about 45% of the
34.13 GB/s dual-channel peak. That figure bounds the two Zen+ cores through the
load/store path and says nothing about the iGPU, which reaches memory through
the Data Fabric on a different path with its own limit. The GPU's achievable
streaming rate is unmeasured, so the fraction of it that decode uses is unknown,
and `evidence/decode-bound-analysis.md` carries what replaced the guess.
