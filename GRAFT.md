# Graft repository workflow

Graft is [trailhq/Graft](https://github.com/trailhq/Graft), published as
`@nanonets/graft`. Its structural pass extracts a tree-sitter graph; its deep
pass sends file and symbol requests to an OpenAI-compatible model. Structural
indexing and retrieval require no model tool calls. Deep indexing requires the
model to return structured records, including the named `record_symbols`
function. Graft supplies repository context; an agent still decides and applies
code changes through its separately authorized editing tools.

The [local package recipe](https://github.com/Oichkatzelesfrettschen/PKGBUILDS/tree/3dc2efc1539dcac100c7f404679c82a9cdd108b4/local/graft)
lives in the PKGBUILDS repository at `local/graft`; the installed patched package
is `graft 0.18.0-2`.
It pins published 0.18.0 at `de8456e892bad5aeee11403e47fb2227773eb27e`.
Upstream main advertised 0.19.0 during research, while npm's published release
remained 0.18.0. The recipe repairs blank-summary retries, echoed target IDs,
and C pointer-declarator spans. Prototypes remain distinct nodes; same-name
prototype/definition resolution remains an upstream limitation.

## Entry points and boundaries

`scripts/graft-workflow.py` provides manual CLI and stdio MCP entry points.
The native llama.cpp UI receives four workflow tools:

| Tool | Result |
| --- | --- |
| `graft_start_build` | Admit a signed structural or deep job and return its ID |
| `graft_build_status` | Read job state and summary coverage |
| `graft_cancel_build` | Cancel one signed job and retain partial artifacts |
| `graft_query` | Read a terminal graph through six upstream retrieval operations |

llama.cpp prefixes those names with `qwen_graft_`. The query operations are
`graft_find_code`, `graft_file_api`, `graft_check_freshness`, `graft_trace_calls`,
`graft_find_all`, and `graft_repo_map`. The wrapper imports Graft's tools module
directly. Upstream MCP startup and its upkeep are outside the query path.

Each WebUI start or cancellation asks for fresh approval of the exact arguments,
even when generic tool permissions were remembered. The broker signs the
operation, configuration digest, repository directory identity and Git HEAD.
The signature also binds each approved source directory's device/inode identity.
The worker and query process pin those directories through descriptors and pass
them to bubblewrap's read-only FD mounts. Replacing a directory invalidates the
approval; changing ordinary file bytes in place retains the documented live-input
semantics. The workflow consumes the nonce once. The native completion schema omits the
broker-owned authorization field; the execution schema requires it. The UI
adds the token to a fresh transport object rather than the conversation.

The job supervisor acquires a repository lock, launches Graft in bubblewrap,
and returns immediately. Graft's requests then use the existing llama-server;
the supervisor acquires no GPU lease. Holding that lease while waiting on the
server would create a lock cycle. The asynchronous design also keeps MCP's
per-server RPC serialization from blocking status calls for an entire build.

MCP job publication and the full query execution hold shared session-admission
locks. Session drain closes admission before inspecting CPU children, cancels
identity-verified active jobs, and retains the server's independent CUDA teardown
proof. Unknown child processes keep the retirement refusal. Manual CLI operations
remain independent of session admission.
Exited unreaped workers require matching retained owner generations, terminal
status and job configuration. Each session keeps helper diagnostics in private
`server-retirement.log`, state transitions in `session-drain.record`, and runtime
messages in `server.log`.

Only approved source directories and query graphs are mounted read-only.
Repository Git metadata is also mounted read-only for Graft's repository
operations, including linked-worktree metadata. Source scope bounds the scan;
the scope is not a confidentiality boundary around committed Git history.
Builds write their own graph and scratch directories. The supervisor retains
bounded, credential-redacted logs, deadlines, identities and terminal state.
Deep jobs share host networking to reach the configured loopback endpoint;
that mechanism is not an egress firewall. Git HEAD binds committed identity;
dirty working-file bytes remain live inputs. Query excerpts likewise use live,
read-only source bytes and report recorded/current HEAD identities.

## Configuration

Select `PYTHON` explicitly. Install bubblewrap and the patched Graft package,
or set `graft_package_root` to an extracted package containing its dependencies.
Sandbox admission requires Bubblewrap's `--ro-bind-fd` option. Ubuntu 24.04's
0.9.0 package lacks that option; CI builds checksum-pinned 0.12.0 and verifies
a real descriptor mount before running the sandbox tests. Its hosted-runner
user-namespace policy follows Bubblewrap's upstream CI.
Create private API and signing-key files of at least 16 bytes. Keep the API key
named `api.key` in the desired session-state directory. The signing key is a
different secret. Each key file requires owner-only permissions.

The operator owns a JSON configuration with this shape:

```json
{
  "version": 1,
  "artifact_root": "/absolute/qwen-nvidia/.local-artifacts/graft-discobsd",
  "graft_executable": "/usr/bin/graft",
  "graft_package_root": "/usr/lib/node_modules/@nanonets/graft",
  "bwrap_executable": "/usr/bin/bwrap",
  "authorization_key_file": "/absolute/private/graft-signing.key",
  "repositories": {
    "discobsd": {
      "path": "/absolute/discobsd-2040-unofficial",
      "allowed_paths": ["sys/arch/rp2040/dev"]
    }
  },
  "model": {
    "base_url": "http://127.0.0.1:8080/v1",
    "name": "qwen-nvidia",
    "api_key_file": "/absolute/private/graft-session/api.key"
  },
  "limits": {"seconds": 900, "log_bytes": 1048576, "maximum_paths": 4}
}
```

Add repository IDs to extend the workflow. An empty `allowed_paths` list admits
the whole registered repository; an empty requested path list selects the
configured allowance. Whole-repository admission should follow a bounded pilot.
The wrapper uses explicit scope and bypasses ignore files inside that scope,
so choose directories that exclude private inputs and irrelevant build output.

```sh
scripts/build-llama-ui.sh
QWEN_MODEL_PATH=/absolute/model.gguf QWEN_CONTEXT_SIZE=16384 \
  QWEN_CHAT_REASONING_BUDGET=512 \
  scripts/qwen-graft-launch.sh /absolute/workflow.json
```

Enter the session API key in the native UI settings. Ask the agent to start a
deep build for `discobsd` restricted to `sys/arch/rp2040/dev`, approve the exact
proposal, then ask for status and context. The native UI keeps its existing
tools, permissions, attachments and model interface. Existing web/sidecar
launch routes remain available. `QWEN_GRAFT_BASE_MCP_CONFIG` composes trusted
MCP entries into the standalone Graft launch; profiles and signing keys must
agree with the shared broker. The launcher refuses conflicting composition.
Unrestricted shell/edit tools remain an explicit operator choice because they
can bypass the narrower Graft source boundary.

The launcher freezes configuration and MCP JSON into content-named snapshots.
It serves authenticated loopback traffic, enables Jinja tool parsing and uses
the native UI. The broker defaults to port 8571. A custom broker port also
requires the UI's `?broker=http://127.0.0.1:PORT` setting.

Manual use shares the same job implementation:

```sh
"$PYTHON" scripts/graft-workflow.py --config /absolute/workflow.json \
  start --repository discobsd --mode structural --path sys/arch/rp2040/dev
"$PYTHON" scripts/graft-workflow.py --config /absolute/workflow.json status JOB_ID
"$PYTHON" scripts/graft-workflow.py --config /absolute/workflow.json \
  query JOB_ID graft_file_api --arguments '{"file":"sys/arch/rp2040/dev/flash_swap.c"}'
"$PYTHON" scripts/graft-workflow.py --config /absolute/workflow.json cancel JOB_ID
```

Other agent clients register `"$PYTHON" scripts/graft-workflow.py --config CONFIG
mcp` with `QWEN_GRAFT_SESSION_BARRIER` and `QWEN_GPU_ADMISSION_BARRIER` both
set to the running session's state directory (the parent of `api.key`). The
generated session MCP JSON supplies those bindings. Their execution layer must acquire start/cancel grants from the broker
after approval. Supplying arbitrary token strings from an LLM fails admission.
The existing `graft-consumer-env.sh` gate checks the named-function object
contract for direct deep-indexing clients. Every curl/wget example or task probe
uses a Mozilla user agent; GitHub source retrieval uses `gh`.

## Downloaded model choices

The two additional candidates beyond the 4B and 7B-coder tests are
**Qwenseer-2B Q4_K_M** and **Klear-AgentForge-8B Q6_K**. Both passed three fresh
`record_symbols` requests covering seven canonical target IDs. Qwenseer is the
interactive choice: the observed requests took 2.35-3.55 seconds versus
15.23-59.86 seconds for Klear. These are functional-probe elapsed times under
workstation load, rather than controlled comparative throughput benchmarks.
Two target spans in the older input graph were ungradeable; neither model was
credited with proving those spans.

Qwenseer also chose the build tool with `tool_choice=auto`, then completed the
eight-file deep pilot with 137 ready nodes, zero pending and zero stale, in
about 100 seconds. The concept pass produced nine concepts and zero links.
Coverage does not establish semantic truth. Retained Klear semantic evidence
passes three of six questions, so Klear is an alternative, not a proven quality
upgrade. Corrected Qwen3-4B-Instruct-2507 and the 4B distill remain useful
reference models; the earlier 2507 dropped-ID result included a collector defect.

Phi-4-mini's packaged template lacks the required tool branch. SWE-Dev and
SWE-agent-LM retained forced-call termination failures. A coding label alone
does not establish Graft compatibility. The endpoint, chat template, exact
tool-choice object, argument fidelity and sufficient output budget all matter.

## CUDA, Tensor Cores, OptiX and PhysX

Tensor Cores are execution units inside the CUDA backend, not a second backend
to combine with CUDA. Narrow quantized decode uses MMVQ where the dispatcher
selects it; wider matrix work can use MMQ/Tensor Core kernels. The custom SM89
closure already carries graphs, fusion, mixed-KV flash-attention kernels and
measured Q6_K/Q8_0 dispatch thresholds of 10/16. Forced cuBLAS or MMQ is not a
universal improvement. Preserve those defaults until task-shaped measurements
justify a change.

The inspected promoted closure was `192d0663a533`, built from llama.cpp
`f280b26983ad0fdb705a0d9ebf0503e76f2899b0`, with nvcc 13.4.59 and g++-15.
The fresh host reported driver 615.71.09. Older driver-bound performance records
retain their original authority; the model contract probe does not revalidate
their speedups. The existing named-function object patch already repaired
llama.cpp's API parsing defect. The new runtime repair establishes SCHED_OTHER
explicitly because renice alone preserves inherited SCHED_IDLE.
The workload-lease patch also records ownership when teardown retains an
active request's lease; the conditional log covered only idle reacquisition.
The observation repair preserves acquisition, synchronization and release policy.

OptiX accelerates geometry/ray-query tools; PhysX supplies CUDA physics tools.
Neither mechanism accelerates ordinary transformer inference. Their separately
admitted resident-service and GPU-ownership paths remain unchanged. Graft
extraction uses CPU parsing; only deep summaries consume the model endpoint.

Primary references:

- [Pinned Graft source](https://github.com/trailhq/Graft/tree/de8456e892bad5aeee11403e47fb2227773eb27e)
- [llama.cpp server tools and API](https://github.com/ggml-org/llama.cpp/blob/c550d2f60bde72df19fcef1fef627895095b8ba8/tools/server/README.md)
- [NVIDIA Ada tuning guide](https://docs.nvidia.com/cuda/ada-tuning-guide/)
- [NVIDIA OptiX](https://developer.nvidia.com/rtx/ray-tracing/optix)
- [PhysX GPU rigid bodies](https://nvidia-omniverse.github.io/PhysX/physx/5.4.1/docs/GPURigidBodies.html)

The linked PhysX manual documents 5.4.1; local SDK evidence owns the 5.9 runtime.

## Verification and limits

Run `scripts/repository-quality-gates.sh` with exported `PYTHON`. Focused gates
include `test-graft-workflow.py` (real bubblewrap), `test-graft-launch-config.py`
(HTTP broker and composition), `test-graft-admission.py` (real session locks),
`test-graft-cpu-retirement.py`, `test-serving-startup-regressions.py`,
`test-graft-consumer-env.sh`, `test-native-graft-grant.mjs` and
`test-build-llama-ui.sh`. The standalone package has extraction, collector and
packaged-ELF tests in its own repository.

The API pilot exercised chat selection, signed launch, status and query through
the native server endpoint. UI schema/approval behavior has separate copied-source
type/lint and fixture evidence. That combination does not claim an attended
browser-click test. The native production bundle also reports upstream npm
deprecations and a chunk-size advisory; type/lint checks reported zero warnings.
Retain each result within its measured boundary.
