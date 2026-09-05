#!/bin/sh
set -eu
# The fallback Web UI reaches a device sidecar through one human approval, and
# the properties that make that true are pinned against the served file: the
# device toggle governs whether the physics and geometry tools are offered at
# all, one dialog offers approve-once and deny alone, the grant is requested
# at the lane's own broker path over the fields the listing bound, and the
# proposal's argument text is parsed before any bound is read.
if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
fallback_ui=$script_directory/../webui/index.html
fail() {
    printf 'fallback Web UI sidecar authorization: %s\n' "$1" >&2
    exit 1
}
grep -F '<input type="checkbox" id="sidecar-tools">' "$fallback_ui" >/dev/null ||
    fail 'the device toggle is absent'
grep -F "const sidecarPermission = \$('#sidecar-tools').checked;" "$fallback_ui" >/dev/null ||
    fail 'send() takes no per-turn device snapshot'
grep -F "\$('#sidecar-tools').checked = false;" "$fallback_ui" >/dev/null ||
    fail 'the device toggle is not reset at the turn boundary'
grep -F 'if (sidecarPermission) {' "$fallback_ui" >/dev/null ||
    fail 'the device tools are offered without the permission'
grep -F "physics: { tool: 'physics_simulate_rigid'" "$fallback_ui" >/dev/null ||
    fail 'the physics lane names another tool'
grep -F "geometry: { tool: 'geometry_ray_query'" "$fallback_ui" >/dev/null ||
    fail 'the geometry lane names another tool'
grep -F "grantPath: '/grant-physics'" "$fallback_ui" >/dev/null ||
    fail 'the physics grant is requested at another path'
grep -F "grantPath: '/grant-geometry'" "$fallback_ui" >/dev/null ||
    fail 'the geometry grant is requested at another path'
grep -F "const SIDECAR_GRANT_CONTEXT = 'qwen-sidecar-run-v1';" "$fallback_ui" >/dev/null ||
    fail 'the grant context differs from the broker claim'
# One dialog, two buttons, and no third path to a run.
grep -F '<dialog class="approval" id="sidecar-approval">' "$fallback_ui" >/dev/null ||
    fail 'the device dialog is absent'
grep -F 'id="sidecar-approve-once">approve once</button>' "$fallback_ui" >/dev/null ||
    fail 'the device dialog offers no approve-once'
grep -F 'id="sidecar-approve-deny">deny</button>' "$fallback_ui" >/dev/null ||
    fail 'the device dialog offers no deny'
grep -c 'id="sidecar-approve-' "$fallback_ui" | grep -qx 2 ||
    fail 'the device dialog offers a third button'
# The grant binds what the listing stated, read out of the definition rather
# than typed anywhere on the page.
grep -F 'const scene = properties.profile_id.x_scene;' "$fallback_ui" >/dev/null ||
    fail 'the scene is not read from the listing'
grep -F 'const runtime = properties.profile_id.x_runtime_sha256;' "$fallback_ui" >/dev/null ||
    fail 'the runtime digest is not read from the listing'
grep -F 'runtime_sha256: bounds.runtime,' "$fallback_ui" >/dev/null ||
    fail 'the grant request omits the runtime digest'
grep -F 'count_ceiling: bounds.ceiling,' "$fallback_ui" >/dev/null ||
    fail 'the grant request omits the ceiling'
# The proposal's argument text is parsed as one JSON object before any bound
# is read, since llama-server streams the arguments as a string.
grep -F 'function proposedSidecarFields(lane, argumentText, bounds) {' "$fallback_ui" >/dev/null ||
    fail 'the proposal parser takes no argument text'
grep -F 'args = JSON.parse(argumentText);' "$fallback_ui" >/dev/null ||
    fail 'the proposal parser does not parse the argument text'
# One run per lane per turn, and the call carries the grant inside params.
grep -F 'const SIDECAR_RUNS_PER_TURN = 1;' "$fallback_ui" >/dev/null ||
    fail 'the per-turn allowance is not one run per lane'
grep -F 'authorization: sidecarOutcome.authorization };' "$fallback_ui" >/dev/null ||
    fail 'the run params omit the grant'
grep -F "const text = await executeWebTool(toolName, params, proposalModel);" "$fallback_ui" >/dev/null ||
    fail 'the run does not go through the shared tool executor'
# Code mode keeps the device surface off beside the others.
grep -F "for (const id of ['#tools', '#web-tools', '#image-tools', '#sidecar-tools'])" "$fallback_ui" >/dev/null ||
    fail 'Code mode does not exclude the device toggle'
# No grant reaches browser storage.
if grep -n 'localStorage\|sessionStorage' "$fallback_ui" | grep -qi 'sidecar\|authorization'; then
    fail 'a sidecar grant reaches browser storage'
fi
printf 'fallback_webui_sidecar_authorization=accepted\n'
