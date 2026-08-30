#!/bin/sh
set -eu

# The repository Web UI is the fallback when the separately built llama-ui is
# absent. Router mode exposes only preset ids, so the fallback must derive its
# request model from /v1/models and never send a single-model alias.

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
fallback_ui=$script_directory/../webui/index.html

grep -F '<select class="model-picker" id="model-picker"' "$fallback_ui" >/dev/null
grep -F "fetch('./v1/models'" "$fallback_ui" >/dev/null
grep -F 'model: requestModel' "$fallback_ui" >/dev/null
grep -F 'model: selectedModel, content: text, add_special: false' \
    "$fallback_ui" >/dev/null
grep -F './props?model=${encodeURIComponent(selectedModel)}' \
    "$fallback_ui" >/dev/null
grep -F "if (!selectedModel) throw new Error('no routable model is selected')" \
    "$fallback_ui" >/dev/null
# A row that offers no tool -- a review-only vision section -- cannot act on
# a chat turn's own Web or image toggle, so the roster's sort order alone
# cannot set the default: the page probes `GET /tools` per roster row and
# prefers the first one that answers 200 over sort position, while a still-
# valid stored choice from browser storage stays authoritative over the probe.
#
# The probe passes autoload=false. The router loads a model on demand by
# default, so a probe that autoloads makes the page load every roster row at
# boot, and a row larger than the device carve-out is killed by the kernel
# while loading, which ends the server the page is talking to.
grep -F 'async function probeToolOffering(modelId)' "$fallback_ui" >/dev/null
grep -F './tools?model=${encodeURIComponent(modelId)}&autoload=false' \
    "$fallback_ui" >/dev/null
if grep -F './tools?model=${encodeURIComponent(modelId)}&autoload=true' \
    "$fallback_ui" >/dev/null; then
    printf 'the roster probe autoloads, which loads every roster row at boot\n' >&2
    exit 1
fi
grep -F 'modelIds.includes(storedModel)' "$fallback_ui" >/dev/null
grep -F 'modelIds.find(modelId => toolOffering[modelId] === true) ?? modelIds[0]' \
    "$fallback_ui" >/dev/null
# The option label reads the section's own tags. Absent tools mean an ordinary
# model, which is every row while each execution lane reads refused, so a label
# keyed on the tool listing marks the whole roster as review-only.
grep -F "rowTags.includes('review-only')" "$fallback_ui" >/dev/null
grep -F "modelTags[model.id] = Array.isArray(model.tags) ? model.tags : []" \
    "$fallback_ui" >/dev/null
grep -F "readBrowserStorage('localStorage', 'qwen-model-id')" \
    "$fallback_ui" >/dev/null
grep -F "writeBrowserStorage('localStorage', 'qwen-model-id', selectedModel)" \
    "$fallback_ui" >/dev/null
grep -F 'const generation = ++modelStateGeneration' "$fallback_ui" >/dev/null
grep -F 'return requestModel === selectedModel && modelStateGeneration === generation' \
    "$fallback_ui" >/dev/null
grep -F 'attachment.tokenModel = selectedModel' "$fallback_ui" >/dev/null
grep -F 'attachment.tokenModel = null' "$fallback_ui" >/dev/null
grep -F 'nctxModel = selectedModel' "$fallback_ui" >/dev/null
grep -F 'nctxModel = null' "$fallback_ui" >/dev/null
grep -F 'selectRequestModel(event.target.value)' "$fallback_ui" >/dev/null

if grep -F "fetch('./props'" "$fallback_ui" >/dev/null; then
    printf 'fallback Web UI requests unscoped router context metadata\n' >&2
    exit 1
fi

if grep -E '(localStorage|sessionStorage)\.(getItem|setItem|removeItem)' \
    "$fallback_ui" >/dev/null; then
    printf 'fallback Web UI bypasses storage-denial handling\n' >&2
    exit 1
fi

if grep -E "model: ['\"]qwen-(apu|nvidia)['\"]" "$fallback_ui" >/dev/null; then
    printf 'fallback Web UI still sends the single-model compatibility alias\n' >&2
    exit 1
fi

printf 'fallback_webui_model_selection=accepted\n'
