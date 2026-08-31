# The qwen-coder security principal

The coding lane executes under its own operating-system identity, because
Qwen Code's daemon runs with the authority of its user rather than as a
sandbox: the account is the boundary, so the account holds nothing worth
taking. `scripts/setup-coding-principal.sh` creates and converges it under
root, and `scripts/test-coding-principal.sh` verifies the locked shape from
an unprivileged caller, reading the home interior through a cached sudo and
reporting `not-run` where neither path can look, so denial never reads as
absence.

## The locked shape

```text
user:    qwen-coder, system account, locked password
shell:   /usr/bin/nologin
home:    /var/lib/qwen-coder, mode 0700, owner qwen-coder
groups:  qwen-coder alone
state:   repos/ worktrees/ tmp/, each 0700
absent:  SSH keys, GitHub and cloud credentials, browser state
```

The account holds no write path into `~/Github/qwen-nvidia`: the checkout
and its `.git` are owned by the primary user with no group or world write
bit, which the verifier checks on every run. A worktree created from the
live repository would store its writable index and administrative state
under the live `.git/worktrees/`, so the task mirror lives apart:

```text
/var/lib/qwen-coder/repos/<repository-id>.git   bare mirror per repository
/var/lib/qwen-coder/worktrees/<job-id>/         ephemeral detached worktree
```

The coding-agent service imports one approved base revision into the
mirror, creates a detached worktree for the job, and exports the patch,
diffstat, changed-file list, test log, event stream, base commit, and
result tree hash; the authoritative checkout changes only when the human
applies the exported patch. The verifier's fifteen checks passed on
2026-08-31 and the check joins the repository quality gates, so a drifted
account fails the gate rather than serving.
