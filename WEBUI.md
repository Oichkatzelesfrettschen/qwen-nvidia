# Web UI

## Deployment boundary

The workstation runs one `llama-server` process, the runtime monitor, and no
graphical client of its own beyond the desktop already on the machine. Two
deployments differ only in the listener address.

The workstation is the whole system. `http://127.0.0.1:8080` is the canonical
address, and the model, the projector, the static UI, and the guards all live
on the machine running the browser when the browser opens locally, so the
appliance answers with the network off. `qwen-launch.sh` binds loopback by
default. The tunnel and the LAN listener below are conveniences for reaching
this host's appliance from a separate client machine.

An SSH tunnel from a remote client keeps both endpoints on loopback and
serves the operator alone:

```text
remote client browser -> client 127.0.0.1:8080 -> SSH tunnel
                       -> host 127.0.0.1:8080 -> guarded llama-server
```

`QWEN_BIND_HOST=0.0.0.0` serves every browser on the network directly:

```text
any browser on the LAN -> host:8080 -> guarded llama-server
```

The server fixes one slot and one inference sequence per request. `QWEN_BIND_HOST`
sets the listener and defaults to `127.0.0.1`; `QWEN_CORS_ORIGINS` sets the
allowed origins and defaults to `localhost`. The server runs without an API
key at every bind address. A key authenticates a caller on a shared network
and withholds nothing the model itself protects, so a local model on a
trusted network serves the page directly. `QWEN_REQUIRE_API_KEY=1` mints one
at `$HOME/qwen-webui-state/api.key` with mode 0600 and makes llama-server
demand it; the browser then keeps the entered key in tab-scoped session
storage. The page requests `/v1/models` first, so it reaches a keyless
server and prompts only when a server answers 401. Each roster selection
then requests the encoded `/props?model=<id>` endpoint and tokenizes
attachments through the same model id. A model change marks both values
pending until matching responses return.

With `--parallel 1` the slot serves one request at a time. A second person
waits for the first to finish. Raising `--parallel` divides the KV cache
between slots and lowers the context each person gets, so the single slot
stands.

A queue-priority probe measures whether the desktop's own graphics work
preempts inference the way the server's queue setting asks it to.
`QWEN_LATENCY_MODE` selects what a missed deadline does: `observe`, the
default, counts breaches against a 20 ms service deadline sampled every 16 ms
and keeps serving; `terminate` stops the server on the first late frame and
is retained for deliberately strict runs. A fence that returns anything other
than success ends the run in both modes, because that is a device fault
rather than a scheduling delay. No run on this host has measured the
percentile distribution that would justify preferring one mode as the
default; `evidence/legacy/raven2/comparative-findings.tsv` carries the prior
host's own queue-scheduling findings and none of them set a default here.

## Runtime provenance

The Git checkout and the runtime share this host, so no separate deployment
mirror exists and no path below names a different machine. `$HOME/src/llama.cpp-qwen-nvidia`
is the llama.cpp checkout `scripts/build-llama-cuda.sh` builds from, and
`$HOME/src/llama.cpp-qwen-nvidia/build-qwen-cuda-sm89/bin/llama-server`
(or the promoted `build-appliance-current` build) is the CUDA-and-Vulkan
binary the launch chain execs.

The pinned binary omits embedded SvelteKit assets but retains `--path`,
`--ui`, OpenAI-compatible routes, API-key files, Web UI configuration, and
static-file serving. `webui/index.html` is this repository's adaptation of
the MIT-licensed qwen-lab single-file diagnostic page. It uses the loaded
server's `/tokenize` route, accepts text attachments, exposes reasoning
separately, and prefers server-reported prefill and decode timing. It
contains no external resources and starts no second process on the host.
`qwen-webui-control.sh` serves a pinned llama.cpp UI build under
`webui-llama-ui/` when that directory holds an `index.html`, and
`qwen-web-launch.sh` sets `QWEN_STATIC_PATH` to `webui/` because the web
path's executor is this page: it scopes `GET /tools` by model and posts the
routing key beside the tool, which the pinned build does not.

