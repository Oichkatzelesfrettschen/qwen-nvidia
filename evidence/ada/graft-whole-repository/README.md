# Whole-repository DiscoBSD admission

The private operator profile at `.local-artifacts/graft-discobsd/config.json`
sets both `discobsd.allowed_paths` and `discobsd_snapshot.allowed_paths` to
`[]`, with a bounded 28800-second job limit. `discobsd` names the live checkout;
`discobsd_snapshot` names a detached worktree at a fixed source commit. The
profile keeps the OpenAI-compatible model endpoint at loopback. Attempts
1-3 used Graft 0.18.0-2; the installed package is now 0.18.0-3, whose
`-j 1` bound reaches both the concept and symbol passes. The selected model is
Qwen3.8-4B-Distill Q4_K_M under CUDA closure `39a6bc778ef4`; the model
comparison and its semantic caveats are in
`evidence/ada/graft-model-comparison/README.md`.

At DiscoBSD HEAD `3f80ebd93435936393dd53e9e59da688497c03df`, a
whole-repository structural job completed in 15 seconds with 26002 pending
meaning nodes, zero ready summaries, and exit status zero. The status is
correct for structural extraction: it establishes the wiring graph, not deep
LLM completion. A Graft file-API query for `flash_swap.c` returned the two
RP2040 function skeleton entries from that isolated graph. The private job
ID is `d058451a1ebfa9452c1b47a16971dc81`.

A deep job on the live checkout started with ID
`77fe81cb7aaf46d9a1ec1e9ac36d4048`. Another writer fast-forwarded the
live checkout to `be592ce54013f5bd1f71a1ba5d3617c4e0b7c006` while that
job ran. The changed paths included `tools/changed_comments_test.py` and
`tools/check_changed_comments.py`, which Graft can index. The job mounted a
live read-only tree, so its initial source HEAD did not freeze subsequent
file bytes. A signed cancellation ended the mixed-revision risk with state
`cancelled` and exit code -15; its partial cache is retained, not admitted.

The detached worktree at `be592ce` completed a new whole-repository
structural job with 26019 pending meaning nodes, zero ready summaries and
exit status zero. A regression test runs `git ls-files` inside the whole-root
linked-worktree sandbox and verifies that pinned Git metadata remains mounted;
the earlier wrapper had mounted that metadata only for narrow scopes. The
snapshot structural job ID is `8330243dbce63c8e3846bc6a9db1fa75`.
A new live structural job at the same HEAD also completed with 26019 nodes;
its ID is `67fab71eccab864e6a784a6731df5d31`. These counts agree while
the two source trees hold the same tracked files. Both graph queries returned
the two `flash_swap.c` function skeletons and reported matching graph and
current source HEAD values.
A fresh deep job, `91e23763f6896c56d1165450c71c4e12`, uses that immutable
source, one Graft summary worker, the authenticated llama.cpp endpoint and
the private 8-hour job bound. Its final coverage and semantic validity remain
unmeasured until completion. The native UI served HTTP 200, `/v1/models` named
`qwen-nvidia`, and native `/tools` listed the four `qwen_graft_` workflow
tools. The current endpoint is loopback-only and key-protected.
An intermediate cache spot-check found a semantic error in the selected
model's `lib/libc/stdio/doscan.c` file summary. The summary says `_doscan`
relies on `sysctl.c` for `kern.hostid` conversion; the source at `be592ce`
says the shipped `sysctl -w` path reaches the scanner through `%ld`.
The dependency direction is reversed. Cache progress and eventual ready-node
counts must therefore remain distinct from source-verified claims.
With all four native Graft tools exposed and `tool_choice=auto`, the selected
4B distill emitted exactly one `qwen_graft_graft_build_status` call for the
snapshot deep job ID. A native `/tools` execution of those arguments returned
the running job's `discobsd_snapshot` state. The probe selected and executed
a read-only tool; it did not exercise a WebUI click or issue a new start grant.
The raw transport schema still names `authorization` as required, and a direct
model probe over that schema fabricated a token. The WebUI projects the
start/cancel schemas without that broker-owned field. With the projected
schema, the selected model emitted one exact whole-scope structural start
proposal and no authorization field. A fresh broker session signed the
proposal, and native `/tools` queued job
`218fb8f36910f25f138c01e99abfd24c` for live `discobsd`. The model never
received the signed grant. Live HEAD had advanced to
`02acfdbdf2236141c5bc2c8a795bad4c122a4fd1` before that start; the
new structural job completed with 26043 pending meaning nodes and zero ready
summaries. A native file-API query returned `flash_swap_append` with equal
graph and current source HEAD values and `isError=false`. The snapshot deep
job remains fixed at `be592ce`. The API proof exercises the
model, schema projection, broker and native execution, while an attended
browser-click remains unmeasured.

