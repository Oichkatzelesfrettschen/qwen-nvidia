#!/bin/sh
set -eu

# The fallback Web UI reaches the network through one human approval, and the
# two properties that make that true are absences a reading eye loses: the
# approval dialog offers ONCE and DENY alone, and no grant or session secret
# reaches browser storage. Grep asserts both against the served file, which
# needs no Node and no browser, so the gate runs wherever the tree is cloned.

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
fallback_ui=$script_directory/../webui/index.html

# The per-turn toggle governs the tool list rather than the request text, so a
# turn run with it off carries no web tool for the model to propose.
grep -F '<input type="checkbox" id="web-tools">' "$fallback_ui" >/dev/null
grep -F "const webPermission = \$('#web-tools').checked;" "$fallback_ui" >/dev/null
grep -F "\$('#web-tools').checked = false;" "$fallback_ui" >/dev/null
grep -F 'if (webPermission) {' "$fallback_ui" >/dev/null
grep -F 'tools.push(...await resolveWebTools(requestModel, modelStateGeneration));' \
    "$fallback_ui" >/dev/null

# The schemas come from the running server rather than from a copy kept in the
# page, so the model reads the arguments the wrapper validates. A build without
# the tool routes answers 404 and the turn carries no web tool.
# shellcheck disable=SC2016
grep -F 'tools?model=${encodeURIComponent(selectedModel)}&autoload=true`,' \
    "$fallback_ui" >/dev/null
grep -F 'WEB_TOOL_NAMES.includes(entry && entry.tool)' "$fallback_ui" >/dev/null
grep -F 'const { authorization, ...offered } = parameters.properties;' \
    "$fallback_ui" >/dev/null
grep -F "parameters.required.filter(name => name !== 'authorization')" \
    "$fallback_ui" >/dev/null
# The composed list belongs to one selection, so a roster change clears it
# beside the context length.
grep -F 'function forgetWebTools()' "$fallback_ui" >/dev/null
grep -F 'webToolsGeneration === generation' "$fallback_ui" >/dev/null
grep -F "const WEB_SEARCH_TOOL_NAME = 'web_search_exa'" "$fallback_ui" >/dev/null
grep -F "const WEB_FETCH_TOOL_NAME = 'web_fetch_exa'" "$fallback_ui" >/dev/null

# The dialog names every field the grant is signed over, including the live
# crawl that max_age_hours of 0 forces.
grep -F "row('query'" "$fallback_ui" >/dev/null
grep -F "row('publication interval'" "$fallback_ui" >/dev/null
grep -F "row('included domains'" "$fallback_ui" >/dev/null
grep -F "row('excluded domains'" "$fallback_ui" >/dev/null
grep -F "row('max results'" "$fallback_ui" >/dev/null
grep -F "row('live crawl'" "$fallback_ui" >/dev/null
grep -F 'id="approve-once"' "$fallback_ui" >/dev/null
grep -F 'id="approve-deny"' "$fallback_ui" >/dev/null

# The approval posts the parsed proposal and the grant reaches the executor
# inside the one POST /tools body, so the transcript keeps the proposal alone.
grep -F \
    "await requestGrant({ ...fields, profile_id: requestModel }, controller.signal)" \
    "$fallback_ui" >/dev/null
grep -F 'BROKER_SESSION_HEADER]: secret' "$fallback_ui" >/dev/null
grep -F 'searchRequestParams(fields, outcome.authorization)' "$fallback_ui" >/dev/null
grep -F "body: JSON.stringify({ model, tool: toolName, params, stream: false })" "$fallback_ui" >/dev/null
grep -F "'The user refused this web search. It did not run.'" \
    "$fallback_ui" >/dev/null

# The grant enters one request body. A transcript message, a stored value, or a
# completion body carrying it would present a single-use token twice.
grep -F 'outcome = await streamCompletion(history, view, webPermission, imagePermission);' \
    "$fallback_ui" >/dev/null
if grep -E 'answerCall\([^)]*authorization' "$fallback_ui" >/dev/null; then
    printf 'fallback Web UI writes a grant into the transcript\n' >&2
    exit 1
fi
# The signed grant reaches exactly one call site, which is the params object of
# the POST /tools body.
if [ "$(grep -c 'outcome.authorization' "$fallback_ui")" -ne 1 ]; then
    printf 'fallback Web UI reads the issued grant at more than one site\n' >&2
    exit 1
fi
if grep -F 'requestMessages' "$fallback_ui" >/dev/null; then
    printf 'fallback Web UI still splices a grant into a completion request\n' >&2
    exit 1
fi

