# Web router admission through the router port

`remote/admit-web-router-fake.sh` runs the merged web path on the appliance
with every tool request on the router port, against a closure that carries
`patches/llama-router-tools-proxy.patch`. `evidence/web-admission-fake.md`
found that the pinned `server.cpp` registers `/tools` only in the process
whose own MCP manager holds a server, so the router answered
`403 feature_disabled` and the executor was reachable on the child's internal
port alone. The patch registers `/tools` on a tool-free router as `proxy_get`
and `proxy_post`, and this run measures the page's path as the page performs
it: `GET /tools?model=<alias>&autoload=true` for the listing and
`POST /tools` with `{model, tool, params, stream: false}` for execution. The
checked-in `remote/web-profiles.tsv` stayed at `execution_policy=refused`; the
one-row ledger the harness writes names `web-balanced-admission` at 8192
tokens, `max_results` 3, `max_fetches` 1, `max_chars_per_fetch` 12000.

## Terms

```text
closure:        llama.cpp f280b269 plus the five-patch production series, preset
                raven2-vulkan-production, promoted to build-appliance-current
llama-server:   4117a9c4d58e530c3c5ef6934596ae6d257ca61ef80c5f0f8a5ee71d1d63ca79
llama-cli:      59b8154a83cb3da1555e07330a7ca7bf5cefd3de2603791302f2c29388e9c21c
llama-bench:    557d6690d338bc79b81ea690762a0d8987c0ca66f3c122a5fcc0f2a8420df092
llama-mtmd-cli: dd094cfbddf4bc971c003a3612b8a83a34c6f39e05b6cac871ed78cdd98e54af
server.cpp:     d2d5cb43a83c6b2b459b85f2df181a3d976efcaef351e5cbc6b418ba839390e3
router:         127.0.0.1:8080, QWEN_ROUTER_MAX=1, one preset section
broker:         127.0.0.1:8571, --profile web-balanced-admission --provider fake
child:          the router's model process, loopback port assigned at load
MCP child:      python3 server.py --provider fake, timeout_ms 30000
fixture:        remote/test-fixtures/web-fake-provider.json, with two delayed
                queries at 5 s and 40 s
page:           webui/index.html, served by qwen-web-launch.sh through
                QWEN_STATIC_PATH; the ordinary router keeps the pinned llama UI
browser:        Chromium 151 headless on the appliance, driven over the
                DevTools protocol by remote/web-mcp/drive-fallback-page.py
api key:        minted by the session at $HOME/qwen-webui-state/api.key,
                0600; the router answers 401 and the broker's /session 403
                without it, and the harness and the driven page carry it
                the way the page's authHeaders() does
outage:         23:11:49Z to 23:17:28Z, ordinary router restored
```

The promotion ran the tree's own gate first (`promotion-chain.log`): one token
through `llama-cli` entirely on Vulkan, an image read through `llama-mtmd-cli`
whose answer carries the declared content, and the artifact manifest matching
the build byte for byte. `remote/test-strict-vulkan-placement.sh` then
required CPU tensor placement and CPU graph placement to be rejected and
completed a strict Vulkan run on the 4B distill
(`strict-vulkan-placement/`). The laptop rebooted between the promotion and
the strict check from an unrelated `vkpeak` run at the desktop; the promotion
symlink survived and the chain resumed from the strict step.

## Registered falsifiers

The run fails when any required check fails, and the set grew over the first
run's by the router-port checks: `GET /tools` without `model` or with an
unknown alias answers anything but a refusal; the listing on the router port
names anything but `web_search_exa` and `web_fetch_exa`; `POST /tools`
without `model` or with an unknown alias executes; a `params.model` reaches
the tool unrefused; the 5 s query fails to complete through the router; the
40 s query is answered by anything other than HTTP 200 carrying the child's
own `request timed out` inside the 25 to 40 s window, or a granted search
after the provider's sleep has ended fails to execute; the router or the
broker's `/session` answers a request without the API key; the
restored ordinary router serves a tool for any of its models; loading a
second model under `models-max=1` leaves the first loaded. The first run's
falsifiers all remain: loopback listeners, sole profile, broker identity,
`/session` and `/grant` gates, single use, allowance, Result ID signature,
secret hygiene, teardown residue, roster restoration.

