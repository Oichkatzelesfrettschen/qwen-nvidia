# Projector-to-language-model device embedding handoff

## Claim

A vision request's image embeddings pass from the projector's last graph
node to the language model's first as a device-resident handoff with one
batch-owned device copy, with the bytes the language model reads and the
tokens it produces identical to the host path's under the same request
history. The claim is stated for the copy it keeps: the host detour is
gone and one device-to-device copy into storage the mtmd batch owns
remains, so the mechanism is a device handoff rather than a zero-copy one.

## The four stages the ordinary path pays

At pin `f280b269` the projector output passes through four stages on the
way to the language model, one device-to-host copy, a host pointer
handoff, one host-to-host copy, and one host-to-device upload:

1. `clip_encode` (`tools/mtmd/clip.cpp`) reads the scheduler's output tensor
   into `params->out_embd` with `ggml_backend_tensor_get`, a device-to-host
   copy of `n_tokens * n_embd * 4` bytes.
2. `mtmd_batch_get_output_embd` hands a pointer into that host vector to
   `mtmd_helper_decode_image_chunk`, which places it in `llama_batch::embd`.
3. `llama_batch_allocr::ubatch_add` (`src/llama-batch.cpp`) copies the rows
   of each ubatch it splits off into `udata->embd`, host to host.
4. `llm_graph_input_embd::set_input` (`src/llama-graph.cpp`) writes those
   rows into the graph's `inp_embd` with `ggml_backend_tensor_set`. That
   input carries `GGML_TENSOR_FLAG_INPUT` and no buffer of its own, so
   `ggml_backend_sched_backend_id_from_cur` assigns it to the last backend
   and the scheduler stages it through a host buffer ahead of the first
   split, which is the host-to-device copy.

Image preprocessing on the host is untouched by this record: the pixels the
projector consumes are prepared the same way in every arm.

## The device path

`patches/llama-mtmd-device-embd.patch` is the candidate. Under
`LLAMA_MTMD_EMBD_DEVICE=1`, read once at `mtmd_context` construction:

- `mtmd_batch_encode` allocates one F32 tensor `[n_embd_out, n_tokens]` on
  the projector backend's default buffer type, owned by the batch and
  freed with it, and encodes into it through
  `clip_image_batch_encode_device`. `clip_encode` copies the scheduler's
  output into that tensor with `ggml_backend_tensor_copy` through a
  shape-matched alias, which on one CUDA device is a device-to-device
  copy; the host vector stays empty.
- `mtmd_batch_get_output_embd_device` names a chunk's rows as the tensor
  and a row offset, and `mtmd_helper_decode_image_chunk_device` builds a
  `llama_batch` with `embd_dev` and `embd_dev_offset` set and `embd` null.
  `llama_batch` gains those two trailing fields; every brace initializer
  in the tree names them.
- `llama_batch_allocr::ubatch_add` requires a device batch's ubatch to be
  one contiguous row range and records the tensor and the offset on the
  `llama_ubatch`; the host copy of step 3 has nothing to copy.
- `build_inp_embd` makes `inp_embd` a `ggml_view_2d` of the batch's rows
  when the ubatch carries a device tensor. The view's source holds a
  buffer, so the scheduler assigns it to that buffer's backend and the
  language model's first node reads the projector's bytes in place;
  `set_input` uploads nothing on that path. `can_reuse` compares the
  source tensor and offset, since the graph bakes both in.
- `LLAMA_CONTEXT_TYPE_MTP` refuses a device batch, because the MTP draft
  reads hidden states through the host `embd` path; the arm runs with
  speculation off.

`LLAMA_EMBD_HANDOFF_TRACE=1` is the recorder. `clip_embd_handoff` names
where the projector output landed (`dst=host|device`, the backend the
scheduler computed it on, the destination buffer) and its FNV-1a 64
digest; `embd_handoff` names the source of each ubatch's embedding input
(`host|device`), the buffer the graph reads it from, and the digest of the
bytes it holds. The device path reads its view back for the digest alone,
and every read-back is absent when the variable is unset.

