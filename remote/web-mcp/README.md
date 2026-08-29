# The web research MCP server

`server.py` speaks MCP over stdio and offers two tools, `search_exa` and
`fetch_exa`. llama-server composes the configured server name with each tool
name, so the name `web` in `--mcp-servers-config` produces `web_search_exa` and
`web_fetch_exa`, which the pinned llama-ui renders natively from the
`Title:`/`URL:`/`Published:`/`Author:`/`Highlights:` block layout and the `---`
separator. A server named `exa` would produce `exa_web_search_exa` and reach the
generic renderer instead.

## Launch

`mcp-servers.example.json` carries the launch shape: command, args, env, cwd,
and `timeout_ms`, with placeholder paths for the two key files.

```sh
llama-server --mcp-servers-config /path/to/mcp-servers.json
```

`--provider`, `--exa-key-file`, `--token-key-file`, and `--fixtures` override
`QWEN_WEB_PROVIDER`, `QWEN_WEB_EXA_KEY_FILE`, `QWEN_WEB_TOKEN_KEY_FILE`, and
`QWEN_WEB_FAKE_FIXTURES`. `QWEN_WEB_SEARCH_AUTH` and
`QWEN_WEB_TOKEN_LIFETIME_SECONDS` carry the authorization mode and the token
lifetime.

## The operator authorizes a search; the model does not

A result identifier guards `fetch_exa` alone. A search query is written by the
model, and `evidence/model-admission` records `tool-08` carrying an injected
city into a tool call in place of the authorized one in all six measured arms,
so a note the model reads can rewrite the query it searches for. `search_exa`
therefore takes an `authorization` argument: an HMAC-signed grant over the
query, both domain lists, the publication window, the cached age, the result
count, and an expiry, issued outside the session by

```sh
remote/web-mcp/server.py authorize --token-key-file PATH --query TEXT \
    [--include-domain D]... [--exclude-domain D]... \
    [--published-after DATE] [--published-before DATE] \
    [--max-age-hours N] [--provider exa|fake] [--profile NAME] \
    [--max-results N] [--lifetime SECONDS]
```

`max_age_hours` is covered because 0 forces a live crawl, which is the one
search parameter that spends provider budget on the model's word.

The serving path rebuilds the same canonical claim from the arguments it
received and compares field by field, admitting a smaller `max_results` as a
narrowing of the grant and refusing every other difference.
`QWEN_WEB_SEARCH_AUTH` selects `required`, the default, or `optional` for an
operator who accepts an unauthorized query.

A grant admits one search. Beside the policy the claim carries `grant_id`,
`provider`, `profile_id`, `issued_at`, `expiry`, and `max_uses`, and the
serving path requires the provider and the profile it runs as before it
proceeds, so a token issued for the metered production profile buys nothing
against another profile or another provider. The ledger inserts `grant_id` and
consumes the search call, page, and provider buckets in one `BEGIN IMMEDIATE`
transaction. A replay meets the primary-key constraint before any bucket
changes, while a rate or budget refusal rolls the grant insertion and every
bucket update back. The transaction commits immediately ahead of the provider
request. Every local configuration the reply depends on resolves first -- the
result and fetch caps, token lifetime, all search budget limits, and the
provider credential, which `Provider.preflight` reads from the same file the
request does -- so a local refusal leaves the grant and buckets available. A
presented grant requires `QWEN_WEB_STATE_DIR` because the single-use record
lives in that database.

## The broker turns one human approval into one grant

`server.py authorize` signs from a command line, which serves an operator
ahead of a session and serves nothing while one runs. `authorize-broker.py`
gives the same signing path a request interface: a front end that has shown a
human the exact proposed `search_exa` arguments posts those arguments, plus a
required `profile_id` naming the web profile the human selected, and receives
the grant that admits them. `POST /grant` requires `profile_id` on every
request and refuses one that names no profile, or a profile other than the
one this broker's own `--profile` serves, with HTTP 400 before it signs
anything -- a caller sending the `search_exa` arguments alone gets that
refusal rather than a grant issued against an assumed profile.

```sh
remote/web-mcp/authorize-broker.py --origin http://127.0.0.1:8080 \
    [--host 127.0.0.1] [--port N] [--token-key-file PATH] [--state-dir PATH] \
    [--provider exa|fake] [--profile NAME] [--lifetime SECONDS] \
    [--per-minute N]
```

