# Lease behavioral and orderly-drain admission preparation

The companion delivery is merged in PR #64 at
`e92833143fe35b12f7451d6a77b07f67024f79b4`. The local companion gate records
exit 0, `repository_quality_gates=accepted`, and a current 9909-entry evidence
manifest. Hosted `clone-local` CI passes on
`4620d884c650f1a6f6ec7e8a6006b318ded23992`; that head and the merge have identical
Git trees. The staged stage-two repairs are included in that head. The local
gate has a retained log and sentinel; a separate start-of-run content manifest
is unavailable. Hosted CI binds the tested content to the published head.

This directory is an off-device preparation record, not runtime admission.
`TASK_TRACKER.md`'s Compute lease coverage section owns the dispositions; it
carries named obligations rather than a numbered #123 definition. The records
here freeze observations at the publication revision above. Any later harness
change requires a new revision binding before a device run.

## Subjects and retained integrity

`frozen-inputs.tsv` records full SHA-256 values and sizes for the historical,
companion, and candidate server executables, every adjacent shared-library
path, CMake caches, build configurations, model files, and authority inputs.
Symlinked library names remain separate rows naming their resolved file bytes.
The inventory reads files and executes neither a server nor a model.

| Closure | Role | Runtime obligation |
| --- | --- | --- |
| `88681bf4d161` | historical production and deployed-behavior reference | historical binary regression required |
| `fd27a84d9199` | known-source lease-off companion | companion behavioral comparison required |
| `15bc632adf7f` | known-source lease-on candidate | both comparisons; orderly-drain device admission |

The companion source remains at `$HOME/src/llama.cpp-lease-off-companion`,
and its build remains in that source directory's
`build-qwen-cuda-fd27a84d9199`. The source snapshot, executable, configuration,
and committed evidence survive outside the removed companion worktree.
The candidate source remains at `$HOME/src/llama.cpp-qwen-nvidia`.
Both source HEADs read `f280b26983ad0fdb705a0d9ebf0503e76f2899b0`.
A successful `git diff --binary HEAD`, run with inherited `GIT_*` variables
removed before either subprocess, hashes to:

```text
companion ca47669a0f45f82348832ac35991f9127143f38f63f2217cd0a916e6c10eea7d
candidate 76f4b8e888cde28f354482e4fea3d91e609ce634fb9d6654608b68f496a96768
```

The retained isolation report identifies one file with 331 additions and zero
deletions, zero device targets reached, and identical normalized SASS:
`2c25d6c80277b9232f404027b2b504ac290518e01efb2ff6f18a091221280220`.
That reading covers 8167 functions and 15052727 lines per side, with the
normalization and its limits specified in `../companion-build/README.md`.
Whole linked binaries differ. Sixteen of seventeen mutations discriminate;
M07 leaves the keyed placeholder unproven by an arm, while the retained unit
tail and M07b's collision test carry the reported normalization boundary.

Historical source reconstruction remains unavailable within the retained
search: 160 requested combinations, 152 reconstructed, eight unavailable,
and 4256 hashes across 28 serialization settings. The companion supplies
replacement provenance, not recovered historical source. The search stays
closed absent new retained historical material.

## Behavioral matrix and numerical contract

`behavioral-matrix.tsv` names six rows, ordered with all 2B rows before 0.8B.
Each row runs control-open, candidate, control-close. Each control must first
reproduce itself under identical prompt order, prefill composition, checkpoint,
cache state, and runtime settings. An opening/closing control difference
refuses attribution. An unexplained subject token difference refuses admission
in either comparison, independently of a successful lease-exclusion reading.

The text corpus is the existing identity harness's six prompts, copied exactly
into `prompts.tsv` and hashed in `frozen-inputs.tsv`. Use 256 predicted tokens,
seed 1, temperature 0, top-k 1, `ignore_eos=true`, `cache_prompt=false`,
`return_tokens=true`, and one request at a time. Pin the harness's host thread
count to 1 in every arm, retain prompt order and responses, and compare every
generated integer token ID. Require token-array length to equal both the
requested count and the server's actual `tokens_predicted`. Boolean values
are rejected as token IDs. Preserve a first-divergence index and both arrays.

