# Static admission: what a candidate declares before it is fetched

A GGUF places its metadata block and tensor index at the head of the file, so
an HTTP range request over the first bytes answers what architecture a
candidate declares, what chat template it carries, what vocabulary it tokenizes
with, and what an ordinary load streams, while the weights stay on the server.
`remote/admit-candidate-static.py` reads fourteen candidates that way in 32
seconds of wall time and 16 MiB per row, against roughly one gigabyte per row
for a load admission. That ratio is what lets the funnel cut the set before any
device time is spent, and it is why this stage runs first.

## Terms

```text
parser:      remote/gguf-tensor-census.py, imported rather than reimplemented
transport:   HTTP range request, Hugging Face resolve endpoint, pinned revision
window:      16 MiB, grown to 64 and 256 on a short read
artifact:    one file per repository, chosen by the Q4_K_M preference rule
device:      none
```

## The control that makes a ranged read equal a local one

The parser reads a buffer, and a buffer that stops inside the metadata block
would report the trailing keys absent rather than failing. That absence would
enter the ledger as a finding. Two checks separate the cases.

`remote/test-admit-candidate-static.py` truncates a hand-built header at every
seventh byte from the magic to the end and requires `GgufReadError` at each cut,
so no partial parse returns a dictionary. The reader then grows its window and
reports `short-read` only when the largest window still fails.

The bound holds only if the server honours the range. HTTP permits a server that
does not implement ranges to answer 200 with the whole representation, and the
resolve URL redirects to a CDN, so the hop that decides is the last one. The
body goes to a file rather than a pipe, `--max-filesize` refuses a declared
length over the window before any body transfers, and a response is admitted on
three facts: a zero curl status, and either 206 with a `Content-Range` that
starts at zero and ends inside the window, or 200 whose transferred size fits
the window, which means the whole object fits. `validate_range_response` is a
pure function of those facts and eleven cases exercise it, including the 200
that ignored the range and the 206 that named no range at all.

The end-to-end control is the appliance's own copy of the served 2B distill.
Its full local census and this ranged read agree on every identity field:

| field | local full census | ranged read |
| --- | --- | --- |
| chat_template_sha256 | 273d8e0e...1822d80 | 273d8e0e...1822d80 |
| chat_template_bytes | 7755 | 7755 |
| tokens_sha256 | 5cf6b9d7...c99d2af9 | 5cf6b9d7...c99d2af9 |
| vocabulary_size | 248320 | 248320 |
| tokenizer pre | qwen35 | qwen35 |
| prediction-block bytes | 37767168 | 37767168 |

The prediction-block figure is the one `CLAUDE.md` already records from the
census, so the ranged read reproduces a number this tree measured
independently. The 2B distill's header ends at 10,962,034 bytes, which is why
the first window is 16 MiB: a Qwen3.5 metadata block carries 248,320 tokens and
their merges, and a one-megabyte window falls short on every one of them.

## Fourteen artifacts, four runtime classes

Throughput belongs to an architecture and a value format. Grouping the rows by
architecture, embedding width, feed-forward width, and head counts -- leaving
out block count, which differs only by the appended prediction block an ordinary
load skips -- collapses fourteen candidates into four classes.

| class | rows | streamed MiB | reference at that format |
| --- | ---: | ---: | --- |
| qwen35 / 2048 / 6144 / 8 / 2 | 8 | 1201 to 1211 | Qwen3.8-2B Distill Q4_K_M, 9.19 tok/s |
| qwen35 / 1024 / 3584 / 8 / 2 | 3 | 493 to 522 | none at Q4_K_M |
| qwen3 / 1024 / 3072 / 16 / 8 | 2 | 455 | none |
| qwen2vl / 1536 / 8960 / 12 / 2 | 1 | 935 | none |

The eight rows of the largest class span 0.83% in streamed bytes. This machine
carries about 4% of uncontrolled spread on a repeated depth-0 rate and 30.6%
between sweeps under desktop load, so a throughput arm run inside that class
measures queue position rather than the checkpoint. One reference arm per class
is what the numbers support.