# llama-server answers an MCP refusal with `error` at HTTP 200 and a result
# with `plain_text_response`, so all three outcomes are read from the body and
# a refusal names what refused it.
grep -F "if (payload && typeof payload.error === 'string') {" "$fallback_ui" >/dev/null
grep -F "return truncateToolResult(\`The \${toolName} call was refused: \${payload.error}\`);" \
    "$fallback_ui" >/dev/null
grep -F 'The ${toolName} call returned HTTP ${response.status} and no result.' \
    "$fallback_ui" >/dev/null
grep -F "typeof payload.plain_text_response !== 'string'" "$fallback_ui" >/dev/null
grep -F 'return truncateToolResult(payload.plain_text_response);' "$fallback_ui" >/dev/null
grep -F 'const TOOL_RESULT_CHARACTER_CAP = 8000;' "$fallback_ui" >/dev/null

# A truncated tool result still ends its frame: a `.slice()` alone could cut
# the `END UNTRUSTED WEB CONTENT [nonce]` footer `wrap_untrusted`
# (scripts/web-mcp/server.py) closes an untrusted page's text with, leaving
# the model no way to tell where attacker-controlled content ends.
# `truncateToolResult` finds that footer and truncates the frame body ahead
# of it instead, so the cap and the footer both survive in the model's turn.
grep -F 'function truncateToolResult(text) {' "$fallback_ui" >/dev/null
grep -F 'END UNTRUSTED WEB CONTENT \[[^\]\n]*\]' "$fallback_ui" >/dev/null
grep -F 'Truncated by the client at ${TOOL_RESULT_CHARACTER_CAP} characters.' \
    "$fallback_ui" >/dev/null

# A capped search-result reply keeps whole result blocks: `truncateSearchResult`
# splits on the server's own `\n---\n` block separator, keeps only the blocks
# that fit whole under the cap, and rewrites `Results Omitted:` to add what this
# cap newly drops to whatever the server already reported, rather than slicing
# through a block and losing a Result ID or the omission count with it.
grep -F 'function truncateSearchResult(text) {' "$fallback_ui" >/dev/null
grep -F 'const blocks = withoutOmitted.slice(0, -4).split(' "$fallback_ui" >/dev/null
grep -F 'const totalOmitted = serverOmitted + (blocks.length - kept.length);' \
    "$fallback_ui" >/dev/null
grep -F 'const searchTruncated = truncateSearchResult(text);' "$fallback_ui" >/dev/null

# When the first block alone exceeds the cap, no whole block fits and `kept`
# stays empty; `truncateSearchResult` truncates that one block inside its own
# closed frame with the client notice instead of returning null and falling
# back to `truncateToolResult`'s raw `.slice(0, cap)`, which would cut inside
# the block and drop its Result ID with no omission count.
grep -F 'if (!kept.length) {' "$fallback_ui" >/dev/null
grep -F 'const additionalOmitted = serverOmitted + (blocks.length - 1);' \
    "$fallback_ui" >/dev/null

# A capped fetch frame rewrites its own navigation lines rather than leaving
# them to describe the server's uncapped window: Returned Characters and Next
# Start Index are recomputed from the window the client actually kept, and
# Possibly Truncated is forced to yes since a client-side cut is truncation
# regardless of what wrap_untrusted (scripts/web-mcp/server.py) reported.
grep -F 'function truncateFetchResult(text, footerMatch) {' "$fallback_ui" >/dev/null
grep -F 'const fetchTruncated = truncateFetchResult(text, footerMatch);' "$fallback_ui" >/dev/null
grep -F "\`\\nNext Start Index: \${startIndex + keptWindowPoints.length}\`" "$fallback_ui" >/dev/null
grep -F "\\nPossibly Truncated: yes\\n" "$fallback_ui" >/dev/null

# `wrap_untrusted` (scripts/web-mcp/server.py) counts Start Index and Next
# Start Index in Python Unicode code points, so a client-side recomputation
# over JavaScript's UTF-16 `.length` reports one too many per astral
# character and a `.slice` can split its surrogate pair. truncateFetchResult
# iterates the kept window by code point instead.
grep -F 'const codePoints = str => Array.from(str);' "$fallback_ui" >/dev/null
grep -F 'const windowPoints = codePoints(window);' "$fallback_ui" >/dev/null

# Clear can land while a stream, an approval dialog, or a fetch is still
# awaited, so every later write to `history` for that turn checks the
# conversation generation Clear increments and discards the result rather
# than appending it to the conversation Clear just replaced.
grep -F 'let conversationGeneration = 0;' "$fallback_ui" >/dev/null
grep -F 'conversationGeneration++;' "$fallback_ui" >/dev/null
grep -F 'const turnGeneration = conversationGeneration;' "$fallback_ui" >/dev/null
grep -F 'function answerCall(callId, toolName, content, turnGeneration) {' "$fallback_ui" >/dev/null
grep -F 'if (turnGeneration !== conversationGeneration) return;' "$fallback_ui" >/dev/null

