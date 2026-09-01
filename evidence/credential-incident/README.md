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

## Falsifier

`git rev-list --objects --all` over the published repository returning any path
with a profiler extension refutes the rewrite. A `git ls-remote --heads`
listing that still names the reconciliation branch refutes the branch removal.
Either reopens the incident.
