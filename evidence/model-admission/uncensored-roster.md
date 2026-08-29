# The uncensored roster

Six uncensored, unredacted, and heretic-lineage checkpoints enter
`remote/models.tsv` at tier `candidate`, which is what puts them in the router
picker. Each row rests on a published GGUF header, a publisher LFS digest, and
one strict Vulkan load already recorded in
`evidence/one-token-admission/admission-summary.tsv`. None rests on a rate, a
filled depth, or a graded reply, and the row fields say so.

## The picker cannot be regenerated until the staged weights move

`remote/build-router-presets.sh` owns `$QWEN_MODEL_ROOT/candidates` as the
candidate tier's symlink directory and refuses any real entry it finds there:

```text
tier directory holds a real entry where a symlink belongs: .../candidates/qwen35-2b-heretic
move it out of the tier tree; reconciliation refuses to touch it
```

`remote/run-one-token-admission.sh` staged every fetched candidate into that
same path, so the appliance holds thirteen real directories where the builder
expects links and the builder exits 1 before it writes a section. The staging
default moves to `$HOME/models/candidate-staging`, which removes the recurrence,
and the artifacts already on disk move once by hand. Each registered row's
weights move into the per-publisher directory its `model_file` names, and the
staged directories no row claims move to the new staging root:

```sh
cd ~/models
mkdir -p Qwen3.8-2B-Uncensored-GGUF \
    Qwen3.5-2B-Uncensored-HauhauCS-Aggressive-GGUF \
    Qwen3.5-2B-Unredacted-MAX-GGUF Qwen3.5-2B-Opus-Distilled-Heretic-GGUF \
    Qwen3.5-0.8B-Uncensored-GGUF Qwenseer-2B-GGUF candidate-staging
mv candidates/qwen38-2b-uncensored/Qwen3.8-2B-Uncensored-Q4_K_M.gguf \
    Qwen3.8-2B-Uncensored-GGUF/
mv candidates/qwen35-2b-hauhau/Qwen3.5-2B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf \
    Qwen3.5-2B-Uncensored-HauhauCS-Aggressive-GGUF/
mv candidates/qwen35-2b-unredacted/Qwen3.5-2B-Unredacted-MAX.Q4_K_M.gguf \
    Qwen3.5-2B-Unredacted-MAX-GGUF/
mv "candidates/qwen35-2b-heretic/Qwen3.5-2B-Opus-Distilled-Heretic-Thinking-Multistage-SFT-v1.0.Q4_K_M.gguf" \
    Qwen3.5-2B-Opus-Distilled-Heretic-GGUF/
mv candidates/qwen35-08b-unsloth-unc/Qwen3.5-0.8B.Q4_K_M.gguf \
    Qwen3.5-0.8B-Uncensored-GGUF/
mv candidates/qwenseer-2b/Qwenseer-2B.Q4_K_M.gguf Qwenseer-2B-GGUF/

# The digest sidecar travels with the artifact it records, and the six emptied
# staging directories go once both files have left them.
for staged in qwen38-2b-uncensored:Qwen3.8-2B-Uncensored-GGUF \
    qwen35-2b-hauhau:Qwen3.5-2B-Uncensored-HauhauCS-Aggressive-GGUF \
    qwen35-2b-unredacted:Qwen3.5-2B-Unredacted-MAX-GGUF \
    qwen35-2b-heretic:Qwen3.5-2B-Opus-Distilled-Heretic-GGUF \
    qwen35-08b-unsloth-unc:Qwen3.5-0.8B-Uncensored-GGUF \
    qwenseer-2b:Qwenseer-2B-GGUF; do
    mv "candidates/${staged%%:*}"/*.observed-sha256 "${staged#*:}/"
    rmdir "candidates/${staged%%:*}"
done

# The seven staged directories no registry row claims move to the new staging
# root, and the symlinks an earlier builder run left behind are removed rather
# than moved, because the next run recreates them from the registry.
for staged in qwen2vl-2b-platinum qwen35-08b-bartowski qwen35-08b-opus-reason \
    qwen35-2b-unredacted-i1 qwen35-2b-unsloth qwen3-zero-coder-08b \
    qwen3-zero-coder-v2-08b; do
    mv "candidates/$staged" candidate-staging/
done
rm -f candidates/*

~/qwen-laptop-setup/remote/build-router-presets.sh
```

Each fetch script verifies an artifact already in place, so
`remote/download-<name>.sh` run after the move reports
`artifact_status=already_verified` and proves the move preserved the bytes.

The six sections take the router's servable set from 7 to 13. Router startup
selects the largest installed servable GGUF as the resident-memory preflight
subject, and every new artifact is smaller than the 2.78 GB `qwen38-4b-distill`
already served, so the picker grows while the preflight subject stays where it
is.

