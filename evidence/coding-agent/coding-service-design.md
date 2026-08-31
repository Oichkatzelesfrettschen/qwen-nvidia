# The bounded coding-agent service

The service owns what the agent runtime must never decide: job identity,
repository selection, the base commit, the worktree path, model selection,
timeouts, the process group, resource limits, cancellation, result
retention, and teardown. `scripts/coding-agent-service.py` listens on a
mode-0600 Unix socket, `scripts/coding-mcp/server.py` is the one
browser-facing surface, and the four authorities --
`scripts/coding-profiles.tsv`, `coding-workspaces.tsv`, `coding-models.tsv`,
`coding-quarantine.tsv` -- are validated whole per request the way the
model and quarantine registries are.

## The job lifecycle

A job opens against a single-use HMAC grant bound to the action, workspace,
repository identity, base commit, model, profile, instruction hash, allowed
test profile, the three bounds, conversation generation, expiry, and nonce;
a changed model, workspace, base commit, instruction, or test profile
invalidates the signature, and the nonce ledger spends the grant once. The
approved base revision travels into the bare mirror under
`/var/lib/qwen-coder/repos/` as a bundle carrying a job-scoped export ref,
so the principal reads only the bundle and the mirror gains exactly the
approved commit; the worktree is detached, ephemeral, and lives under the
principal's own `worktrees/` root, keeping every writable index and
administrative file outside the authoritative `.git`. Finish exports patch,
diffstat, changed files, test log, event stream, base commit, and result
tree hash, then removes the worktree; the authoritative checkout changes
only when a human applies the exported patch.

## Containment

The agent runs in a fresh session and process group with a scrubbed
environment (`HOME` is the worktree, `PATH` is `/usr/bin:/bin`, git prompts
and global config off), CPU, file-size, and descriptor rlimits, and the
profile's wall deadline; expiry SIGTERMs the group and SIGKILLs survivors,
so a TERM-trapping child dies on the escalation. Path access resolves
inside the worktree: absolute paths, `..` traversal, and symlinks pointing
outside are each refused by name. `code_run_tests` executes the one command
the profile's `allowed_test_profile` maps to in the service source, never a
caller-composed command, and the browser-facing tool set carries no generic
shell. A child that leaves its process group survives the group kill, so
`coding-agent-teardown.sh` ends every process of the principal by uid --
the account exists for this lane alone, which is what makes the uid-wide
kill exact.

## The full-chain repairs

Eight defects the fixture-driven suites could not expose were repaired
ahead of the full-chain admission, each now carried by its own check.
`preexec_fn` is gone from the threaded service: `start_new_session=True`
establishes the fresh session through the supported `Popen` mechanism and
`prlimit --cpu --nofile --fsize` applies the limits inside the executed
child path, the same threaded-process hazard `image-service.py` removed.
The runtime ledger is its own execution authority: `admit_profile` requires
`coding-runtimes.tsv` to read `validator-gated` beside the profile, and the
profile's `allowed_test_profile` must equal the workspace's own
`test_profile`. Every signed grant field is compared against live state:
`repository_identity` against the workspace row's new column,
`conversation_generation` against the request, base commit against the
resolved repository. The executed agent path is
`scripts/coding-agent-launch.sh`, run as the principal inside the
containment: it verifies the loopback `/v1` endpoint and the mode-0400/0600
appliance-local key at `/run/qwen-coder/llama-api.key`, installs the
service-owned settings into the worktree-scoped home, scrubs ambient
provider variables, selects `--approval-mode plan` for a plan run against
`yolo` for apply, and keeps the key in the environment alone
(`scripts/test-coding-agent-launch.sh`, 11 checks). `finish` stages with
`git add -A` before `write-tree`, reproduces the result tree independently
by applying the exported patch to the base tree in a temporary index
against the authoritative repository, refuses a mismatch, and returns
`export_id`, `result_tree`, `patch_sha256`, and `test_log_sha256` with the
machine-local path kept on the service side of the socket. Transfer
residue is proven absent: the export ref deletion runs on both bundle
outcomes and again at startup recovery, the mirror's `refs/import/<job>`
dies with the worktree, and the bundle crosses the ownership boundary as a
principal-owned mode-0600 copy under the 0700 `handoff/` directory.
Operations serialize per job through a nonblocking `operation_lock`
answered `job_busy`, with cancel killing the group first and then taking
the lock for cleanup. Model-visible results are bounded to 16 KiB of plan,
32 KiB of inspect window with an `offset` paging argument, a 32 KiB test
tail, and a 64 KiB diff view, each beside a truncation flag, while the
full outputs remain in the events and the finish export.

## What the suites prove and what remains

`scripts/test-coding-agent-service.py` (47 checks) runs the service as the
current user against a temporary mirror root with
`scripts/test-fixtures/fake-coding-agent.sh` standing in for the pinned
runtime, each job's behavior selected by the base commit it was approved
over. It admits the full worktree-edit-test-diff-teardown chain and the
negatives: refused profile, refused runtime, test profile outside the
workspace, grant tamper on model, base commit, workspace, repository
identity, conversation generation, and instruction, replay, expiry,
traversal, absolute path, symlink escape, file-count and patch-byte bounds
with worktree reset, deadline kill of a TERM-resistant child, cancellation
with late-result refusal, concurrent-operation `job_busy`, the
tracked-file-only result tree departing from the base tree, `git push`
with no destination, worktree, bundle, handoff, export-ref, and import-ref
residue absence, and the authoritative repository untouched throughout.
`scripts/coding-mcp/test-coding-mcp.py` (20 checks) drives the stdio
child: the bare tool names compose with the section's `code` key into
`code_plan` through `code_cancel` at the router, the listing states the
profile's own bounds and marks `finish` and `cancel` as browser-session
controls, five model-facing tools plus the two controls run one full
chain, and unknown tools, unknown arguments, and ungranted opens are
refused as isError results.

The three checks the unit suite reports not-run are admitted on the
appliance by `scripts/test-coding-principal-path.sh` (5 checks, accepted
2026-08-31): one job through the real qwen-coder principal leaves its
worktree owned by qwen-coder and finishes clean, `sudo -n` from that
account dies at the policy, and with `scripts/setup-coding-egress.sh
apply` in force the nftables output hook drops the principal's external
traffic by socket uid while loopback passes -- the rule binds the account,
so a double-forked child that left the process group is still contained.
Prompt injection in repository text is contained by the same bounds every
job runs under: the injected instruction can steer only what the grant
already authorized, inside the worktree, under the profile's file, byte,
and time ceilings, with no shell tool offered to the browser. Every
`scripts/coding-profiles.tsv` row reads `execution_policy=refused`, so the
lane executes nothing until the full-chain admission passes and a reviewed
edit moves a row to `validator-gated`.