## Preregistration

`scripts/admit-embd-handoff.sh` runs three arms against one closure: host,
device, host-close, each the same request sequence of three fixture images
twice over, greedy, cache off, 48 reply tokens, through `/completion` with
`multimodal_data`. The first arm is `qwen35-2b` with its projector; the
second is `lfm25-vl-450m`. Written ahead of the first run:

| check | holds when | refutes the claim when |
| --- | --- | --- |
| reply identity | every request's token ids equal across host, device, and host-close | any request differs between device and either host arm while the two host arms agree |
| graph digests | the per-ubatch `embd_handoff` digest sequence of the device arm equals the host arm's, row for row | any digest differs, or the row counts differ |
| projector digests | the `clip_embd_handoff` digest sequence equals across arms | any digest differs |
| placement | every device-arm graph row reads `source=device` on a CUDA0 buffer and every clip row reads `dst=device` from `src_backend=CUDA0` into a CUDA0 buffer | a host buffer or a host source on any row, which makes the copy a staging copy rather than a handoff |
| projector-to-graph agreement | where a chunk decodes in one ubatch, its clip digest equals its graph digest | the two differ, which says the graph read bytes other than the ones the projector wrote |
| closing arm | host-close agrees with host on every check | the two host arms differ, which puts the sequence rather than the mechanism under the device arm's result |

A digest difference between host and device with identical replies is
still a refutation: the claim is byte identity, and a language model that
tolerates a perturbation does not make the bytes equal. Prefill time per
request is recorded beside each reply as an observation and gates
nothing; the arm's purpose is identity, and a latency claim needs a
paired campaign of its own.

The fixtures come from `scripts/quality-images/`, drawn by
`scripts/generate-quality-images.py` from declarations in its source.

## Run 01: refused, and what the refusal read

`qwen35-2b-run-01/` and `lfm25-vl-450m-run-01/` ran the first form of the
patch on closure `747c1c92585b`. Both host arms agree with each other on
every check, and the host trace reads the staging the ordinary path pays:
every `clip_embd_handoff` row names `src_backend=CUDA0`, every host
`embd_handoff` row names `buffer=CUDA_Host`, the pinned host buffer the
scheduler stages graph inputs through, and each clip digest equals the
graph digest that follows it, 6 of 6 rows on each row's model. The device
arm refused on three checks at once: its six graph rows read
`source=device` on `buffer=CUDA0`, so the view reached the graph, but the
trace holds no `clip_embd_handoff` row, the graph digests differ from the
host's, and every reply differs. The cause is one guard in `clip_encode`:
the output node was fetched only where a host vector was requested, so
the device destination was never written and the language model read an
unwritten tensor. That is the failure the digest gate exists to name
ahead of the reply gate, and the run stays in the record as the negative
the second form is read against. The `prompt_ms` figures of run 01's
device arm are figures for a projector whose output was discarded and
state nothing about the handoff.

## Run 02: admitted on both rows

`qwen35-2b-run-02/` and `lfm25-vl-450m-run-02/` run the second form of
the patch, with the output-node guard corrected, on closure
`53e3d7d1a653`, the pinned tree with the four candidate patches and this
one at `89-real`. Every check holds on both rows.

| check | qwen35-2b | lfm25-vl-450m |
| --- | --- | --- |
| reply identity, host = device = host-close | 6 of 6 requests | 6 of 6 requests |
| projector digests across arms | 6 of 6 rows | 6 of 6 rows |
| graph digests across arms | 6 of 6 rows | 6 of 6 rows |
| device-arm placement | every graph row `source=device buffer=CUDA0`; every clip row `dst=device src_backend=CUDA0 dst_buffer=CUDA0` | the same |
| projector-to-graph agreement | 6 of 6 rows in every arm | 6 of 6 rows in every arm |
| closing arm | agrees with host on every check | the same |

