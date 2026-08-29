# The web provider capability contract

A search argument reaches the web MCP child through a human approval. The
dialog in `webui/index.html` names the query, the publication interval, both
domain lists, the result count, and whether `max_age_hours` of 0 forces a live
crawl, and `remote/web-mcp/authorize-broker.py` signs a single-use grant over
those exact fields. `enforce_search_authorization` in
`remote/web-mcp/server.py` compares the call's arguments against that claim
field by field, so the arguments the provider receives are the ones a person
read.

A backend that silently drops one of those fields answers a different question
than the one approved. `Provider` therefore declares five capability flags and
`refuse_unhonored_arguments` refuses an authorized argument the active provider
cannot carry, naming both the argument and the provider in an `isError` result.
The refusal runs in `call_search` after `select_provider` and `preflight` and
before `ledger.consume_search`, which is the same ordering every other local
configuration check takes: the grant's single use stays available to a
corrected call.

## The five flags

| Flag | What it states |
| --- | --- |
| `supports_exact_date_bounds` | `published_after` and `published_before` reach the request as a calendar interval. |
| `supports_freshness_max_age` | `max_age_hours` bounds the age of the copy served. |
| `supports_domain_filter` | `include_domains` and `exclude_domains` bound the sources. |
| `supports_num_results` | `max_results` bounds the returned count. |
| `supports_paging` | The backend returns further pages of one result set. |

A flag reads true where the argument is honored, whether the provider's own
request field carries it or the wrapper enforces it over the response.
`supports_paging` gates no argument: `fetch_exa`'s `start_index` pages the
document snapshot the ledger stores, which is wrapper state rather than a
provider result page, so the flag records the surface a later argument would
consult.

| Provider | date bounds | freshness | domains | count | paging |
| --- | --- | --- | --- | --- | --- |
| `exa` | yes | yes | yes | yes | no |
| `fake` | yes | yes | yes | yes | no |
| `searxng` | no | no | yes, in the provider | yes, in the provider | no |

Exa keeps every field optional. Its Search API reads `startPublishedDate`,
`endPublishedDate`, `includeDomains`, `excludeDomains`, and `numResults` at the
request top level and `maxAgeHours` inside `contents`, so a grant naming any
combination reaches the provider unchanged and no capability refusal fires
against it. The fake provider answers from a fixture document and meets the
same wrapper enforcement, so a fixture run reaches the refusals a live run
reaches.

## SearXNG

One SearXNG instance on the appliance is the general-search endpoint.
`SearXNGProvider` issues `GET {base}/search?q=...&format=json&categories=<name>`
and reads the `results` array. The response carries result metadata and no page
text, so `contents` retrieves the source itself over one GET of the exact
canonical URL a prior search signed into a Result ID.

### Categories rather than engines

Which engines answer belongs to the instance's own `settings.yml`, which groups
them under qwen-named categories. The web profile names a category and the
provider sends it, so the engine population changes by editing the instance
rather than through any request field a model or an environment reaches.
`remote/web-profiles.tsv` carries the policy in five trailing columns:

| Column | What it states |
| --- | --- |
| `provider` | The backend the row expects, which must equal the generator's `QWEN_WEB_PROVIDER`. |
| `primary_category` | The category every approved search queries first. |
| `fallback_category` | The category queried once where the primary is short; `-` for none. |
| `minimum_results` | The count of usable results below which the fallback runs. |
| `searxng_url` | The instance, over loopback. |

The seeded rows: `web-open` queries `qwen-open` alone; `web-balanced` queries
`qwen-open` and falls back to `qwen-broad` below three usable results;
`web-sovereign` queries `qwen-yacy` alone. Every checked-in row keeps
`execution_policy=refused`, so the shipped ledger emits nothing.

`remote/build-web-presets.sh` validates the policy for every row whatever its
execution_policy -- the way the depth and tier rules are validated -- and emits
it into the MCP configuration as `QWEN_WEB_SEARXNG_URL`,
`QWEN_WEB_SEARXNG_PRIMARY_CATEGORY`, `QWEN_WEB_SEARXNG_FALLBACK_CATEGORY`, and
`QWEN_WEB_SEARXNG_MINIMUM_RESULTS`. `SearXNGProvider.__init__` validates all
four again before the first request, so a hand-edited configuration meets the
rules too. The two gates are not identical and the generator is the stricter of
them: it admits the literal hosts `127.0.0.1` and `localhost` where
`require_loopback_endpoint` admits every address in 127/8 and `::1`, and it
bounds a category by character class where `SEARXNG_CATEGORY_PATTERN` also caps
the length at 64. Both differences refuse more in the generator than in the
child, so a row this file admits is one the child admits. The model supplies
none of the four.

### One fallback, no retry loop

A search queries `primary_category` once. A record is usable when its URL
canonicalizes, names a public host, survives the granted domain lists, and is
not a URL an earlier record already carried, so the count that decides the
fallback is the count of results the reply can actually carry:
`render_search_results` renders one block per canonical URL, so a repeat that
counted would both inflate the audit's `usable_results` and suppress a fallback
the reply needed. Where that count falls below `minimum_results` and a fallback
category exists, the provider queries the fallback exactly once and appends the
records whose canonical URLs no earlier record issued. A failing
engine is the instance's own problem: SearXNG suspends one on its own, so a
retry loop here would spend the approval on an outage the instance is already
routing around.

### No time range

SearXNG maps `time_range` onto each engine, and an engine that expresses none
-- Bing's web engine among them -- simply ignores it. A qwen-named category is
a mix of engines, so no category can promise that a recency bound was applied to
every result in its answer. `supports_freshness_max_age` and
`supports_exact_date_bounds` therefore both read false and both temporal
arguments are refused by name, which states the absence to the model rather
than returning a result set filtered on some engines and not others.