Both paths reach the key through `server.issue_grant`, which validates through
`require_string`, `require_domain_list`, `require_iso_date`,
`require_optional_integer`, and `require_integer` and builds the claim through
`authorization_claim`, so an approved argument and a served argument pass one
validator and the serving path's field-by-field comparison holds. That function
also signs and measures the grant against `AUTHORIZATION_CHARACTER_CAP`, so a
token the search argument would refuse before signature verification is refused
where it is issued, and the operator's command and the broker's request meet
that refusal alike.

The broker validates its signing key before it prints `listening`: the path
is required, the file is a regular file rather than a symlink, owned by the
serving user, at mode 0600 or tighter, readable, and nonempty, and a failure
names the rule on stderr with exit 2. `GET /health` then reports what the
process is without requiring an Origin or the session header: `protocol`,
`profile`, `provider`, `pid`, `start_time` (field 22 of `/proc/self/stat`,
in clock ticks), `signing_key_sha256`, `state_dir` as device and inode, and
the admitted `origins`. `qwen-webui-session.sh` compares pid, profile,
provider, and key digest against what it launched and records pid and start
time, so a teardown signals the process the launch identified rather than a
later holder of the same number.

The service admits `127.0.0.1` and `::1` and refuses every other `--host` with
exit 2 before the socket exists, so a browser on another machine reaches it
through `ssh -L PORT:127.0.0.1:PORT` rather than through a wider bind. The
`Host` header is compared against the same two literals, which is what closes
DNS rebinding against a socket a resolver can point a name at.

`GET /session` returns the per-launch session secret to a page whose `Origin`
matches `--origin` or `QWEN_WEB_BROKER_ORIGIN`; an absent Origin is refused, so
omitting the header reaches no fallback. `POST /grant` requires that secret in
an `X-Qwen-Web-Session` header compared with `hmac.compare_digest`. The secret
lives in memory as the authority and reaches the front end through
`authorize-session.secret`, a file created at mode 0600 under the state
directory and removed when the launch ends, so a stale file authorizes nothing
against the next launch. `OPTIONS` answers the preflight a custom header and a
JSON body force, echoing the one admitted origin rather than a wildcard and
leaving credentials unallowed.

The `authorize-minute` bucket sits beside `search-minute` and `fetch-minute` in
the same table and refuses under the same `rate_limited` term, defaulting to
six approvals a minute. Each outcome writes one audit row with `authorize` as
its operation, the SHA-256 of the query, the domain filters, and the requested
result count; the signing key and the issued grant reach the row, the access
log, and every error message nowhere. The claim carries `max_uses` of one, so
one approval buys one search and the endpoint has no standing grade to offer.

The grant and the result identifier are signed under the same key with
different context strings, so neither verifies in the other's position. Both
mechanisms mark provenance and enforce authorization at the wrapper; the model
is not the boundary.

## The result identifier carries the state the process cannot

llama-server spawns the child to enumerate tools, kills it, and spawns it again
for each invocation, so nothing held in memory survives between two calls. A
search therefore signs each result into a token: base64url of a JSON claim
naming the canonical URL, the provider's own result identifier, the provider,
the issue time, the expiry, the search identifier, and the freshness policy the
search ran under, followed by a dot and the base64url HMAC-SHA256 of that
payload string under the signing key. `fetch_exa` verifies the signature with
`hmac.compare_digest`, checks the expiry, and retrieves the page the claim
names. A URL the model writes carries no signature and is refused, so the tool
surface reaches pages a prior search returned and nothing else.

One canonical URL issues one result identifier. The snapshot and the ledger row
key a document by the search and that URL, so two records canonicalizing alike
would map to one stored document and the second token would return the first's
text without reaching the provider; the renderer issues the first and drops the
duplicate.

