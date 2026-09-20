# graft's crux retry policy, crossed with the checkpoints it was said to penalize

**The collector defect is in the installed source and did not fire.** Correcting
`collectFileCrux` to accept a record only when it carries a summary changed
nothing either checkpoint recorded: the same symbols ready, the same symbols
pending, the same number of requests issued, and wall times within 0.15 percent.
The 2507's missing records are not the retry policy losing them.

That falsifies the prediction this run was built to test. The reading was that
an id returned with a blank summary is stored by the collector on its arrival,
removed from the next attempt's work, and then rejected by enrichment, so a
checkpoint producing that reply shape spends one of its two attempts on nothing
and loses records to the client rather than to its own answers. The mechanism is
real in the code and the arms show it is not reached by this failure.

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

## Why the defect did not reach this failure

The 2507 loses `mpu.c` to `empty-parsed, finish_reason=null`, which
`classifyCruxMiss` reaches when the reply parses into entries and not one of
them carries a summary. With every entry blank, the stock collector stores
nothing:

    for (const r of list)
        if (!results.has(r.id))
            results.set(r.id, r);
    missing = refs.filter((r) => !results.has(r.id));

`results` stays empty, `missing` stays the whole target list, and the second
attempt runs. The 2507 issued 8 requests against the distill's 6 under both
collectors, and those two extra requests are that retry. It ran, and it failed
the same way.

The defect needs a **mixed** reply to bite: some ids carrying summaries and
others blank in one response, so `results` is non-empty and the blank ids are
filtered out of the retry while enrichment still rejects them. Neither
checkpoint produced one here. `swapram.c` succeeded whole for both, `mpu.c`
failed whole for the 2507, and 5 pending is exactly `mpu.c`'s five symbols. The
condition was never exercised, so this run says nothing about what the
correction is worth when it is.

## What this does not settle

The correction stays worth carrying, because the invariant it restores is the
one the rest of this pipeline now holds: a record is accepted on the same terms
wherever it is read. It costs nothing measurable when it does not trigger, which
these arms establish.

Whether the 2507's 41 pending symbols in
`evidence/ada/graft-deep-pilot/` have the same cause as the 5 here is open. That
run indexed 22 files and lost `mpu.c` and `swapram.c` whole; this one indexed 2
and lost only `mpu.c`, so `swapram.c`'s failure there did not reproduce under a
smaller tree. The difference is the input to the concept and summarize passes
that precede the crux, not the crux prompt, which is byte-identical in both.

The prompt comparison remains the next independent experiment, and it is now the
only remaining explanation this evidence has not ruled out.