The first deep attempt ended `partial` after the monitor measured
`MemAvailable=4179900` KiB below its 4194304-KiB hard reserve at
2026-09-23T05:09:41Z and terminated llama-server. Graft retained 26019
structural nodes, 51 ready meaning nodes, 2662 file-summary cache entries,
and 45 synthesis batches. Its log names five consecutive connection errors
after serving stopped. Host allocation by other processes was not captured
per process at the breach, so the monitor identifies the stop condition, not
the share attributable to each concurrent process.

A restart at 05:22Z stopped separately on `swapin_rate_breached`: the monitor
measured 84787200 swap-in bytes in one sample with 8147692 KiB available,
below its default 8388608-KiB swap-in headroom. The host uses priority-100
zram and had more than 4 GiB available; the sample alone does not establish
disk thrashing. The prior note claiming a 4194304-KiB setting was incorrect:
`qwen-webui-control.sh` did not forward `QWEN_SWAPIN_HEADROOM_KIB` through
the tmux launch boundary. The launcher now forwards that policy variable. The
next session's monitor records 6291456 KiB for swap-in headroom while keeping
the 4194304-KiB hard reserve and 67108864-byte per-sample swap-in limit.

Graft 0.18.0-2 reads its prior extraction cache and `wiring.json` meaning
cache in the same graph directory. The workflow now resumes only a partial
deep job under a fresh approval, the original source HEAD and configuration,
and the repository lock. Attempt 2 started on the retained job ID at
2026-09-23T05:25Z. The recovery launcher set `QWEN_CONTEXT_SIZE=16384`, below
the profile's validated 32768; a concept request carrying 11471 prompt tokens
produced 4913 tokens and the server reported `truncated=1` at 16383 slot
tokens. Graft retried that file instead of advancing its cache. The
controller's stop drained admissions but reported `destroy=failed` after
bounded retirement escalation; the recorded server PID and tmux session were
absent afterward. Graft ended `partial` with the same 51 ready nodes. The next
launch verified `n_ctx_slot=32768` in the server log and resumed attempt 3 at
2026-09-23T05:32Z. `build.log`, `build-attempt-2.log`, and both prior status
records remain retained. Final coverage and semantic validity remain
unmeasured after attempt 3 ended partial.
The server's telemetry and Graft status remain the authorities for another
abort or completion.

Attempt 3 ended `partial` at 2026-09-23T05:47:16Z with exit status 1.
The resource monitor measured `MemAvailable=3617212` KiB at 05:47:05Z,
below the 4194304-KiB hard reserve, and stopped serving. The last
telemetry sample recorded llama-server RSS of 183388 KiB, a process peak
of 2875072 KiB, GPU activity of 93%, and 5315231744 bytes of device
memory in use; those fields do not account
for other host processes. The graph still reports 26019 nodes, 51 ready
and 25968 pending. The retained cache holds 2663 file summaries and 45
synthesis batches. A subsequent host probe found an unrelated Android
`soong_build` process holding about 6 GiB RSS while available memory was
under 4 GiB. The later process sample is a competing-pressure observation,
not an attribution of the exact memory drop at the monitor breach. The
same job ID, source snapshot and graph remain eligible for another
authorized resume after host headroom returns. Its concept and meaning
coverage remain incomplete, and the `doscan.c` dependency error remains a
source-accuracy counterexample.

Attempt 4 resumed the same graph against the same source HEAD at
2026-09-23T08:13Z under the 32768-token CUDA WebUI. The native UI carried
the Graft broker marker, and the server reached readiness with the configured
6 GiB swap-in headroom and unchanged 4 GiB hard memory reserve. The monitor
stopped the server at 08:13:34Z when `MemAvailable=3501884` KiB fell below
4194304 KiB; that sample reported 2711552 swap-in bytes, below the
67108864-byte rate limit. Graft returned `partial` with 51 of 26019 meaning
nodes ready, 2663 retained file summaries, and 45 synthesis batches. The
server's recorded peak RSS was 1878580 KiB in this session. The monitor
records the stop condition, not the process responsible for the host-wide
memory drop. A later sample found the unrelated Android `ninja` in its own
checkout using about 5.6 GiB RSS, but that process started after the abort
and cannot be assigned the earlier drop. Zram and the fast NVMe swapfile were
both active; swap availability does not satisfy the unchanged `MemAvailable`
reserve. Another resume awaits stable headroom while the Android build keeps
running.

Raw status, graph, telemetry, and server logs remain under the ignored
`.local-artifacts/graft-discobsd/jobs/` and `.local-artifacts/graft-discobsd/state/`
directories. Both structural jobs mounted source read-only and wrote graphs
in the repository-local artifact root. The untracked live DiscoBSD inputs
observed before admission were `.ignore`, `tools/aoututils/aout/`, and
`usr.bin/pdp11/`; the live checkout retained those paths. The detached
worktree contains only files checked out from `be592ce`. Graft's Git
selection can include non-ignored untracked source in the live checkout,
so the two node counts have different source boundaries.
