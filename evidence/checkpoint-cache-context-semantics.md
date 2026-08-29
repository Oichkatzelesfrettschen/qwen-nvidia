# llama.cpp Checkpoint, Cache, and Context Semantics

## Authority

This audit covers llama.cpp commit
`f280b26983ad0fdb705a0d9ebf0503e76f2899b0`. No executable exists from that
checkout yet, so generated `llama-server --help` verification remains a build
gate. The option declarations and server implementation establish the source
semantics below.

## Defaults and option names

`common/common.h` and `common/arg.cpp` define these server defaults:

| Option | Default | Source meaning |
|---|---:|---|
| `--ctx-checkpoints N` | 32 | Maximum context checkpoints retained per slot. Zero disables them. |
| `--checkpoint-min-step N` | 8192 | Minimum token spacing used when selecting and pruning checkpoints. Zero removes the spacing minimum. |
| `--cache-ram N` | 8192 MiB | Maximum prompt-state cache size. Zero disables it; `-1` makes it unbounded. |
| `--context-shift` / `--no-context-shift` | disabled | Enables or disables removal and position shifting when generation fills the context. |

`--checkpoint-every-n-tokens` is not registered by `common/arg.cpp` and does
not exist in this revision. The applicable control is
`--checkpoint-min-step`.

## Context checkpoints

`tools/server/server-context.cpp` creates checkpoints only for completion
tasks and only when the memory topology requires a saved non-rollback state,
including hybrid recurrent contexts. The server:

- stores checkpoints per slot;
- creates checkpoints near prompt boundaries and qualifying user-message
  boundaries;
- uses the minimum step when pruning or deciding whether another ordinary
  checkpoint is sufficiently far away;
- permits boundary-specific exceptions for the active task, final user
  message, or prompt end; and
- removes the oldest checkpoint before the per-slot maximum would be exceeded.

Each Qwen3.8 checkpoint uses `LLAMA_STATE_SEQ_FLAGS_PARTIAL_ONLY`. The hybrid
state writer omits the full-attention KV cache and serializes the recurrent
state into a host byte vector. Exact Qwen3.8 payload accounting is in
`evidence/qwen38-checkpoint-memory.md`.

The checkpoint maximum and minimum step serve different purposes. Four
checkpoints with an 8192-token minimum step means at most four saved recurrent
states, not a guaranteed checkpoint every 8192 tokens.

## Prompt RAM cache

The prompt RAM cache is a separate server subsystem. It saves prompt tokens,
full target state, optional draft state, and copies of the prompt's context
checkpoints. Its size limit accounts for the serialized state and checkpoint
payloads. A cached prompt can therefore duplicate state already retained by an
active slot.

`--cache-idle-slots` defaults to enabled but requires the RAM cache. When
`--cache-ram 0` is selected, server initialization disables idle-slot caching.
The one-shot capacity profile must set `--cache-ram 0` so prompt-state copies
cannot consume the desktop reserve.

## Context shift

Context shift is disabled by default in the selected revision. The explicit
`--no-context-shift` flag makes the capacity-test invariant visible in retained
commands.

With context shift disabled, the server stops generation and marks the result
truncated when the next token would exhaust the slot context. It does not
discard old tokens. With context shift enabled, the server retains a configured
prefix, removes a middle range, shifts later positions, clears checkpointed
prompt bookkeeping, and continues. That mutation makes a filled-depth test no
longer represent the original 128K sequence, so it remains excluded from
capacity and fidelity runs.

## Admission checks after the build

The generated binary must still prove:

1. `llama-server --help` reports defaults 32, 8192, 8192 MiB, and context shift
   disabled.
2. `llama-server --help` lists `--checkpoint-min-step` and does not list
   `--checkpoint-every-n-tokens`.
3. A parser-only invocation rejects `--checkpoint-every-n-tokens`.
4. Startup traces with `--ctx-checkpoints 0 --cache-ram 0
   --no-context-shift` report both cache systems disabled.
5. A context-limit test stops without a context-shift trace.

Any failed check reopens this source audit before model-capacity testing.