Both provider keys are signed because Exa keys a contents entry by either, and
a redirect or a trailing-slash difference moves the URL while leaving the
opaque identifier, so `select_by_reference` resolves the statuses and results
entry on the identifier or the canonical URL. The freshness policy travels in
the same claim, so a fetch spends the publication window and cached age the
operator approved rather than a value the model writes on the second call. A
result URL naming a loopback, RFC 1918, link-local, or reserved literal, the
`localhost` name, or userinfo credentials is refused where the search renders
it. A legacy numeric spelling is refused on the spelling: `ipaddress` rejects
`2130706433`, `0x7f000001`, and `0177.0.0.1` while common resolvers read all
three as 127.0.0.1, so a host whose every label is a decimal or hexadecimal
integer and which fails canonical parsing meets that refusal and a canonical
public literal stays admitted.

The token lifetime is 900 seconds by default and
`QWEN_WEB_TOKEN_LIFETIME_SECONDS` sets it anywhere in [60, 3600]. The child holds no registry, so the expiry is what
bounds replay of a leaked token, and the lifetime covers a reasoning turn while
staying short against a transcript that outlives the session. `search_id` is
enforced rather than provenance where a ledger exists: each search writes its
identifier, its profile's fetch allowance, and one row per issued URL, and a
fetch charges that row before it reaches the provider, so a result the ledger
never issued and a search identifier it never recorded both refuse. The
`searches` row carries the profile and the admission reads it ahead of the
snapshot, so a second configuration sharing the signing key and the state
directory reaches neither the allowance nor the stored document of the first.
`QWEN_WEB_MAX_FETCHES_PER_SEARCH` sets the allowance, which defaults to eight
documents per search.

## Two key files, paths alone in the environment

The Exa API key and the HMAC signing key each live in a file that only its owner
reads, and the launch configuration passes the paths. Each file is read at call
time, so a replaced key takes effect on the next invocation, and the mode is
checked at the same moment: a file with any group or world bit set refuses the
call and reports its octal mode. The key contents reach the `x-api-key` header
and the HMAC alone, so they stay out of the argument vector, the environment
values, stderr, and every error message.

## Caps

Query 512 characters, results 1 to 10, each domain list 10 entries of validated
hostname, title 300 characters, author 200, each highlight 1200, a whole
rendered search 16000, a result identifier 4096, a grant 12288, a URL 2048, and
a 20-second wall-clock deadline over DNS, connection, headers, and the complete
response body.

A signed token fits the argument that redeems it. The grant cap is sized to the
largest one `authorize` can emit -- a 512-character query beside twenty
253-character domains signs into roughly 7 KiB -- and the subcommand refuses to
print a longer one. A result identifier past its own cap is reissued without the
opaque provider identifier, which is what a long claim carries, and the
canonical URL still resolves the contents entry.

The first fetch of one (search, URL) pair retrieves the whole document the
character cap admits and stores its exact text, digest, observed truncation,
provider status, retrieval time, and the result identifier's expiry. Every
later window reads that row, so paging costs one provider request per document,
a source that changes between two pages leaves both pages as retrieved, and the
`Retrieved:` line keeps the time of the one retrieval. The fetch allowance
charges documents rather than windows for the same reason, while the per-minute
call bucket and the daily page bucket charge every invocation, so a window read
from the snapshot spends them and spares the provider request alone. The
allowance is reserved and the snapshot is reread inside one BEGIN IMMEDIATE, so
two children spawned for one result issue one billable request, and a daily
provider budget that refuses the request returns the document to the search.
`prune` deletes
the stored text when the reference that reaches it expires. A body refused for
its size or its encoding stores nothing, so the next attempt charges the
provider again.

`Possibly Truncated:` reads the extraction record rather than recomputing a
comparison. A document whose length equals the requested maximum is the case a
character count cannot settle, so it reports that more may remain unless the
provider marks the extraction complete, and the snapshot carries that
observation into every later window.

Three separate limits bound a fetch. The HTTP response cap of 4 MiB defends
this process against a provider response of any size and is applied during the
read, one byte past the limit. The document cap of 131072 characters bounds how
much page text one result may hold, reaches Exa as `text.maxCharacters`, and
truncates a longer document. The window cap of 24000 characters, 12000 by
default, bounds one reply, and a window whose end passes the document cap
refuses the call. A fetched body decodes as strict UTF-8; anything else is
refused rather than substituted.