## Inventory

Every digest below is the publisher's own LFS object id read from the Hugging
Face `paths-info` API at the pinned revision. The six on-disk artifacts each
carry the digest their `.observed-sha256` sidecar records, and each of those
equals the publisher oid, so all six are `verified_sha256`.

| checkpoint | where it lives | repository @ revision | bytes | sha256 | runtime class |
| --- | --- | --- | ---: | --- | --- |
| `qwen38-2b-uncensored` | staged on disk | atakhadivi/Qwen3.8-2B-Uncensored-GGUF @ 649ee94d | 1274396640 | 61713f6d | qwen35 / 2048 / 6144 / 8 / 2 |
| `qwen35-2b-hauhau` | staged on disk | HauhauCS/Qwen3.5-2B-Uncensored-HauhauCS-Aggressive @ 2bcf35c1 | 1270808032 | be3ccca1 | qwen35 / 2048 / 6144 / 8 / 2 |
| `qwen35-2b-unredacted` | staged on disk | mradermacher/Qwen3.5-2B-Unredacted-MAX-GGUF @ 69d5860d | 1270809056 | b0d7d091 | qwen35 / 2048 / 6144 / 8 / 2 |
| `qwen35-2b-heretic` | staged on disk | prithivMLmods/Qwen3.5-2B-Opus-Distilled-Heretic-Thinking-Multistage-SFT-v1.0-GGUF @ 48027b69 | 1274396512 | a4abaa15 | qwen35 / 2048 / 6144 / 8 / 2 |
| `qwen35-08b-unsloth-unc` | staged on disk | tsilva/unsloth_Qwen3.5-0.8B_uncensored @ 2333f322 | 529297024 | 190e491d | qwen35 / 1024 / 3584 / 8 / 2 |
| `qwenseer-2b` | staged on disk | skyyuno/Qwenseer-2B-GGUF @ 81416455 | 1312164640 | 52826f50 | qwen35 / 2048 / 6144 / 8 / 2 |
| `qwen35-9b-defiant-fable` | fetch script only | DavidAU/Qwen3.5-9B-The-Defiant-Fable-Uncensored-Heretic-NEO-IMATRIX-MAX-MTP-GGUF @ 239d236b | 4942441760 | ae9679de | qwen35 / 4096 / 12288 / 16 / 4 |
| `qwen35-08b-abliterated` | recorded only | amkkk/Qwen3.5-0.8B-Opus-Distill-abliterated @ 6b7c6bb3 | 1746937880 | 04fd0471 | unread |

The last two carry no registry row. `qwen35-9b-defiant-fable` gets
`remote/download-qwen35-9b-defiant-fable-iq2m.sh`, which names the readable
IQ2_M artifact rather than letting a Q4_K_M preference choose: the repository's
identically sized MTP variant carries 10.5 MiB of leading zeros, so its magic,
metadata block, and tensor index are absent. Fetching 4.94 GB needs the router
torn down, through `remote/fetch-candidate-artifact.sh` or the download script
directly, and its class incumbent `qwen38-9b-distill` is tiered `archive` at
1.76 tok/s decode, so a 9B row competes against a checkpoint the roster already
displaced.

`qwen35-08b-abliterated` is the only abliterated row in the tree and it
publishes safetensors alone. `conversion_required=yes` in
`evidence/model-admission/candidate-ledger.tsv`, the appliance holds no torch,
and no GGUF exists at the pinned revision, so it gets no download script. An
abliterated checkpoint reaches the picker when a GGUF conversion exists.

Three staged artifacts stay unregistered for stated reasons.
`qwen35-2b-unredacted-i1` is the i1 repository's Q4_K_M rung of the same
fine-tune already registered as `qwen35-2b-unredacted`, byte-identical in tensor
payload at 1259846912 loaded bytes, and the ledger carries it as `redundant`
with `next_test: none`. `qwen35-08b-bartowski` is the served `qwen35-08b`
weights at a different value format. `qwen35-2b-unsloth` is stock Qwen3.5-2B,
already served as `qwen35-2b` from the bartowski conversion.

Four further staged artifacts sit outside the uncensored lineage and stay
unregistered: `qwen35-08b-opus-reason` (Jackrong Opus reasoning distill, whose
generation prompt ends in an unguarded `<think>` so a thinking-off request is
inert against it), `qwen3-zero-coder-08b` and `qwen3-zero-coder-v2-08b` (DavidAU
code-reasoning, qwen3 / 1024 / 3072 / 16 / 8), and `qwen2vl-2b-platinum` (the
only vision candidate staged, qwen2vl / 1536 / 8960 / 12 / 2). Each has passed
the strict Vulkan load and would register the same way on request.

## What a row claims