# A fetch runs without a grant, because the wrapper enforces the signed Result
# ID and its own allowance, and the page bounds the pages one turn reads.
grep -F 'const WEB_FETCH_BUDGET_PER_TURN = 2;' "$fallback_ui" >/dev/null
grep -F 'if (fetchBudget.remaining <= 0) {' "$fallback_ui" >/dev/null
grep -F 'fetchBudget.remaining--;' "$fallback_ui" >/dev/null
# The MCP child of the profile that ran the search signed the Result ID, so
# the fetch posts under the proposing model and a picker moved mid-stream
# refuses by name instead of routing the ID into another child.
grep -F 'answerCall(callId, toolName, await executeWebTool(toolName, params, proposalModel), turnGeneration);' \
    "$fallback_ui" >/dev/null
grep -F 'The fetch did not run: it was proposed by model ${proposalModel}, ' \
    "$fallback_ui" >/dev/null
grep -F 'toolName, searchRequestParams(fields, outcome.authorization), proposalModel), turnGeneration);' \
    "$fallback_ui" >/dev/null
if grep -F 'executeWebTool(toolName, params, requestModel)' "$fallback_ui" >/dev/null; then
    printf 'a fetch still executes under the picker value rather than the proposing model\n' >&2
    exit 1
fi

# One completion can emit several web_search_exa calls in one round, and
# CONTINUATION_CAP bounds only the round count, so a per-turn search budget
# bounds the calls inside a round too: only the first reaches an approval
# dialog and an execution, and every later one in the same turn is refused
# with a tool message naming the cap before any dialog opens.
grep -F 'const WEB_SEARCH_BUDGET_PER_TURN = 1;' "$fallback_ui" >/dev/null
grep -F 'if (searchBudget.remaining <= 0) {' "$fallback_ui" >/dev/null
grep -F "The per-turn budget of \${WEB_SEARCH_BUDGET_PER_TURN} search approvals is spent;" \
    "$fallback_ui" >/dev/null
grep -F 'searchBudget.remaining--;' "$fallback_ui" >/dev/null
grep -F 'const searchBudget = { remaining: WEB_SEARCH_BUDGET_PER_TURN };' "$fallback_ui" >/dev/null
grep -F \
    'async function runProposedTools(calls, callIds, view, roundBudgetExhausted, fetchBudget,
                                 searchBudget, turnGeneration, proposalModel,
                                 webPermission, imagePermission, imageBudget, imageCancelToolName) {' \
    "$fallback_ui" >/dev/null
grep -F \
    'outcome.calls, callIds, view, round === CONTINUATION_CAP - 1, fetchBudget,
        searchBudget, turnGeneration, proposalModel, webPermission,
        imagePermission, imageBudget, imageCancelToolName);' \
    "$fallback_ui" >/dev/null
# The decrement precedes the approval dialog: the budget is spent by opening
# the dialog and executing on approval, not by a later decision inside it.
decrement_line=$(grep -n 'searchBudget.remaining--;' "$fallback_ui" | cut -d: -f1)
approve_line=$(grep -n 'const outcome = await approveWebSearch(fields, proposalModel);' \
    "$fallback_ui" | cut -d: -f1)
if [ -z "$decrement_line" ] || [ -z "$approve_line" ] || [ "$decrement_line" -ge "$approve_line" ]; then
    printf 'fallback Web UI spends the search budget after opening the approval dialog\n' >&2
    exit 1
fi

# A model-picker change between a web proposal and execution refuses both
# tools before either per-turn allowance moves. The approval handler repeats
# the check because the picker stays enabled while the dialog is showing.
grep -F 'const proposalModel = requestModel;' "$fallback_ui" >/dev/null
grep -F 'if (requestModel !== proposalModel && WEB_TOOL_NAMES.includes(toolName)) {' \
    "$fallback_ui" >/dev/null
grep -F 'function approveWebSearch(fields, proposalModel) {' "$fallback_ui" >/dev/null
grep -F 'const outcome = await approveWebSearch(fields, proposalModel);' "$fallback_ui" >/dev/null
# The grant request is awaited with the picker enabled, so the model is read
# again after approval and before the grant is spent.
grep -F "if (outcome.decision === 'once' && requestModel !== proposalModel) {" "$fallback_ui" >/dev/null
# The picker can move while a tool request is awaited, so the turn ends
# rather than sending the proposing model's call and result to another model.
grep -F 'during the tool call; the turn ends without a continuation' "$fallback_ui" >/dev/null

