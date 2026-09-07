# The lease-off companion build and the isolation it is held to

The candidate closure `15bc632adf7f` carries
`patches/llama-server-vulkan-workload-lease.patch` and the promoted closure
`88681bf4d161` does not, so a rate or behavior difference between the two
confounds the lease change with every other difference their source carries.
`source-provenance/` closed that confound at the source level: the candidate
reconstructs exactly from the checked-in patch files, the historical production
source reconstructs from no retained patch tree, and the replacement baseline is
the candidate's own sequence with the lease patch removed. That companion's
source is `ca47669a0f45f82348832ac35991f9127143f38f63f2217cd0a916e6c10eea7d`,
differing from the candidate's
`76f4b8e888cde28f354482e4fea3d91e609ce634fb9d6654608b68f496a96768` by
`tools/server/server-context.cpp` at 331 insertions and no deletion in one
file, and reapplying the patch reproduces the candidate's recorded digest.

A source-level result is not a binary, so this directory carries the build and
the object comparison that turn it into one.

## What is predicted, and what refutes it

The two trees differ in one host translation unit. `build-configuration.tsv`
records the same value for every field except `source_diff_sha256`, so the
compiler, the host compiler, the CUDA architecture, both MMVQ thresholds, the
tiling threshold, and every CMake option are held equal by the configuration
digest rather than by assertion.

```text
prediction   libggml-cuda.so is byte-identical between fd27a84d9199 and
             15bc632adf7f, and so is every cubin the payload carries
prediction   the objects that differ are the server translation unit and the
             artifacts that link it
refutation   a differing CUDA object or a differing cubin, which places the
             lease change on the device path rather than in host server code
```

A cubin count that agrees states that two builds emitted the same number of
objects rather than the same kernels, so the count is reported beside the
digests rather than in place of them.

Byte-identity has two sources and they are distinguished rather than merged.
An object compiled independently to the same bytes is a stronger reading than
one restored from a compiler cache, which establishes preprocessed-source
equality alone. The build therefore runs against an isolated read-only ccache,
which reaches no shared entry, and `build-result.tsv` records the cache mode
beside the exit status.

## What the build does not establish

The companion is not the historical production source and carries none of the
candidate's served admission. `88681bf4d161` stays the behavioral regression
reference and stays promoted; `15bc632adf7f` stays unpromoted. The build
executes nothing it produced, because `llama-bench` and `llama-server` call
`ggml_backend_load_all()` ahead of parsing argv and a closing `--version` print
therefore opens a CUDA context inside a compile.

## What the build emitted

`scripts/build-llama-cuda.sh` built the tree at
`$HOME/src/llama.cpp-lease-off-companion` under `QWEN_CUDA_ARCHITECTURES=89-real`
against an isolated read-only ccache, and `build.log` is its output.

```text
configuration_id     fd27a84d9199, the value the dry run predicted
source_diff_sha256   ca47669a, the companion source the provenance run derived
patch_series_sha256  3d5f301750bd, equal to the candidate's
builder_sha256       e7dc827b, equal to the candidate's
cubin                187      ptx 0, the counts the candidate and the promoted
                              closure carry
build_exit           0        runtime_execution not_run reason=build_only
```

`build-configuration.tsv` differs from the candidate's in `source_diff_sha256`
and in nothing else, so the compiler, the host compiler, the CUDA
architecture, both MMVQ ceilings, the tiling threshold, and every CMake option
are held equal by the configuration digest rather than by assertion.

Today's invocation ran eight ninja edges, all of them UI provisioning and
stamps, and relinked nothing: every file in `bin/` keeps its timestamp from the
compile the prior run recorded. The 187 cubins therefore come from that
compile, which `build-result.tsv` records as running against an isolated
read-only ccache, and today's run re-derived the configuration digest and
re-verified the payload rather than rebuilding it.

The objects were compiled independently rather than restored from the
candidate's compiler cache, and the cubins carry the positive proof. nvcc
writes the translation unit's absolute path into `.nv.global.init`, so a cubin
restored from a candidate cache entry would name the candidate tree.

```text
companion cubins naming the companion tree   116 of 187
candidate cubins naming the candidate tree   116 of 187
cubins carrying no llama.cpp path at all      71 of 187, each side
companion cubins naming the candidate tree     0
candidate cubins naming the companion tree     0
```

The 71 are the kernels whose sources place no `__FILE__` in device global data.
What the count establishes is the absence of cross-contamination in both
directions rather than a path in every cubin.

## What the isolation established

`scripts/compare-closure-isolation.py` reads the pair over three questions and
`isolation/` carries its rows.

```text
configuration_axes        1, source_diff_sha256 alone
differing_sources         1, tools/server/server-context.cpp
transitive_consumers      41
device_targets_reached    0
artifacts reached         bin/libllama-cli-impl.so, bin/libllama-server-impl.so,
                          bin/llama-cli, bin/llama-server
device_code               identical
```

