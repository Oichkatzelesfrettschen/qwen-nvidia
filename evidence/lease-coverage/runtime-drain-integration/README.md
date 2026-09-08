# Server retirement and telemetry restoration integration

The integration connects the session stop path and router capacity transition
to the existing admission barrier and drain controller. The controller binds
real callers to the inflight identity captured at session startup. Session
retirement keeps admission closed through service cleanup; strict retirement
preserves quiescence when teardown proof is missing.

The router capacity transition belongs to llama.cpp server-models.cpp. The
router integration patch changes its source identity and requires a separately
built closure. Closure `15bc632adf7f` retains its loading/evaluation evidence;
the patch grants that binary no additional behavior. The lease-off companion
`fd27a84d9199` remains built with its completed static-isolation evidence.
Historical production remains `88681bf4d161`.

## Validation boundary

The integration uses off-device subprocess and HTTP fixtures. A fixture verdict
establishes the exercised caller, ordering, and refusal behavior. Device
completion and destructor exclusion still require the device admission record.
The behavioral comparisons remain separate: companion versus candidate
attributes the lease change; historical production versus candidate measures
compatibility with deployed behavior. Exact generated token IDs remain the
numerical gate under matched prefill, cache, and per-model settings.

Local test logs and the private before/after telemetry observations live under
`.local-artifacts/runtime-drain-restoration/` in the primary checkout. The
published acceptance receipt records selected sanitized outcomes after testing.
GPU execution, runtime comparisons, device drain admission, and promotion
remain `not_run` during this integration.

## Runtime activation and restoration contract

`QWEN_ROUTER_ORDERLY_RETIREMENT=1` on a router session exports the checked-in
retirement helper and the API-key file reference. The default remains zero.
The new source patch is opt-in during patch verification through
`QWEN_LLAMA_ORDERLY_RETIREMENT_PATCH=1` with the candidate patch stage enabled.
The CPU-only router fixture binary establishes caller behavior on fake children;
its build supplies no CUDA serving identity.

At an authorized handoff, `scripts/telemetry-restoration.py capture` records the
live PID and start time, recorded owner ancestry, exact argv, resolved executable,
working directory, affinity, nice value, loaded-library hashes, listener, health,
model/projector hashes, and explicit configuration-file references. Each required
non-secret environment name is passed separately with `--environment`. Credential
values stay in their existing referenced files. The capture records legacy owner
lock state as observed; restoration acquires and verifies the current owner
capability before launching the recorded service.

The operational snapshot belongs in a private directory under
`.local-artifacts/`. Before running an authorized `run-closure-identity-ab.sh`
campaign, the operator binds `QWEN_TELEMETRY_RESTORE_SNAPSHOT`,
`QWEN_TELEMETRY_RESTORED_PID_FILE`, and `QWEN_TELEMETRY_RESTORE_RECORD` to fresh
paths in that directory. The campaign launches each server in a distinct POSIX session, records that
boundary with its launch identity, and scans remaining session members after
retirement. A missing terminal boundary record refuses a reaped verdict; a child
created during termination remains visible to the boundary census. The finalizer
preserves its original failure status, records cleanup, releases its owner
descriptor, and invokes restoration
only after safe cleanup and latch checks. Restoration verifies the recorded
runtime rather than following a latest-build symlink.

Pre-launch refusal records `restoration=blocked` with the failed precondition.
Post-launch verification failure also records the launched PID/start identity,
executable digest, and requested owner location with disposition
`retained_pending_identity_bound_teardown`. That receipt makes surviving work
explicit; the verifier does not terminate a potentially active device service
outside the declared drain policy. The caller stops the campaign and uses the
recorded identity for an explicit teardown before another attempt.

`campaign.json` retains both original behavioral comparisons and records the
additional new-closure prerequisite introduced by the router source patch.
After merge, preparation binds the merged revision, materializes the new source,
and freezes its executable/library digests before requesting a device window.
The retained candidate's numerical evidence does not automatically qualify that
new closure. Promotion requires the complete final admission sequence.

## Repeating the compiled caller fixture

The external-source check uses the pinned llama.cpp tree with the reviewed
router patch applied. Configure a separate build under `.local-artifacts/`
with `GGML_CUDA=OFF`, `GGML_VULKAN=OFF`, `LLAMA_OPENSSL=OFF`,
`LLAMA_BUILD_TESTS=OFF`, `LLAMA_BUILD_EXAMPLES=OFF`, GCC 15, and
`CMAKE_CXX_FLAGS=-Werror`; build the `llama-server` target. The fixture copies
that CPU-only router executable, starts its listener, and atomically replaces
the copied pathname with the fake-child script before requesting a model load.
The original router process retains its already opened executable.

Run `scripts/test-router-retirement-caller.py` with
`QWEN_ROUTER_FIXTURE_SERVER` bound to the resulting executable. Run each declared
`QWEN_ROUTER_CALLER_MODE` serially against the frozen build. The clone-local gate
runs the adapter and page-state fixtures; the compiled caller stays separate
because a fresh repository clone excludes the external llama.cpp source.

## Acceptance record

The selected focused logs establish session-stop wiring, capacity-one eviction,
positive teardown-proof refusal, exact telemetry restoration, unsafe-precondition
refusal, and post-launch failure attribution. `test-map.tsv` maps mechanisms to
fixtures; `mutation-map.json` separates discriminating mutations from redundant
guards and the earlier failed calibration. The five compiled router modes run
serially on the binary inventory in `cpu-build.json`.

`implementation.sha256` binds the integration files used by the fixture record.
The publication procedure stages those bytes, refreshes the evidence manifest,
runs one full repository gate, and verifies the staged tree and working bytes
remain unchanged before committing. Hosted CI must accept the published head
before merge. The exact local gate exit and staged-tree receipt remain under
`.local-artifacts/gates/`; GitHub retains the public hosted-check result.

`live-boundary.tsv` reports the enumerated before/after observations. Production
and telemetry preserve their recorded identities and settings. Integration is
ready for device admission; device drain and both runtime comparisons remain
unexecuted. The new CUDA closure and final merged-revision freeze remain explicit
prerequisites to requesting that window.

Hosted run `34271125798` refused the telemetry fixture because the repository-local
tmux socket pathname exceeded the Unix socket address limit on the runner. The
fixture now addresses the same repository-local directory through a held directory
descriptor and verifies the socket resolves inside that directory. The descriptor
remains open through restoration and isolated-server cleanup. The failed hosted
run remains retained; the repair changes fixture addressing alone.
