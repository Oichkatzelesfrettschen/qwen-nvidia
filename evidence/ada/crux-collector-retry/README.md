# graft's crux retry policy, crossed with the checkpoints it was said to penalize

**The collector defect is real, it fires on the reply it was written for, and
the 2507 does not produce that reply.** Correcting `collectFileCrux` to accept a
record only when it carries a summary changed nothing either checkpoint
recorded: the same symbols ready, the same symbols pending, the same requests
issued, and wall times within 0.15 percent. The cause is narrower than a null
result: the 2507 answers with ids the request never named, and an id the
collector cannot match is outside the reach of any acceptance rule.

The first reading of this run held that a blank summary leaves the collector's
map empty so the retry runs under both rules. That is wrong, and the stock
source says so: the predicate stores a record on its id alone, blank or not.
The corrected mechanism is below, and a stub-model calibration reproduces both
the defect and the observed failure.

## What ran

Two checkpoints, two collectors, one input:

| | |
| --- | --- |
| tree | `sys/arch/rp2040/rp2040/mpu.c` and `swapram.c` alone, under their real paths |
| mpu.c | `6705807c2440b491e039977ae331b242a0c90863038ea58961b3413403f2b0e7` |
| swapram.c | `4205c644a2abc86b5aebff6b4fbde4081e953404ffff28fa93465d81b8ac7422` |
| graft | 0.18.0, stock at the system install and a copy carrying `collector-acceptance.patch` |
| geometry | depth 16384, reasoning budget 512, concurrency 1, `QWEN_CHAT_TOOLS=on` |
| isolation | one graft directory per arm, so no arm reads another's cache |

`collector-acceptance.patch` is the whole of the difference between the two
collectors. It makes the retry set the ids that still have no accepted record
rather than the ids that have not been seen.

## The arms

| model | collector | ready | pending | requests | file errors | wall ms | verdict |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| qwen38-4b-distill | stock | 41 | 0 | 6 | 0 | 57,573 | accepted |
| qwen38-4b-distill | fixed | 41 | 0 | 6 | 0 | 57,509 | accepted |
| qwen3-4b-instruct-2507 | stock | 36 | 5 | 8 | 1 | 141,667 | incomplete |
| qwen3-4b-instruct-2507 | fixed | 36 | 5 | 8 | 1 | 141,452 | incomplete |

Every column but wall time is identical across the collector pair, and wall time
differs by 64 ms and 215 ms, below the run-to-run span of a single arm.

`ready` and `pending` count symbol nodes. The deep logs report one more of each
-- `37 computed, 6 pending` for the 2507 -- because graft's crux pass treats a
file's own node as a target: `refs` in `enrichGraph` maps every node of the file
with no filter on kind. `swapram.c` contributes 36 symbols and its file node;
`mpu.c` contributes 5 symbols and its file node, and both fail together.

## The acceptance rule is not what lost these records

`scripts/admit-crux-collector-acceptance.sh` drives both collectors from a stub
model, so the reply class is the only variable and no GPU is involved. Each mode
states what the collectors must do, and a departure fails the run.

| reply | collector | requests | ready | pending |
| --- | --- | ---: | ---: | ---: |
| every requested id, summarized | stock | 1 | 3 | 0 |
| every requested id, summarized | fixed | 1 | 3 | 0 |
| every requested id, blank | stock | 1 | 0 | 3 |
| every requested id, blank | fixed | 2 | 0 | 3 |
| first requested id summarized | stock | 1 | 1 | 2 |
| first requested id summarized | fixed | 2 | **2** | 1 |
| bare name, blank | stock | 2 | 0 | 3 |
| bare name, blank | fixed | 2 | 0 | 3 |
| bare name, summarized | stock | 2 | 0 | 3 |
| bare name, summarized | fixed | 2 | 0 | 3 |

The defect is in the first two blank rows: the stock collector stores the
blank record on its id, computes `missing` from that map, finds nothing missing,
and spends only one of its two attempts. The correction re-asks. On a mixed
reply the correction recovers a record the stock rule discards, 1 ready against
2. On a clean reply the two are identical, so the correction costs nothing.

The last four rows are this run. An id that was never requested satisfies
`!results.has(r.id)` under the stock rule and fails `results.has(r.id)` in the
`missing` filter, so the map fills with entries no target matches, `missing`
stays whole, and the second attempt runs under both rules and is discarded under
both. The acceptance predicate never governs a record the collector cannot
match to a target.

The retained server log shows exactly that shape. The 2507's stock arm issues
eight requests, and the crux pairs repeat a prompt of identical length:

    task 0     149 tokens   admission probe
    task 20   2997          summarize, first file
    task 22   6701          summarize, second file
    task 710  1658          synthesize
    task 3091 4454          crux, first file, attempt 1
    task 3647 4454          crux, first file, attempt 2
    task 4209 8614          crux, second file, attempt 1
    task 7935 8614          crux, second file, attempt 2

Both files already retried under the **stock** collector. A retry requires
`missing` to be non-empty after the first attempt, which requires `results` to
lack the requested ids. Combined with `empty-parsed` -- which `classifyCruxMiss`
reaches only when the reply parsed into entries -- entries came back and their
ids did not match the targets.

## What the miss label can and cannot say

`empty-parsed` reaches the log by two paths: `collectFileCrux` reports it for a
total miss, and `enrichGraph` reports it again when entries arrived and nothing
applied. Both read `summarizer.lastMiss`, a single mutable field on a summarizer
shared by every file in flight. At `-j 1`, as here, the label belongs to the
file it is printed against. Above `-j 1` it is whatever the last concurrent
`describeFile` left, so a miss class read off a concurrent deep run does not
attribute to its file. The pilot at `-j 6` in `evidence/ada/graft-deep-pilot/`
is subject to that, and its per-file classes are not evidence of per-file cause.

## What this settles and what it does not

The correction is worth carrying on its own terms: the calibration shows it
recovers a record on a mixed reply and costs nothing on a clean one, and it
makes a record accepted on the same terms wherever it is read. It is not a fix
for the 2507, which fails earlier.

The open question is no longer the retry policy but why the 2507 answers with
ids the request did not name. The request carries each target as
`- id=<path>#<symbol> | <kind> | lines L<start>-L<end>`, and one of those targets
is the file node itself, which has no signature and spans the whole file. What
the model returned in place of those ids is not in this evidence: no reply body
was retained. Capturing one attempt's parsed ids against its requested ids is
the next measurement, and it is a single request, not a repository pass.
