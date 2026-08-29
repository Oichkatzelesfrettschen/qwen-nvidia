# Quarantined model: Nanbeige4.2-3B

```text
id             nanbeige42-3b
scope          model
subject        nanbeige42-3b
model file     Nanbeige4.2-3B-GGUF/Nanbeige4.2-3B-Q4_K_M.gguf
failure class  no-validated-safe-tuple
tuple          unbounded; no geometry of this checkpoint has been validated at depth
first evidence evidence/kv-cache-policy-factorial.md
latest evidence evidence/model-admission/nanbeige42-3b-admission.md
```

## The ground of the quarantine

`validated_filled_depth` is `-` for this row. Every depth this checkpoint has
been measured at is depth 0: `llama-bench tg64` against a near-empty cache
returned 2.38 decode and 14.06 prefill tok/s. No served depth has been filled
and decoded, so no tuple of this checkpoint carries the property the tier
`candidate` asserts.

That alone is decisive and does not depend on the reset record below.

## The reset claim and what retains it

`remote/models.tsv` carried, and `evidence/kv-cache-policy-factorial.md`
repeats, that 16384 wedged the amdgpu compute ring under Nanbeige with an f16
cache. The factorial file cites it twice: it names "a compute-ring timeout at
that depth" measured "during the Nanbeige ladder", and it distinguishes that
event from its own d16384 wedge by the absence of a coredump -- "Unlike the
Nanbeige wedge, the driver produced a coredump".

**The arm's own record is not retained.** Searching `evidence/` and the
appliance's probe directories finds ring-reset and `ErrorDeviceLost` lines in
`qwen-kv-cache-factorial/d16384-kq8_0-vq4_0-faon.log`,
`qwen-kv-cache-factorial/factorial-summary.tsv`, and
`qwen-depth-wedge-preprotocol/wedge-summary.tsv`, all of which are Qwen 4B arms.
No Nanbeige ladder output, kernel delta, or summary row survives. The reset is
therefore an assertion carried forward in prose rather than a retained
measurement, and it is recorded here at that evidence class. It is not the
ground of this quarantine and it is not treated as one.

The failure class is `no-validated-safe-tuple` for that reason. Were the reset
record retained, the class would be `ring-timeout-only`, matching the
distinguishing detail the factorial file gives.

## The confound the 4B result now exposes

Both wedges this tree recorded were found under `llama-bench` at its own
defaults, `-b 2048 -ub 512`, while the guarded server runs `--batch-size 128
--ubatch-size 32`. `evidence/depth-versus-submission-geometry.md` resolved that
confound for the Qwen3.8-4B distill: at 16384 the harness geometry wedged the
ring and the served geometry completed twice, so submission geometry rather than
depth decided the outcome.

The Nanbeige wedge, if it occurred, was found at the harness geometry and has
never been repeated at the served one. The 4B result makes it likely that the
same exoneration applies. Likely is not measured, and this checkpoint has no
depth measurement of any kind to stand on.

## Why the checkpoint would not serve even if the gate were met

`nanbeige.cpp` reads `{arch}.num_loops` and sets `n_layer_all = n_layer_phys *
n_loops`, so 22 physical layers run twice per token over one copy of the
weights. Per-token traffic is 4.149 GB against the 4B distill's 2.698, and every
one of the 44 effective slots keeps its own KV index against 8 full-attention
layers in the 32-layer Qwen hybrid, which is 73,216 bytes of cache per token of
context against 13,312. At 24576 tokens that is 1716 MiB against 312, and the
attention read grows with the same factor, so the gap widens exactly where an
agent workload lives.

Measured, it is slower than the 4B on both halves while being nominally
smaller -- 2.38 against 3.07 decode, 14.06 against 23.48 prefill -- and four
times slower than the 2B.

## Re-entry gate

Nanbeige returns from `quarantine` to `candidate` when every one of the
following holds:

- Two passes at its declared maximum served depth, which is 8192 under the
  current ceiling.
- The tuple is explicit: `q8_0`/`q4_0`, Flash Attention on, batch 128, ubatch
  32, at 8192 filled and decoded.
- Zero ring resets, page faults, VM protection faults, and device losses across
  both passes.
- Both post-arm controls pass at the served geometry.
- Desktop latency stays inside the policy `remote/qwen-webui-session.sh` arms.
- The 55-row graded suite passes its admission threshold, which has never run
  against this checkpoint.

`remote/probe-depth-wedge.sh` runs that arm directly with
`QWEN_WEDGE_DEPTHS=8192` and the served geometry, and it retains the kernel
delta, the fault counts, the allocation peaks, and the post-arm control that the
gate reads.

Promotion past `candidate` needs the quality suite to place it against the
incumbents, not merely to pass. The loop is a good trade where bandwidth is
abundant and memory is scarce; this machine has 29 GiB of DDR4 against 34.13
GB/s theoretical peak, which is the other case.
