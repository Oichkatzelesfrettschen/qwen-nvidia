# RCA: why qwen25-coder-7b serves at 8192 tokens

## Tool selection

Twelve programs from `$HOME/Documents/AI/Notes/1_TOOLS.md`, chosen for
static/registry inspection, GGUF header reading, arithmetic, and log
forensics. GPU load generators (glmark2, vkpeak, deqp, apitrace, ...) are
excluded on purpose: the device is owned by another run and this audit reads
files only.

| tool | why selected | used / not-applicable |
| --- | --- | --- |
| `git` | commit history for the `models.tsv` row and the depth-validation evidence commits | used: found `512b306` (admits the row at 8192) and `c3d498d` (validates `qwenseer-2b` at 65536, leaves the 7B alone) |
| `ripgrep` (`rg`) via `grep -n`/`grep -rl` | fast text/regex search across `scripts/`, `evidence/` for row mentions and the depth-validation logic | used: located `probe-filled-depth.sh`'s ceiling check, the `qwen25-coder-7b` occurrences across `evidence/` |
| `fd` | locate evidence subdirectories by name pattern | used: enumerated `evidence/depth-validation-cuda/*` and confirmed `qwen25-coder-7b/` holds four files, no extra unlisted arms |
| `jq` | parse the JSONL failure-evidence stream from the fresh Qwen Code run | used: `jq -r '.mode + ": " + .output' events.jsonl` extracts the two run modes and their embedded transcripts in one line; a second-level `jq -c 'select(.type=="assistant")...'` over the extracted string fails because the `output` field mixes non-JSON startup warning lines ahead of the JSON transcript lines, so the top-level extraction plus a `grep` for the `API Error` line was the working combination |
| `python3` | GGUF header parsing (a hand-rolled reader over the file's own KV block) and the VRAM/token arithmetic | used: extracted `attention.head_count_kv`, `embedding_length`, `context_length`, `rope.freq_base`; computed KV-cache bytes/token and the weights+KV totals at four depths |
| `sha256sum` | verify the local GGUF file identity against the recorded `observed-sha256` and the admission commit's digest | used: `509287f7...894d3c` matches both the `.observed-sha256` sidecar and the commit message's `509287f7` prefix |
| `miller` (`mlr`) | structured TSV queries against `models.tsv` / `validated-tuples.tsv` | not applicable here: the registry rows needed were found faster with `grep -n` on two known model IDs than by loading `mlr --tsv` over a 170-row file with a 26-column comment-heavy header; no aggregate query was needed |
| `visidata` (`vd`) | interactive cross-check of TSV columns against the header comment block | not applicable here: the column mapping was resolved by reading the header comment line at `models.tsv:140` directly, which named all 26 fields in order; an interactive session added nothing a `Read` did not already give |
| `qsv` | validate/summarize TSV column counts, catch header/row field-count drift | not applicable here: `awk -F'\t' '{print NF}'` on the target row (26 fields, matching the header) was sufficient to confirm no column drift; qsv's stats/validation subcommands would answer the same question at higher setup cost for a single row |
| `sqlite3` | structured join across `models.tsv`, `validated-tuples.tsv`, and the coding-service authority TSVs if a multi-table join were needed | not applicable here: three two-column greps answered the join (row keyed on `qwen25-coder-7b` in each file) without needing a database |
| `gnuplot` | plot the VRAM-vs-depth curve if the arithmetic needed a visual argument | not applicable here: four depths (8192/32768/65536/131072) and two lines (weights, weights+KV) read clearly as a small table; a plot would not change the verdict |
| `graphviz` (`dot`) | diagram the launch-chain dependency between `models.tsv`, `probe-filled-depth.sh`, and `check-validated-tuples.sh` if the causal chain needed a picture | not applicable here: the chain is three files deep and states cleanly as prose; a diagram would recreate the "Root cause" section below without adding information |

## The four hypotheses

### (a) Policy: 8192 is the only depth a filled-depth arm has validated -- CONFIRMED, but the mechanism is a circular default, not a clamp rule

`scripts/models.tsv` line 168 (columns per the header comment at line 140):

```
id=qwen25-coder-7b  context_default=8192  context_ceiling=8192  context_target=32768
cache_type_k=q8_0  cache_type_v=q4_0  flash_attention=on  batch=2048  ubatch=512
validated_filled_depth=8192  validation_evidence=evidence/depth-validation-cuda/qwen25-coder-7b/
```

The CLAUDE.md sentence is "A ceiling never exceeds a depth measured to
**fail**" (line 148) -- a floor against setting a ceiling above a depth known
to break, not a rule that clamps a ceiling to a depth already validated safe.
Two other rows in this same file falsify the stronger reading: `qwen35-4b-base`
(`context_ceiling=32768`, tier `production`) and `lfm25-12b-thinking`
(`context_ceiling=65536`, tier `candidate`) both carry `validated_filled_depth=-`
-- an unvalidated ceiling well above any measured fill, one of them serving in
production. So a ceiling exceeding a validated depth is normal in this
registry; `qwen25-coder-7b` at 8192/8192 is not obeying a clamp that binds
every row.

The real mechanism is `models.tsv:39-42`'s own entry rule, read verbatim:
"A candidate enters at 8192 default and ceiling with `-` for
validated_filled_depth... The depth arm is what moves those two fields." 8192
is the fixed entry boilerplate every new row gets, not a measured limit for
this checkpoint. `probe-filled-depth.sh` compounds that boilerplate into a
self-confirming default: `depths=${QWEN_PROBE_DEPTHS:-$context_ceiling}` --
absent an explicit override, the probe fills exactly the ceiling it is meant
to justify. Commit `512b30699b7180ca042740793776f10bfc7465e8` ("registry:
admit Qwen2.5-Coder-7B-Instruct through the full chain") ran the arm with no
`QWEN_PROBE_DEPTHS` override, so it filled 8192 (the boilerplate entry value),
got 8067/8192 tokens and needle retrieval, and wrote `validated_filled_depth=8192`
-- which confirms the entry boilerplate rather than testing the row's own
stated `context_target=32768`. `evidence/depth-validation-cuda/qwen25-coder-7b/filled-depth-summary.tsv`:

```
arm               model_id          depth  batch  ubatch  cache_k cache_v flash  status  prompt_n  completion_tokens  needle     health
d8192-b2048-ub512 qwen25-coder-7b   8192   2048   512     q8_0    q4_0    on     ok      8067      11                 retrieved  healthy
```

`evidence/depth-validation-cuda/README.md` states the outcome directly: "the
deep coder serves at 8192 until a deeper arm passes." Six rows were admitted
in that sweep; five moved past their own entry boilerplate to 24576-65536
because their admission commits passed `QWEN_PROBE_DEPTHS` explicitly.
`qwen25-coder-7b` is the one row whose admission arm never overrode the
default, so it validated exactly what it started at.

The next depth-moving commit, `c3d498d` ("registry: validate qwenseer-2b at
65536 and admit the 7B evict-first move"), validates a *different* row
(`qwenseer-2b`) at 65536 and only touches the 7B's `switch_policy` field
(`lru` -> `evict-first`), not its depth -- see the VRAM section below for what
that commit actually measured. No commit since has run `probe-filled-depth.sh`
with `QWEN_PROBE_DEPTHS=32768` (or any deeper value) against
`qwen25-coder-7b`. `scripts/validated-tuples.tsv` carries exactly one row for
this model, at depth 8192:

```
qwen25-coder-7b-d8192-b2048-ub512  qwen25-coder-7b  standalone  8192  2048  512  q8_0  q4_0  on  ...  validated  ...  2026-08-31
```

The gap between `context_target=32768` and `context_ceiling=8192` is not a
bug and not a rule being enforced against this row specifically; it is an
unrun experiment sitting behind a default nobody has overridden yet.

### (b) VRAM fit -- REFUTED for the standalone probe tuple; a separate, narrower VRAM finding governs router co-residency

GGUF file: `~/models/Qwen2.5-Coder-7B-Instruct-GGUF/qwen2.5-coder-7b-instruct-q4_k_m.gguf`,
4,683,073,536 bytes (4466.13 MiB), SHA-256 `509287f78cb4d4cf6b3843734733b914b2c158e43e22a7f4bf5e963800894d3c`,
verified against the `.observed-sha256` sidecar and matching the admission
commit's cited digest and byte count. `gguf-tensor-census.py` reads:

```
architecture=qwen2  block_count=28  attention.head_count=28  attention.head_count_kv=4
embedding_length=3584  context_length=131072  rope.freq_base=1000000.0
```

`head_dim = embedding_length / head_count = 3584 / 28 = 128`.

KV cache bytes/token, per the row's own cache triple:

```
q8_0 (K):  34 bytes / 32-element block = 1.0625 bytes/element
q4_0 (V):  18 bytes / 32-element block = 0.5625 bytes/element
kv_bytes_per_token = n_layer * n_kv_head * head_dim * (bytes_k + bytes_v)
                    = 28 * 4 * 128 * (1.0625 + 0.5625)
                    = 14336 * 1.625
                    = 23296 bytes/token  (22.75 KiB/token)
```

Weights + KV at four depths:

| depth | KV cache | weights + KV |
| ---: | ---: | ---: |
| 8192 | 182.00 MiB | 4648.13 MiB |
| 32768 | 728.00 MiB | 5194.13 MiB |
| 65536 | 1456.00 MiB | 5922.13 MiB |
| 131072 (n_ctx_train) | 2912.00 MiB | 7378.13 MiB |

Device: 12282 MiB total, ~2560 MiB (2.5 GiB) compositor-resident per CLAUDE.md's
own measured figure, leaving 9722 MiB of headroom before the model loads at
all. Even the model's own *native trained* context length of 131072 costs
7378 MiB against that 9722 MiB headroom -- 2344 MiB spare before a compute
buffer is even counted. `grep -rn "compute buffer size" evidence/` across the
whole tree turns up exactly one hit, `evidence/quarantine/ministral3-3b.md`'s
`Vulkan0 compute buffer size = 5.20 MiB`, which is a different backend, a
different (much smaller) model, and a quarantined row -- not a usable anchor
for this row's CUDA/ubatch-512 buffer. No CUDA0 compute-buffer figure for any
7B-scale row exists anywhere in `evidence/` at any captured verbosity
(`not run`, and this file does not invent a number to fill the gap). The
admission commit's own report -- "all 4460 MiB of weights on the device" --
matches the 4466 MiB file size and carries no separate buffer line. Even
without that figure, the margin at 32768 (5194 MiB against 9722 MiB headroom,
4528 MiB spare) is wide enough that no plausible compute-buffer size closes
it. For the tuple `probe-filled-depth.sh` actually runs -- one model,
standalone, no router coexistence -- hypothesis (b) is refuted: VRAM is not
why the ceiling sits at 8192.

That refutation is scoped to the standalone probe. `c3d498d`'s own body
records a real, measured VRAM constraint, but it is a *different* one: the
commit that moved `qwen25-coder-7b` to `switch_policy=evict-first` cites
`evidence/ada/evict-first-7b-admission/README.md`, which ran the router
transition at `QWEN_ROUTER_MAX=1` between the resident `qwen38-2b-distill`
and this row and measured "framebuffer trough 1255 MiB against the 1199-1225
MiB desktop rest, peak 6272 of 12282 MiB against the 11500 MiB ceiling" --
comfortable, and the roster poll shows the 2B reading `unloaded` 1404 ms
*before* the 7B reads `loaded`, i.e. the two were never simultaneously
resident in that run. CLAUDE.md's general description of `evict-first` --
"the router capacity gate counts models rather than bytes and a second
resident beside this row exceeds the carve-out" -- states the class of row
this switch_policy exists for; the measured admission run for this specific
pair at their current depths does not itself show an overflow, because
evict-first is precisely what prevents the two from ever being simultaneously
resident under `QWEN_ROUTER_MAX=1`. The distinction that survives: VRAM does
not bind the standalone depth tuple the probe would run at 32768 (4528 MiB of
margin); it is the reason this row is barred from co-resident LRU serving
alongside another router child, which is an orthogonal constraint on
`switch_policy`, not on `context_ceiling`.

### (c) Model configuration -- REFUTED, the file declares far more headroom than 8192

The GGUF's own metadata: `qwen2.context_length = 131072`,
`qwen2.rope.freq_base = 1000000.0`. No `rope.scaling.type`,
`rope.scaling.factor`, or `rope.scaling.original_context_length` key exists in
the KV block (checked by walking the raw GGUF header rather than trusting a
summarizer that might filter absent keys). The file declares a flat
131072-token window with no YaRN dial baked into the metadata -- it is not
declaring a 32768-native-plus-YaRN-extension shape the way some Qwen2.5-Coder
HF configs do when `rope_scaling` is toggled on; this GGUF's own header simply
states 131072 as `n_ctx_train`. Either way, 8192 sits nowhere near any limit
the file itself declares: it is 6.25% of the file's stated 131072 and 25% of
Qwen's documented 32768 native pretraining window. Nothing in the checkpoint's
own configuration explains the 8192 ceiling. Hypothesis (c) is refuted.

### (d) Unified memory -- NOT APPLICABLE at these sizes

`scripts/cuda-runtime-env.sh`'s `unified` profile sets exactly one variable:

```sh
unified)
    export GGML_CUDA_ENABLE_UNIFIED_MEMORY=1
    ;;
```

Per CLAUDE.md, this "lets an allocation exceed the 12 GiB carve-out by paging
over PCIe, which belongs to an arm that would otherwise not run at all." Per
part (b) above, weights+KV for this row do not approach the 9722 MiB headroom
at any depth up to the model's own 131072-token native limit (7378 MiB, a
2344 MiB margin). `GGML_CUDA_ENABLE_UNIFIED_MEMORY` is a residency lever for
an allocation too large to fit in the carve-out at all; this row never reaches
that regime, so the flag is irrelevant to why the ceiling sits at 8192.
Hypothesis (d) does not apply.

## The agent-runtime floor: how deep this row actually needs to go

`/tmp/.../coding-deep-1/service-state/export/job-1788223394-6c87b2d5/events.jsonl`
records two failed turns against the live 8192-token server, both from Qwen
Code v0.22.3 against the `qwen25-coder-7b` alias:

```
plan mode:  [API Error: 400 request (16275 tokens) exceeds the available context size (8192 tokens)]
apply mode: [API Error: 400 request (18348 tokens) exceeds the available context size (8192 tokens)]
```

Both failures happen on the *opening* request, before a single file read,
grep, or edit tool call executes. The harness's own startup warning states
the fixed floor under both: "Loaded always-on context (QWEN.md context files +
auto-memory) uses about 1,455 tokens, more than 15% of this model's 8,192
token context window." Plan mode's system prompt carries 23 tool schemas
(`get_goal` through `loop_wakeup`); apply mode carries 28 (`plan`'s list plus
`edit`, `notebook_edit`, `write_file`, `run_shell_command`, `monitor`), which
is why apply's opening request (18348) runs 2073 tokens heavier than plan's
(16275) -- five additional tool schemas at roughly 400 tokens each.

Minimum depth arithmetic for one completed turn, apply mode (the mode that
actually edits):

```
opening request (tools + QWEN.md + auto-memory + system prompt + user turn) = 18348 tokens
+ reply budget (a modest 1024-token completion)                              =  1024 tokens
------------------------------------------------------------------------------------------
floor to answer once, doing no work at all                                  = 19372 tokens
```

19372 already exceeds 8192 by 2.37x and exceeds even a hypothetical 16384
ceiling. A real edit turn is not one exchange: each `read_file`, `grep_search`,
or `edit` call appends its own output plus the model's next reasoning span
before the following request, so context grows monotonically across a
multi-step edit rather than resetting between tool calls. The registry's own
`context_target=32768` for this row is consistent with that growth pattern --
roughly 1.8x the measured 18348-token opening request, enough headroom for one
or two moderate file reads plus a reply budget before the next request would
overflow. 8192 fails before the agent does anything; 32768 is the row's own
declared floor for surviving a real edit turn.

## Root cause, stated flat

`qwen25-coder-7b` serves at 8192 tokens because every candidate enters the
registry at `context_default=8192 context_ceiling=8192` as fixed boilerplate
(`models.tsv:39-42`), and `probe-filled-depth.sh` defaults its fill target to
whatever `context_ceiling` already holds when no `QWEN_PROBE_DEPTHS` override
is given. Commit `512b306`'s admission arm ran with no override, so it filled
exactly the entry value, passed, and wrote `validated_filled_depth=8192` --
which confirms the boilerplate rather than testing the row's own declared
`context_target=32768`. This is a circular default going unnoticed, not the
registry's stated ceiling-versus-failure rule (line 148: "a ceiling never
exceeds a depth measured to *fail*") -- two other rows in the same file
(`qwen35-4b-base`, `lfm25-12b-thinking`) carry ceilings well above an
unvalidated `-`, so an unvalidated ceiling is not itself forbidden here; this
row's ceiling is simply pinned to a value nobody has tried to push past. No
VRAM ceiling forces the 8192 pin for the standalone tuple this probe would
run (weights+KV at 32768 costs 5194 MiB against 9722 MiB of headroom, 4528
MiB spare; even the model's native 131072-token limit fits with 2344 MiB to
spare) -- the one measured VRAM constraint on this row, evict-first
switch_policy, governs router co-residency with another child, not this
depth. No GGUF-declared context limit forces this (the file states 131072,
sixteen times the served depth), and `GGML_CUDA_ENABLE_UNIFIED_MEMORY` is
irrelevant because the allocation never approaches the carve-out at any depth
this checkpoint supports. The Qwen Code v0.22.3 failures are the downstream
symptom of exactly this gap: the coding agent's own opening request
(16275-18348 tokens, driven by its 23-28 tool schemas plus 1455 tokens of
always-on QWEN.md/auto-memory context) exceeds the 8192-token ceiling before
any edit work starts, and the registry's own unvalidated `context_target` of
32768 is sized correctly to clear that floor. The row is capped by an unrun
experiment behind its own entry default, not by architecture or VRAM.

## Remediation: run the depth arm the row is missing

`scripts/probe-filled-depth.sh` refuses any requested depth above the
registry's current `context_ceiling` (its own guard: "depth %s exceeds the
registry ceiling %s"). `context_ceiling` must move from 8192 to 32768 in
`scripts/models.tsv` (matching the row's own already-declared `context_target`)
before the probe can run at that depth. Sequence, commands written out and
NOT executed:

```sh
# 1. Raise the row's context_ceiling from 8192 to 32768 in scripts/models.tsv
#    (context_target already reads 32768; this promotes it to what the probe
#    is permitted to attempt -- validated_filled_depth stays at 8192 until
#    the arm below passes).

# 2. Run the filled-depth probe at 32768, the row's own cache triple
#    (q8_0/q4_0, flash-attn on) and submission geometry (batch 2048, ubatch 512),
#    using the same invocation shape evidence/depth-validation-cuda/README.md
#    documents for the other five rows:
QWEN_PROBE_DEPTHS=32768 \
scripts/probe-filled-depth.sh qwen25-coder-7b evidence/depth-validation-cuda/qwen25-coder-7b

# 3. On a healthy result (status=ok, needle=retrieved, health=healthy),
#    validated_filled_depth moves to 32768 in scripts/models.tsv and the
#    emitted validated-tuples-rows.tsv line is appended to
#    scripts/validated-tuples.tsv, per the same admission pattern
#    evidence/depth-validation-cuda/qwen38-4b-distill/ already shows.
#    Step 3 is not optional bookkeeping: CLAUDE.md states that on the web/
#    coding preset path "the launch bounds that depth again by the row's
#    current validated_filled_depth and refuses a `-` outright." Raising
#    context_ceiling in step 1 alone does not let code-deep-a or any other
#    coding profile actually serve 32768 -- the served path clamps to
#    validated_filled_depth, so step 3 is the step that changes what the
#    coding agent's context window becomes.

# 4. Re-run the registry gate to confirm the new row joins cleanly:
scripts/check-validated-tuples.sh
# check-validated-tuples.sh derives the tuple from the numeric
# validated_filled_depth and requires a matching `validated` ledger row; with
# ceiling=32768 and validated_filled_depth left at 8192 pending step 3, the
# still-8192 ledger row it derives against still exists and still matches, so
# step 1 by itself does not trip the gate before step 3 lands.
```

Projected VRAM at 32768: weights 4466.13 MiB + KV cache 728.00 MiB =
5194.13 MiB, against 9722 MiB of headroom after the ~2560 MiB (2.5 GiB)
compositor-resident desktop is subtracted from the 12282 MiB carve-out. That
leaves roughly 4527 MiB of margin even before folding in a compute buffer, so
the deeper tuple coexists with the live desktop compositor by a wide margin --
this is not a close-fit arm the way the appliance's larger checkpoints are.
The step this repository has not yet taken is the measurement itself, not a
resource shortage: `probe-filled-depth.sh` proves execution and long-range
attention at 32768, not merely that the allocation reserves without OOM,
which is the exact distinction `validated_filled_depth` exists to keep
separate from `context_ceiling`.
