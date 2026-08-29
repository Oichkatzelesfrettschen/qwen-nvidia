#!/bin/sh
set -eu

# Run the clone-local gates that protect executable policy and retained
# evidence. Hardware, model files, and the pinned llama.cpp source remain
# separate integration surfaces; this gate names that boundary by running only
# tests whose complete fixtures live in this repository.

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH='' cd -- "$script_directory/.." && pwd)
cd "$repository_root"

for required_command in bash node shellcheck ruff python3 curl; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        printf 'required quality-gate command is absent: %s\n' \
            "$required_command" >&2
        exit 2
    fi
done

shell_files=$(find remote -type f -name '*.sh' -print | sort)
for shell_file in $shell_files; do
    IFS= read -r shebang <"$shell_file"
    case $shebang in
        *bash*) bash -n "$shell_file" ;;
        *) sh -n "$shell_file" ;;
    esac
done
# Warning-level diagnostics fail the gate. The repository treats warning drift
# as a defect even where ShellCheck would return success at error level.
shellcheck -S warning $shell_files
ruff check remote

PYTHONDONTWRITEBYTECODE=1 python3 remote/test-quality-suite.py
PYTHONDONTWRITEBYTECODE=1 python3 remote/test-regrade-quality-roster.py
PYTHONDONTWRITEBYTECODE=1 python3 remote/test-gguf-tokenizer-identity.py
PYTHONDONTWRITEBYTECODE=1 python3 remote/test-admit-candidate-static.py
PYTHONDONTWRITEBYTECODE=1 python3 remote/test-verify-representation-pair.py
PYTHONDONTWRITEBYTECODE=1 python3 remote/web-mcp/test-web-mcp.py
PYTHONDONTWRITEBYTECODE=1 python3 remote/web-mcp/test-authorize-broker.py
remote/test-fallback-webui-model-selection.sh
remote/test-fallback-webui-web-authorization.sh
remote/test-web-tools-roundtrip.sh
node remote/test-fallback-webui-model-state.mjs
remote/test-measurement-harnesses.sh
remote/test-representation-arm.sh
remote/test-one-token-admission.sh
remote/test-fetch-candidate-artifact.sh
remote/test-model-registry.sh
remote/test-model-tiers.sh
remote/check-validated-tuples.sh
remote/test-projector-fetch-dispatch.sh
remote/test-projector-pairing.sh
remote/test-probe-depth-projector.sh
remote/test-promote-llama-build.sh
remote/test-qwen-launch-router-preflight.sh
remote/test-qwen-capacity-policy.sh
remote/test-web-presets.sh
remote/test-qwen-web-launch.sh
remote/test-prepare-llama-vulkan-source.sh
remote/test-qwen-session-signals.sh
remote/test-admit-web-router-fake.sh
remote/test-quality-roster.sh
remote/test-qwen-runtime-guards.sh
remote/refresh-evidence-manifest.sh --check
PYTHONDONTWRITEBYTECODE=1 python3 remote/check-text-policy.py

printf 'repository_quality_gates=accepted\n'