The device arm's digests equal the host arm's digest for digest: the
88-token `bars.png` chunk reads `06ec71a5a4d38382` from the projector and
from the graph input in all three arms of the 2B, and the same holds for
the other two fixtures and for the 450M's three. Each fixture encodes to
one chunk of 45 to 88 tokens on these projectors, under the 512-token
ubatch, so every chunk decodes in one ubatch and the projector-to-graph
comparison covers every row. The host arms read `buffer=CUDA_Host` on
each graph row and the device arm reads `buffer=CUDA0`, which is the
staging copy the view removes.

The bytes moved per image are 315 to 721 KiB, so the round trip they
paid was tens of microseconds of PCIe time inside a prefill of 17 to 150
ms, and the per-request `prompt_ms` beside each reply moves by less than
the spread between the two host arms; no latency claim is made and none
was preregistered. What the run establishes is the handoff itself: the
projector's output tensor is the language model's input tensor, byte for
byte, with the host out of the path. The decode-side handoff and a
multi-chunk request whose chunk exceeds the ubatch, which would split the
view across ubatches at a nonzero offset, stay outside this record.

## Review, and run 03 on the committed form

A read-only review pass over the second form returned one high and four
medium findings, each closed in the committed form and none moving a
measured byte:

- graph reuse compared the tensor pointer and the row offset while the
  cached view held the storage address, so a tensor freed and reallocated
  at the same metadata address with other storage would have reused the
  graph over the old allocation; `can_reuse` now compares the tensor, its
  `data`, its buffer, and the offset, and `set_input` asserts the same
  four;
- a device batch whose rows a sequence-based split selected out of order
  aborted in `ubatch_add`; the split now logs the two rows and returns an
  empty ubatch, which `llama_decode` reports as a refused batch, and the
  `llama_batch` contract states that a device batch carries one sequence
  in row order;
- the DFlash, GLM4, and DeepSeek-V4 cache sites had been switched to the
  shared `has_embd()` predicate while building their own host input; they
  read `embd` alone again, and the contract says models with their own
  embedding input read the host field;
- three `llama_batch` brace initializers in `examples/parallel`,
  `tools/perplexity`, and `tools/batched-bench` name the new fields, so a
  warning-fatal build of those tools passes;
- a projector on a host backend would have labeled host memory `device`;
  `mtmd_batch_encode` now refuses the device path unless the projector's
  buffer type belongs to a GPU device, and `clip_encode` refuses a source
  or destination in a host buffer ahead of the copy, so `dst=device`
  states device memory at both ends. The copy itself goes through the
  destination buffer's own copy, a device-to-device memcpy on one CUDA
  device, and the trace names both buffers.

`qwen35-2b-run-03/` and `lfm25-vl-450m-run-03/` run that form on closure
`b4ea7cc19274`. Every check holds on both rows, and every digest equals
its run 02 value: the six device-arm digests of each row read the same
sixteen hex characters across the two closures and across the three arms,
so the bytes are a property of the projector and the fixture rather than
of the closure or the path. The table under run 02 is the table of run 03.
The 2B's first request in each arm pays the projector's first-use cost,
122 to 314 ms across the six arms of the two runs, against 32 to 34 ms for
the two that follow; the 450M reads 68 to 97 ms and 13 to 24 ms; neither
spread separates the device arm from the host arms.

The handoff is admitted on `qwen35-2b` and `lfm25-vl-450m` as a candidate
under `LLAMA_MTMD_EMBD_DEVICE=1`, off by default, and the served path
leaves it off until a served vision tuple is measured under it.

## Run 04: completeness on the committed form

