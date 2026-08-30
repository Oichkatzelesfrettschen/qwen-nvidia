# Web router admission through the router port

This record is the prior host's run of `scripts/admit-web-router-fake.sh`
against a Vulkan build. Every build identity, timing, and device-observed
result that run produced belongs to that host and is not restated here as a
claim about this device; the prior host's raw records live in the qwen-apu
repository. `scripts/admit-web-router-fake.sh`, `patches/llama-router-tools-proxy.patch`,
`scripts/web-profiles.tsv`, and `webui/index.html` are unchanged mechanism this
tree still ships, so the source-level claims below -- what the patch
registers, what the routing key proves, how the three deadlines stack -- hold
from the code alone and are kept. The specific pass/fail table, the build
hashes, and the run narrative are prior-host history and are not repeated
here. A fresh run of `scripts/admit-web-router-fake.sh` on this device is the
open item that would produce this document's own next version.

## What the patch changes

At `f280b269` `server.cpp` registers `/tools` only in a process whose own MCP
manager holds a server, so an unpatched router answers `403 feature_disabled`
while the child serves the route on an internal loopback port
(`evidence/web-admission-fake.md`). `patches/llama-router-tools-proxy.patch`
registers `/tools` on a router that holds no tools of its own as `proxy_get`
and `proxy_post`: `GET` resolves `?model=` and `POST` resolves the body's
top-level `model` key the way `/props` and `/v1/chat/completions` do, and the
child that read the section's own configuration executes the call.

## What the routing key proves

`server-tools.cpp` reads `tool`, `params`, and `stream` from the body and
forwards `params` to the MCP child, and `server.py` refuses any argument
outside a tool's `inputSchema` by name. A search that carries `model` at the
top level executes, and a control that places the same key inside `params` is
refused naming it, so the router's routing key demonstrably stops at the
router and a later parser that forwarded it would fail that check rather than
run the search.

## The three deadlines are ordered

The generated MCP configuration names `timeout_ms` 30000, the fake provider
holds a query for the seconds its fixture names, and the router proxies with
llama-server's 3600 s read timeout. A 5 s query completes through the router
with its results, and a 40 s query is answered at 30 s by the child's own
deadline as an error body at HTTP 200 (`request timed out`), which is the
shape `mcp_result_to_response` gives every refusal. The listing answers on the
next request, so a stalled call leaves the child and its MCP process serving.
The provider's own 20 s request timeout in `server.py` is not exercised by the
fake provider, which sleeps rather than waits on a socket; its position inside
the 30 s child deadline is a code fact rather than a measured one.

## What the harness establishes and what remains device-specific

The fixed router port is the only address the page needs: listing, execution,
and every refusal resolve there in source, the child's port is read once as a
control, and the ordinary roster on the same binary exposes no tool because
its sections carry no MCP configuration. Authority remains conjunctive: the
selected child's configuration, the ledger's `execution_policy`, the loopback
listener, the identity-checked broker, the human's approval, and the
single-use grant all still gate a call, and the patch forwards a route
without adding a grant.

The checked-in `scripts/web-profiles.tsv` reads `execution_policy=refused` in
this tree, the same as it read on the prior host before that host's own
campaign. Promotion of a web profile waits on the live Exa smoke through the
served page and the graded web rows, run against this device.