# A present-but-malformed start_index or max_chars refuses the fetch rather
# than falling back to require_integer's default (scripts/web-mcp/server.py):
# an absent field takes the default, a malformed one fails the proposal, and
# fetches run without an approval dialog to catch the difference otherwise.
grep -F "for (const key of ['start_index', 'max_chars']) {" "$fallback_ui" >/dev/null
grep -F 'if (!(key in parsed)) continue;' "$fallback_ui" >/dev/null
grep -F "throw new Error(\`\${key} must be a non-negative integer\`);" "$fallback_ui" >/dev/null

# A demo or otherwise advertised call receives a tool message too: every
# tool_calls entry pairs with a result before the round ends.
grep -F "if (toolName !== WEB_SEARCH_TOOL_NAME) {" "$fallback_ui" >/dev/null
grep -F 'The served path executes no tool named' "$fallback_ui" >/dev/null
grep -F 'if (!outcome.calls.length) return;' "$fallback_ui" >/dev/null

# The turn snapshot governs execution after the visible control resets for
# the next turn.
grep -F 'if (!webPermission && WEB_TOOL_NAMES.includes(toolName)) {' \
    "$fallback_ui" >/dev/null
grep -F 'The web surface is off for this turn; ${toolName} did not run.' \
    "$fallback_ui" >/dev/null

# The final continuation round runs neither web tool: a result issued there
# reaches no request the round budget still sends, so the guard precedes the
# tool-name dispatch and covers the fetch beside the search.
grep -F 'if (roundBudgetExhausted && WEB_TOOL_NAMES.includes(toolName)) {' \
    "$fallback_ui" >/dev/null
grep -F 'The round budget is exhausted; ${toolName} did not run.' "$fallback_ui" >/dev/null
grep -F 'round === CONTINUATION_CAP - 1' "$fallback_ui" >/dev/null

# Tool-call ids come from a conversation-wide counter rather than a per-round
# index, so a later approved search cannot collide with an earlier call and
# overwrite its arguments through requestMessages' id lookup.
grep -F 'let toolCallSequence = 0;' "$fallback_ui" >/dev/null
grep -F 'callIds = outcome.calls.map(() => `call_${toolCallSequence++}`);' \
    "$fallback_ui" >/dev/null
grep -F "history = []; toolCallSequence = 0;" "$fallback_ui" >/dev/null

# The grant admits one search, so a standing grade would promise a permission
# the serving path refuses on the second call. The pinned llama-ui spells those
# grades ALWAYS and ALWAYS_SERVER, and the check names the approval region
# rather than the file, so ordinary prose elsewhere carries no verdict.
if sed -n '/dialog class="approval"/,/<\/dialog>/p;/^function approveWebSearch/,/^}/p' \
        "$fallback_ui" | grep -iE 'always' >/dev/null; then
    printf 'fallback Web UI offers a standing tool permission grade\n' >&2
    exit 1
fi
if grep -F 'ALWAYS_SERVER' "$fallback_ui" >/dev/null; then
    printf 'fallback Web UI carries a server-wide permission grade\n' >&2
    exit 1
fi

# The session secret and every grant live in page memory. A storage write
# naming either would outlive the launch that signed it.
if grep -E "writeBrowserStorage\([^)]*(grant|authorization|session|secret)" \
    "$fallback_ui" >/dev/null; then
    printf 'fallback Web UI persists an approval secret into browser storage\n' >&2
    exit 1
fi
if grep -E "(readBrowserStorage|writeBrowserStorage)\([^)]*brokerSession" \
    "$fallback_ui" >/dev/null; then
    printf 'fallback Web UI persists the broker session secret\n' >&2
    exit 1
fi

# The broker is reached over loopback by construction, so a fallback naming any
# other host would send the approval to a listener the broker refuses to be.
# The served page states the deployed origin in its own meta tag, a `?broker=`
# query parameter overrides it for one visit, and the fallback holds the port
# qwen-webui-session.sh binds by default, so a page that lost both sources
# still reaches the launched broker.
grep -F "const BROKER_ORIGIN_FALLBACK = 'http://127.0.0.1:8571'" \
    "$fallback_ui" >/dev/null
grep -F '<meta name="qwen-web-broker" content="http://127.0.0.1:8571">' \
    "$fallback_ui" >/dev/null
grep -F "searchParams.get('broker')" "$fallback_ui" >/dev/null
grep -F 'meta[name="qwen-web-broker"]' "$fallback_ui" >/dev/null
grep -F "const BROKER_ORIGIN_DEFAULT = configuredBrokerOrigin();" \
    "$fallback_ui" >/dev/null