Runs 02 and 03 covered chunks of 45 to 88 tokens, each inside one ubatch
and one `llama_decode`, and left the row-offset paths, the batch lifetime,
and the transfer question open. Run 04 closes them on closure
`228f5a79ba2c`, the pinned tree with the four candidate patches and the
revised handoff patch at `89-real`, server
`c453ba34641a14640f60b8bfea0b7d8fa4de1d1bc1bb329fde068c1359376214`, with
`qwen35-2b-run-04/` and `lfm25-vl-450m-run-04/` both admitted at zero
refused checks.

The patch gains three things ahead of the run. The recorder names every
encoded batch, its tensor, and each chunk's row range, digests every
projector output row, and per ubatch records the batch rows selected and a
`rowchain`, the FNV-1a 64 chain over the per-row digests of exactly the
bytes the graph read, so `read-embd-handoff-trace.py` joins each consumed
slice to its source rows and holds coverage, order, and the chain per
chunk; the join is what lets a slice at a nonzero offset be compared
against the rows it claims rather than against a whole-tensor digest.
`mtmd_helper_decode_image_chunk_device` calls `llama_synchronize` before
it returns, because `llama_decode` returns with its graph still queued
(`graph_compute` is the asynchronous form and the context synchronizes
under pipeline parallelism alone), so a batch freed at slot release could
otherwise be read after free by a graph the decode had queued; producer
completion was already explicit, `clip_encode` computing synchronously and
the CUDA buffer copy synchronizing its stream. And the trace lines are
paired as the allocator issues them: every ubatch of a decode is split
ahead of the first graph, so the reader queues the ubatch lines and each
graph input takes the oldest.

### Request shapes and the encoder's own token counts

The sequence is five shapes, twice per identity arm: one image; two
same-shape images adjacent; two images separated by text; one large image;
two large images separated by text. `scripts/handoff-images/` carries the
large fixtures, the graded `bars` and `shapes` drawings at three times
their size. The projector's token counts per fixture are read from the
trace rather than inferred:

| fixture | qwen35-2b tokens | lfm25-vl-450m tokens |
| --- | ---: | ---: |
| bars.png | 88 | 88 |
| shapes.png | 60 | 77 |
| compare-a.png, compare-b.png | 45 each | 77 each |
| bars-large.png | 816, one chunk | 234 and 256, two tiles |
| shapes-large.png | 570, one chunk | 240 and 256, two tiles |

The 2B's projector encodes a large image as one chunk past the 512-token
ubatch, and the 450M's cuts it into tiles it emits as separate chunks with
text between them. Neither projector's graph builder declares batch
support at this pin, so `mtmd_batch_add_chunk` admits one chunk per media
batch on both rows and the several-chunks-in-one-batch path, with its
nonzero row offset inside the batch tensor, stays at zero on these rows;
the reader's own test exercises that join on a synthetic two-entry batch.
The five other conditions are required of the campaign as a whole and
the comparison refuses where a geometry pair leaves one unreached; this
one is reported per geometry and required only where a caller lists it,
so the record names it as unreached rather than passed.

### Identity at two geometries

| stage and geometry | qwen35-2b | lfm25-vl-450m |
| --- | --- | --- |
| registry, batch 2048 and ubatch 512 | 16 chunks, 22 slices, 6 chunks split across ubatches, 6 slices at a nonzero offset | 52 chunks, 52 slices, none split |
| split, batch 64 and ubatch 32 | 16 chunks, 164 slices, every chunk split across ubatches and 10 across `llama_decode` calls, 148 slices at a nonzero offset | 52 chunks, 366 slices, every chunk split across both, 314 at a nonzero offset |

