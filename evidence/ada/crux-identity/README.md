# What the 2507 returns for a crux request, and why graft discards it

**qwen3-4b-instruct-2507 answers the crux request correctly and loses the answer
to punctuation.** It returns as each record's id the whole target line the
request printed -- `sys/arch/rp2040/rp2040/mpu.c#mpu_program | function | lines
L141-L159` where the target was `sys/arch/rp2040/rp2040/mpu.c#mpu_program` --
and every one of those records carries a correct summary. graft matches ids by
equality, so none of them reaches a target, the retry set never shrinks, and the
file is reported as though the model said nothing. Resolving the leading field
of a returned id against the requested set recovers the whole file: the same
checkpoint goes from 37 computed and 6 pending to 43 computed and 0 pending, in
half the attempts and 31 percent less wall time.

This replaces capability as the explanation for the 2507's pending records. The
deep-pilot reading, that the 2507 "lost mpu.c and swapram.c whole", measured a
client-side identity comparison rather than a model's answer.

## What ran

| | |
| --- | --- |
| tree | `sys/arch/rp2040/rp2040/mpu.c` and `swapram.c`, under their real paths |
| mpu.c | `6705807c2440b491e039977ae331b242a0c90863038ea58961b3413403f2b0e7` |
| swapram.c | `4205c644a2abc86b5aebff6b4fbde4081e953404ffff28fa93465d81b8ac7422` |
| graft | 0.18.0, instrumented per attempt, collector stock or `resolved` |
| geometry | depth 16384, reasoning budget 512, concurrency 1, `QWEN_CHAT_TOOLS=on` |

The instrumentation records, for each attempt, the ids requested, the ids
parsed, the ids carrying a summary, the ids accepted and the ids still missing.
It changes no acceptance rule, and its insertions anchor on lines the collector
corrections leave alone, so an arm reports what its own collector did.

## The arms

| model | collector | wall ms | attempts | computed | pending | verdict |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| qwen38-4b-distill | stock | 59,507 | 2 | 43 | 0 | complete |
| qwen3-4b-instruct-2507 | stock | 142,305 | 4 | 37 | 6 | identity_loss |
| qwen3-4b-instruct-2507 | resolved | 98,542 | 2 | 43 | 0 | identity_recovered |

`computed` counts every node graft describes, which includes each file's own
node: `refs` in `enrichGraph` maps every node of the file with no filter on
kind, so the two files carry 41 symbols and 2 file nodes.

## Per attempt

The distill answers under the ids it was given, once per file:

| file | attempt | requested | parsed | matched | summarized | missing after |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| mpu.c | 0 | 6 | 6 | 6 | 6 | 0 |
| swapram.c | 0 | 37 | 37 | 37 | 37 | 0 |

The 2507 under the stock collector matches nothing on three of four attempts,
and the one attempt it does match is the one that made `swapram.c` succeed in
every earlier run:

| file | attempt | requested | parsed | matched | summarized | missing after |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| mpu.c | 0 | 6 | 6 | 0 | 0 | 6 |
| mpu.c | 1 | 6 | 6 | 0 | 0 | 6 |
| swapram.c | 0 | 37 | 37 | 0 | 0 | 37 |
| swapram.c | 1 | 37 | 37 | 37 | 37 | 0 |

`parsed` equals `requested` on every one of those attempts. The model returned
an entry for every target it was asked about, on the first try, including the
36-target file. Nothing was omitted, invented or truncated; the ids carried
trailing text.

Under the `resolved` collector the same checkpoint needs one attempt per file:

| file | attempt | requested | parsed | matched | summarized | missing after |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| mpu.c | 0 | 6 | 6 | 0 | 0 | 0 |
| swapram.c | 0 | 37 | 37 | 0 | 0 | 0 |

`matched` stays 0 because it counts literal equality against the requested set,
which is the defect in the reply. `missing after` is 0 because the collector
resolved it. The reply is unchanged; the graph is complete.

## Why the miss label said otherwise

`classifyCruxMiss` returns null here, because the entries do carry summaries.
`enrichGraph` then finds that nothing applied and reports
`cruxMissMessage(summarizer, "empty-parsed")`, which reads
`summarizer.lastMiss?.kind ?? fallback` -- and with `lastMiss` null the literal
fallback is printed. Every `empty-parsed` recorded against these files is that
fallback, not a classification. The class name says entries parsed with no
summary; the actual state was entries parsed, all summarized, none matching an
id.

## Calibration

`scripts/admit-crux-collector-acceptance.sh` crosses three collectors with six
reply classes against a stub model, with the expectation stated per arm; a
departure fails the run. All eighteen arms hold. The rows that matter here:

| reply | stock | accepted | resolved |
| --- | --- | --- | --- |
| whole target line as the id, summarized | 2 requests, 0 ready | 2 requests, 0 ready | 1 request, 3 ready |
| bare symbol name, summarized | 2 requests, 0 ready | 2 requests, 0 ready | 2 requests, 0 ready |

A bare name names no target and stays lost under every rule, so the resolution
recovers an echoed id and nothing else. It cannot manufacture a match.

## What this does not settle

Why the 2507 echoes the line at all is a prompt property, and one attempt in
four came back clean, so the behavior is not deterministic. Whether removing the
kind and span from the target line would end it is the ablation this makes
worth running, and it is now a prompt question with a known failure mode rather
than a model search.

The resolution is a client-side repair of a model's output, which the rest of
this pipeline treats as grounds for withholding a verdict. It is reported here
as a measured recovery, not adopted as a default: what it establishes is that
the 2507's records exist and are correct, so any comparison that ranked the two
checkpoints on recording quality was ranking id punctuation.
