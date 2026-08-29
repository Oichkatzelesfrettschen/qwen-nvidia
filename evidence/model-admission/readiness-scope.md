# Model readiness scope

Three read-only passes over the tree and the appliance, joined here: the
served registry (`remote/models.tsv`), the candidate ledger
(`evidence/model-admission/candidate-ledger.tsv`), and the artifacts under
`$HOME/models` on the appliance. The tables beside this file carry one row per
model with the evidence file behind each cell.

## Served registry (15 rows)

| category | rows | what remains |
| --- | --- | --- |
| ready-production | `qwen38-4b-distill`, `qwen38-2b-distill` | nothing; 32768 validated, graded 47/55 and 40/55 |
| ready-candidate | `qwen35-08b`, `qwen35-08b-f16` | 32768 validated, graded 33/55 and 32/55; a tier move is a quality decision |
| needs-depth-validation | `qwen35-4b-base` | no depth arm exists for the base 4B; the vision profile serves it, so this is the largest open gap on a served row |
| depth validated text-only | `qwen35-2b`, `lfm25-vl-16b` | `validated_filled_depth` reads `-` and stays so: the ledger's validated rows at 8192, 16384, and 32768 carry `projector_state=none` (llama-bench), the registry row requires a projector, and `check-validated-tuples.sh` keys a required-projector row on `loaded`, so a numeric claim fails the gate until a projector-loaded arm fills and decodes through the served path |
| quarantined | `nanbeige42-3b`, `ministral3-3b` | each has a reason record and a re-entry gate under `evidence/quarantine/` |
| archive or rejected | `qwen38-9b-distill`, the three 4B i1 rungs, the two 27B rungs | measured and displaced; nothing to configure |

## Candidate ledger (28 rows)

| category | rows |
| --- | --- |
| promoted | `qwen38-2b-distill-gguf`, `qwen35-08b-bartowski` |
| needs-quality-grade | `qwen35-08b-opus-reason` (loaded, 32768 validated), `qwen3-zero-coder-v2-08b` (loaded, 32768 validated), `qwen3-zero-coder-08b` (loaded, throughput measured), `qwen2vl-2b-platinum` (loaded, throughput measured) |
| needs-throughput | the seven 2B fine-tunes (`qwen38-2b-uncensored`, `qwen35-2b-hauhau`, `qwen35-2b-unsloth`, `qwen35-2b-unredacted`, `qwen35-2b-unredacted-i1`, `qwen35-2b-heretic`, `qwenseer-2b`) and `qwen35-08b-unsloth-unc`: one-token load passed, no arm since |
| needs-one-token-load | `qwen35-9b-defiant-fable` (static admission already parsed it; the ledger stage is stale), `minicpm5-1b-fable5-v2` |
| needs-control-arm | `qwen38-9b-distill`: served as `archive` in the registry, `phase-1` in the ledger, and called absent by the throughput document |
| artifact-absent | six rows, safetensors-only or empty repositories, including both Damien420 rows |
| rejected or provenance | five rows |

Two ledger stage fields disagreed with the evidence they cite and are
repaired beside this file: `qwen35-9b-defiant-fable` read `phase-1` where
`static-admission.tsv` reads `parsed`, and `qwen38-9b-distill` read `phase-1`
where `models.tsv` serves it. No stock MiniCPM5-1B row exists, so the Fable-trace fine-tune has no
lineage control yet.

## Appliance artifacts

23 GGUF files at the top level of `$HOME/models`, 63.4 GB, every one matching
the byte count its pinned `download-*.sh` states; ten candidate staging
directories under `candidates/` at mode 0700; five symlink groups
(`production/`, `candidates/`, `quarantine/`). Installed and unregistered:
`Qwen3.5-0.8B-bf16.gguf` and `Qwen3.8-2B-BF16.gguf` (F16 derivation
sources, which is their documented role), `Qwen3.8-2B-F16.gguf` (derived, no
registry row, unlike its 0.8B sibling), and the `stories15M` fixture. Pinned
but absent: `qwen38-4b-i1-iq3s` (expected 2,191,729,152 bytes, never
fetched).

## Order of work that follows from this

1. Ledger repair, no device time: the two stale stages now read
   `static-admitted` and `served`. `Qwen3.8-2B-F16.gguf` stays a derived,
   unregistered artifact until `run-representation-arm.sh` measures it against
   its BF16 source the way the 0.8B pair was measured; the registry row follows
   the arm.
2. Quality grading, device time: `qwen35-08b-opus-reason` against stock
   Qwen3.5-0.8B Q4_K_M in native thinking mode; `qwen3-zero-coder-v2-08b`,
   `qwen3-zero-coder-08b`, `qwen2vl-2b-platinum` through the roster suite.
3. MiniCPM5: add the stock control row, fetch both, strict load, template and
   structured tool-call check, throughput, then the paired suite.
4. One throughput arm per runtime class for the eight loaded-and-unmeasured
   fine-tunes, read as ratios inside one sweep.
5. Projector-loaded depth arms for `qwen35-4b-base`, `qwen35-2b`, and
   `lfm25-vl-16b`, since the vision profiles serve all three.
