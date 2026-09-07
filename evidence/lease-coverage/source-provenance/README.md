# The source identity of the promoted and candidate closures

`candidate-build-source-identity.tsv` recorded that the promoted closure
`88681bf4d161` carries a `source_diff_sha256` no reconstruction reproduced, and
named two routes out. This directory runs both to their end. Route A is
exhausted and Route B holds: the candidate closure `15bc632adf7f` reconstructs
exactly from checked-in patch files, and the lease-off companion is one patch
away from it.

## What a digest is a digest of

`scripts/build-llama-cuda.sh:241` sets the field as
`git diff --binary HEAD -- | sha256sum` over the tree it is about to compile,
after `:236` has refused an untracked source file, which is why the three
headers the Vulkan patches add are staged: staging is what makes an added file
appear in a `HEAD` diff. `scripts/reconstruct-closure-source.sh` reproduces that
procedure -- check the pin out into a scratch clone, apply named patches in
order, stage, hash -- and every run reconstructs a control before its subjects
and refuses where the control misses, so a git or environment change is
reported as a broken procedure rather than as a subject's provenance verdict.

Four identities separate, and a mismatch in the first implies nothing about the
others:

```text
raw diff identity     the exact serialized diff bytes the builder hashed
source-tree identity  paths, modes, and file contents the compiler read
build identity        that tree plus options, compiler, and dependencies
binary identity       the executable and library bytes
```

The serialization is configurable and that was tested rather than assumed. Over
the candidate's own tree, `diff.algorithm` at `myers`, `minimal`, `patience`,
and `histogram` produces one digest, while `core.abbrev`, `diff.context`, and
`diff.noprefix` each move it. The historical sweep below therefore varied all
three.

## Route A: the historical source is unavailable

The search covered the retained material rather than guessed combinations.

`patch_series_sha256` is the first reading and it removes the obvious cause. The
seven closures built at 08:46 on 2026-08-31 record `689d3f35`, the promoted
closure fourteen minutes later records `0d6e3be3`, and **both record the same
`948e1fb2` patch series**. The patch files are held constant across the gap, so
they do not explain it.

`builder_sha256` moves across the same gap, `f0612bf3` to `9c96ed73`, and those
two blobs are `dbc700f0` and `08596370` in this repository. Their difference is
a threshold range check widening from 1-12 to 1-16 and a comment. It touches
neither the diff invocation nor what the builder stages, so the builder does not
explain the gap either. What it does explain is why the tree moved: the promoted
build serves `mmvq_q8_0_max 16`, whose `static_assert` against
`MMVQ_KERNEL_MAX_NCOLS` fails to compile unless that macro is at least 16, and
the crossover patch at the contemporaneous `04f952c9` defines it as 12.

The sweep then took every distinct `patches/` tree in this repository's history
-- twenty of them, listed in `patch-trees.tsv` -- crossed with all eight subsets
of the three candidate patches, against the promoted closure's digest.
`reconstruction-run.txt` is that run: one control, 160 historical
reconstructions of which 152 produced a digest and eight named an absent patch,
and **none matches**.

`serialization-sweep.tsv` extends the same crossing over the three settings
that move a digest, `core.abbrev` at seven values, `diff.context` at two, and
`diff.noprefix` at two, with each setting's control being the candidate's own
tree hashed under that same setting. It carries the variant count and the hit
count against both `0d6e3be3` and `689d3f35` per setting, and every hit count is
zero.

The negative is real rather than procedural, because the same sweep reproduces
the candidate's `76f4b8e8` exactly and reproduces the empty-tree
`e3b0c442` three closures record. Raising `MMVQ_KERNEL_MAX_NCOLS` from 12 to 16
by hand on top of the contemporaneous patch set reproduces neither target
either, so the Aug-31 tree carried content beyond that one macro.

The scope is the generation rather than the binary. `689d3f35` covers seven
closures and `0d6e3be3` one, and none of the eight reconstructs, so whatever
the cause, it belongs to that day rather than to the promoted closure alone.
The same construction reproduces closures built on 2026-09-05, so the practice
changed between the two dates.

What the search establishes is that no retained patch set reproduces those two
**diff digests**. The document separates raw diff identity from source-tree
identity above, and that separation applies here: an unreproduced digest is
consistent with a source tree that was never exported to patch files, and it is
equally consistent with an export that lost bytes the compiler read. The
reading that the trees were edited live and exported afterwards is a hypothesis
the timeline fits rather than a finding this search made, and it is recorded as
one. Deciding it would take a retained artifact of that day's tree -- a build
log naming file contents, an object with the compiled bytes, or a snapshot --
and this repository holds none.

`historical_source_reconstruction=unavailable`.

## Route B: the replacement baseline is reproducible

The candidate closure `15bc632adf7f` reconstructs from the checked-in patch
files at the pinned commit `f280b2698`, applied in
`verify-llama-patch-series.sh`'s own order:

