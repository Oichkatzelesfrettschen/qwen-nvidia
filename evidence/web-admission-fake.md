# Web router admission against the fake provider

`scripts/admit-web-router-fake.sh` runs the merged web path on the appliance
with nothing reaching a network: the production `llama-server`
(`3d5b158160b08cf8...`, `build-qwen-vulkan`), one real router child serving
the 4B distill, `authorize-broker.py`, and the `server.py` MCP child under
`--provider fake`. Every request the fallback page would make runs with curl in
its place, and every boundary the design relies on is provoked once. The
checked-in `scripts/web-profiles.tsv` stayed at `execution_policy=refused`; the
one-row ledger the harness writes names `web-balanced-admission` at 8192 tokens,
`max_results` 3, `max_fetches` 1, `max_chars_per_fetch` 12000.

## Terms

```text
closure:        production llama-server at f280b269 plus the five-patch series
router:         127.0.0.1:8080, QWEN_ROUTER_MAX=1, one preset section
broker:         127.0.0.1:8571, --profile web-balanced-admission --provider fake
child:          the router's model process, loopback port assigned at load
MCP child:      python3 server.py --provider fake, stdio under the child
fixture:        scripts/test-fixtures/web-fake-provider.json
outage:         18:08:56Z to 18:10:51Z, ordinary router restored
```

## Registered falsifiers

The run fails when any required check fails: the router or broker listens
anywhere but the loopback literal; the roster names more than the one profile;
the tool list names anything but `web_search_exa` and `web_fetch_exa`; the
broker's `/health` names another pid, profile, or provider than the launch
recorded; `/session` answers a foreign or absent Origin or a name in `Host`;
`/grant` answers a wrong `profile_id`, a wrong session header, or a foreign
Origin; a spent grant, an absent grant, a fetch past the allowance, or a
`result_id` that is a URL executes; the key bytes, the grant, the session
secret, or the query text appear in any process image, log, status file, or
audit row; teardown leaves a process, a secret, or a port; the restored router
serves a different roster than the one found.

## Results

Two runs preceded the retained one and both were harness defects rather than
appliance findings: the ledger header was read as a data row, and dash ends the
shell on `shift 4` past `$#`. The third run is retained whole under
`evidence/web-admission-fake/` with the grant, session secret, and key digest
redacted.

| check | result |
| --- | --- |
| ordinary router recorded and torn down | pass, no residue |
| preset generated from the test ledger | pass, one section |
| web launch, signing key, sole profile, provider | pass |
| router and broker listeners | pass, `127.0.0.1` alone |
| `broker_pid` recorded, secret at 0600 | pass |
| roster and served depth | `web-balanced-admission`, `n_ctx` 8192 |
| `GET /tools` on the router port | 403 `feature_disabled` (finding) |
| child port discovered, `GET /tools` on it | pass, both tools |
| broker `/health` identity | pass |
| `/session` gates | admitted origin 200; foreign, absent, name host 403 |
| `/grant` gates | issued 200; wrong profile, wrong session, foreign origin 403 |
| search through the child and the MCP child | pass, 2 results, Result IDs |
| grant replay | refused, `the authorization is spent` |
| search without a grant | refused |
| fetch by Result ID | pass, 632 characters |
| second fetch under allowance 1 | refused, `fetch budget of 1 is exhausted` |
| fetch naming a URL | refused, `signature fails verification` |
| model proposes the search | observed, `web_search_exa` with the query |
| model reads the tool result | pass, answer states `3.07 tok/s` |
| secret hygiene | pass |
| teardown and absence | pass, router, child, broker, secret, both ports |
| ordinary router restored | pass, seven-model roster unchanged |

## The router does not serve `/tools`

