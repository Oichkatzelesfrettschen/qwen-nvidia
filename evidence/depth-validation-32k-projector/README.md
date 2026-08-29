# Filled depth to 32768 with the projector loaded

`evidence/depth-validation-32k/` fills and decodes 8192, 16384, and 32768 on
five checkpoints through `llama-bench -d`, which takes no `--mmproj` and
allocates no projector buffers. Every arm it records reads
`projector_state=none`, so the two vision rows that require a projector in
serving, `qwen35-2b` and `lfm25-vl-16b`, kept `validated_filled_depth` at `-`
and `context_ceiling` at 8192 however many text-only arms accumulated there,
and `qwen35-4b-base` carried no depth arm at all.
`remote/probe-depth-projector.sh` measures the tuple those rows need: one
llama-server instance, standalone, at the row's own cache triple and
submission geometry, with the row's own projector attached through
`--mmproj`, filled by one chat completion carrying a fixture image plus text
padding and answered by one recovery question afterward.

## Falsifier registered before the arms ran

A vision row cannot claim a numeric `validated_filled_depth` from an arm that
did not load its projector. The prediction under test was that the served
128/32 geometry fills and decodes to 32768 with the projector resident and
that the projector still writes usable image tokens into the language model's
embedding space after the deep fill; a wedge, a reset, a fault, a fill outside
the acceptance window, or a control answer missing "JUN" at any depth would
have stopped the chain at the deepest arm that passed and left the row's
ceiling there. `probe-depth-projector.sh` enforces this: `device_corrupt` is
set on the first failed arm, and the loop over depths stops rather than
measuring a corrupted device at a greater depth.

## Terms

```text
runner:      remote/probe-depth-projector.sh
tuple:       q8_0 K, q4_0 V, Flash Attention on, batch 128, ubatch 32
threads:     1, threads-batch 1 (the served tuple's own submission thread
             count, distinct from the threads 2 the llama-bench text-only
             arms in evidence/depth-validation-32k/ recorded)
kernel:      7.0.0-29-generic
device:      RADV RAVEN2, whole device, standalone llama-server per arm
control:     bars.png, "Which bar is tallest in this chart? Reply with its
             label alone.", declared answer JUN
window:      DEPTH - 2% <= prompt_n <= DEPTH - decode_tokens (32)
health:      status ok, control_status ok, ring resets 0, GPU faults 0
```

Each arm's `prompt_n` is the server's own `timings.prompt_n` after the fill
request: the image contributes a token lump `/tokenize` cannot see, since that
route tokenizes text alone and the projector writes image tokens inside the
chat pipeline, so the harness measures the template-plus-image overhead with
one probe request and closes the remainder with text padding measured through
`/tokenize`.

## Results

`prompt_n`, `prefill_s`, and `decode tok/s` are `timings.prompt_n`,
`prompt_ms / 1000`, and `predicted_per_second` from the fill request's own
`/v1/chat/completions` response. These are standalone-server fills with one
image in the prompt at `--parallel 1`, not `llama-bench` rates: no repetition
count, no isolated prefill/decode phase split, and the image token cost is
inside `prompt_n` rather than reported separately.

| checkpoint | depth | prompt_n | prefill s | decode tok/s | control | resets | faults | health |
| --- | ---: | ---: | ---: | ---: | --- | ---: | ---: | --- |
| Qwen3.5-2B Q4_K_M | 8192 | 8041 | 219.165 | 6.386 | ok | 0 | 0 | healthy |
| | 16384 | 16231 | 568.193 | 6.391 | ok | 0 | 0 | healthy |
| | 32768 | 32632 | 1454.187 | 3.902 | ok | 0 | 0 | healthy |
| LFM2.5-VL-1.6B Q4_K_M | 8192 | 8042 | 199.712 | 10.158 | ok | 0 | 0 | healthy |
| | 16384 | 16248 | 504.125 | 8.353 | ok | 0 | 0 | healthy |
| | 32768 | 32616 | 1410.909 | 6.857 | ok | 0 | 0 | healthy |
| Qwen3.5-4B base Q4_K_M | 8192 | 8041 | 693.049 | 2.698 | ok | 0 | 0 | healthy |
| | 16384 | 16231 | 1241.084 | 2.318 | ok | 0 | 0 | healthy |
| | 32768 | 32632 | 3375.497 | 1.816 | ok | 0 | 0 | healthy |

Every arm's `prompt_n` sits inside its acceptance window and every control
answers JUN. Every `.dmesg-method.txt` reads `follow`, so each `.dmesg.txt`
window is captured live rather than by an offset subtraction. Eight of the
nine windows are empty; the ninth, `qwen35-4b-base` at 32768, carries two
userif link-flap pairs and two `dm_irq_work_func` workqueue-latency warnings,
none of which the reset or fault patterns match, so the arm's own summary row
reads `ring_resets=0 gpu_faults=0` and the ledger's `classify_hazard` names it
`none`. The chain never halted, so no depth was left unmeasured behind a
failed arm.

## What the rows establish

A context of 32768 tokens allocates, fills, and decodes with the projector
resident on all three checkpoints that require one in serving, at the served
cache triple and submission geometry, on one device, in one session per
checkpoint, with the device answering its own recovery question afterward.
`remote/models.tsv` now reads `validated_filled_depth=32768` for `qwen35-2b`,
`lfm25-vl-16b`, and `qwen35-4b-base`, each pointing `validation_evidence` at
its subdirectory here. `context_ceiling` moves from 8192 to 32768 for
`qwen35-2b` and `lfm25-vl-16b` and from 24576 to 32768 for `qwen35-4b-base`
alongside the validated depth: `remote/test-model-registry.sh` refuses a
`validated_filled_depth` that exceeds `context_ceiling`, and this campaign's
own precedent in `evidence/depth-validation-32k.md` states the rule directly
-- a row moves from unmeasured to measured, in both fields, when its arm
passes. `qwen35-4b-base` had no depth arm of any kind before this campaign;
its evidence directory here is not an addition to prior arms, since its
`projector` field reads `required` and `llama-bench` never attaches one.

Every measured arm's `evidence` and `validation_evidence` path resolves to a
directory under this one, so `remote/model-registry.sh tuples MODEL_ID`
returns nine new rows across the three model ids, each `status=validated`
beside its own subdirectory, and `remote/check-validated-tuples.sh` and
`remote/test-model-registry.sh` both accept the joined registry.

## Retained artifacts

Each of `qwen35-2b/`, `lfm25-vl-16b/`, and `qwen35-4b-base/` carries
`projector-summary.tsv` (the table above, source), `validated-tuples-rows.tsv`
(the rows appended to `remote/validated-tuples.tsv`), `projector-identity.tsv`
(one provenance row per invocation naming the llama-server, runner, sampler,
and control-image digests, the kernel release, and the argv), and
`wedge-metadata.tsv` (the model and projector SHA-256 and byte counts, cache
triple, submission geometry, decode length, fill margin, and control claim the
ledger binds every resumed row to). Each arm additionally carries its
`.server.log`, `.requests.txt` (the four dependent requests: probe, padding
tokenize, fill, control), `.clocks.tsv` (GPU clock and memory samples), and
`.dmesg.txt`/`.dmesg-method.txt` (the kernel delta and whether it was captured
by following the ring buffer or by an offset subtraction). Every path under
`$HOME` in these files is written literally as `$HOME`, matching this
repository's Git-copy sanitization rule.
