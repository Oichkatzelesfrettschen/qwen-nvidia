# Raven2 Vulkan Duty-Cycle Policy

## Mechanism

`patches/llama-vulkan-duty-cycle.patch` adds an opt-in Vulkan graph pacer to
the pinned llama.cpp source. `GGML_VK_DUTY_CYCLE_PERCENT` accepts only decimal
integers from 1 through 100. An unset value or 100 preserves upstream async
execution.

When pacing is active, the wrapper also enables Vulkan's serialized-submission
path. Raven2's weak-AMD policy already divides a graph by node count and FLOP
budget. Each resulting command batch carries a fence; `submit_after()` waits
for that fence, measures the completed interval with a monotonic clock, and
sleeps for:

```
idle = ceil(active * (100 - target) / target)
```

The measured interval includes command construction, submission, and fence
completion. Treating that entire interval as active GPU time makes the duty
cycle conservative when CPU-side command work is present. The backend rejects
a duty-cycle target unless serialized submissions are also active.

The `paced-60` control fixes the model target at 60%. Its runtime monitor still
terminates the process when aggregate Raven2 busy time first exceeds 75%.
Raven2 reports one device-wide busy value that includes the compositor, so the
15-point gap reserves measured headroom for desktop work. LOW global queue
priority gives the compositor precedence between submissions, while
`--batch-size 128 --ubatch-size 32` also limits prompt-ingest graph size.

This control profile manages model submission duty at intra-graph fence boundaries. It
does not partition the GPU or promise that an individual command batch never
reaches full engine occupancy. The LOW queue, short microbatch, serialized
submission pacer, and aggregate abort form one responsiveness policy.

## Falsifiers

The policy fails if any of these observations occurs:

- an invalid percentage reaches graph execution;
- a paced submission sleeps before its fence completes;
- the calculated active share exceeds the configured percentage;
- the launcher exposes an inherited target instead of fixing 60%;
- the launcher permits pacing without serialized submissions;
- prompt ingestion uses a microbatch above 32 tokens; or
- an admitted run records aggregate GPU busy above 75%.

## Validation

`remote/test-vulkan-pacing-math.sh` compiles the shared pacing header with
`-Wall -Wextra -Werror -pedantic`. It verifies disabled behavior, accepted
boundaries, malformed-input rejection, and exact 75% and 60% idle intervals.
`remote/verify-llama-patch-series.sh` replays all four patches against commit
`f280b26983ad0fdb705a0d9ebf0503e76f2899b0` and verifies the resulting source
hashes. `remote/test-qwen-capacity-policy.sh` observes target 60 in the child
environment and the exact 128/32 batch arguments.

The priority-first daily candidate is specified separately in
`evidence/vulkan-priority-first-policy.md`. The first real Qwen3.5-4B startup falsified whole-graph pacing: model loading
sampled 32-37% busy, then the warmup graph sampled 97% before reaching its
end-of-graph sleep and the guard terminated the server. That observation moved
the sleep boundary into the already bounded serialized submission path. The
revised patch passes a real-model startup and HTTP request. The 34-token prompt
runs at 3.79 tok/s, generation runs
at 0.677 tok/s, and 31 request-window samples report 49.65% mean and 72%
maximum aggregate GPU busy.

`evidence/benchmarks/qwen35-4b-webui-serialized/summary.md` separates the exact
40% duty-sleep cost from the residual serialization, microbatch, and
short-prompt cost that the safe profile cannot isolate.