A `candidate` row states that the artifact loads under strict Vulkan placement
with no CPU fallback reached, that its header declares an architecture the
pinned build serves, and that its bytes match the publisher's digest. It states
nothing about rate, depth, or quality, and the fields carry that:
`decode_tok_s` and `prefill_tok_s` read `-`, `quality` reads `untested`,
`raw_tool_selection` reads `unmeasured`, and `guarded_tool_execution` reads
`refused` the way every row in the file does.

`validated_filled_depth` reads `-`, so `context_default` and `context_ceiling`
both read 8192, which is the depth a candidate enters at. Copying the served 2B
distill's 24576/32768 would ship an allocation claim no probe has filled, and
this tree has wedged the compute ring at a depth it had only allocated. The
cache triple, Flash Attention state, and submission geometry are copied from the
class incumbent -- q8_0 keys, q4_0 values, Flash Attention on, batch 128, ubatch
32 -- which is the tuple every row in the registry serves at.

Every row reads `projector: none`. No projector sits beside any staged artifact,
though the ledger records that several of these repositories publish one, so
vision through these rows is unavailable as registered rather than unavailable
in principle.

## Admitting a row on the appliance

The strict Vulkan load is already recorded for all six, so the open steps are
the graded suite and the depth arm. Each needs the device, so each runs with the
router torn down and one at a time:

```sh
~/qwen-laptop-setup/remote/qwen-teardown.sh

# The strict load, if a re-run against the moved artifact is wanted. The record
# argument is a candidate-ledger row; fetch runs without the device.
~/qwen-laptop-setup/remote/run-one-token-admission.sh \
    ~/Github/qwen-apu/evidence/model-admission/candidate-ledger.tsv \
    ~/qwen-webui-state/uncensored-admission

# The graded suite over every servable row, which now includes the six.
~/qwen-laptop-setup/remote/run-quality-roster.sh \
    ~/qwen-webui-state/uncensored-quality

# The depth arm, one checkpoint at a time. The output directory is a resumable
# ledger bound to the model digest, so a different model or cache tuple
# requires a new directory.
~/qwen-laptop-setup/remote/probe-depth-wedge.sh \
    ~/models/Qwen3.5-2B-Opus-Distilled-Heretic-GGUF/Qwen3.5-2B-Opus-Distilled-Heretic-Thinking-Multistage-SFT-v1.0.Q4_K_M.gguf \
    ~/qwen-webui-state/depth-qwen35-2b-heretic
```

A graded result is read inside one sweep, so the six run in the same
`run-quality-roster.sh` invocation as their class incumbents rather than against
retained numbers from an earlier sweep: the same checkpoint under identical
flags has spanned 30.6% between sweeps on this machine. A row moves to
`production` when a sweep places it, a depth arm fills and decodes under its own
tuple, and `remote/validated-tuples.tsv` carries that arm with its evidence
path.

## What the web, image, and vision lanes still need

The web lane needs a `remote/web-profiles.tsv` row per profile, naming the
registry id in `model_id` and carrying a `provider`, category pair, and
`searxng_url`. Its `validated_filled_depth` copies the registry's `-`, so a
preset built from it carries the unvalidated-depth marker and
`remote/qwen-web-launch.sh` binds 127.0.0.1. It stays
`execution_policy: refused`: a `validator-gated` row
requires a runtime comparing emitted tool arguments against the user's own
authorization, and this tree holds none. `remote/build-web-presets.sh` against
an all-refused ledger emits nothing and says so, which is the correct outcome
for a checkpoint whose `raw_tool_selection` is unmeasured.

The image lane binds one language profile to one image profile in a single
grant, and the language profile's model must propose a schema-valid tool call
inside the listing's stated maxima.
`evidence/image-appliance/served-turn-admission/` records the 4B distill doing
that and the 2B distill answering in prose, which its `raw_tool_selection` grade
of 2/10 already states. Every row registered here is 2B or 0.8B class with that
grade unmeasured, so the image lane needs
`evidence/model-admission/vision-and-tool-sweep.md`'s tool category run against
these rows before an `image-profiles.tsv` row names one.

The vision lane needs three things per row: a projector fetched into the
checkpoint's own directory so `remote/select-projector.sh` pairs it, the
registry row moved to `projector: required` with its fetch script, and a
`validated` row in `remote/validated-tuples.tsv` at `projector_state=loaded`
from `remote/probe-depth-projector.sh`. `remote/probe-depth-wedge.sh` cannot
supply that row, because llama-bench takes no `--mmproj` and allocates no
projector buffers, so every arm it records reads `projector_state=none`.
`image-profiles.tsv`'s `review_model` column names a vision checkpoint, and it
keeps naming `lfm25-vl-16b` until one of these rows carries a loaded-projector
tuple.
