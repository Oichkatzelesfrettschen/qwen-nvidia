# A bounded graft deep pass on two 4B checkpoints

The incumbent `qwen38-4b-distill` fills the graph the candidate
`qwen3-4b-instruct-2507` leaves incomplete, and it does so in two thirds of
the time. Over the same 22 files at the same commit, the distill described
every one of the 243 describable symbols and exited 0; the 2507 left 41
symbols pending because two files returned entries carrying no summary.
The candidate is better at exactly one thing the distill fails outright: the
concept map, where the distill returned 18 nodes joined by no links at all and
the 2507 returned 15 nodes and 25 links.

That falsifies the prediction this pilot was built to test. The 2507 was the
roster review's candidate on the argument that an instruct template spends
none of graft's reply budget on a thought block, so it should drop fewer
records than a thinking template under the same cap. It dropped more.

## What ran

`scripts/admit-graft-deep.sh` runs graft's own `build --deep` against the
served closure `192d0663a533`, which carries
`patches/llama-server-tool-choice-object.patch`. The crux pass sends
`responseFormat {kind:"tool", name:"record_symbols"}`, the OpenAI adapter
turns that into the named-function `tool_choice` object, and the closure
resolves the object to the named tool under `required`. Neither arm printed
graft's `did not honor tool_choice` warning and neither server log carries
`Wrong type supplied for parameter 'tool_choice'`, so every request either
arm made was enforced as sent.

`pilot-inputs.tsv` carries the run's identity: source commit
`0c85040e3bda01913d687fca538b3fa49f6af82b`, the cone paths
`sys/arch/rp2040/dev` and `sys/arch/rp2040/rp2040`, depth 16384, reasoning
budget 512, concurrency 1, graft 0.18.0. Each arm reads its own detached
worktree sparse-checked-out to those paths and writes its own graft directory
outside that worktree, so no arm replays another's `graft/.cache`. The
structural tier is identical in both: 265 nodes, 229 of them functions, 171
edges, 18 cards.

The reasoning budget is set for both arms and named for one. The distill's
template thinks; without a bound it spends the reply cap before its content
reaches the call. The 2507 instruct template has no thought block, so 512
costs it nothing, and leaving the budget unset would have measured the two
templates rather than the two models. Concurrency is 1 because
`qwen-capacity-policy.sh` serves `--parallel 1`, so a higher value queues at
the one slot and inflates per-request latency while wall time stands still.

## Completion and coverage

| | qwen38-4b-distill | qwen3-4b-instruct-2507 |
| --- | --- | --- |
| deep pass exit | 0 | 0 |
| describable symbols | 243 | 243 |
| ready | 243 | 202 |
| pending | 0 | 41 |
| files with no usable summaries | 0 | 2 |
| verdict | accepted | incomplete |

The 2507's two failures are `sys/arch/rp2040/rp2040/mpu.c` and
`sys/arch/rp2040/rp2040/swapram.c`, both classified `empty-parsed,
finish_reason=null`: `classifyCruxMiss` reaches that class when the reply
parses into entries and not one of them carries a summary. swapram.c holds 36
of the 41 pending symbols and mpu.c the other 5.

The replica request does not reproduce either failure. `admit-record-symbols.sh`
sends the same file under the same line numbering with the same target list
and the same 8192-token cap, and the 2507 answers mpu.c with 5 exact entries
(`record-symbols-wire/symbols.tsv`). What differs is graft's own system prompt
and its target lines, which carry each symbol's signature. The failure
therefore belongs to graft's phrasing of the request rather than to the file
or to the checkpoint's ability to answer one.

## Speed

| | wall time |
| --- | --- |
| qwen38-4b-distill | 317,252 ms |
| qwen3-4b-instruct-2507 | 471,445 ms |

The distill is 1.49 times faster over the whole pass while filling more of the
graph, and it carries the smaller quantization: Q4_K_M against the 2507's
Q8_0. The five-file replica reverses on four files and agrees on the total:
the 2507 answers flash_swap.c, exec_hsaout.c, uart.c and mpu.c faster and
loses all of it on swapram.c, 24,990 ms against 16,674 ms, for 47,917 ms
against 43,996 ms overall.

## What the recorded spans say, and what they cannot

`buildCrux` clamps a returned span into the node's own range before storing
it, so every crux in `wiring.json` lies inside its symbol whatever the model
answered. `graft-deep-evidence.py` reports where a stored span landed and
stops there.

| | distill | 2507 |
| --- | --- | --- |
| crux present | 213 | 174 |
| crux absent | 30 | 69 |
| opens on the node's first line | 123 | 81 |
| closes on the node's last line | 84 | 101 |
| strictly interior | 90 | 55 |

