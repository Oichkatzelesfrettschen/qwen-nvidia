#!/bin/sh
set -eu

# Admit the Qwen Code pin without the network or an installed runtime: the
# registry row is structurally valid and refused, the settings template
# disables auto-update, persists no credential, and names only loopback
# endpoints, the fetcher refuses a link member and an escaping path in a
# crafted archive, and the launch wrapper refuses the refused policy, a
# non-loopback base URL, an undefined model, and a world-readable key file.

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
work_directory=$(mktemp -d "${TMPDIR:-/tmp}/test-qwen-code-pin.XXXXXX")
trap 'rm -rf "$work_directory"' EXIT INT TERM

checks_total=0
checks_failed=0
check() {
    checks_total=$((checks_total + 1))
    if [ "$2" = pass ]; then
        printf 'check=%s outcome=pass\n' "$1"
    else
        checks_failed=$((checks_failed + 1))
        printf 'check=%s outcome=FAIL detail=%s\n' "$1" "${3:-}" >&2
    fi
}

# Registry structure: one qwen-code row, eleven fields, execution refused,
# a 64-hex digest, a positive byte count, and existing validation evidence.
row=$(awk -F'\t' '!/^#/ && $1 == "qwen-code"' \
    "$script_directory/coding-runtimes.tsv")
field_count=$(printf '%s' "$row" | awk -F'\t' '{ print NF }')
[ "$field_count" = 11 ] && check registry_field_count pass ||
    check registry_field_count fail "fields=$field_count"
[ "$(printf '%s' "$row" | cut -f10)" = refused ] &&
    check registry_execution_refused pass ||
    check registry_execution_refused fail "$(printf '%s' "$row" | cut -f10)"
printf '%s' "$row" | cut -f7 | grep -qE '^[0-9a-f]{64}$' &&
    check registry_digest_shape pass || check registry_digest_shape fail
printf '%s' "$row" | cut -f6 | grep -qE '^[1-9][0-9]*$' &&
    check registry_bytes_shape pass || check registry_bytes_shape fail
[ -f "$script_directory/../$(printf '%s' "$row" | cut -f11)" ] &&
    check registry_evidence_exists pass ||
    check registry_evidence_exists fail "$(printf '%s' "$row" | cut -f11)"

# Settings template: valid JSON, auto-update off, loopback endpoints only,
# no persisted credential, both coder models defined with an envKey.
if python3 - "$script_directory/qwen-code-settings.json" <<'EOF'
import json, sys
settings = json.load(open(sys.argv[1]))
assert settings["general"]["enableAutoUpdate"] is False
entries = [entry for provider in settings["modelProviders"].values()
           for entry in provider]
ids = {entry["id"] for entry in entries}
assert {"qwenseer-2b", "qwen25-coder-7b"} <= ids
for entry in entries:
    assert entry["baseUrl"].startswith("http://127.0.0.1")
    assert entry["envKey"] == "QWEN_NVIDIA_LOCAL_API_KEY"
    assert "apiKey" not in entry and "api_key" not in entry
assert settings["providerProtocol"]["qwen-nvidia"] == "openai"
EOF
then check settings_template pass; else check settings_template fail; fi

# The fetcher against a local fixture: stand in for the release host with
# file paths through a curl shim, so the digest, byte, link-member, and
# escaping-path refusals each fire on the crafted inputs.
fixture_root=$work_directory/fixture
mkdir -p "$fixture_root/qwen-code/bin" "$fixture_root/qwen-code/node/bin"
cat >"$fixture_root/qwen-code/bin/qwen" <<'EOF'
#!/bin/sh
echo 0.22.3
EOF
chmod +x "$fixture_root/qwen-code/bin/qwen"
(cd "$fixture_root" && tar -czf "$work_directory/good.tar.gz" qwen-code)
good_bytes=$(wc -c <"$work_directory/good.tar.gz" | tr -d ' ')
good_sha256=$(sha256sum "$work_directory/good.tar.gz" | cut -d ' ' -f 1)

ln -s /etc/passwd "$fixture_root/qwen-code/escape-link"
(cd "$fixture_root" && tar -czf "$work_directory/link.tar.gz" qwen-code)
rm "$fixture_root/qwen-code/escape-link"

(cd "$fixture_root" && tar -czf "$work_directory/traverse.tar.gz" \
    --transform 's|^qwen-code/bin/qwen$|qwen-code/../escaped|' \
    qwen-code/bin/qwen)

make_registry() {
    sed -E "s|84633418|$2|; s|9db29c26[0-9a-f]{56}|$3|" \
        "$script_directory/coding-runtimes.tsv" >"$1/coding-runtimes.tsv"
}
make_curl_shim() {
    # The shim answers the asset URL with the named archive and the digest
    # URL with a SHA256SUMS naming that archive's digest.
    cat >"$1/curl" <<EOF
#!/bin/sh
output=''
url=''
while [ "\$#" -gt 0 ]; do
    case \$1 in
        --output) output=\$2; shift 2 ;;
        http*) url=\$1; shift ;;
        *) shift ;;
    esac
done
case \$url in
    */SHA256SUMS) printf '%s  %s\n' "$3" qwen-code-linux-x64.tar.gz >"\$output" ;;
    *) cp "$2" "\$output" ;;
