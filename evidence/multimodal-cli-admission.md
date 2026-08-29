# llama-mtmd-cli in the Vulkan build

The appliance served images through `llama-server` alone. `libmtmd` was already
linked into that binary, so the projector path had exactly one consumer and a
wrong answer about an image could not be attributed between the projector, the
chat template, the request shape, and the server's own image handling.
`llama-mtmd-cli` is a second consumer of the same library reached without HTTP,
which is what splits those.

## What changed

`remote/build-llama-vulkan.sh` names it beside `llama-server` and `llama-cli`
and refuses a build that produced fewer than the three. The two Vulkan preset
arms in `remote/build-llama-preset.sh` carry it in `preset_targets` and
`preset_outputs`, so it is removed before compilation and its mtime is proven
past the build stamp like every other declared output, and
`remote/hash-load-closure.sh` puts it in the artifact manifest.
`remote/build-llama-on-workstation.sh` builds it in the container and ships it
with the rest of `bin/`.

`remote/promote-llama-build.sh` refuses a preset that produced no
`llama-mtmd-cli`, runs its `--version`, and reads one image through it.

## The build

```text
commit          f280b26983ad0fdb705a0d9ebf0503e76f2899b0
tree            build-qwen-vulkan, the pinned appliance build
target          llama-mtmd-cli, incremental against an existing tree
version         0.2.0-dev (build 1, commit f280b26)
compiler        GNU 13.3.0, Linux x86_64
load closure    executable llama-mtmd-cli 55610680
                96e01162de9b4f5c1ebbaed246ad9cfe8964812c6e006c468df9cf44322cba52
```

The closure holds one object. The appliance builds `-DBUILD_SHARED_LIBS=OFF`,
so the backend is inside the executable rather than dlopened beside it.

## The image smoke

`remote/select-projector.sh` resolves `mmproj-F16.gguf` from the checkpoint's
own directory, and the run reads `remote/quality-images/shapes.png`, which
`remote/generate-quality-images.py` draws as a red square, a green circle, and a
blue triangle:

```text
The colours of the shapes in the image are:
- **Red** (square)
- **Green** (circle)
- **Blue** (triangle)
```

Three colours and three shapes, each paired correctly. The gate requires two of
the three declared colours rather than three, which refuses a reply carrying no
image content while leaving room for a model that describes the image in fewer
words than it holds shapes.

## Why the gate reads an image rather than checking that the binary runs

A projector fails by answering. One of matching dimensions loads cleanly and
writes image tokens into the embedding space of a model that reads nothing
there, so the reply is fluent and wrong. `--version` and a text token cannot see
that; an image whose content this repository declares can.

## The text smoke did not run, and the mechanism says why

`tools/mtmd/mtmd-cli.cpp:403` sets

```cpp
bool is_single_turn = !params.prompt.empty() && !params.image.empty();
```

so a single-shot run requires a prompt **and** an image. `--prompt` alone enters
the interactive chat loop, which emitted eight `> ` prompts over eight minutes
and answered nothing, and closing stdin did not end it either. A text smoke
through this binary is therefore not an available invocation at this commit
rather than a check that was skipped. The image form terminates on its own and
is what the promotion gate runs.

`llama-cli` remains the text consumer of the same tree and the strict Vulkan
one-token check in the promotion gate is unchanged.