### Provenance

Each result carries `engines` (the instance's own list), `category`, `rank`
(the position the instance returned it at), and `score`. The rendered block adds
one line, `Sources: google, brave`, after `Trust:` and before `Highlights:`.
The pinned llama-ui reads everything after `Highlights:` up to the `---`
separator as highlight text and `webui/index.html` reads the block for
`Result ID:` and the trailing separator, so the line sits outside both parse
regions, and a record carrying no engines renders no line -- an Exa block is
byte-identical to what it was.

The audit row gains seven columns beside the original twelve: `search_id`,
`category`, `engines_attempted`, `engines_answered`, `engines_failed` (from the
answer's `unresponsive_engines`), `fallback_used`, and `usable_results`. A
database written before those columns is migrated in place by
`PRAGMA table_info(audit)` and `ALTER TABLE ADD COLUMN`, and both `Ledger.record`
and the broker's own insert name their columns rather than counting on the
table's width. The trail still holds the SHA-256 of the query and no query
text.

### Configuration

| Name | Effect |
| --- | --- |
| `QWEN_WEB_SEARXNG_URL` | The instance base URL. From the profile row. |
| `QWEN_WEB_SEARXNG_PRIMARY_CATEGORY` | The first category. From the profile row. |
| `QWEN_WEB_SEARXNG_FALLBACK_CATEGORY` | The second category, or `-`. From the profile row. |
| `QWEN_WEB_SEARXNG_MINIMUM_RESULTS` | The fallback threshold. From the profile row. |
| `QWEN_WEB_SEARXNG_LANGUAGE` | `language` request field. Operator-set, omitted where unset. |
| `QWEN_WEB_SEARXNG_SAFESEARCH` | `safesearch` request field, one of 0, 1, 2. Operator-set, omitted where unset. |
| `QWEN_WEB_SEARXNG_ALLOW_REMOTE` | `1` admits an instance URL outside loopback. |

`require_loopback_endpoint` reads the base URL the way `require_public_host`
reads a result host and with the opposite polarity: the literal address and the
reserved `localhost` name classify it, no hostname resolves in the process, and
a host that is neither is refused. An SSH-forwarded loopback port therefore
reaches a remote instance while a bare hostname refuses, and
`QWEN_WEB_SEARXNG_ALLOW_REMOTE=1` is the operator's statement that the
model-authored query may leave the machine. `build-web-presets.sh` enforces the
loopback form on the row's own `searxng_url` as well.

The `searxng` branch reads no key file, because the instance is unauthenticated
and this provider holds no secret at all.

### What the retrieval keeps and what it costs

Every wrapper guard applies unchanged. A SearXNG result is mapped into the
record shape the renderer already reads, so `canonical_url` runs
`require_public_host` over each URL before a Result ID is signed,
`issue_result_id` signs the same claim, `open_search` records the profile's
fetch allowance, and `reserve_fetch` meters the redemption. A metasearch
instance indexes what its engines return, so a result naming loopback, an
RFC 1918 address, or a legacy numeric spelling of one is dropped from the answer
-- one entry among ten is an entry to discard rather than a reason to refuse the
approved search -- and it reaches no Result ID and never counts toward the
fallback threshold. That differs from Exa, where the same URL ends the call:
Exa returns its own crawler's results and a private target there is a provider
defect.

`contents` costs two things a page-text provider does not. The retrieval runs
through `PROVIDER_OPENER`, which ends a redirect at the response that requested
it, so a page that answers only behind a redirect fails: the Result ID is
signed over one canonical URL and following a redirect would return a document
from a host the signature never covered. The declared content type also decides
admission -- `text/html`, `application/xhtml+xml`, and `text/plain`, in UTF-8 or
ASCII -- so a PDF or a non-UTF-8 page is named by its type rather than reaching
the decode as a byte error. Both are limitations of this provider rather than
defects to work around.

`HtmlTextExtractor` reduces an HTML response to its readable text, dropping
`script`, `style`, `noscript`, `template`, `svg`, and `head` contents and
ending a line at each block element. A parser failure returns the raw document,
because the frame around the window already states that the content is
untrusted and a refusal there would let a broken page deny a fetch its Result ID
bought.

One guard does differ. `ExaProvider.contents` carries the signed `freshness`
claim into its request as `maxAgeHours`, and `SearXNGProvider.contents` reads
the source live on every retrieval. A live read satisfies any granted age
bound, so the claim is met rather than ignored, and the field simply has no
request position to occupy.

## Tool names

The tools stay `search_exa` and `fetch_exa`, which llama-server composes with
the MCP server name `web` into `web_search_exa` and `web_fetch_exa`. The
identifiers are written into `webui/index.html`, `remote/admit-web-router-fake.sh`,
and `evidence/web-admission-fake.md`, and the pinned llama-ui renders those two
natively. The rename to `web_search` and `web_fetch` with the current names kept
as aliases is a later phase: it touches the page, the admission harness, and two
evidence records together, and an alias period is what keeps a running session
from losing its tool surface mid-turn.

## What is unmeasured

No run of this provider against a live SearXNG instance is retained. Every
result here comes from `remote/web-mcp/test-web-mcp.py`, which stands a
standard-library HTTP server on loopback in the instance's place and in the
source page's place. That covers the request the provider composes, the category
and fallback logic, the mapping and provenance, every refusal the contract
states, the deadline, the audit row, and the wrapper guards around a fetch; it
establishes nothing about result quality, coverage, or latency from any real
engine population, and nothing about how often a real page is lost to the
redirect refusal or the content-type gate.

`remote/admit-web-router-fake.sh` runs the router path on the appliance against
the fake provider and has not been run against `searxng`.