# The Web UI API bearer capability protects /session. Only the broker's
# explicit stale-session-secret code refreshes the cache; another 403 stays a
# standing refusal and does not spend a second authorization request.
grep -F "headers: authHeaders(), signal" "$fallback_ui" >/dev/null
grep -F "const STALE_SESSION_SECRET_CODE = 'stale_session_secret';" \
    "$fallback_ui" >/dev/null
grep -F 'if (response.status === 403 && payload.code === STALE_SESSION_SECRET_CODE) {' \
    "$fallback_ui" >/dev/null
grep -F "brokerSessionSecret = null;" "$fallback_ui" >/dev/null
grep -F "const refreshed = await brokerSession(signal);" "$fallback_ui" >/dev/null
grep -F "await postGrant(fields, refreshed, signal)" "$fallback_ui" >/dev/null

# A denial or dismissal while requestGrant(fields) is pending must not let
# that request still land: `settled` makes completion one-shot and
# `controller.abort()` cancels the in-flight fetch so a late grant is never
# injected and a stale finish() cannot close a dialog it no longer owns.
grep -F "let settled = false;" "$fallback_ui" >/dev/null
grep -F "const controller = new AbortController();" "$fallback_ui" >/dev/null
grep -F "if (settled) return;" "$fallback_ui" >/dev/null
grep -F "controller.abort();" "$fallback_ui" >/dev/null

# The grep checks above prove the frame-preserving code is present; this arm
# proves it does what it claims against a wrap_untrusted-shaped string, when
# node is on the path. `truncateToolResult` is extracted verbatim from the
# served file rather than reimplemented, so the check exercises the exact
# function a browser runs.
if command -v node >/dev/null 2>&1; then
    node -e '
const fs = require("fs");
const source = fs.readFileSync(process.argv[1], "utf8");
const match = source.match(
    /const TOOL_RESULT_CHARACTER_CAP[\s\S]*?\nfunction truncateSearchResult[\s\S]*?\n}\n/
);
if (!match) throw new Error("truncateToolResult was not found in the served file");
eval(match[0]);
const nonce = "abc123XYZ";
const header = `BEGIN UNTRUSTED WEB CONTENT [${nonce}]`;
const footer = `END UNTRUSTED WEB CONTENT [${nonce}]`;
const window = "x".repeat(9000);
const framed = [header, "Source: https://example.org/raven2", window, footer].join("\n");
const truncated = truncateToolResult(framed);
if (!truncated.endsWith(footer)) {
    throw new Error("a truncated frame lost its END UNTRUSTED WEB CONTENT footer");
}
if (!truncated.includes("Truncated by the client at")) {
    throw new Error("a truncated frame carries no client-truncation notice");
}
if (truncated.length > 8000) {
    throw new Error(`a truncated frame still measures ${truncated.length} characters`);
}

function searchBlock(n) {
    return [
        `Title: Result ${n}`,
        `URL: https://example.org/r${n}`,
        "Published: 2026-01-05",
        "Author: A. Measurer",
        `Result ID: rid-${"x".repeat(200)}-${n}`,
        "Trust: untrusted-web-result",
        "Highlights:",
        `- ${"highlight text ".repeat(20)}${n}`
    ].join("\n");
}
const searchBlocks = [];
for (let i = 0; i < 30; i++) searchBlocks.push(searchBlock(i));
const searchReply = searchBlocks.join("\n---\n") + "\n---\nResults Omitted: 3";
if (searchReply.length <= 8000) throw new Error("the fixture search reply fits under the cap already");
const cappedSearch = truncateToolResult(searchReply);
if (cappedSearch.length > 8000) {
    throw new Error(`a capped search reply still measures ${cappedSearch.length} characters`);
}
const keptBlocks = cappedSearch.replace(/\nResults Omitted: \d+$/, "")
    .replace(/\n---$/, "").split("\n---\n");
for (const keptBlock of keptBlocks) {
    if (!searchBlocks.includes(keptBlock)) {
        throw new Error("a capped search reply carries a block that was cut mid-block");
    }
}
const keptOmittedMatch = cappedSearch.match(/\nResults Omitted: (\d+)$/);
if (!keptOmittedMatch) throw new Error("a capped search reply lost its Results Omitted line");
if (Number(keptOmittedMatch[1]) <= 3) {
    throw new Error("a capped search reply did not add the newly dropped blocks to the omitted count");
}
' "$fallback_ui"
fi

# node exercises the single-oversized-block branch: a search reply whose
# first (and only) block alone exceeds the cap must still return a truncated
# frame carrying the client notice rather than an empty result set.
if command -v node >/dev/null 2>&1; then
    node -e '
