# Whole-repository DiscoBSD admission

The private operator profile at `.local-artifacts/graft-discobsd/config.json`
sets both `discobsd.allowed_paths` and `discobsd_snapshot.allowed_paths` to
`[]`, with a bounded 28800-second job limit. `discobsd` names the live checkout;
`discobsd_snapshot` names a detached worktree at a fixed source commit. The
profile keeps the OpenAI-compatible model endpoint at loopback and uses
Graft's installed 0.18.0-2 package. The selected model is
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

The server monitor's swap-in headroom was set to 4194304 KiB for this run,
equal to its unchanged minimum-memory reserve. Earlier comparative 4B and
7B sessions met the broader 8388608-KiB swap-in band alongside unrelated
host work; this setting keeps the hard memory reserve and the
64-MiB-per-sample swap-in limit at that reserve. The server's own telemetry
and Graft job status remain the authorities for any later abort or completion.

Raw status, graph, telemetry, and server logs remain under the ignored
`.local-artifacts/graft-discobsd/jobs/` and `.local-artifacts/graft-discobsd/state/`
directories. Both structural jobs mounted source read-only and wrote graphs
in the repository-local artifact root. The untracked live DiscoBSD inputs
observed before admission were `.ignore`, `tools/aoututils/aout/`, and
`usr.bin/pdp11/`; the live checkout retained those paths. The detached
worktree contains only files checked out from `be592ce`. Graft's Git
selection can include non-ignored untracked source in the live checkout,
so the two node counts have different source boundaries.
