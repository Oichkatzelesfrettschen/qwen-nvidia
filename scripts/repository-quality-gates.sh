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

shell_files=$(find scripts -type f -name '*.sh' -print | sort)
# An empty set makes shellcheck print its usage and the gate report a pass
# over nothing, so the count is asserted before the check runs.
if [ -z "$shell_files" ]; then
    printf 'no shell files found under scripts/\n' >&2
    exit 1
fi
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
ruff check scripts

PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-quality-suite.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-regrade-quality-roster.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-gguf-tokenizer-identity.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-admit-candidate-static.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-verify-representation-pair.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/web-mcp/test-web-mcp.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/web-mcp/test-authorize-broker.py
scripts/test-fallback-webui-model-selection.sh
scripts/test-fallback-webui-web-authorization.sh
scripts/test-web-tools-roundtrip.sh
node scripts/test-fallback-webui-model-state.mjs
scripts/test-one-token-admission.sh
scripts/test-fetch-candidate-artifact.sh
scripts/test-model-registry.sh
scripts/test-model-tiers.sh
scripts/check-nvidia-authority.sh
scripts/test-exec-idle-priority.sh
scripts/check-validated-tuples.sh
PYTHONDONTWRITEBYTECODE=1 python3 scripts/check-authority-consistency.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-authority-consistency.py
scripts/test-qwen-code-pin.sh
scripts/test-projector-fetch-dispatch.sh
scripts/test-projector-pairing.sh
scripts/test-probe-depth-projector.sh
scripts/test-promote-llama-build.sh
scripts/test-qwen-launch-router-preflight.sh
scripts/test-qwen-capacity-policy.sh
scripts/test-web-presets.sh
scripts/test-qwen-web-launch.sh
scripts/test-prepare-llama-vulkan-source.sh
scripts/test-qwen-session-signals.sh
scripts/test-admit-web-router-fake.sh
scripts/test-quality-roster.sh
scripts/test-qwen-runtime-guards.sh
scripts/refresh-evidence-manifest.sh --check
PYTHONDONTWRITEBYTECODE=1 python3 scripts/check-text-policy.py

printf 'repository_quality_gates=accepted\n'