## Start and connect

`qwen-webui-control.sh` runs the session inside its own tmux session, so it
outlives the terminal that started it.

Start locally, serving the network at the 24,576-token ceiling:

```sh
QWEN_BIND_HOST=0.0.0.0 scripts/qwen-webui-control.sh start
```

Start locally, serving the operator alone over loopback:

```sh
scripts/qwen-webui-control.sh start
```

`start` defaults to 24,576 tokens, `observe` latency mode, port 8080, and the
CUDA-serving default profile. `QWEN_CONTEXT_SIZE`, `QWEN_REQUIRED_VULKAN_MIB`,
`QWEN_SERVER_PORT`, and `QWEN_LATENCY_MODE` override each in turn.

Read the API key and enter it in the page:

```sh
scripts/qwen-webui-control.sh key
```

A LAN reader opens `http://HOST:8080` directly, naming this host's own
address. A remote client instead keeps a tunnel running on its own machine
and opens `http://127.0.0.1:8080`. The helper forwards the approval broker on
port 8571 beside the server, run from the remote client:

```sh
./scripts/connect-qwen-webui.sh HOST 8080 8080
```

When the browser-facing server port differs from the server's own port, bind
the broker to that exact browser origin before starting the session:

```sh
QWEN_WEB_BROKER_ORIGIN=http://127.0.0.1:18080 scripts/qwen-webui-control.sh start
./scripts/connect-qwen-webui.sh HOST 18080 8080
```

`QWEN_WEB_BROKER_LOCAL_PORT` and `QWEN_WEB_BROKER_PORT` override the local
and remote broker tunnel endpoints together with the matching Web UI broker
configuration.

Inspect status and retained log tails:

```sh
scripts/qwen-webui-control.sh status
```

Stop the server and its tmux session:

```sh
scripts/qwen-teardown.sh
```

## Web search and image generation

A web search reaches the network through one human approval, and the browser
is the executor. llama-server reads `tools` from the client body alone and
runs a wrapped MCP tool through the standalone `POST /tools` route, so the
page composes `body.tools` from `GET /tools?model=<id>&autoload=true` when
the per-turn Web toggle is on. A proposed search or fetch opens a dialog
naming its parameters, and an approval posts those exact parsed fields to
`scripts/web-mcp/authorize-broker.py` and posts the returned single-use grant
inside one `POST /tools` request; the token reaches the server once and stays
out of the transcript every later request re-sends.

An image generation reaches the device the way a search reaches the network,
gated by the same kind of single-use grant and a workload lease that keeps
one generation running at a time. The Review button on a generated artifact
card sends the image to a vision model through a request that carries no
`tools` key, so a review verdict can propose a correction but never execute
one directly; a correction is itself a fresh proposal requiring its own
approval. `CLAUDE.md` carries the full state machine, schema, and grant
mechanics for both lanes.

## UI selection

| UI | Fit for this deployment | Decision |
| --- | --- | --- |
| llama.cpp embedded Web UI | Same-process UI with the widest upstream-tested llama.cpp feature coverage | Preferred after a separately hash-pinned UI-enabled rebuild |
| This repository's static panel | Same-process, text and image attachments, exact tokenizer counts, server timing, no remote GUI, model-scoped tool routing | Selected as the default fallback page |
| Open WebUI | Strong history, RAG, RBAC, PWA, and OpenAI-compatible integration | Run on a client workstation and connect through SSH, if ever needed |
| LibreChat | Strong multi-provider, multi-user, MCP, and authentication surface | Excess service and database scope for a one-slot host |
| LobeHub | Polished multi-provider self-hosted application | Excess container and database scope |

Primary sources:

- https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md
- https://github.com/open-webui/open-webui
- https://github.com/danny-avila/LibreChat
- https://github.com/lobehub/lobehub