const fs = require("fs");
const source = fs.readFileSync(process.argv[1], "utf8");
const match = source.match(
    /const TOOL_RESULT_CHARACTER_CAP[\s\S]*?\nfunction truncateSearchResult[\s\S]*?\n}\n/
);
if (!match) throw new Error("truncateToolResult was not found in the served file");
eval(match[0]);

const oversizedBlock = [
    `Title: Result 0`,
    `URL: https://example.org/r0?${"q".repeat(2048)}`,
    "Published: 2026-01-05",
    "Author: A. Measurer",
    "Result ID: rid-0",
    "Trust: untrusted-web-result",
    "Highlights:",
    `- ${"highlight text ".repeat(400)}`
].join("\n");
const searchReply = oversizedBlock + "\n---";
if (searchReply.length <= 8000) {
    throw new Error("the fixture single-block reply fits under the cap already");
}
const cappedSearch = truncateToolResult(searchReply);
if (cappedSearch === null || cappedSearch.length === 0) {
    throw new Error("an oversized single block produced an empty result set");
}
if (cappedSearch.length > 8000) {
    throw new Error(`a capped single-block reply still measures ${cappedSearch.length} characters`);
}
if (!cappedSearch.includes("Truncated by the client at")) {
    throw new Error("a capped single-block reply carries no client-truncation notice");
}
if (!oversizedBlock.startsWith(cappedSearch.split("\n---\n")[0])) {
    throw new Error("a capped single-block reply does not keep a prefix of the oversized block");
}

const notice = "Truncated by the client at 8000 characters.";
const suffix = `\n---\n${notice}`;
const blockBudget = 8000 - suffix.length;
const astralHeader = [
    "Title: Astral result",
    "URL: https://example.org/astral",
    "Result ID: rid-astral",
    "Trust: untrusted-web-result",
    "Highlights:",
].join("\n") + "\n- ";
const padding = "x".repeat((blockBudget - astralHeader.length) % 2 === 0 ? 1 : 0);
const astralBlock = astralHeader + padding + "\u{1F600}".repeat(5000);
const astralCapped = truncateSearchResult(astralBlock + "\n---");
const keptAstralBlock = astralCapped.slice(0, -suffix.length);
if (/\uD83D(?!\uDE00)|(?<!\uD83D)\uDE00/.test(keptAstralBlock)) {
    throw new Error("a capped search-result block split a Unicode code point");
}
' "$fallback_ui"
fi

# `GET /tools` failing, answering non-2xx, or returning a body that is not an
# array all raise from fetchWebToolListing the same way, and resolveWebTools
# retries once after a short delay before leaving the turn without a web
# tool. A listing this loop never parsed must not reach the cache: a cached
# empty result would leave every later turn on this model and generation
# silently offering no web tool until a reselect or a reload.
grep -F 'async function fetchWebToolListing(selectedModel) {' "$fallback_ui" >/dev/null
grep -F "throw new Error(\`GET /tools returned HTTP \${response.status}\`);" \
    "$fallback_ui" >/dev/null
grep -F "throw new Error('GET /tools returned a body that is not an array');" \
    "$fallback_ui" >/dev/null
grep -F 'const TOOLS_LISTING_RETRY_DELAY_MS = 300;' "$fallback_ui" >/dev/null
grep -F 'for (let attempt = 0; attempt < 2; attempt++) {' "$fallback_ui" >/dev/null
grep -F 'if (attempt === 0) await sleep(TOOLS_LISTING_RETRY_DELAY_MS);' \
    "$fallback_ui" >/dev/null
grep -F 'if (listed === null) return [];' "$fallback_ui" >/dev/null
# The early return above must precede the cache write below it, so a listing
# this loop never parsed cannot reach webToolDefinitions.
cache_write_line=$(grep -n 'webToolDefinitions = composed;' "$fallback_ui" | cut -d: -f1)
early_return_line=$(grep -n 'if (listed === null) return \[\];' "$fallback_ui" | cut -d: -f1)
if [ -z "$cache_write_line" ] || [ -z "$early_return_line" ] \
    || [ "$early_return_line" -ge "$cache_write_line" ]; then
    printf 'fallback Web UI can cache a listing it never parsed\n' >&2
    exit 1
fi

# node exercises the actual retry-then-give-up behavior against a stubbed
# fetch, when node is on the path: two failures leave the turn without a web
# tool and write no cache, and a listing that recovers after one failure is
# read and cached.
if command -v node >/dev/null 2>&1; then
    node -e '
