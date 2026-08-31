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

## What the suites prove and what remains

`scripts/test-coding-agent-service.py` (35 checks) runs the service as the
current user against a temporary mirror root with
`scripts/test-fixtures/fake-coding-agent.sh` standing in for the pinned
runtime, each job's behavior selected by the base commit it was approved
over. It admits the full worktree-edit-test-diff-teardown chain and the
negatives: refused profile, grant tamper on model, base commit, workspace,
and instruction, replay, expiry, traversal, absolute path, symlink escape,
file-count and patch-byte bounds with worktree reset, deadline kill of a
TERM-resistant child, cancellation with late-result refusal, `git push`
with no destination, worktree and bundle residue absence, and the
authoritative repository untouched throughout.
`scripts/coding-mcp/test-coding-mcp.py` (15 checks) drives the stdio child:
the listing states the profile's own bounds, the six tools run one full
chain, and unknown tools, unknown arguments, and ungranted opens are
refused as isError results.

Three checks are reported not-run here and belong to the on-appliance
admission: uid separation, sudo denial for the principal, and the
uid-scoped network egress rule. Every `scripts/coding-profiles.tsv` row
reads `execution_policy=refused`, so the lane executes nothing until those
gates and the full-chain admission pass and a reviewed edit moves a row to
`validator-gated`.