`tools/server/server.cpp:347-360` at f280b269 registers `GET /tools` and
`POST /tools` on `tools.handle_get` and `tools.handle_post` when the process's
own `mcp_mgr` holds a server, and on `res_403` otherwise. The router branch at
`server.cpp:199-231` proxies chat completions, props, slots, tokenize, and the
rest through `models_routes->proxy_get` and `proxy_post`, and names `/tools`
nowhere. The router process holds no MCP configuration by design, because
`common_preset::merge` would copy a router-level argument into every section,
so the router answers `feature_disabled` while the child that read the
section's `LLAMA_ARG_MCP_SERVERS_CONFIG` serves the route on the loopback port
`server-models.cpp` assigned it (`CHILD_ADDR` is `127.0.0.1`, port 32963 in
this run).

The harness reads that port from the listening sockets `llama-server`
processes hold beside the router's and runs the executor checks there, which
is what makes the rest of the table measurable on the current closure. The
fallback page cannot do the same: it targets `/tools` on its own origin,
learns no child port, and would meet a cross-origin child. On this closure the
browser path therefore ends at `GET /tools` with `feature_disabled`, and the
executor evidence above is from curl at the child port alone.

Three ways close the gap and the choice is a deployment decision rather than
a measurement:

1. A patch registering `/tools` in the router branch on `proxy_get` and
   `proxy_post`, with the page naming the model on `GET /tools?model=` and in
   the `POST /tools` body. `handle_post` reads `tool`, `params`, and `stream`
   from the body (`server-tools.cpp:2080-2083`), so an added `model` key is
   inert at the child. This changes the served closure and joins the patch
   series.
2. `LLAMA_ARG_MCP_SERVERS_CONFIG` on the router process, which serves `/tools`
   from the router and runs the MCP child there. `common_preset::merge` copies
   the value into every section, so it holds only while the preset carries
   one section, which `qwen-web-launch.sh` now requires; it also places the
   executor in the router process rather than the model child.
3. A standalone web launch outside router mode, which forgoes the preset file
   and the per-profile section the ledger is built on.

Until one is chosen, `scripts/web-profiles.tsv` stays refused and the page's
Web toggle reaches no executor on the appliance.

## Two defects found and repaired before the run

The generated MCP configuration named `QWEN_WEB_SEARCH_KEY_FILE`,
`QWEN_WEB_MAX_RESULTS`, `QWEN_WEB_MAX_FETCHES`, and
`QWEN_WEB_MAX_CHARS_PER_FETCH`, and `server.py` read `QWEN_WEB_EXA_KEY_FILE`,
`QWEN_WEB_MAX_FETCHES_PER_SEARCH`, and neither cap. A live Exa child would
have found no key and every profile would have run at the server's own caps.
The generator now emits the names the server reads, `server.py` reads the two
caps and bounds each call by them, and the fake provider's fixture path travels
as `QWEN_WEB_FAKE_FIXTURES`. The child's environment keys in
`mcp-child-*.environ-keys` show the corrected set.

`POST /grant` required the loopback Host and the session secret and echoed
the Origin without gating on it, so a request from `http://localhost:8080`
carrying the secret was signed. The secret is issued through `/session`, which
the allowlist gates, so the exposure needed a secret that had already left the
admitted page; the signing route now applies the same allowlist and the
`grant_foreign_origin_refused` row reads 403.

## What the run establishes and leaves open

The broker lifetime, the sole-profile rule, the signing-key rules, the
`/health` handshake, the identity line, and the teardown's start-time
comparison all ran on the appliance under the production closure. The grant
path, the single use, the fetch allowance, the Result ID signature, and the
audit vocabulary all executed through the real `llama-server` tool routes and
the real MCP child. The model, offered the composed tools, proposed
`web_search_exa` with the user's query and, given the search text as a tool
message, answered from it.

The browser was not in the loop. The approval dialog, the grant injection
into `params`, and the transcript hygiene the page performs are tested against
the stdio fixture in `scripts/test-fallback-webui-web-authorization.sh` and
`scripts/test-web-tools-roundtrip.sh`, and their first appliance run waits on
the `/tools` routing decision above. The model altered the query in its own
proposal (`raven2 vulkan decode rate` against the user's `raven2 vulkan
decode`), which is the case the dialog exists for: the grant is signed over
what the human read, and the harness signed the user's query rather than the
model's.