## Results

Four runs were made on this closure. The first passed every check but the
eviction one, where the harness read the roster while the first model was
still `loading` because `POST /models/load` returns before the child is
resident; the harness now polls the roster until the model reads `loaded`.
The second passed every check and recorded the page-side check as observed,
because the router served the pinned llama UI build. The third served the
fallback page and ran the browser arm, which passed every routing check and
failed `browser_tool_result_in_transcript`: the fake provider keys results on
the exact query, the fixture held `raven2 vulkan decode`, and the model
composed `raven2 vulkan decode rate` in the dialog, so the search executed
through the router with a grant and returned `No results.`;
`browser-turn-fixture-miss.json` retains that turn. Three more runs followed the merge of `origin/main`, which made web mode
mint a bearer API key that the router and the broker's `/session` route both
demand: the first failed every router request at 401 until the harness and
the driven page carried the key; the next two collided, because the second
was started while the first was still running and its teardown removed the
first's web session, which is what the admission lock now refuses; and one
run of the harness alone missed the fixture again on `Raven2 Vulkan decode
rate`, a capitalization the exact-string lookup could not see, so the fake
provider now matches a key by its words. That run also exposed a harness
edit that had dropped the eviction check's first load. The final run is
retained whole here with the grants, session secret, and key digest
redacted; the API key stays in the state directory and in no retained file.
A review of that run tightened three checks and two more runs followed: the
stall check now requires HTTP 200 with the child's own message, the
after-stall check runs a granted search once the provider's sleep has
ended, and the driven page receives the broker origin as `?broker=`. The
first of those runs met the broker's authorize-minute limit on the
after-stall grant, 6 per 60 s, which the harness now records as the limit
working and waits out; the run retained here is the second.

| check | result |
| --- | --- |
| ordinary router recorded (absent after promotion), preset generated | pass |
| web launch, signing key, sole profile, provider | pass |
| router and broker listeners | pass, `127.0.0.1` alone |
| `broker_pid` recorded, secret at 0600 | pass |
| roster and served depth | `web-balanced-admission`, `n_ctx` 8192 |
| API key minted at 0600 | pass |
| `GET /tools` without the key | 401 |
| broker `/session` without the key | 403 |
| `GET /tools` without `model` | 400, `model name is missing from the request` |
| `GET /tools?model=no-such-model` | 400, `model 'no-such-model' not found` |
| `GET /tools?model=web-balanced-admission&autoload=true` | both tools, on the router port |
| child port, direct `GET /tools` (control) | observed, both tools |
| served page composes the model-scoped routes | observed: the appliance serves the pinned llama UI build, not the fallback page |
| broker `/health` identity | pass |
| `/session` gates | admitted origin 200; foreign, absent, name host 403 |
| `/grant` gates | issued 200; wrong profile, wrong session, foreign origin 403 |
| `POST /tools` without `model` | 400, refused |
| `POST /tools` with an unknown alias | 400, refused |
| search with `{model, tool, params, stream: false}` | pass, 2 results, Result IDs, on the router port |
| grant replay | refused, `the authorization is spent` |
| search without a grant | refused |
| `model` inside `params` | refused, `the call carries an argument the tool does not read: model` |
| fetch by Result ID | pass, 632 characters, on the router port |
| second fetch under allowance 1 | refused, `fetch budget of 1 is exhausted` |
| fetch naming a URL | refused, `signature fails verification` |
| 5 s provider delay | completes, elapsed 5 s, HTTP 200 with results |
| 40 s provider stall | HTTP 200 with the child's own `request timed out` at 30 s; a 5xx or proxy failure in the window fails the check |
| after the stall | listing intact, and a granted search executed once the provider's own 40 s sleep had ended |
| model proposes the search | observed, `web_search_exa` with the query |
| model reads the tool result | pass, answer states `3.07 tok/s` |
| secret hygiene | pass |
| teardown and absence | pass, router, child, broker, secret, both ports |
| ordinary router restored | pass, seven-model roster |
| `GET /tools?model=lfm25-vl-16b` on the ordinary router | 403 `feature_disabled` |
| load `qwen35-08b` then `qwen38-2b-distill` under `models-max=1` | `lfm25-vl-16b` resident at restore; first `loaded`, then `unloaded`; second `loaded` |
| resident set after the eviction check | pass: both loaded models unloaded, `lfm25-vl-16b` reloaded, statuses equal before and after |

