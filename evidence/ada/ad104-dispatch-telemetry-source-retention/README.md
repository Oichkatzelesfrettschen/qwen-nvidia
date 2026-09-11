# AD104 dispatch telemetry source and binary retention

The AD104 dispatch worktree held two different evidence objects. Commit
`54f7f7a7ac554d0ef7ec16f9a2e1e8a93b551000` is a reconstructable source
change based directly on llama.cpp
`f280b26983ad0fdb705a0d9ebf0503e76f2899b0`. The earlier trace-only binary
closure is an exact retained binary with an unavailable exact source tree.
The committed source must not be used as retrospective source attribution for
that closure.

## Reconstructable source change

`patches/superseded/llama-cuda-dispatch-trace-force-mmvq.patch` is the exact
binary diff from the pinned base to commit `54f7f7a7`. The patch adds a
default-off route log and a forced MMVQ build mode. The retained commit changes
four files with 66 additions and four deletions and produces tree
`ca89214846cf056897a949059b11e92fcd01580c`.

`scripts/check-superseded-dispatch-telemetry-patch.sh` resolves the retained
target commit, requires its parent and tree to match the registered identities,
verifies the patch digest, checks the diff against a fresh checkout of the
pinned base, applies the diff, rejects whitespace errors, and requires the
replayed tree to equal the resolved commit tree. The fresh checkout stays under
the repository's ignored artifact root. The patch stays superseded. The current diagnostic census
records dispatch at graph granularity through
`patches/llama-cuda-dispatch-census.patch`, while the AD104 crossover patch
owns the measured MMVQ thresholds.

## Earlier trace-only binary closure

The earlier build log records base commit `f280b269`, a dirty tree summarized
as one file with 38 insertions, and linked outputs completed before the build
wrapper exited 127 in a later shell step. The binary predates commit `54f7f7a7`
and its source summary differs from that commit's four-file diff. The log
retains neither the dirty diff bytes nor a source-tree digest. The exact source
for executable digest
`d1f934b2dc03bddfb4881e953175ae7df4cd262ee08324320782ddb57dfd401c`
therefore reads `unavailable`.

The executable remains a binary authority. Existing records bind the
executable and nine repository-built libraries in
`evidence/lease-coverage/admission-preparation/telemetry-snapshot.json` and
`telemetry-loaded-libraries.tsv`. The retention operation copied the complete
`bin` output directory, its CMake cache, and its build log into the ignored
qwen-nvidia artifact store. The original path remains intact because tracked
evidence names it and this retention change rewrites none of those historical
records.

The private copy contains 21 regular files and 16 symbolic links. Ten runtime
members total 161397600 bytes. Its `SHA256SUMS` digest is
`65916cf59ac2989cd7a21667ff7e7f85bd9f333752e34944adce38a0326f520d`,
its symlink inventory digest is
`c41cd219348ef00b1b7bf37bdf0cbf8d7410bd223fe91f6efa262d0008e3035b`,
and its relocation receipt digest is
`e0bca05425c8754ab2c862498e870dab4c7d8e482d8022cafe6939c6b6afe034`.
All 21 regular-file checks passed after the copy, and recursive comparison
matched the source build output. The retention operation executed no binary
and changed no serving configuration.

## Boundaries

The source patch proves replay of commit `54f7f7a7`. The private copy preserves
the earlier binary bytes. Neither record reconstructs the dirty source that
produced the trace-only closure, promotes the superseded patch, or supplies a
new runtime or performance result.
