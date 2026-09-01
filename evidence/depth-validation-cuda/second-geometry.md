# The validated depths survive a halved submission geometry

The registry claims one filled depth per runtime class and one submission
geometry beside it, and those are two claims: a depth that fills under batch
2048 and ubatch 512 can fail under another geometry on the same model and cache
triple, which is why `batch` and `ubatch` are registry fields rather than
constants in the argv. This campaign measures the second geometry the
depth-validation record left open.

Each of the four runtime classes ran `scripts/probe-filled-depth.sh` at its own
registry ceiling under batch 1024 and ubatch 256 -- half the served submission
size in both terms -- at the same `q8_0`/`q4_0` cache triple with Flash
Attention on, with strict CUDA0 placement, and each arm ends on retrieving a
needle planted at the head of the fill.

| class | model | depth | prompt_n | needle |
| --- | --- | ---: | ---: | --- |
| secondary-08b | qwen35-08b | 65536 | 65197 | retrieved |
| primary-2b | qwen38-2b-distill | 65536 | 65197 | retrieved |
| quality-4b | qwen38-4b-distill | 32768 | 32577 | retrieved |
| deep-9b | qwen38-9b-distill | 24576 | 24415 | retrieved |

Every arm passed, and that is the finding: halving the submission geometry
moves no ceiling on this device. The prediction under test was the opposite at
the deep end. A smaller ubatch reduces the peak compute buffer, so the 9B at
24576 -- the row whose allocation leaves the least room in the 12 GiB carve-out
-- was where a geometry-dependent ceiling would appear first if one existed
here, and it filled 24415 of 24576 and decoded. The served geometry is
therefore the registry's claim rather than the only geometry the depth
survives, and `scripts/validated-tuples.tsv` now carries both arms per class as
separate `validated` rows keyed by their own `tuple_id`.

Every arm ran with the compositor and one Electron GPU process resident, 316
and 594 MiB, which `scripts/gpu-workload-ownership.sh` recorded as the covariate
this workstation always carries rather than excluding. That occupancy is the
condition the 9B's headroom was measured against; a run on a quiet device has
more room, not less, so it cannot overturn a pass.

## Falsifiers

A geometry that fails where 1024/256 and 2048/512 both pass would show the
relationship is non-monotonic in submission size rather than absent, which two
passing points cannot exclude: this campaign measures two geometries, not the
space between and beyond them. An arm at the same depth and geometry that fails
on a quiet device would report that the pass depended on something other than
the geometry. A ceiling that moves after a cache-triple or Flash Attention
change is a different tuple and belongs to its own arm.
