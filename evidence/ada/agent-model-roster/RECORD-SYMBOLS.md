# graft's own record_symbols contract, which the fast row cannot satisfy

The broad screen's tool column records whether a row completes a forced
`record_probe` call whose only argument is a boolean. graft's symbol pass
sends something else: the file under 1-based line numbers, a list of target
definitions by id with their line ranges, a forced call to `record_symbols`,
and a requirement of exactly one entry per target id, that id verbatim, a
one-sentence summary, and a crux span inside the symbol's own range or the
literal 0/0 that means it has none.

`scripts/admit-record-symbols.sh` builds that request the way
`dist/ai/crux.js` builds it, takes its target ids from `graft skeleton` so
they are the ids the graph uses, and checks the answer against the request:
a returned id the file never listed is an invention, an absent id is a
dropped target, and a crux outside the symbol's range points at code its
summary does not describe. Three files, three rows, on 2026-09-19.

| model | files called | ids exact | ids missing | ids invented | crux out of range | s per file |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| qwen38-4b-distill | 3/3 | 7/7 | 0 | 0 | 0 | 3.4 |
| qwen3-4b-instruct-2507 | 3/3 | 7/7 | 0 | 0 | 1 | 2.0 |
| lfm25-350m-qad | 0/3 | 0/7 | 7 | 0 | 0 | 0.24 |

## The fast row does not call the tool

`lfm25-350m-qad` returns `tool_calls: null` on every file and finishes with
`stop`. What it puts in `content` instead is a fenced JSON block keyed
`targets` rather than `symbols`, and the entries inside it are wrong: it
gives `flash_swap_append` the summary "Rewrite an arbitrary
program-page-aligned range through a spare sector", which is the comment
standing above `flash_swap_rewrite`, the other function in the file, and
then repeats that same sentence for `flash_swap_rewrite` itself. Both
cruxes are 1/1, outside either symbol.

That row's `tool_call=yes` in the broad screen is therefore not evidence
it can drive the symbol pass. A boolean argument under a forced call
exercises neither the wrapper key, nor an array of entries, nor an id
copied verbatim, nor a line number that has to land inside a range. The
screen's column should be read as what it is: the row emitted something
containing a completed `record_probe`, and nothing more.

## The one defect in the challenger is graft's, not the model's

`qwen3-4b-instruct-2507` returns every id exactly once with no invention on
all three files. Its single out-of-range crux is `brk` in kern_mman.c,
where it answered 16 to 20 against a target range of L16 to L16. The
function's body runs to line 60; `graft skeleton` reports its range as one
line, because the extraction reads the K&R definition `brk()` on line 16
and not the block beneath it. The model pointed at the argument fetch and
the size computation, which is the right span; the range it was checked
against is wrong. The C tier's caller drop is already recorded in the
DiscoBSD invariant map, and this is the same extraction being imprecise in
a second way.

## Where this leaves the three rows

Taken with CONTRACT-QUESTIONS.md, which asked the same rows the six
semantic questions of the invariant map:

| model | record_symbols | six contracts | screen s/file |
| --- | ---: | ---: | ---: |
| qwen3-4b-instruct-2507 | 3/3 called, 2/3 clean | 6/6 | 3.6 |
| qwen38-4b-distill | 3/3 called, 3/3 clean | 4/6 | 4.1 |
| lfm25-350m-qad | 0/3 called | 0/6 | 0.6 |

The incumbent is the more reliable recorder and the challenger is the more
accurate reader, and the difference between them on either axis is one
case out of three or two out of six. Neither gap is a sample that settles
anything; both are small enough that the next step is more files rather
than a promotion.

The Liquid row fails both gates. Its 7.13x execution advantage is real and
was never the question: a row that cannot emit the call graft's symbol
pass requires produces no graph input at any speed. Whether a narrower
request with a smaller schema could reach it is a separate experiment,
and the evidence here is that the one that already exists does not.