The reachability reading is what a byte comparison would have been asked for.
Ninja records every edge, so the transitive consumer closure of
`server-context.cpp.o` is the exact set of targets the lease change can reach,
and no ggml or CUDA target is inside it. The reading holds whatever the
absolute build paths are, which is what a byte comparison here does not.

`llama-cli` is in that set beside `llama-server`, because
`tools/server/libserver-context.a` links into `bin/libllama-cli-impl.so` at
this pin. A reader expecting the lease to reach the server alone reads one
artifact too few.

The device-code reading compares 15052727 lines of `cuobjdump -sass` per side
and they are identical. Six symbols differ ahead of that normalization and all
six are internal-linkage entities whose `_INTERNAL_<hex>_<len>_<unit>` module
identifier nvcc derives from the translation unit: `binbcast.cu`, `unary.cu`,
`convert.cu`, `set_rows.cu`, `cpy.cu`, and `getrows.cu` pair one-to-one across
the two closures with distinct hashes and identical unit names.

## A byte comparison of linked artifacts is unavailable here

Every artifact in `bin/` differs between the two closures, `libggml-base.so`
included, and that library shares no source difference at all. The cause is the
build path rather than the code: both libraries are 938656 bytes and each
embeds nine absolute source paths naming its own tree. The same contamination
reaches the device payload, where nvcc writes `__FILE__` into
`.nv.global.init`, which is initialized device global data rather than a
strippable debug section.

So a linked-artifact byte comparison between two closures in this repository
requires equal build paths, which no procedure here provides, and the reader
reports `artifact_byte_comparison=unavailable reason=build_paths_differ`
rather than reporting a difference it cannot attribute. Removing the
contamination is a build change rather than a reading change:
`-ffile-prefix-map` on the host compiler and its nvcc counterpart would make
artifacts comparable and would move the bytes of every closure this tree has
retained.

## The closure name depends on the checkout it was built from

The first launch of this build named itself `68ccb587c586` rather than
`fd27a84d9199`, on source whose digest read `ca47669a` either way.
`build-llama-cuda.sh:243` computes

```sh
patch_series_sha256=$(sha256sum "$script_directory"/../patches/*.patch |
    LC_ALL=C sort | sha256sum | cut -d ' ' -f 1)
```

and `sha256sum` prints the pathname beside each digest, so the field digests
the patch series together with the absolute path of the checkout that held it.
Read from the primary checkout the field is `3d5f301750bd`, the value the
candidate and the companion both record; read from a worktree of the same
commit it is `a9f5ff334d83`. The patch bytes are equal from both, at
`ce15de854cba`.

The field enters the configuration digest, so the twelve-hex closure name that
`serving-closures.tsv` carries and that the promotion program compares against
is a property of where the checkout sits as well as of what it contains. Every
retained closure name was computed from the primary checkout, and the branching
rule puts repository work in a worktree, so a build launched the way this
repository asks for branch work carries a name no ledger row matches. The
companion here was therefore built from the primary checkout, which reads the
recorded value and reproduces the predicted name.

Making the digest path-independent is a one-line change -- read the directory
from inside it so `sha256sum` prints basenames -- and it moves the
configuration digest of every future build, so `88681bf4d161`,
`15bc632adf7f`, and `fd27a84d9199` would no longer be the names their own
sources produce. That trade belongs to the promotion program rather than to
this build, and the defect is recorded here rather than repaired.

## The reader's own arms decide something

`scripts/test-compare-closure-isolation.py` holds the reader to fixtures whose
answer is declared, and `isolation-mutation-summary.tsv` records what each arm
discriminates: seven mutations, each reverting one mechanism, each failing
exactly the arm that names it and no other, with the reader restored
byte-identical after every one. M7 fails two arms because both rest on the
module-identifier normalization producing agreeing device code.

M4 is the arm that matters most, and it exists because the first version of this
reader failed it. That version computed

```python
isolated = device_reached == 0 and device_verdict in ("identical", "not_run")
```

so a run invoked with `--skip-device-code` printed `device_path_isolation=held`
with the device payload unread, and a run on a host without `cuobjdump` printed
`refuted` for a missing tool. One binary verdict produced a false positive and a
false negative, which is the same positive-classification-from-absence the drain
tranche closed eleven times. The verdict is three-valued for that reason:
`held` requires every differing source traced, both graphs agreeing, no device
target in any consumer closure, and a device reading that ran and agreed;
`refuted` names a reading that contradicts the isolation; `not_established`
covers a device payload that was not read, a source ninja traces to no object,
and two graphs that disagree. The quality gate runs the reader against fixtures
alone, so the arm that the gate exercises now states what it did not read.