The 2B uses context 16384, batch 2048, ubatch 512, q8_0/q4_0 KV,
flash attention on, and its pinned projector even in its text row. Its image
row uses `scripts/quality-images/bars.png` through the actual reviewer request
path, with identical image bytes, prompt, schema, and cache state across arms.
The fixture's declared tallest bar is JUN. The image row needs exact-token
comparison as well as the reviewer's grounding verdict. A schema activates
host sampling under the pinned server; preserve that behavior.

The 0.8B uses context 65536, batch 2048, ubatch 512, q8_0/q4_0 KV,
flash attention on, and the `mtp1` policy from `scripts/speculation-profiles.tsv`:
`draft-mtp`, maximum one draft token, backend sampling 0. Its projector is
`none` by registry declaration. Its text result cannot become a multimodal
admission. The 2B selects `off`; each row's actual argv must agree with its
profile. The general 2B text role and measured 4B image-coordinator role remain
separate; the 4B is outside this comparison matrix.

Run every arm under the default CUDA runtime profile, explicit CUDA0 tensor
placement, fit off, parallel 1, ordinary KV, device embedding off, and inactivity
sleeping disabled. Keep the promoted build's Q6_K=10, Q8_0=16, and MMQ=90.
Use the candidate with its compute lease configured; controls use the same
configuration, which their lease-free code does not implement. The behavioral
arms serialize with other device work; exclusion is a separate claim.

## Drain matrix and execution readiness

`drain-matrix.tsv` separates full-session shutdown from capacity-one model
eviction. Both use the candidate and start with the 2B. The second model is
0.8B. The controller is merged through PR #63 at `18f7fff`; the fixtures and
mutation-to-assertion mappings live in `../orderly-drain/` and
`../drain-review-hardening/`. Reuse those mechanisms and their calibrated
failure cases. Historical table counts are not a device verdict.

The live code inspection establishes the following execution prerequisites:

| Surface | Existing implementation | Requirement before requesting a device window |
| --- | --- | --- |
| text identity | `run-closure-identity-ab.sh` checks the requested count, actual `tokens_predicted`, and integer IDs | refusal fixtures pass; bind the final tested revision before execution |
| per-row policy | identity harness accepts extra argv and environment | bind the frozen projector and speculation selections, then verify emitted argv |
| reviewer comparison | reviewer and image fixtures exist | drive the actual schema-bearing reviewer request across all three arms and retain exact IDs |
| session destruction | `qwen-drain-controller.sh` and barrier exist | route the real session retirement through the controller; retain child identity and its destructor lease event |
| capacity-one eviction | controller fixtures exercise marker commands | exercise a real retiring child and surviving router listener; bind admissions and active references to that session |
| emergency residue | calibrated deadline and signal fixtures exist | preserve named escalation and independently prove child/listener/lock residue |
| telemetry restoration | process argv, runtime environment, loaded-library hashes are frozen | bind an explicit telemetry launch/stop procedure to the observed diagnostic process and validate its preparation off-device |

`qwen-teardown.sh`, `qwen-webui-control.sh`, and `qwen-webui-session.sh` contain
zero calls to `qwen-drain-controller.sh` at the observed revision. The control
script's stop path signals the server and later removes its tmux session.
Consequently, invoking the ordinary teardown command alone cannot test the
merged controller's orderly exclusion. The publication revision's identity harness also accepts a requested-length
array while omitting an actual-predicted-count check. The preparation repair
requires an integer actual count equal to the request and rejects boolean IDs;
`scripts/test-closure-identity-token-count.py` exercises those refusals against
the reader extracted from the actual harness.
These are off-device preparation findings, not a request to repeat completed
reviews or served lease arms. Execution readiness remains `not_ready` until
the listed paths carry their required positive evidence.

