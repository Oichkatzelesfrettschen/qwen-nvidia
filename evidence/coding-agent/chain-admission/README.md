# One full worktree-edit-test-diff-teardown chain, admitted

`scripts/admit-coding-chain.sh` ran the whole coding lane on the appliance
with every real link in place: the promoted llama-server
(closure 88681bf4d161, CUDA0) serving `qwenseer-2b` in router mode on its
own port beside the ordinary session, the approval broker signing the two
coding grants, the coding MCP child on the router's `/tools` routes, the
coding-agent service under the `qwen-coder` principal with the uid-scoped
egress rule applied, and the pinned Qwen Code v0.22.3 installed under
`/var/lib/qwen-coder/runtime` executing plan and apply inside the
ephemeral mirror worktree. `summary.tsv` carries the 36 checks, all
accepted; the checked-in coding authorities stayed `refused` throughout,
the admission set being a copy that moved exactly `code-fast-a` and the
`qwen-code` runtime row to `validator-gated`.

## What the run proves

The deterministic fixture is one declared value and the one assertion
that reads it. The replayed request sequence and the served page each ran
the chain once, and both produced the same patch
(`4d8306ee84fa25db1dade8ba87ec7346825bc85399c6d27c340cb7e3fa58a7cc`) and
the same result tree (`f5459c5cd33bc698ad09becc40a819ae0fd21e32`): Qwen
Code, driven by `qwenseer-2b` over the loopback `/v1` endpoint at
temperature 0, edited `declared-value.txt` from 41 to 42 and the
assertion beside it, the worktree's own test run passed on the edited
tree (`declared-value-check=pass value=42`), and the exported patch
applies cleanly to the base commit and reproduces the reported result
tree in a temporary index against the authoritative repository -- the
independent reproduction, not the service's word.

Each refusal the design rests on ran once: a replayed plan grant, an
apply without a grant, an apply grant over a foreign plan hash, a
replayed apply grant, a foreign job id, and a late result after
cancellation. The teardown proves absence: socket, worktree, transfer
bundle and handoff copy, `refs/coding-export/*` in the authoritative
repository, `refs/import/*` in the mirror, with the authoritative HEAD
unchanged and the tree byte-identical by content digest.

In the page arm (`page-summary.json`), the served `webui/index.html` in
headless Chromium selected `qwenseer-2b`, and the model proposed the
four-step sequence itself -- `code_plan` with the instruction alone,
then `code_apply_patch`, `code_run_tests`, and `code_review_diff` on the
returned job id -- through both approval dialogs: the plan dialog naming
the instruction, workspace, server-resolved base commit and subject,
model, profile, bounds, and test profile, and the apply dialog naming
the 64-hex plan hash the grant was signed over. The finish ran from the
job card's own browser control and rendered the export identity, result
tree, and patch digest; every page request stayed on the router and
broker origins, and the transcript carries no grant material.

## What the model needed

`qwenseer-2b` proposes a schema-valid `code_plan` unprompted, but left to
a vague turn it spends its continuation rounds on `code_inspect` and
never reaches the apply: the first page run timed out waiting for the
apply dialog while the model re-issued glob inspects. The accepted run's
turn names the sequence explicitly -- "Call code_plan exactly once with
the instruction: set VALUE to 42 in declared-value.txt and change
expected=41 to expected=42 in check-value.sh. When the plan result
returns, immediately call code_apply_patch with the returned job_id.
After the patch result, call code_run_tests with the same job_id, then
code_review_diff. Never call code_inspect." -- passed as
`QWEN_CODING_PAGE_PROMPT`, which is a statement about this checkpoint's tool
discipline -- its registry `raw_tool_selection` is unmeasured -- rather
than about the chain. The lane's bounds held either way: the undirected
run consumed only refused inspects and its job died on Clear-equivalent
cancellation with no residue.

## Two runtime prerequisites the run established

Qwen Code v0.22.3 refuses non-interactive runs without an auth type, so
`scripts/qwen-code-settings.json` names `security.auth.selectedType:
openai` beside the model providers. And sudo resets the environment
across the identity switch, so the service delivers the contained
environment as `env -i` assignments inside the executed command line;
the child starts with exactly the declared dictionary under both
principal modes. Git reads `info/exclude` from the common dir alone, so
the worktree exclude that keeps `.qwen/` runtime state and `.job-tmp/`
out of the exported diff is written through `--git-common-dir`.

## Falsifiers

A patch digest differing between the replay and page jobs would report
nondeterminism in the agent path. A result tree the temporary-index
reproduction cannot produce from the exported patch would report an
export that misstates the worktree. Any of the six refusals answering
success, or any teardown check finding residue, rejects the run;
`summary.tsv` is the check-by-check record and the fixture arm of the
same harness runs in `repository-quality-gates.sh` on every clone.

## The deep-coder condition refuted itself at 8192

The same chain ran against `qwen25-coder-7b` at its validated 8192 depth
(`deep-coder-8192-summary.tsv`) and the arithmetic ends it before the
model's skill is measured: Qwen Code v0.22.3's opening request is 16275
tokens in plan mode and 18348 in apply mode -- its own system prompt and
tool roster, ahead of any file content -- and llama-server answered both
with `400 request exceeds the available context size (8192 tokens)`
(`deep-coder-8192-errors.json`). The runtime made no edit, and the four
edit-dependent checks refused: empty changed-file list, the assertion
still reading 41, an empty diff, and no patch to apply. Every grant,
refusal, containment, and teardown check held, and the fixture repository
stayed byte-identical, so the chain contains a failing agent run the same
way it contains a hostile one.

The refutation carries a second finding: Qwen Code exits 0 with a
`success` result subtype on that API error, so exit status can never gate
an apply -- the harness's independent diff, test, and patch-reproduction
checks are what refused the run.

`code-deep-a` stays `refused`. The depth half of its gate is now closed:
`evidence/depth-validation-cuda/qwen25-coder-7b/` validates the 7B at
32768 (32539 of 32768, needle retrieved), the registry ceiling and
`validated_filled_depth` read 32768, and `code-deep-a` carries
`maximum_context=32768`. The remaining gate is a rerun of this chain at
that depth under the evict-first transition; the 8192 tuple stays a valid
earlier arm that cannot host this agent runtime.