One class holds a reference and three do not. `remote/models.tsv` serves the
0.8B at Q8_0 and F16 alone, and the Q8_0 streams 764 MiB per token against the
493 to 522 MiB its Q4_K_M class members stream, which is 46 to 55% more. A
throughput class is an architecture and a value format together, so the served
0.8B references its own format rather than this class, and reading a Q4_K_M
candidate against it would report the format. The throughput stage therefore
needs three arms rather than fourteen: `qwen3` at 42 blocks, `qwen2vl`, and a
0.8B Q4_K_M reference for a class whose three members have no measured rate at
the format they publish.

Those three representative arms ran beside three anchors in one sweep and
`evidence/model-admission/runtime-class-throughput.md` carries them. The sweep
measures the selected checkpoints; it does not validate substitution of every
member inside a structural class. The three measured 0.8B checkpoints decode
within 5.2% across 67.9% of byte spread, so the selected Q4_K_M rung supplies no
resolved speed advantage over the served Q8_0. Other class members still need
their own arm before the same throughput claim transfers to them.

## Six chat templates over fourteen artifacts

| template | bytes | rows |
| --- | ---: | --- |
| 273d8e0e | 7755 | 2B distill, 2B uncensored, hauhau, unredacted, unredacted-i1, heretic, 0.8B bartowski |
| 7f0e5290 | 7816 | unsloth 2B, unsloth 0.8B uncensored |
| ea210e5b | 7991 | Qwenseer-2B |
| 8428c815 | 4761 | Qwen3-Zero-Coder |
| 87a2728c | 4116 | Qwen3-Zero-Coder V2 |
| a0bc6f6f | 1017 | Qwen2-VL-2B Platinum |
| 0800c03b | 4047 | Qwen3.5-0.8B Opus Reasoning Distilled |

Seven rows carry the stock Qwen3.5 template byte for byte, including the
checkpoint the appliance serves, so their graded results are comparable with the
retained roster sweep without a template variable. Unsloth substitutes one
template across two model sizes, which is a converter property rather than a
model property.

## Two templates break the appliance's serving assumptions

The appliance turns reasoning off through
`chat_template_kwargs.enable_thinking`, and the graded tool rows put a schema in
the request body's `tools` field. A template that never names those keys answers
the same way whatever the request sets, so the reader flags both.

`Qwen3.5-0.8B-Opus-Reasoning-Distilled` names `<think>` and `tools` and never
names `enable_thinking`. Its generation prompt ends
`{{- '<|im_start|>assistant\n<think>\n' }}` under `add_generation_prompt` alone,
so the assistant turn opens a thinking block unconditionally and the appliance's
thinking-off request is inert against it. The consequence is measurable rather
than theoretical: the base 4B's single failure in the retained roster sweep was
an empty answer after 2048 predicted tokens of reasoning, which is the
termination failure thinking off removes. A row that cannot be told to stop
reasoning meets that failure at the suite's 1024-token budget, and grading it
beside a thinking-off row would measure the template.

`Qwen2-VL-2B-Instruct-Platinum` names none of `enable_thinking`, `<think>`,
`tools`, or `tool_calls` in 1017 bytes. It is gradeable on the vision and text
categories and holds no path the tool rows can exercise, so a zero there would
report an absent template branch rather than a selection failure.

Neither finding rejects a row. Each names the arm the row must run under, and
each cost no device time.

## The plain and i1 conversions of one fine-tune agree

`mradermacher/Qwen3.5-2B-Unredacted-MAX-GGUF` and its `-i1-GGUF` twin publish
one fine-tune through two conversion pipelines. Their Q4_K_M rungs agree on
architecture fingerprint, chat template hash, vocabulary hash, and streamed
bytes to the byte. A disagreement would have been a finding about a converter;
the agreement means the i1 repository's Q4_K_M rung is the plain rung, and
reading it exercises the same K-quant kernels.

The reconstruction kernels this tree leaves unmeasured live in the IQ rungs of
that repository rather than in its Q4_K_M:

| rung | streamed MiB | against Q4_K_M |
| --- | ---: | ---: |
| i1-Q4_K_M | 1201 | -- |
| i1-IQ4_XS | 1096 | -8.7% |
| i1-IQ3_S | 963 | -19.8% |