const fs = require("fs");
const source = fs.readFileSync(process.argv[1], "utf8");
const match = source.match(
    /const TOOLS_LISTING_RETRY_DELAY_MS[\s\S]*?async function resolveWebTools[\s\S]*?\n}\n/
);
if (!match) throw new Error("resolveWebTools was not found in the served file");
const WEB_SEARCH_TOOL_NAME = "web_search_exa";
const WEB_FETCH_TOOL_NAME = "web_fetch_exa";
const WEB_TOOL_NAMES = [WEB_SEARCH_TOOL_NAME, WEB_FETCH_TOOL_NAME];
function authHeaders(extra) { return extra || {}; }
function webToolDefinition(entry) { return entry; }
let webToolDefinitions = null, webToolsModel = null, webToolsGeneration = -1;
function modelStateMatches(model, generation) {
  return model === "m" && generation === 1;
}
eval(match[0]);

async function run() {
  let calls = 0;
  global.fetch = async () => { calls++; return { ok: false, status: 503 }; };
  const failed = await resolveWebTools("m", 1);
  if (failed.length !== 0) throw new Error("a listing that never parsed returned tools");
  if (calls !== 2) throw new Error(`expected one retry (2 calls), got ${calls}`);
  if (webToolsModel !== null) throw new Error("a failed listing wrote the cache");

  calls = 0;
  global.fetch = async () => {
    calls++;
    if (calls === 1) return { ok: false, status: 503 };
    return { ok: true, status: 200, json: async () => [{ tool: "web_search_exa" }] };
  };
  const recovered = await resolveWebTools("m", 1);
  if (recovered.length !== 1) throw new Error("a listing that recovered was not read");
  if (webToolsModel !== "m") throw new Error("a recovered listing did not write the cache");
}
run().catch(error => { console.error(error.message); process.exit(1); });
' "$fallback_ui"
fi

# node exercises proposedFetchParams directly, when node is on the path: an
# absent start_index or max_chars is left out to take the wrapper's own
# default, and a present-but-malformed one -- a float, a negative number, a
# numeric string -- throws rather than being silently dropped the same way.
if command -v node >/dev/null 2>&1; then
    node -e '
const fs = require("fs");
const source = fs.readFileSync(process.argv[1], "utf8");
const match = source.match(
    /function proposedFetchParams[\s\S]*?\n}\n/
);
if (!match) throw new Error("proposedFetchParams was not found in the served file");
eval(match[0]);

const absent = proposedFetchParams(JSON.stringify({ result_id: "r1" }));
if ("start_index" in absent || "max_chars" in absent) {
    throw new Error("an absent optional field reached params");
}

const valid = proposedFetchParams(
    JSON.stringify({ result_id: "r1", start_index: 8000, max_chars: 1000 }));
if (valid.start_index !== 8000 || valid.max_chars !== 1000) {
    throw new Error("a valid integer field was not carried through");
}

for (const malformed of [
    { result_id: "r1", max_chars: "1000" },
    { result_id: "r1", start_index: "8000" },
    { result_id: "r1", start_index: 8000.5 },
    { result_id: "r1", start_index: -1 },
]) {
    let threw = false;
    try { proposedFetchParams(JSON.stringify(malformed)); }
    catch { threw = true; }
    if (!threw) {
        throw new Error(
            `a malformed field was not refused: ${JSON.stringify(malformed)}`);
    }
}
' "$fallback_ui"
fi

# node exercises truncateFetchResult against a full wrap_untrusted-shaped
# frame, when node is on the path: Returned Characters and Next Start Index
# must describe the window actually kept rather than the server's original
# window, and Possibly Truncated must read yes even where the server's own
# line read no.
if command -v node >/dev/null 2>&1; then
    node -e '
const fs = require("fs");
const source = fs.readFileSync(process.argv[1], "utf8");
const match = source.match(
    /const TOOL_RESULT_CHARACTER_CAP[\s\S]*?\nfunction truncateSearchResult[\s\S]*?\n}\n/
);
if (!match) throw new Error("truncateToolResult was not found in the served file");
eval(match[0]);

const nonce = "fetchNonce9";
const startIndex = 4000;
const window = "y".repeat(9000);
const originalDigest = "0".repeat(64);
const frame = [
    `BEGIN UNTRUSTED WEB CONTENT [${nonce}]`,
    "Source: https://example.org/raven2",
    "Retrieved: 2026-01-05T00:00:00Z",
    "Content SHA-256: " + originalDigest,
    `Start Index: ${startIndex}`,
    `Returned Characters: ${window.length}`,
    "Next Start Index: end",
    "Possibly Truncated: no",
    window,
    `END UNTRUSTED WEB CONTENT [${nonce}]`
].join("\n");
if (frame.length <= 8000) throw new Error("the fixture fetch frame fits under the cap already");

