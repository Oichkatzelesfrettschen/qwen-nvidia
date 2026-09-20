# Six contract questions: does the fast row say true things?

The broad screen ranked thirty-three rows by how fast they produce an
answer and said plainly that it measured nothing about whether the answer
is true. This is that measurement, on the six contracts
docs/research/invariant-map.md records for the DiscoBSD tree. Each
contract supplies one bounded source package, one question whose
discriminator the map already states, and three mechanical checks a reader
can rerun from the retained answers: whether the answer names the
enforcing symbol, whether it draws the entry's distinction, and whether
every identifier it names appears in the package it was given.

`scripts/admit-contract-questions.sh` ran the two screen finalists and the
incumbent on 2026-09-19 at a 1024-token cap, a 512-token thought budget and
a 16384-token allocation. `contracts.tsv` carries one row per answer and
the answers themselves are retained beside it.

## Result

| model | mechanical | after reading | s per answer |
| --- | ---: | ---: | ---: |
| qwen3-4b-instruct-2507 | 5/6 | 6/6 | 4.4 |
| qwen38-4b-distill (incumbent) | 4/6 | 4/6 | 5.2 |
| lfm25-350m-qad | 1/6 | 0/6 | 0.24 |

Two grader verdicts move on reading, in opposite directions, and both are
worth stating because they bound what the mechanical checks are worth.

The challenger's one mechanical failure is a false negative. Its SwapRAM
answer says the process "does not get a swapmap block" and that "swapin
still reads the clean text from the executable", naming
`exec_text_restore` and its arguments. That is both halves of entry 6,
correct. The check missed it because it looked for the token `swapram`
and the answer said "the RAM tier". A vocabulary check cannot grade a
paraphrase.

The 350M's one mechanical pass is a false positive, and it is the more
important one. Its signal-frame answer contains `xPSR`, `STKALIGN` and
`sendsig`, so every regex fired, and the sentences around them are false:
it attributes the STKALIGN clear to `sigreturn` rather than `sendsig`,
and describes it as "setting the sfp structure's ss_flags to
~XPSR_STKALIGN", which is neither the field nor the operation. Read that
way the 350M answers none of the six.

## What the 350M actually produced

Its answers are fast because it does not engage the package. Three of six
came back in under 120 ms.

- `flash_swap_append`: invents the checks. It reports tests on whether
  "the offset is not zero", whether the length is non-zero, and whether
  the offset falls "within the range of the spare sector". The function
  tests one thing, `offset & (FLASH_PROG_BYTES - 1)`, and the spare sector
  belongs to `flash_swap_rewrite`, a different function in the same file.
- heap refusal: answers with a numbered list of eight identifiers,
  `SWAPRAM`, `MAXMEM`, `ENOMEM`, `u.u_procp` and so on, and no sentence.
  The question asks how many conditions refuse and what each is.
- SwapRAM: invents a "freecore flag" the process "does not get" and says
  `odata` and `ostack` "would have been read from the pool".

None of those trips the invention check, because each is built from
identifiers the package does contain. That is the limit of the check and
the reason this note exists: an identifier test catches a fabricated name
and cannot catch a fabricated claim about a real one.

## What this decides

`qwen3-4b-instruct-2507` is the replacement candidate. It is faster than
the incumbent on the screen, 3.6 seconds per file against 4.1, and more
accurate here, six contracts against four. The incumbent's two failures
are its signal-frame answer, which never names `sendsig`, and its SwapRAM
answer, which draws the distinction without naming the tier's own
functions.

`lfm25-350m-qad` is not a summarizer for this tree at this request shape.
Its 7.13x execution advantage is real and measured; what it produces in
that time is not usable as graph input, and no amount of it would be.
The advantage is worth keeping in view for a different job: a bounded
extraction whose every claim is a span the caller can check, where being
wrong is detectable mechanically rather than by reading. That is a
different experiment from this one, and this note does not run it.

Nothing here promotes anything. Six questions on three rows is a screen
with a sample of six, and the next step for the challenger is the
`record_graph` and `record_symbols` schemas at small instances, which
these prose questions do not exercise.
