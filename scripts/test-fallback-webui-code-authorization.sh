#!/bin/sh
set -eu

# Code mode reaches the coding-agent service through the same
# one-human-approval discipline the web and image lanes use, with two grant
# contexts of its own: a plan grant over the instruction, workspace, and
# server-resolved base commit, and an apply grant over the reviewed plan
# hash. Grep asserts the structural properties against the served file the
# way the web and image authorization tests do, so the gate runs wherever
# the tree is cloned.

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
fallback_ui=$script_directory/../webui/index.html

fail() {
    printf 'fallback Web UI code authorization: %s\n' "$1" >&2
    exit 1
}

# The per-turn Code snapshot governs the tool list, and Code is exclusive:
# turning it on clears and disables the demo, Web, and Image toggles, so a
# turn carries one authority surface.
grep -F '<input type="checkbox" id="code-tools">' "$fallback_ui" >/dev/null ||
    fail 'the Code toggle is absent'
grep -F "const codePermission = \$('#code-tools').checked;" "$fallback_ui" \
    >/dev/null || fail 'send() takes no per-turn Code snapshot'
grep -F "for (const id of ['#tools', '#web-tools', '#image-tools'])" \
    "$fallback_ui" >/dev/null || fail 'Code mode is not exclusive'

# The served names compose from the section's `code` key, the composition
# llama-server applies, so the page and find_tool read one name.
grep -F "const CODE_MCP_SERVER_NAME = 'code';" "$fallback_ui" >/dev/null ||
    fail 'the code MCP server key is unnamed'
grep -F 'const codeToolName = bare => `${CODE_MCP_SERVER_NAME}_${bare}`;' \
    "$fallback_ui" >/dev/null || fail 'the composed-name rule is absent'

# Five model-facing tools; finish, cancel, and workspace are browser-session
# controls the model's tool array never carries, and a model proposing one
# is answered rather than executed.
grep -F 'const CODE_MODEL_TOOL_NAMES = [' "$fallback_ui" >/dev/null ||
    fail 'the model-facing tool set is unnamed'
grep -F 'const CODE_SESSION_CONTROL_NAMES = [' "$fallback_ui" >/dev/null ||
    fail 'the session-control set is unnamed'
grep -F 'is a browser-session control; the page invokes it, not the model.' \
    "$fallback_ui" >/dev/null || fail 'a proposed session control executes'

# Before a job exists only the plan tool is offered, stripped to the one
# argument the model owns; the base commit and every other plan field are
# browser-injected after approval from the server-resolved workspace state.
grep -F "required: ['instruction']," "$fallback_ui" >/dev/null ||
    fail 'the plan schema offers the model more than the instruction'
grep -F 'await executeCodeTool(CODE_WORKSPACE_TOOL_NAME, {}, proposalModel)' \
    "$fallback_ui" >/dev/null || fail 'the base commit is not server-resolved'
grep -F 'base_commit: ws.base_commit,' "$fallback_ui" >/dev/null ||
    fail 'the injected base commit does not come from the workspace state'

# Two grants, each posted to its own broker route, the apply grant signed
# over the plan hash the human reviewed.
grep -F "requestCodeGrant('/grant-code-plan', {" "$fallback_ui" >/dev/null ||
    fail 'the plan grant route is absent'
grep -F "requestCodeGrant('/grant-code-apply', {" "$fallback_ui" >/dev/null ||
    fail 'the apply grant route is absent'
grep -F 'plan_sha256: job.planSha256,' "$fallback_ui" >/dev/null ||
    fail 'the apply grant is not bound to the reviewed plan hash'

# A changed model, a Clear, or a roster re-resolution cancels the job and
# discards late results.
grep -c 'invalidateCodeJob(' "$fallback_ui" | {
    read -r count
    [ "$count" -ge 3 ] || fail 'job invalidation misses a state change'
}
grep -F "invalidateCodeJob('cancelled: the conversation was cleared');" \
    "$fallback_ui" >/dev/null || fail 'Clear leaves the job running'

# Finish and cancel are card buttons the browser drives, and finish renders
# the export identity rather than a machine-local path.
grep -F 'finishButton.onclick = () => { void finishCodeJob(job); };' \
    "$fallback_ui" >/dev/null || fail 'the finish control is absent'
grep -F 'finished: export ${finished.payload.export_id}' "$fallback_ui" \
    >/dev/null || fail 'finish does not render the export identity'

printf 'fallback_webui_code_authorization=accepted\n'
