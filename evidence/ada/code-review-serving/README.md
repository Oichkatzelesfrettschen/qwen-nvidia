# Serving a code reviewer on AD104

Which local model serves an adversarial code review of Mesa driver C on this
appliance, measured rather than assumed. The reviewer replaces an external
service when that service is unavailable, so it carries the same calibration
requirement any verdict-producing tool does.

## Device state at measurement

`nvidia-smi` reports 12282 MiB total with 1393 MiB resident before serving, so
10284 MiB is free to a server. `lspci -v` on 0000:0b:00.0 shows a 16G
prefetchable 64-bit BAR, so resizable BAR and above-4G decoding are active and
the whole frame buffer is CPU-mappable. Host memory is 31 GiB with 19 GiB
available.

## Rows

| model | quant | file GiB | placement | context | decode t/s | serves a review |
|---|---|---|---|---|---|---|
| Qwen3.8-9B-Distill | Q4_K_M | 5.4 | resident, `-ot .*=CUDA0` | 32768 | interactive | yes |
| Qwen3.8-27B | UD-IQ4_XS | 13.3 | `GGML_CUDA_ENABLE_UNIFIED_MEMORY=1` | 16384 | 0.58 | no |
| Qwen3.8-27B | UD-IQ3_XXS | 10.18 | resident attempt | 8192 | n/a | no |

The IQ4_XS row loads: 11810 MiB of device memory plus host spill, GPU at 100
percent utilization, and `llama_server` reports a steady `tg = 0.58 t/s`. A
700-token review therefore costs about twenty minutes, which is why the row
reads no. Unified memory is what makes a 13.3 GiB model run on a 12282 MiB
device at all; the cost it charges is decode rate.

The IQ3_XXS row does not load. The file is 10.18 GiB against 10284 MiB free, so
the weights fit and the KV cache and compute buffers do not:
`common_init_: failed to create context with model`. Reducing context does not
recover it, because the residual after weights is smaller than the smallest
usable context. The 27B is reachable on this device only through unified
memory, and unified memory is what the first row already prices.

## Calibration

A reviewer is a verdict-producing tool, so it runs against a known-bad and a
known-good before its output is trusted. Both fixtures are a real defect and
its real fix from the r3v fill-route work, so ground truth is known:

- known-bad: a `GPU_ONLY` policy branch demanding `device_submission` at a
  phase where an invariant above already forces that flag false, which refuses
  the prepared record the policy exists to admit.
- known-good: the same branch with the demand removed and the invariant named.

The 9B separates them: `VERDICT: DEFECT` on the first, naming the guard that
blocks the case it exists to permit, and `VERDICT: CLEAN` on the second.

The first framing of the system prompt failed calibration in an instructive
way. Asked only whether the code was correct, the model reasoned correctly that
a `GPU_ONLY` caller at `PHASE_PREPARED` "can never pass" and then labeled that
`CLEAN`: it judged internal consistency and stopped. The prompt now states that
a rule which always refuses, a branch that cannot run, or a guard that blocks
the case it exists to permit is a defect even when the code is self-consistent.
Fitness for the caller is the question; self-consistency is not.

## Reproducing

    llama-server -m ~/models/Qwen3.8-9B-Distill-GGUF/Qwen3.8-9B-Q4_K_M.gguf \
      --device CUDA0 -ot '.*=CUDA0' -ngl 99 \
      --ctx-size 32768 --cache-type-k q8_0 --cache-type-v q4_0 -fa on \
      --host 127.0.0.1 --port 18086 --no-webui

`--device CUDA0` and `-ot .*=CUDA0` are both required: the card enumerates as
CUDA0 and Vulkan0, and a launch naming neither risks the scheduler placing
tensors on the Vulkan device for the same card.

The server binary is the telemetry closure under
`~/worktrees/llama-cpp-ad104-dispatch-telemetry/build-qwen-cuda-sm89-telemetry`,
build 1935, commit f280b2698, built with GNU 15.3.0.

## Where the reviewer false-positives

A review whose evidence lies outside the prompt produces a confident wrong
verdict rather than a request for more. Asked whether an appended ledger's rows
chained -- each row's `previous` must equal that thread's last recorded
`evidence` -- and given the diff alone truncated at 120 lines, the 9B answered
`VERDICT: DEFECT` and described a break it could not have seen: the prior rows
that establish each chain were above the truncation.

An independent pass over all 204 rows found zero chain violations and zero
duplicates, and the repository's own checker, which had failed loudly on
`previous commit differs` while the chaining really was wrong, passed.

The rule this sets: give the reviewer a self-contained artifact, or give the
question to a deterministic checker. A whole-file diff, a function with its
callees, or a single claim with its surrounding invariants is reviewable; a
window cut out of a longer ordered structure is not, and the model does not
say so. A truncated prompt is an unsound denominator in the same way a gate
that examines an empty set is.