On every arm of every geometry the reader's verdict holds: every chunk's
rows are consumed exactly once in order, every slice's rowchain equals
the chain over the projector's rows it names, every ubatch is a contiguous
row range, and every device-arm view offset equals the joined tensor row.
Across host, device, and host-close the ten replies are identical token
for token, every slice's byte digest is identical at its joined position,
and every chunk's per-row projector digests are identical. The final
partial ubatch is exercised in every arm, 304 rows of the 2B's 816-token
chunk at the registry geometry and the tails of every chunk at the split
one. Prefill time per request is an observation: the 2B's 842-token large
request reads 169 to 177 ms across the six registry-geometry requests,
the device arm's 169 and 171 inside the host arms' 169 to 176, and 261 to
273 ms at the split geometry, where the device arm's 269 and 273 sit at
and 4 ms above the host arms' 261 to 268; a latency claim needs a paired
campaign and none is made.

### Lifetime

The identity device arms allocate one batch tensor per request and the
driver hands consecutive allocations the same storage: 16 batches at 2
addresses on the 2B and 52 at 2 on the 450M, so 14 and 50 consecutive
batches respectively landed at an address the previous batch had used,
which is the reuse the graph-reuse guard compares tensor, storage,
buffer, and offset against, and every one of those requests read the
right bytes.

The lifetime stage abandons a large-image request at 0.02, 0.1, and 0.6
seconds after sending, each with `ignore_eos` and a 2048-token budget,
and follows each with an ordinary request. The server reads the
connection per generated token and never inside prompt processing, so
each disconnect took effect in generation: the 2B released the three
slots at 1026 to 1027 tokens of a 842-token prompt and the 450M at 2485
to 2582 tokens of 1805, in both arms, with the slot's media batch freed at
that release. Every following request completed, the server answered
`/health` after each, and the six completed requests of the device arm
match the host arm on replies, slice digests, and projector rows. A
cancellation between split ubatches is therefore unreachable through the
served path, since the server holds the connection unread until the first
generated token; what the stage establishes is that a batch freed after
its decode, at any later point, leaves no consumer in flight, which the
synchronize in the device helper is what guarantees.

### Transfer, recorder off

The transfer stage runs the five shapes once per arm at the registry
geometry with `LLAMA_EMBD_HANDOFF_TRACE` unset, under `nsys launch` with
the capture started after the load, and `read-nsys-embd-transfers.py`
lists every copy against the embedding sizes the identity stage recorded:
every ubatch slice and every batch's whole output.

| arm | qwen35-2b | lfm25-vl-450m |
| --- | --- | --- |
| host | 8 device-to-host reads, one per batch, after `k_bin_bcast` or `rms_norm_f32`; 11 host-to-device uploads, one per ubatch, ahead of `rms_norm_f32` | 26 reads, one per batch; 27 uploads ahead of `k_get_rows_float` against 26 slices |
| device | 8 device-to-device copies, one per batch; zero embedding-sized copies in either host direction | 26 device-to-device copies; zero reads; one 1048576-byte pinned-to-device upload ahead of `k_get_rows_float` |

The 450M's extra upload appears once in each arm at the language model's
first kernel, in the host arm as one more sized upload than the sequence
has slices, so it is a scheduler-staged graph input whose byte count
coincides with a 256-row chunk of the 1024-wide embedding rather than an
embedding. The gate takes the host arm's sized copies beyond one upload
per slice and one read per batch as a multiset of byte counts, exempts a
device-arm host copy only where it takes one of those byte counts out of
that multiset, classes any copy of a whole number of rows beside the
exact sizes, and requires the device-to-device count to equal the batch
count; the record lists every host-direction copy with its neighbors. The replies with the recorder off
agree between host and device on all five requests of both rows. The
device path's whole traffic for the handoff is one device-to-device copy
per batch, and the host path's staging reads and uploads are absent.

### What run 04 leaves open

The handoff is admitted as a candidate on `qwen35-2b` and
`lfm25-vl-450m` under `LLAMA_MTMD_EMBD_DEVICE=1`, default-off. A
projector that batches several chunks into one tensor would exercise the
in-batch row offset the reader joins but neither served row reaches. The
MTP context still refuses a device batch. Device-resident media decode and
preprocessing, the stages ahead of the projector, are a separate
transition with their own codec placement and preprocessing contract.