Span fidelity is measured on the unclamped wire instead. Over five files both
checkpoints pass four and fail the same one:

| file | targets | distill | 2507 |
| --- | --- | --- | --- |
| flash_swap.c | 2 | pass | pass |
| exec_hsaout.c | 6 | pass | pass |
| uart.c | 19 | pass | pass |
| swapram.c | 34 | fail: 36 entries, 4 spans outside range | fail: 36 entries, 2 spans outside range |
| mpu.c | 5 | pass | pass |

Neither model invented an id and neither dropped one. Both returned 36 entries
for 34 targets, which is the same id twice, and both placed spans outside the
symbol they name. The failure is the largest request in the set for both
checkpoints, which places it on the request shape rather than on either model.

## Source accuracy

`accuracy-sample.txt` carries ten symbols sampled at a fixed stride from the
ids both arms describe, each with its source span and both summaries. Reading
them against the code, the distill states three claims the source does not
support and the 2507 states six.

The distill says `usbgetc` handles the E15 guard, which `usb_e15_critical` and
its callers do and `usbgetc` does not; it says `usbopen` allocates a tty and
registers it, which a prototype in a header cannot show; and it places the
swap cursor in flash, where `swap_cursor_init` reads
`WATCHDOG_SCRATCH0`.

The 2507 calls `dhara_nand_copy` a byte-by-byte transfer where the loop steps
`FLASH_PROG_BYTES` at a time; it attributes `flsize` to a calculated capacity
the function has no path for; it says `dhara_nand_is_free` verifies bytes are
zero-filled where the scan looks for a byte that is not 0xff, which inverts
the erased state of NOR flash; it has `usb_e15_critical` decide whether a bulk
IN buffer is armed, where the function compares a microsecond delta against
800 and 998 and returns; and it invents endpoint and buffer preparation for
the same header prototype the distill invented a tty for.

Ten symbols judged by one reader is a lead, not a rate. It is enough to say
the candidate does not buy its lost coverage back in accuracy, and not enough
to rank the two.

## The first run measured the host

`guard-terminated-run/` holds a pair of arms that must not be read as a model
result. Both ended in a transport error, the distill during the concept
synthesis and the 2507 after four files of the crux pass, and graft reported
each as `Connection error.` The cause is in the appliance's own telemetry,
read live while the run was in flight:

    sample_utc=2026-09-20T17:44:54Z ... mem_available_kib=8368128 swapin_bytes=175443968
    abort_utc=2026-09-20T17:44:54Z reason=swapin_rate_breached
    termination_utc=2026-09-20T17:44:56Z action=SIGKILL grace_milliseconds=2000

`monitor-qwen-runtime.sh` ends a server that reads more than 64 MiB of swap in
one sample while `mem_available` sits under its headroom, which defaults to
8 GiB. This host swaps to zram at priority 100, so a desktop page-in storm
reaches that rate while the server holds none of it, and `mem_available` sat
20 MiB under the headroom for the whole run. A replay of the same requests
through curl died the same way, which places the fault outside graft and
outside both checkpoints. The live telemetry has since been rewritten by later
launches; the transcript above is the reading taken at the time.

The rerun sets `QWEN_SWAPIN_HEADROOM_KIB=6291456`, which the guard's own knob
exists to carry, and leaves `minimum_mem_available_kib` at its 4 GiB reserve,
which terminates a server on its own. Under it a larger burst was recorded and
not acted on:

    swapin_report_utc=2026-09-20T17:58:40Z swapin_bytes=208924672 threshold_bytes=67108864 mem_available_kib=9572372 headroom_kib=6291456 action=observe

`admit-graft-deep.sh` now slices the guard's telemetry per arm and writes the
verdict `void` for any arm the guard ended, so a terminated server is never
read as a checkpoint that could not answer. The 2507's concept output is
identical across the two runs, 15 nodes and 25 links, which is what a
temperature of 0 should give and what says the rerun repeats the first.

## What this does not settle

The pilot ranks two checkpoints on one bounded tree of C under one client. It
says nothing about either checkpoint on another language, on a tree large
enough for the concept map to matter, or under a client that batches targets
differently. The concept-map split is one observation each way and rests on a
single synthesize call per arm.

Two defects it does name belong to the request rather than to either model.
The largest file in the set breaks the one-entry-per-id rule for both
checkpoints, so a target list that graft splits by count would test the models
rather than the cap. And graft's crux prompt loses two files for the 2507 that
the replica request recovers, so the prompt is worth a diff before the next
checkpoint is judged on it.
