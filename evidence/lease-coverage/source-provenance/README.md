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
of the three candidate patches, against the promoted closure's digest. That
reads 160 reconstructions, in `reconstruction-run.txt`, and **none matches**. An
earlier pass extended the same crossing over `core.abbrev` at seven values,
`diff.context` at two, and `diff.noprefix` at two: 4256 serialization variants,
none matching either `0d6e3be3` or the 08:46 batch's `689d3f35`.

The negative is real rather than procedural, because the same sweep reproduces
the candidate's `76f4b8e8` exactly and reproduces the empty-tree
`e3b0c442` three closures record. Raising `MMVQ_KERNEL_MAX_NCOLS` from 12 to 16
by hand on top of the contemporaneous patch set reproduces neither target
either, so the Aug-31 tree carried content beyond that one macro.

The scope is the generation rather than the binary. `689d3f35` covers seven
closures and `0d6e3be3` one, and none of the eight reconstructs, so the gap is a
property of how that day's trees were built -- edited live, exported to patch
files afterwards -- rather than something peculiar to the promoted closure. The
practice reproduces by 2026-09-05, which is what makes the candidate verifiable.

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

Route B is independent replacement admission. It states that the candidate and
its control have known source, and it states nothing retrospective about the
historical source that remains unavailable.

## Reproducing this

```sh
scripts/reconstruct-closure-source.sh ~/src/llama.cpp-qwen-nvidia \
    f280b26983ad0fdb705a0d9ebf0503e76f2899b0 WORK_DIR \
    evidence/lease-coverage/source-provenance/reconstruction-manifest.tsv
```

The manifest's historical rows name patch directories materialized from the
commits `patch-trees.tsv` lists; `scripts/test-reconstruct-closure-source.sh`
holds the reconstructor itself against a two-file fixture repository, including
the refusal a missed control produces.
