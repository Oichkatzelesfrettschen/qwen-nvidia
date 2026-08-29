#!/bin/sh
set -eu

# Verify the identities that the capacity policy validated after the Vulkan
# environment is configured and immediately before llama-server replaces this
# process. The server never reads these authorities; their identities bind the
# assembled argv to the exact preset, model registry, quarantine registry, and
# web profile ledger whose identity admitted the server command. Non-web router launches
# carry `-` for the web-ledger pair.

if [ "$#" -lt 9 ]; then
    printf 'usage: %s PRESET PRESET_SHA MODEL_REGISTRY MODEL_SHA QUARANTINE_REGISTRY QUARANTINE_SHA WEB_PROFILES WEB_PROFILES_SHA COMMAND [ARG ...]\n' \
        "$0" >&2
    exit 2
fi

preset_path=$1
preset_sha256=$2
model_registry_path=$3
model_registry_sha256=$4
quarantine_registry_path=$5
quarantine_registry_sha256=$6
web_profiles_path=$7
web_profiles_sha256=$8
shift 8

verify_identity() {
    identity_name=$1
    identity_path=$2
    expected_sha256=$3
    if [ "${#expected_sha256}" -ne 64 ]; then
        printf '%s SHA-256 must hold 64 lowercase hexadecimal characters\n' \
            "$identity_name" >&2
        return 1
    fi
    case $expected_sha256 in
        *[!0-9a-f]*)
            printf '%s SHA-256 must hold 64 lowercase hexadecimal characters\n' \
                "$identity_name" >&2
            return 1
            ;;
    esac
    if ! measured_identity=$(sha256sum "$identity_path"); then
        printf '%s identity cannot be measured: %s\n' \
            "$identity_name" "$identity_path" >&2
        return 1
    fi
    measured_sha256=${measured_identity%% *}
    if [ "$measured_sha256" != "$expected_sha256" ]; then
        printf '%s identity changed: expected %s, measured %s\n' \
            "$identity_name" "$expected_sha256" "$measured_sha256" >&2
        return 1
    fi
}

verify_identity 'router preset' "$preset_path" "$preset_sha256"
verify_identity 'router model registry' \
    "$model_registry_path" "$model_registry_sha256"
verify_identity 'router quarantine registry' \
    "$quarantine_registry_path" "$quarantine_registry_sha256"
if [ "$web_profiles_path" = - ] || [ "$web_profiles_sha256" = - ]; then
    if [ "$web_profiles_path" != - ] || [ "$web_profiles_sha256" != - ]; then
        printf 'router web profile ledger path and SHA-256 must both be `-` or both be present\n' >&2
        exit 1
    fi
else
    verify_identity 'router web profile ledger' \
        "$web_profiles_path" "$web_profiles_sha256"
fi

exec "$@"
