# Strict Vulkan Model Placement

## Mechanism

The pinned local llama.cpp fork adds the opt-in environment flag
`LLAMA_NO_CPU_FALLBACK=1`. The retained patch is
`patches/llama-no-cpu-fallback.patch`.

The model-loader gate examines the buffer selected for every model tensor. If
the selected buffer has no accelerator device or belongs to the CPU backend,
loading stops with the tensor name and buffer type. This converts llama.cpp's
ordinary compatibility fallback into a hard error.

The graph gate runs after scheduler allocation for every new graph topology.
It resolves the backend assigned to every operation node and stops before
execution if any node belongs to the CPU backend. Reused graphs retain the
already-validated placement.

The flag is unset by default, so the pinned upstream behavior is preserved for
ordinary invocations. The guarded laptop launcher will always set it.

`remote/radv-low-priority-env.sh` supplies the process boundary. It selects the
single RADV ICD through both the current and compatibility Vulkan-loader
variables, removes X11 and Wayland display variables, enables the LOW queue and
strict placement flags, removes Vulkan system-memory fallback, and enforces one
core with low CPU and I/O scheduling before executing its child command.

`remote/test-radv-low-priority-env.sh` passes ShellCheck and its remote
acceptance run. It observes affinity list `0`, nice level `19`, idle I/O,
unset display and system-memory-fallback variables, both strict flags enabled,
and only `AMD Radeon Graphics (RADV RAVEN2)` from offscreen enumeration.

## CPU boundary

The CPU backend remains compiled and initialized because llama.cpp requires it
for host buffers, control flow, sampling infrastructure, and data transfer.
The strict flag governs model tensors and graph operations. It does not claim
that tokenization, HTTP processing, queue submission, or copying final logits
to host memory occurs on the GPU.

## Validation result

The compiled fork passes three model-backed placement gates with the pinned
`stories15M-q4_0.gguf` fixture:

1. `--device none --n-gpu-layers 0` stops at `token_embd.weight selected CPU
   buffer CPU` before context creation.
2. `--device Vulkan0 --n-gpu-layers all` without a tensor override stops at
   `CPU fallback rejected for graph node embd (GET_ROWS)`. Complete layer
   offload alone therefore does not mean complete graph offload.
3. Adding `--override-tensor '.*=Vulkan0'` places the complete model buffer on
   `Vulkan0`; model, KV, and compute buffers report Vulkan placement, and a
   two-token completion returns HTTP 200 without a CPU-fallback rejection.

`remote/qwen-capacity-policy.sh` now fixes the all-tensor override in the closed
argument surface. `remote/test-strict-vulkan-placement.sh` reproduces the two
negative gates and the positive completion. The exact binary-level output is
retained in `evidence/llama-vulkan-runtime-validation.log`.

The fixture establishes the enforcement mechanism. Qwen3.5 and Qwen3.8 remain
separate admission targets: any unsupported tensor or graph operation is a
failed admission, not permission to weaken the strict flag.

Qwen3.5 first exposed a `VIEW` node labeled with the CPU backend during the
fused Gated DeltaNet reserve probe. GGML's scheduler defines `VIEW`, `RESHAPE`,
`PERMUTE`, and `TRANSPOSE` as view ops, excludes them from executable backend
splits, and implements them as `nop` in the CPU compute switch. The strict
guard now excludes only those metadata-only operations plus `NONE`. The
TinyLlama `GET_ROWS` negative control still fails, and Qwen3.5-4B reaches a
strict 4K allocation with all model, KV, and compute buffers on `Vulkan0`.