const capped = truncateToolResult(frame);
if (capped.length > 8000) {
    throw new Error(`a capped fetch frame still measures ${capped.length} characters`);
}
if (!capped.endsWith(`END UNTRUSTED WEB CONTENT [${nonce}]`)) {
    throw new Error("a capped fetch frame lost its footer");
}
if (!capped.includes("Content SHA-256: not recomputed; the client truncated this window.")) {
    throw new Error("a capped fetch frame retained no digest-invalidated marker");
}
if (capped.includes(`Content SHA-256: ${originalDigest}`)) {
    throw new Error("a capped fetch frame retained the digest of the dropped window");
}
const returnedMatch = capped.match(/\nReturned Characters: (\d+)\n/);
const nextMatch = capped.match(/\nNext Start Index: (\d+)\n/);
const truncatedMatch = capped.match(/\nPossibly Truncated: (yes|no)\n/);
if (!returnedMatch || !nextMatch || !truncatedMatch) {
    throw new Error("a capped fetch frame lost one of its navigation lines");
}
const keptWindowLength = Number(returnedMatch[1]);
if (keptWindowLength >= window.length) {
    throw new Error("Returned Characters was not shrunk to the kept window");
}
if (Number(nextMatch[1]) !== startIndex + keptWindowLength) {
    throw new Error("Next Start Index does not name the kept window'\''s own end");
}
if (truncatedMatch[1] !== "yes") {
    throw new Error("Possibly Truncated was not forced to yes for a client-side cut");
}
' "$fallback_ui"
fi

# node exercises truncateFetchResult against a window built from astral
# characters (outside the BMP, stored as UTF-16 surrogate pairs): Returned
# Characters and Next Start Index must count Unicode code points the way
# wrap_untrusted''s Python `len` does, one per emoji rather than two, and the
# kept window must end on a whole character rather than a split surrogate.
if command -v node >/dev/null 2>&1; then
    node -e '
const fs = require("fs");
const source = fs.readFileSync(process.argv[1], "utf8");
const match = source.match(
    /const TOOL_RESULT_CHARACTER_CAP[\s\S]*?\nfunction truncateSearchResult[\s\S]*?\n}\n/
);
if (!match) throw new Error("truncateToolResult was not found in the served file");
eval(match[0]);

const nonce = "astralNonce1";
const startIndex = 1000;
const window = "\u{1F600}".repeat(4500); // each code point is a UTF-16 surrogate pair
if (window.length !== 9000) throw new Error("fixture window is not 9000 UTF-16 units");
const codePointCount = Array.from(window).length;
if (codePointCount !== 4500) throw new Error("fixture window is not 4500 code points");
const frame = [
    `BEGIN UNTRUSTED WEB CONTENT [${nonce}]`,
    "Source: https://example.org/raven2",
    "Retrieved: 2026-01-05T00:00:00Z",
    "Content SHA-256: " + "0".repeat(64),
    `Start Index: ${startIndex}`,
    `Returned Characters: ${codePointCount}`,
    "Next Start Index: end",
    "Possibly Truncated: no",
    window,
    `END UNTRUSTED WEB CONTENT [${nonce}]`
].join("\n");
if (frame.length <= 8000) throw new Error("the astral fixture frame fits under the cap already");

const capped = truncateToolResult(frame);
if (capped.length > 8000) {
    throw new Error(`a capped astral frame still measures ${capped.length} characters`);
}
const returnedMatch = capped.match(/\nReturned Characters: (\d+)\n/);
const nextMatch = capped.match(/\nNext Start Index: (\d+)\n/);
if (!returnedMatch || !nextMatch) {
    throw new Error("a capped astral frame lost one of its navigation lines");
}
const keptCodePoints = Number(returnedMatch[1]);
const bodyStart = capped.indexOf("Possibly Truncated: yes\n") + "Possibly Truncated: yes\n".length;
const bodyEnd = capped.indexOf(`\nEND UNTRUSTED WEB CONTENT [${nonce}]`);
const keptBody = capped.slice(bodyStart, bodyEnd);
if (Array.from(keptBody).length !== keptCodePoints) {
    throw new Error("Returned Characters does not match the kept window'\''s own code-point count");
}
if (Number(nextMatch[1]) !== startIndex + keptCodePoints) {
    throw new Error("Next Start Index does not count code points the way wrap_untrusted does");
}
if (/\uD83D(?!\uDE00)|(?<!\uD83D)\uDE00/.test(keptBody)) {
    throw new Error("a capped astral frame split a surrogate pair");
}
' "$fallback_ui"
fi

printf 'fallback_webui_web_authorization=accepted\n'