Two of these caps narrow further from the environment, which is what lets a
profile spend a smaller per-call budget than the compiled-in ceiling admits.
`QWEN_WEB_MAX_RESULTS` bounds `search_exa`'s `max_results` argument, an
integer in [1, 10] that defaults to `RESULT_COUNT_CAP` (10) when unset;
`QWEN_WEB_MAX_CHARS_PER_FETCH` bounds `fetch_exa`'s `max_chars` argument, an
integer in [1, 24000] that defaults to `WINDOW_CHARACTER_CAP` (24000) when
unset. Both resolve once in `main`, ahead of the request loop, so a malformed
or out-of-range value refuses the child at startup rather than on the first
call, and both narrow the `tools/list` schema's advertised `maximum` and
default to match what the call enforces. A request above either cap is
refused with a `ToolError` naming the cap it exceeded.

## Fetched text is quarantined in its wrapper

`fetch_exa` returns the page text inside a fixed frame:

```text
BEGIN UNTRUSTED WEB CONTENT [nonce]
Source: <url>
Retrieved: <utc>
Content SHA-256: <hex>
Start Index: <int>
Returned Characters: <int>
Next Start Index: <int or end>
Possibly Truncated: <yes or no>
<text>
END UNTRUSTED WEB CONTENT [nonce]
```

The nonce is drawn after retrieval and redrawn while it occurs in the window,
so page text cannot write the line that closes the frame: a body holding the
literal footer meets a delimiter whose nonce it could not predict. The digest
identifies the exact returned window, and the frame marks where
attacker-controlled text begins and ends. `Next Start Index` names the offset
that continues the document and reads `end` where the window reached the last
character, so paging follows the server's count rather than the model's
arithmetic over a body it cannot measure. `search_exa` returns titles, URLs,
and highlights, and the page body reaches the model through the wrapper alone.

## The rate ledger and the audit trail persist in the state directory

llama-server kills the child after each call, so a counter held in memory
resets between invocations and bounds nothing. `QWEN_WEB_STATE_DIR` names a
directory holding one SQLite file with the token buckets, the audit trail, the
spent grants, the open searches and the results they issued, and the content
snapshots. A call, a page, and a provider request are three costs and three
buckets carry them: the per-minute call bucket, a daily page bucket that a
search charges by the results it asks for, and the daily provider-request
bucket.

The directory is opened rather than assumed. The umask is set to 0o077, the
directory is created at mode 0700 and required to be a directory this uid owns
with no group or world bit, the database is required to be a regular file and
chmodded to 0600, and the connection takes an explicit busy timeout with the
rollback journal and `secure_delete` rather than a WAL whose sidecar retains
page images after a snapshot row is deleted. Every open prunes audit rows past
fourteen days, grants and searches past their expiry, and snapshots past
theirs. BEGIN IMMEDIATE takes the database
write lock for the whole read-modify-write of a bucket, so two children spawned
for concurrent calls serialize rather than both writing back one count, and an
exhausted bucket refuses the call. The daily budget counts provider requests
issued rather than answers used: a request whose body then fails the UTF-8 or
size check has already reached the provider and keeps its slot, and the audit
row copies the provider byte count in its finalization path, so a refused
response records the bytes it read. `QWEN_WEB_PROFILE`
labels the rows and names the profile a grant is issued for, and
`QWEN_WEB_SEARCH_PER_MINUTE`, `QWEN_WEB_FETCH_PER_MINUTE`,
`QWEN_WEB_DAILY_PAGE_BUDGET`, and `QWEN_WEB_DAILY_BUDGET` set the four limits,
which default to 10, 20, 2000, and 500. A provider that spends money and reaches the network
refuses to run without a ledger, so with `--provider exa` an unset or unopenable
`QWEN_WEB_STATE_DIR` fails every tool call and names the variable. The fake
provider reaches no network and spends nothing, so it runs unmetered and a
fixture-driven test needs no directory.

An audit row carries the timestamp, profile, operation, SHA-256 of the query,
the domain filters, the result count, the fetched host, the provider bytes, the
returned characters, the latency in milliseconds, and the status. It carries
the digest rather than the query and the host rather than the URL, so the trail
states what ran, and the query text, the keys, and the page bodies live in the
files and rows that own them.