Those two rows are read outside the ledger sweep, which fingerprints the
Q4_K_M rung of each repository, so they reproduce through the file selector
rather than through the retained record:

```sh
remote/admit-candidate-static.py \
    mradermacher/Qwen3.5-2B-Unredacted-MAX-i1-GGUF \
    51de0e7834d565a91713afd4a9c73cdc57a76218 \
    --file Qwen3.5-2B-Unredacted-MAX.i1-IQ4_XS.gguf
```

Those two rungs are the throughput arm the reconstruction question needs. The
tree has closed the low-bit K-quant route: Q2_K streams 29.4% fewer bytes than
Q4_K_M and decodes no faster. IQ4_XS at -8.7% is the narrower and cleaner
probe, since a purely bandwidth-bound decode predicts a gain near that figure
and a reconstruction cost above K-quant unpacking predicts a loss.

## What this stage does not measure

A header states what a file declares. It does not state that the file loads,
that the device holds it, that the kernels it names exist in this build, or that
the weights answer anything. Every row here remains unloaded, and a
`static-admitted` stage in the ledger claims the architecture and the template
and nothing beyond them.

Three ledger rows publish safetensors alone and keep `-` in both columns, since
there is no GGUF header to read: `qwen35-2b-glm-deepseek`,
`qwen35-08b-abliterated`, and `qwen35-08b-base`. Their admission waits on a
conversion, which is a scheduling fact rather than a rejection.

The selection rule reads one file per repository and the record names it, which
matters where a repository publishes many: the two Qwen3-Zero-Coder rows hold 78
and 81 GGUF files and the fingerprints above speak for their Q4_K_M rungs alone.

A split GGUF carries one tensor index per shard, so a header read of the first
shard describes that shard rather than the checkpoint. The record therefore sums
`artifact_bytes` across the set, which the tree reports for free, and writes `-`
for the tensor byte fields, since an understated figure would place the row in
the wrong throughput class. Every row of this sweep reads `split_shards=1`, so
no figure above rests on that path.

Records are retained as `evidence/model-admission/static-admission.tsv`.

## A published artifact whose header is a hole

`DavidAU/Qwen3.5-9B-The-Defiant-Fable-Uncensored-Heretic-NEO-IMATRIX-MAX-MTP-GGUF`
publishes two IQ2_M artifacts of one fine-tune, one naming the multi-token
prediction block and one not. The MTP artifact does not parse:

```text
file does not begin with the GGUF magic: b'\x00\x00\x00\x00'
```

Sampling the object over ranges places the boundary. Every probe from offset 0
through 10,953,381 returns zeros, and every probe from 11,001,697 onward returns
tensor data, so the leading 10.5 MiB of a 4,942,442,720-byte file is a hole. A
Qwen3.5 metadata block runs to about that size, because it carries 248,320
tokens and their merges: the 2B distill's header ends at 10,962,034 bytes. The
magic, the metadata, and the tensor index are therefore absent while the tensor
payload beyond them is intact.

Three controls separate the object from the transport. The non-MTP sibling in
the same repository at the same revision returns `GGUF` at offset 0, as does the
repository's `mmproj-F16.gguf`, and both this repository and the
`empero-ai/Qwen3.8-9B-Distill-GGUF` control resolve through the same Xet bridge.
The defect is the artifact.

The two files differ by 960 bytes against a 4.9 GB payload, where a ninth-block
prediction head at IQ2_M on a 4096-wide model would add over a hundred
megabytes. The MTP artifact is therefore a header-level variation of the same
tensor data rather than a different quantisation, which is consistent with a
rewrite that produced the hole in the only region the two files do not share.

The weights stay admissible: `qwen35-9b-defiant-fable` reads the intact sibling
at 32 blocks with `nextn_predict_layers` absent, an embedding width of 4096 and
a feed-forward width of 12288, which is a fourth runtime class in the ledger. The
MTP capability is unavailable from this publisher until the artifact is
reuploaded, and `qwen35-9b-defiant-fable-mtp` carries `artifact-defective` rather
than a rejection of the model.

Static admission cost 16 MiB and no device time to establish this. A fetch would
have moved 4.9 GB before the loader refused it.