The browser arm's checks read the request log the page's own `fetch` wrote:

| check | result |
| --- | --- |
| served page composes the model-scoped routes | pass, `webui/index.html` |
| page origin and selected model | `http://127.0.0.1:8080`, `web-balanced-admission` |
| listing | `GET /tools?model=web-balanced-admission&autoload=true`, once |
| grant | `POST 127.0.0.1:8571/grant`, once, after `GET /session` |
| search | `POST /tools` `{model: web-balanced-admission, tool: web_search_exa, stream: false}`, grant present, query equal to the dialog's |
| every request | names the router origin or the broker origin |
| tool message in the transcript | `Result ID:` present, the fixture's two results |
| fetch | observed: the model proposed none |
| final answer | pass, `3.07 tokens/second` read from the tool result |

The page made six requests in the turn: the listing, the completion that
proposed the search, the session secret, the grant, the search, and the
completion that read the result. `browser-turn.json` retains them with the
grant removed from the search body.

## What the routing key proves

`server-tools.cpp` reads `tool`, `params`, and `stream` from the body and
forwards `params` to the MCP child, and `server.py` refuses any argument
outside a tool's `inputSchema` by name. The search that carried `model` at
the top level executed, and the control that placed the same key inside
`params` was refused naming it, so the router's routing key demonstrably
stops at the router and a later parser that forwarded it would fail this
check rather than run the search.

## The three deadlines are ordered

The generated MCP configuration names `timeout_ms` 30000, the fake provider
holds a query for the seconds the fixture names, and the router proxies with
llama-server's 3600 s read timeout. The 5 s query completed through the
router with its results, and the 40 s query was answered at 30 s by the
child's own deadline as an error body at HTTP 200 (`request timed out`),
which is the shape `mcp_result_to_response` gives every refusal. The listing
answered on the next request, so the stalled call left the child and its MCP
process serving. The provider's own 20 s request timeout in `server.py` is
not exercised by the fake provider, which sleeps rather than waits on a
socket; its position inside the 30 s child deadline is a code fact rather
than a measured one here.

## What the run establishes and leaves open

The fixed router port is the only address the page needs: listing,
execution, and every refusal ran there, the child's port was read once as a
control, and the ordinary roster on the same binary exposes no tool because
its sections carry no MCP configuration. Authority remains conjunctive: the
selected child's configuration, the ledger's `execution_policy`, the loopback
listener, the identity-checked broker, the human's approval, and the
single-use grant all still gate a call, and the patch forwards a route
without adding a grant.

The browser ran the served page through the same turn, so the executor the
user runs is measured rather than read: its listing and its search reached
the router port with the model beside the tool, its grant came from the
broker under the session secret, and nothing it sent left those two origins.
The dialog approved was the page's own, clicked by the driver where a user
would click it; the driver adds one `fetch` wrapper for the log and no other
code. The checked-in ledger stays `refused`; promotion of a web profile waits
on the live Exa smoke through this same page and the graded web rows.