```text
production   llama-vulkan-low-priority, llama-no-cpu-fallback,
             llama-vulkan-duty-cycle, llama-vulkan-runtime-submit-limit,
             llama-vulkan-submit-trace, llama-router-tools-proxy
candidate    llama-vulkan-view-alias-deps,
             llama-server-vulkan-workload-lease,
             llama-cuda-mmvq-crossover-ad104
```

That sequence yields
`76f4b8e888cde28f354482e4fea3d91e609ce634fb9d6654608b68f496a96768`, the digest
the closure's own `build-configuration.tsv` records.

Removing the lease patch alone from that sequence is the lease-off companion,
and the difference between the two is accounted for exactly: one file,
`tools/server/server-context.cpp`, 331 insertions and no deletion, with every
other path in the eleven-path working set byte-identical. Applying that one
patch to the companion tree produces the candidate's recorded digest.

```text
88681bf4d161                     historical production binary;
                                 source reconstruction incomplete
reconstructed lease-off companion reproducible experimental control;
                                 not the historical production source
15bc632adf7f                     reproducible replacement candidate
```

`replacement_source_provenance=verified`.

## What this record does not establish

The companion's `ca47669a0f45f823` is a **predicted** digest for a closure no
build has produced. When the companion is built, the builder emits its own
`source_diff_sha256` and that value is the authority; the prediction is what a
build is checked against rather than a substitute for one. The companion's
cubin count, kernel contents, and binary bytes are unmeasured, and the tree's
own rule governs: matching counts of 187 cubins state that two builds emitted
the same number of objects rather than the same kernels. The companion inherits
nothing from the candidate's served admission.

`88681bf4d161` therefore stays the behavioral regression reference rather than
being retired by the companion, and `historical_binary_regression=required` is
an obligation the final campaign carries: an arm against the promoted binary,
not against the companion alone.

Route B is independent replacement admission and it is **not finished**. What
holds is the source half: the candidate and its control have known source, and
the difference between them is accounted for exactly. The route as the record
states it also requires the companion to be built and the lease change isolated
against it, and `companion_build_state` reads `not_built`, so that obligation
stays open beside the drain-before-destroy policy rather than closing with this
search.

Route B states nothing retrospective about the historical source that remains
unavailable.

## Reproducing this

The retained manifest is a record rather than an input: its paths carry the
`$HOME` and `$WORK` the tree scrubs from every checked-in surface, and a TSV
field is read as bytes rather than expanded by a shell.
`scripts/prepare-provenance-manifest.sh` is what turns it back into an input --
it writes each historical patch set out of this repository's committed objects,
by the commits `patch-trees.tsv` names, and emits a manifest naming those
directories. Every blob is written on every run and the resulting directory is
then compared against the tree's own name list, so a directory an earlier run
left behind is overwritten rather than trusted and a file the tree does not
carry refuses the run by name. A manifest row pointing at a directory whose
contents are not the recorded tree would reconstruct something other than the
closure the row claims, which is the whole property this materialization
carries:

```sh
scripts/prepare-provenance-manifest.sh WORK_DIR
scripts/reconstruct-closure-source.sh ~/src/llama.cpp-qwen-nvidia \
    f280b26983ad0fdb705a0d9ebf0503e76f2899b0 WORK_DIR/run \
    WORK_DIR/provenance-manifest.tsv
```

The refusal is checkable in one command: writing an unexpected file into a
materialized directory and re-running the preparer exits 1 and names the entry.

```sh
mkdir -p WORK_DIR/patches-e4026f7462b21db0c8cb5dc087d6b907cc77ccfc
printf poison > WORK_DIR/patches-e4026f7462b21db0c8cb5dc087d6b907cc77ccfc/poison.patch
scripts/prepare-provenance-manifest.sh WORK_DIR   # exits 1, names poison.patch
```

`QWEN_RECONSTRUCT_GIT_OPTIONS` carries additional `-c` settings into every git
invocation, which is how the serialization arms are asked; a setting that moves
the digest moves the control with it, so each arm carries its own control value.

`scripts/test-reconstruct-closure-source.sh` holds the reconstructor against a
two-file fixture repository across forty-five checks, including the refusal a
missed control produces, the withholding of subject readings under a failed
control, and the proof that an inherited `GIT_INDEX_FILE` leaves the source
repository's index, working tree, configuration, and refs unchanged.

Two of the arms are written against a specific defect rather than a behavior,
so each was run under the defect it names and confirmed to fail there.
Restoring
`git diff | sha256sum` in place of the file-backed diff gives a failed diff the
digest of no bytes, and that mutation fails two readings, one of them
`diff_failure_is_not_an_empty_digest` carrying the empty digest as its actual
value. A reconstructor exiting the moment it sees a routing variable would
leave the source intact and reconstruct nothing, and that mutation fails four
readings, since the arm asserts the accepted terminal line and the manifest's
own counts beside the preservation readings under `GIT_INDEX_FILE` and
`GIT_DIR` alike.