`status` comes from a fixed vocabulary of nine terms -- `success`,
`authorization_denied`, `invalid_argument`, `rate_limited`,
`budget_exhausted`, `provider_http_error`, `provider_content_error`,
`expired_result`, and `internal_error` -- which every failure carries as the
`status` of its `ToolError` subclass. The message varies with the argument that
produced it and the trail is queried across calls, so the row holds the fixed
term and the model receives the prose; a term outside the vocabulary is written
as `internal_error`.

## Providers

A request frame is validated before a handler reads a field: the message is
an object, `method` is a string, `params` is an object where it appears, `id`
is a string, a finite number, or null, and an absent `id` alone marks a
notification. The decoder rejects non-finite constants and floating-point
overflow, the encoder refuses non-finite output, and every parsed object
without an `id` remains silent even when its notification is malformed.
A line runs to at most a million characters and the remainder of a longer one
is drained so the next line still parses, and a document nesting past 32 levels
is refused before any walk over it. `params: []` therefore answers -32602.

`Provider` declares `search()` and `contents()`. `ExaProvider` posts to Exa's
`/search` and `/contents` JSON endpoints over urllib with the key in the
`x-api-key` header. The two endpoints are instance attributes seeded from the
module constants and no configuration redirects them, since a redirected
endpoint would carry that header to a host of the redirector's choosing. The
provider opener carries `RefuseRedirect` in place of urllib's own redirect
handler, whose `redirect_request` copies the request headers onto the
redirected request, so a 3xx from the provider is raised with its status and
the key reaches the pinned host alone. The
Search API reads `maxAgeHours` inside the `contents` object beside the
highlight request and the publication window and domain filters at the request
top level; the Contents API reads `maxAgeHours` at its own top level, so the
same policy takes two positions and a bound written in the wrong one is a key
the endpoint ignores. The granted include and exclude lists reach the provider as request
fields and bound what it returns: `filter_by_domains` drops an off-domain
record before the renderer signs it into a fetchable Result ID, reading the
URL's hostname so a port on the netloc leaves the exclusion in force.
`QWEN_WEB_PROVIDER=fake` selects `FakeProvider`, which
serves a fixture document named by `QWEN_WEB_FAKE_FIXTURES`, mapping a query to
a result list and a canonical URL to a content record. A content record supplies
`text`, or `text_base64` for a fixture that carries bytes which are invalid
UTF-8 while the fixture file stays a legal UTF-8 JSON document. An optional
`delays` object maps a query to the seconds the fake provider sleeps before
answering it, which is how an admission run places a call against the
per-call `timeout_ms` llama-server reads from the MCP configuration.
A search or delay key matches a query when every word of the key appears in
the query, case-insensitively, and the key with the most words wins; a model
composes the query it proposes, and one checkpoint at temperature 0 has
phrased the same request three ways, so an exact-string key would measure
the phrasing rather than the path.

A `tools/call` whose arguments name a key outside the tool's `inputSchema` is
refused naming that key. llama-server forwards the `params` object of
`POST /tools` and keeps its own routing keys (`model`, `tool`, `stream`) out
of it, so the refusal is what makes that boundary observable from outside.

## Test

```sh
PYTHONDONTWRITEBYTECODE=1 python3 remote/web-mcp/test-web-mcp.py
PYTHONDONTWRITEBYTECODE=1 python3 remote/web-mcp/test-authorize-broker.py
```

The test spawns the server the way llama-server spawns it, writes its fixtures
into a temporary directory, and runs with the fake provider, so it needs no
network and no key of its own. The arms that decide where `maxAgeHours` sits
and which header carries the key run `ExaProvider` itself against an
Exa-shaped fixture server on an ephemeral 127.0.0.1 port, which records the
exact request bodies and headers a subclass replacing `_post` would measure
nowhere. Each session ends by closing stdin, which is
what ends the server's read loop; a child still running five seconds later is
escalated to SIGTERM and then SIGKILL. Tests exercise both the clean exit
path when the child responds to stdin closure and the escalation to SIGKILL
when the child ignores SIGTERM.

`test-authorize-broker.py` launches the broker as a subprocess, reads its port
from the `listening` line it prints on stdout, and speaks HTTP to that port, so
the bind refusal, the preflight, the session header, the Host check, and the
audit rows are measured on the wire. Each issued grant is then spent against
`server.py` under the fake provider, which is what proves the two paths agree
on one canonical claim.
