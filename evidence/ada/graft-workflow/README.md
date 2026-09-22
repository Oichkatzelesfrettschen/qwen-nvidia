# Graft workflow admission

The functional pilot ran on 2026-09-22 UTC with the promoted
`192d0663a533` CUDA closure, driver 615.71.09 and compiler toolkit 13.4.59.
The server enabled Jinja tools, a 512-token reasoning budget, a 16384-token
context and the registry's mixed q8_0/q4_0 KV configuration. The initial
SCHED_IDLE startup failure is excluded from model grading. Its retained
launch rows identify a runtime-policy failure, not a generated-model reply.

## Symbol contract

`scripts/admit-record-symbols.sh` sent the graph-derived `record_symbols`
requests for three DiscoBSD files. The request cap was 6144 output tokens.

| Model | File | Targets | Elapsed ms | Outcome |
| --- | --- | ---: | ---: | --- |
| Qwenseer-2B Q4_K_M | flash_swap.c | 2 | 3048 | pass |
| Qwenseer-2B Q4_K_M | kern_mman.c | 2 | 2354 | pass |
| Qwenseer-2B Q4_K_M | sig_machdep.c | 3 | 3547 | pass |
| Klear-AgentForge-8B Q6_K | flash_swap.c | 2 | 59859 | pass |
| Klear-AgentForge-8B Q6_K | kern_mman.c | 2 | 15230 | pass |
| Klear-AgentForge-8B Q6_K | sig_machdep.c | 3 | 42978 | pass |

Every response supplied the exact target IDs, with zero missing, invented,
duplicate or blank-summary records. Each model had five gradeable spans in
range and two ungradeable spans inherited from the older input graph. Those
two spans establish neither a pass nor a failure. The elapsed times include
workstation conditions and are functional-probe observations, not a
clock-controlled speed comparison. Both model-session teardown logs reported
completed orderly exclusion.

## Native server workflow

The installed package recipe pins Graft 0.18.0 at upstream commit
`de8456e892bad5aeee11403e47fb2227773eb27e`. The initial API pilot used an
extracted package carrying the same collector and C extraction corrections.

1. Native `/tools` listed the four `qwen_graft_` workflow tools.
2. Qwenseer received the projected completion schemas and a user request to
   deep-index `discobsd`, restricted to `sys/arch/rp2040/dev`.
3. With `tool_choice=auto`, Qwenseer emitted one exact start call, including
   the requested repository, mode and path, with no authorization field.
4. The operator-side HTTP harness obtained a session-authenticated signed
   grant and submitted the native tool execution request.
5. The tool returned a queued job ID immediately. Native status calls observed
   the detached job running and completing.
6. The job parsed eight source files into 137 nodes and 80 edges. It completed
   137 summaries with zero pending, stale, unknown-state or blank-ready nodes
   in 100 seconds. File-API retrieval succeeded through the native query tool.

The concept layer contained nine nodes and zero links. Ready-summary counts
measure coverage, not factual correctness. Source commit identity was
`a23a2f4348290e775d42c18f7c8b95e4ff228c0f`; dirty working-file bytes were live
read-only inputs rather than a committed snapshot.

The first API harness incorrectly expected top-level function definitions and
`plain_text` results. Reading the pinned native ToolsService established
`definition.function` and `plain_text_response`; the corrected harness resumed
the already-admitted job rather than creating another job. Those harness
failures do not change the job's recorded execution.

The installed `graft 0.18.0-2` subsequently passed package integrity checks
(7233 files, zero altered), both package smoke tests and a fresh structural
137-node build followed by file-API and code-search queries. The package
archive SHA-256 is
`7fe7128b15327e108924f50926f37a45e78f6cd1ddfc84ca1c54dfb18680afa2`.

The installed-package native deep replay completed the same 137-node scope in
98 seconds. A later session with the admission barrier bindings completed in
94 seconds, queried the graph through `/tools`, and stopped with status 0:
`orderly_drain=completed teardown_exclusion=orderly inflight_identity=match
teardown_reading=held`. Each replay recorded identical before/after Git HEAD,
index entries, local-ref targets, worktree status and SHA-256 hashes for the
eight scoped source files. Those observations cover the named surfaces only.

The first native MCP session's teardown reported `unattributed` despite the
server's unique `teardown: held=yes` record because the proof refused every
non-router descendant, including the CPU-only MCP process. That record remains
an unaccepted retirement arm; subsequent repaired evidence must be distinct.

The retirement repair recognizes exact configured CPU MCP children and checks
worker configuration, process identities, source descriptors and sandbox argv
before cancelling active jobs. MCP start publication and synchronous queries
hold the existing shared admission barrier. Eleven real-lock tests cover
admission and twelve real-process tests cover retirement, including terminal
unreaped workers and owner-generation mismatch. The barrier-bound
native replay supplies the separate accepted idle-MCP teardown observation.

The mount-only descriptor replay completed the same deep graph in 99 seconds,
then retrieved its file API. A signed native cancellation reached `cancelled`.
Stopping a second active deep build also cancelled that job, while server
retirement returned status 1 after bounded escalation. That active-shutdown
arm remains failed; its successful job cancellation supplies neither server
teardown nor exclusion proof.

A stricter reproduction waited for an acquired inference lease before stopping.
The helper recorded completed process retirement with status 0 while the runtime
omitted the teardown marker. The pinned destroy path emitted that marker only
when it reacquired a lease, so a teardown retaining an active request's lease
performed synchronization and release without the ownership observation.
The source repair moves the observation after that conditional. A compiled
C++17/Werror fixture checks inherited ownership, idle acquisition, contention
and an unconfigured lease; restoring the old branch fails inherited ownership.

The UI patch has separate copied-source Svelte, ESLint and Prettier validation,
21 approval/schema tests and 14 builder fixture checks. The API pilot is not an
attended browser-click test. See [GRAFT.md](../../../GRAFT.md) for operator
configuration, model limits and the CUDA/OptiX/PhysX boundaries.

The exhaustive clone-local gate completed with `repository_quality_gates=accepted`
and exit status 0. Its Graft coverage includes 25 workflow, 15 launch/broker,
11 admission, 12 retirement and 10 startup regression tests. The compiled
teardown-observation fixture passes both its positive and mutation tests.
The existing coding-principal network probe reported `not-run` because the host
egress table was absent; the gate's remaining principal checks passed. The task
left that separate firewall policy unchanged.
