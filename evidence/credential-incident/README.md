# Two credentials reached a public repository inside profiler reports

Nsight Systems embeds the capturing process's whole environment in the report
it writes, under `TARGET_INFO_SYSTEM_ENV` and `DeviceEnvironment`, and a
`.sqlite` export carries that block forward. Eight `.nsys-rep` files captured
from an ordinary interactive shell therefore carried that shell's environment,
including a Greptile API key and a Claude Code messaging token, and those files
were committed and pushed.

`state.tsv` carries the incident's condition set as booleans and nothing else.
A credential's value, prefix, suffix, length, and digest are all absent by
design: each of those is a distinguisher an attacker can test against, so a
record that proves remediation must not narrow the search space it remediates.

## What the tree gained from it

`scripts/exec-profiler-clean-env.sh` runs a profiler under `env -i` with
exactly eleven declared variables, so a capture absorbs a stated environment
rather than the operator's. `scripts/check-tracked-artifacts.py` refuses
`.nsys-rep`, `.ncu-rep`, `.qdrep`, `.qdstrm`, `.sqlite`, and `.sqlite3` as
tracked paths, so the class of file that carried the credentials cannot be
committed again, and `.gitignore` keeps them out of the working set.
`evidence/ada/b789-path-audit/removed-raw-reports.sha256` retains the digests
of the removed reports, and `evidence/ada/mmvq-mmq-occupancy-ad104/` retains
the derived numbers, which are unaffected by the container that carried them:
kernel timing does not depend on the environment string beside it.

## The order the remediation takes

The provider-side deletions come first, because a key that still authenticates
is not remediated by removing the file that held it. The history rewrite
follows, then the removal of the contaminated reconciliation branch, then
GitHub's cached-sensitive-object cleanup, then a fresh clone. The old checkout
is renamed and has its push URL disabled rather than being pulled forward,
since a rewritten history pulled into a contaminated object database restores
the objects the rewrite removed.

Greptile is removed rather than rotated. The integration was unused, so a
replacement key would reintroduce a credential surface for a capability
nothing in this tree consumes.

## The remaining exposure is a merged pull-request ref

The rewritten history is published and `refs/heads/main` reaches no profiler
report. The eight reports remain reachable through `refs/pull/1/head`, whose
commit is the head of a merged pull request, and GitHub retains that ref
independently of the branch it was opened from. Deleting the branch removed the
branch; the pull-request ref survived it, and no push to `main` can reach it.
GitHub Support purging the cached objects is therefore the whole remedy rather
than a tidying step after one.

The repository is private, so the reports were never readable without an
authorization to it. That narrows the exposure and does not close it: the
Greptile GitHub App held repository access over the period the reports were
committed, which is an integration that could read them, and a private
repository is exactly the surface a leaked personal token reaches.

## What remains open, and who owns it

Three conditions read `deferred` rather than `yes`, and they are the ones that
matter most: the Greptile key still authenticates, its GitHub App authorization
still stands, and the Claude Code token is still valid. The operator has
deprioritized them, and this record states that rather than implying a
remediation that did not happen. The repository being private bounds the
exposure to the authorizations it granted, which is a narrower surface than a
public repository and is not an empty one.

The publication half is closed. Remote `main` reaches no profiler report, the
reconciliation branch is gone, the contaminated local checkout is deleted, and
a fresh clone passes every gate. The surviving copy is `refs/pull/1/head`, which
only GitHub Support can purge.

## Falsifier

`git rev-list --objects --all` over the published repository returning any path
with a profiler extension refutes the rewrite. A `git ls-remote --heads`
listing that still names the reconciliation branch refutes the branch removal.
Either reopens the incident.