For an orderly verdict, record the session's original barrier identity, the
accepted operation's true terminal event, and the retiring child's own lease
hold during ordinary destruction. Keep the admission reference while accepted
work waits for compute. Keep result, status, and cancellation delivery reachable
while admission is closed. The orchestrator holds the owner and admission
barrier and lets the child acquire the compute lease itself. A replaced barrier
reports `barrier_identity_mismatch`; a successful exit with `held=no` reports
`not_established`; absent attribution remains unattributed. Emergency cleanup
keeps its bounded escalation and explicit unprotected-cleanup exception.

## Ownership, desktop, and telemetry restoration

`lock-observations.tsv` records the existing owner pathname
`/tmp/qwen-ad104-gpu-0.lock` and the configured session lease's device/inode.
The latter resolves through `gpu_ownership_lease_path` to
`$HOME/qwen-webui-state/vulkan-workload.lock` in the inspected environment.
The historical basename does not change the CUDA-only contract. Bind
`QWEN_GPU_COMPUTE_LEASE` and its verified identity to that shared lease;
create neither a replacement inode nor a service-specific substitute.
The telemetry process itself has the lease variable unset.

`telemetry-snapshot.json` records PID plus start ticks, executable and digest,
argv, cwd, CPU affinity, nice level, and an explicit runtime-environment
allowlist. `telemetry-loaded-libraries.tsv` hashes all 59 mapped shared-library
paths. The snapshot's full diagnostic executable path is independent of the
production pointer, and its 9B model hash is in `frozen-inputs.tsv`.
The snapshot records `/health` answering `status=ok` on 18086.
Other environment variables remain outside the recorded scope; credentials and
complete process environments are excluded from retention.

The restoration procedure has the following ordered acceptance conditions:

1. Before an authorized window, resolve the listener again and compare PID,
   start ticks, executable digest, argv, and loaded-library digests against the
   snapshot. An identity change requires a fresh snapshot before teardown.
2. Bind a telemetry-specific stop and launch operation to that diagnostic
   executable and its captured configuration. The ordinary production launcher
   selects a different closure, so it is insufficient for restoration.
3. After authorization, stop only the verified telemetry process through that
   bound operation. Verify process departure and listener release before
   acquiring the campaign's owner claim. Preserve any failed stop and end the
   attempt under the existing latch policy.
4. Keep the desktop client policy fixed: preserve the compositor and existing
   graphics clients, record their identities, and refuse a changed compute
   client set between arms. Serialize device campaigns; launch zero profiling
   contexts during these admissions. NVML samples corroborate lease events.
5. After success or failure, retire only recorded campaign children, prove
   listener and ownership residue separately, and release the campaign owner.
   A hazard latch that refuses launch takes precedence over restoration;
   retain that refusal and request operator recovery rather than clearing it.
6. Restore the diagnostic binary with captured argv and runtime variables,
   including explicit unset entries, affinity, and nice level. Read back the
   new process identity, loaded-library hashes, model path, and port 18086
   health. Preserve the old and new identities as separate observations.

The telemetry restoration operation itself remains unexecuted and requires the
bounded authorization above. Preparation changes neither production pointers
nor telemetry configuration. A later approval covers one finite attempt,
including restoration, and expires on a refusal; a failed load receives a
retained outcome rather than a silent retry.

## Following admissions

Behavioral comparisons precede orderly-drain device admission. Strict CUDA0
text and multimodal admission, router admission with per-row speculation, and
serialized image generation/review follow on the same candidate configuration.
Evidence review precedes atomic promotion and loaded-process verification.
The combined-session campaign follows promotion, keeping independent grants,
result attribution, repeated use, contention, cancellation, and recovery.
Physics and geometry policy promotions remain independent decisions.
A historical rollback also disables behavior requiring LLM lease participation.