esac
EOF
    chmod +x "$1/curl"
}

run_fetch() {
    harness=$work_directory/$1
    mkdir -p "$harness/install"
    cp "$script_directory/download-qwen-code-v0223.sh" "$harness/"
    make_registry "$harness" "$2" "$3"
    make_curl_shim "$harness" "$4" "$5"
    ( PATH=$harness:$PATH \
        sh "$harness/download-qwen-code-v0223.sh" "$harness/install" ) \
        >"$harness/stdout" 2>"$harness/stderr"
}

if run_fetch accept "$good_bytes" "$good_sha256" \
    "$work_directory/good.tar.gz" "$good_sha256" &&
    grep -q 'qwen_code=pinned' "$work_directory/accept/stdout" &&
    [ -x "$work_directory/accept/install/candidate/qwen-code/bin/qwen" ]; then
    check fetch_accepts_pinned_archive pass
else
    check fetch_accepts_pinned_archive fail \
        "$(cat "$work_directory/accept/stderr" 2>/dev/null | tail -1)"
fi

bad_sha256=$(printf '%s' "$good_sha256" | tr '0-9a-f' 'f0-9a-e')
if run_fetch digest "$good_bytes" "$good_sha256" \
    "$work_directory/good.tar.gz" "$bad_sha256"; then
    check fetch_refuses_publisher_disagreement fail accepted
else
    check fetch_refuses_publisher_disagreement pass
fi

link_bytes=$(wc -c <"$work_directory/link.tar.gz" | tr -d ' ')
link_sha256=$(sha256sum "$work_directory/link.tar.gz" | cut -d ' ' -f 1)
if run_fetch link "$link_bytes" "$link_sha256" \
    "$work_directory/link.tar.gz" "$link_sha256"; then
    check fetch_refuses_link_member fail accepted
else
    grep -q 'non-regular members' "$work_directory/link/stderr" &&
        check fetch_refuses_link_member pass ||
        check fetch_refuses_link_member fail \
            "$(tail -1 "$work_directory/link/stderr")"
fi

traverse_bytes=$(wc -c <"$work_directory/traverse.tar.gz" | tr -d ' ')
traverse_sha256=$(sha256sum "$work_directory/traverse.tar.gz" | cut -d ' ' -f 1)
if run_fetch traverse "$traverse_bytes" "$traverse_sha256" \
    "$work_directory/traverse.tar.gz" "$traverse_sha256"; then
    check fetch_refuses_escaping_path fail accepted
else
    grep -q 'escaping paths' "$work_directory/traverse/stderr" &&
        check fetch_refuses_escaping_path pass ||
        check fetch_refuses_escaping_path fail \
            "$(tail -1 "$work_directory/traverse/stderr")"
fi

if run_fetch bytes 1 "$good_sha256" \
    "$work_directory/good.tar.gz" "$good_sha256"; then
    check fetch_refuses_byte_mismatch fail accepted
else
    check fetch_refuses_byte_mismatch pass
fi

# The launch wrapper's refusals, driven against the accepted install.
wrapper_env() {
    QWEN_CODE_INSTALL_ROOT=$work_directory/accept/install \
    QWEN_CODE_STATE_DIR=$work_directory/state \
    QWEN_CODE_KEY_FILE=${wrapper_key_file:-$work_directory/key} \
    QWEN_CODE_BASE_URL=${wrapper_base_url:-http://127.0.0.1:8080/v1} \
    QWEN_CODE_ALLOW_DIRECT=${wrapper_allow:-1} \
        sh "$script_directory/run-qwen-code.sh" "$@"
}
printf 'test-key\n' >"$work_directory/key"
chmod 600 "$work_directory/key"

if wrapper_allow=0 wrapper_env qwenseer-2b >/dev/null 2>&1; then
    check wrapper_refuses_refused_policy fail accepted
else
    check wrapper_refuses_refused_policy pass
fi
if wrapper_base_url=http://0.0.0.0:8080/v1 \
    wrapper_env qwenseer-2b >/dev/null 2>&1; then
    check wrapper_refuses_non_loopback fail accepted
else
    check wrapper_refuses_non_loopback pass
fi
if wrapper_env no-such-model >/dev/null 2>&1; then
    check wrapper_refuses_undefined_model fail accepted
else
    check wrapper_refuses_undefined_model pass
fi
chmod 644 "$work_directory/key"
if wrapper_env qwenseer-2b >/dev/null 2>&1; then
    check wrapper_refuses_open_key_mode fail accepted
else
    check wrapper_refuses_open_key_mode pass
fi
chmod 600 "$work_directory/key"

# An admitted run reaches the fixture executable, which prints its argv-free
# version line; the key must be absent from the argv the wrapper builds.
if wrapper_output=$(wrapper_env qwenseer-2b 2>&1) &&
    [ "$wrapper_output" = 0.22.3 ]; then
    check wrapper_execs_pinned_runtime pass
else
    check wrapper_execs_pinned_runtime fail "$wrapper_output"
fi

if [ "$checks_failed" -eq 0 ]; then
    printf 'qwen_code_pin=accepted checks=%s\n' "$checks_total"
    exit 0
fi
printf 'qwen_code_pin=rejected failed=%s of=%s\n' \
    "$checks_failed" "$checks_total" >&2
exit 1
