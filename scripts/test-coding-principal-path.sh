#!/bin/sh
set -eu

# Admit the three containment checks the unit suite reports not-run: uid
# separation through the real qwen-coder principal, sudo denial for that
# account, and the uid-scoped egress rule. The service runs with
# --principal qwen-coder against a temporary authoritative repository, so
# the check needs the principal (setup-coding-principal.sh), a cached sudo,
# and the egress table (setup-coding-egress.sh apply); a missing
# precondition reports not-run with its reason rather than failing, since
# this admission belongs to the appliance rather than to every clone.

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
work_directory=$(mktemp -d "${TMPDIR:-/tmp}/coding-principal-path.XXXXXX")
service_pid=''
cleanup() {
    [ -n "$service_pid" ] && kill "$service_pid" 2>/dev/null || :
    [ -n "$service_pid" ] && wait "$service_pid" 2>/dev/null || :
    sudo -n rm -rf /var/lib/qwen-coder/worktrees/job-* \
        /var/lib/qwen-coder/repos/principal-path-test.git 2>/dev/null || :
    rm -rf "$work_directory"
}
trap cleanup EXIT INT TERM

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

id qwen-coder >/dev/null 2>&1 || {
    printf 'coding_principal_path=not-run reason=qwen-coder absent\n'
    exit 0
}
sudo -n true 2>/dev/null || {
    printf 'coding_principal_path=not-run reason=sudo uncached\n'
    exit 0
}

# sudo denial: the principal is outside sudoers, so a privilege step from
# inside a job dies at the policy rather than at a prompt.
if sudo -n -u qwen-coder sudo -n true 2>/dev/null; then
    check sudo_denied_for_principal fail 'principal reached sudo'
else
    check sudo_denied_for_principal pass
fi

# Egress: with the rule applied, the principal reaches loopback and
# nothing else. The external probe targets a documentation address, so a
# refusal is the rule rather than a remote outage.
if sudo -n "$script_directory/setup-coding-egress.sh" status >/dev/null 2>&1; then
    if sudo -n -u qwen-coder curl --silent --max-time 4 \
        http://192.0.2.1/ >/dev/null 2>&1; then
        check external_network_refused fail 'external target reachable'
    else
        check external_network_refused pass
    fi
else
    printf 'check=external_network_refused outcome=not-run detail=egress table absent; run sudo sh scripts/setup-coding-egress.sh apply\n'
fi

# uid separation: one job through the real principal, its worktree owned
# by qwen-coder, its export owned by the service user.
repository=$work_directory/authoritative
mkdir -p "$repository"
git -C "$repository" init -q
git -C "$repository" config user.name test
git -C "$repository" config user.email test@example.invalid
printf 'edit\n' >"$repository/FIXTURE_BEHAVIOR"
git -C "$repository" add -A
git -C "$repository" commit -q -m 'principal path base'
base_commit=$(git -C "$repository" rev-parse HEAD)

authorities=$work_directory/authorities
mkdir -p "$authorities"
printf '# profile_id\tmodel_id\truntime_id\tworkspace_id\tmaximum_context\tmaximum_reply_tokens\tmaximum_files_changed\tmaximum_patch_bytes\tmaximum_job_seconds\tallowed_test_profile\tnetwork_policy\texecution_policy\ncode-test\tqwenseer-2b\tqwen-code\tprincipal-path-test\t32768\t8192\t8\t65536\t120\tfixture-echo\tloopback-llama\tvalidator-gated\n' \
    >"$authorities/coding-profiles.tsv"
printf '# workspace_id\trepository_path\tmirror\ttest_profile\trepository_identity\nprincipal-path-test\t%s\tprincipal-path-test.git\tfixture-echo\tprincipal-path-test\n' \
    "$repository" >"$authorities/coding-workspaces.tsv"
printf '# model_id\trole\tminimum_validated_depth\tmax_reply_tokens\nqwenseer-2b\tfast-coder\t32768\t8192\n' \
    >"$authorities/coding-models.tsv"
printf '# id\tscope\tsubject\tfailure_class\tfirst_evidence\treason_record\n' \
    >"$authorities/coding-quarantine.tsv"
printf '# id\tvalidated_filled_depth\nqwenseer-2b\t65536\n' \
    >"$authorities/models.tsv"
printf '# id\tversion\tupstream_repository\trelease_tag\tasset_name\tasset_bytes\tasset_sha256\tinstall_directory\texecutable\texecution_policy\tvalidation_evidence\nqwen-code\t0.22.3\tQwenLM/qwen-code\tv0.22.3\ta\t1\t%s\tv0.22.3\tqwen-code/bin/qwen\tvalidator-gated\t-\n' \
    "$(printf '0%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63 64)" \
    >"$authorities/coding-runtimes.tsv"
printf 'principal-path-key\n' >"$work_directory/grant.key"
chmod 600 "$work_directory/grant.key"

# The fixture agent must be readable and runnable by the principal, so a
# copy lives in the world-readable work directory.
chmod 755 "$work_directory"
cp "$script_directory/test-fixtures/fake-coding-agent.sh" \
    "$work_directory/fake-coding-agent.sh"
chmod 755 "$work_directory/fake-coding-agent.sh"

python3 "$script_directory/coding-agent-service.py" \
    --state-dir "$work_directory/state" \
    --socket "$work_directory/agent.sock" \
    --profiles "$authorities/coding-profiles.tsv" \
    --workspaces "$authorities/coding-workspaces.tsv" \
    --models "$authorities/coding-models.tsv" \
    --quarantine "$authorities/coding-quarantine.tsv" \
    --registry "$authorities/models.tsv" \
    --runtimes "$authorities/coding-runtimes.tsv" \
    --grant-key-file "$work_directory/grant.key" \
    --principal qwen-coder \
    --bundle-dir "$work_directory/bundles" \
    --agent-command "$work_directory/fake-coding-agent.sh" \
    >"$work_directory/service.log" 2>&1 &
service_pid=$!
waited=0
while [ ! -S "$work_directory/agent.sock" ]; do
    kill -0 "$service_pid" 2>/dev/null || {
        check service_started fail "$(tail -2 "$work_directory/service.log")"
        exit 1
    }
    [ "$waited" -lt 15 ] || { check service_started fail timeout; exit 1; }
    sleep 1
    waited=$((waited + 1))
done
check service_started pass

drive=$(python3 - "$work_directory" "$base_commit" <<'EOF'
import hashlib, hmac, json, os, socket, sys, time
work, base = sys.argv[1], sys.argv[2]
fields = ["action", "workspace_id", "repository_identity", "base_commit",
          "model_id", "profile_id", "instruction_sha256",
          "allowed_test_profile", "maximum_files_changed",
          "maximum_patch_bytes", "maximum_job_seconds",
          "conversation_generation", "expiry_epoch", "nonce"]
instruction = "perform the edit behavior"
claim = {"action": "open_job", "workspace_id": "principal-path-test",
         "repository_identity": "principal-path-test",
         "base_commit": base, "model_id": "qwenseer-2b",
         "profile_id": "code-test",
         "instruction_sha256":
             hashlib.sha256(instruction.encode()).hexdigest(),
         "allowed_test_profile": "fixture-echo",
         "maximum_files_changed": "8", "maximum_patch_bytes": "65536",
         "maximum_job_seconds": "120", "conversation_generation": "1",
         "expiry_epoch": str(time.time() + 300),
         "nonce": os.urandom(8).hex()}
message = "\n".join("%s=%s" % (f, claim[f]) for f in fields)
signature = hmac.new(b"principal-path-key", message.encode(),
                     hashlib.sha256).hexdigest()

def ask(payload):
    connection = socket.socket(socket.AF_UNIX)
    connection.settimeout(120)
    connection.connect(os.path.join(work, "agent.sock"))
    connection.sendall((json.dumps(payload) + "\n").encode())
    return json.loads(connection.makefile().readline())

opened = ask({"action": "open_job", "workspace_id": "principal-path-test",
              "profile_id": "code-test", "model_id": "qwenseer-2b",
              "base_commit": base, "instruction": instruction,
              "conversation_generation": "1",
              "grant": {"claim": claim, "signature": signature}})
if not opened.get("ok"):
    print("open_failed %s %s" % (opened.get("error"),
                                 opened.get("detail")))
    raise SystemExit(1)
job_id = opened["result"]["job_id"]
worktree = opened["result"]["worktree"]
planned = ask({"action": "plan", "job_id": job_id})
apply_fields = ["action", "job_id", "plan_sha256", "instruction_sha256",
                "model_id", "profile_id", "conversation_generation",
                "expiry_epoch", "nonce"]
apply_claim = {"action": "apply_patch", "job_id": job_id,
               "plan_sha256": planned["result"]["plan_sha256"],
               "instruction_sha256": claim["instruction_sha256"],
               "model_id": "qwenseer-2b", "profile_id": "code-test",
               "conversation_generation": "1",
               "expiry_epoch": str(time.time() + 300),
               "nonce": os.urandom(8).hex()}
apply_message = "\n".join("%s=%s" % (f, apply_claim[f])
                          for f in apply_fields)
apply_signature = hmac.new(b"principal-path-key", apply_message.encode(),
                           hashlib.sha256).hexdigest()
applied = ask({"action": "apply_patch", "job_id": job_id,
               "grant": {"claim": apply_claim,
                         "signature": apply_signature}})
import subprocess
owner = subprocess.run(["sudo", "-n", "stat", "-c", "%U", worktree],
                       capture_output=True, text=True).stdout.strip()
finished = ask({"action": "finish", "job_id": job_id})
print("owner=%s applied=%s finished=%s worktree_gone=%s"
      % (owner, applied.get("ok"), finished.get("ok"),
         not os.path.exists(worktree)))
EOF
) || { check principal_job_chain fail "$drive"; exit 1; }
case $drive in
    owner=qwen-coder*applied=True*finished=True*worktree_gone=True)
        check uid_separation pass
        check principal_job_chain pass ;;
    *)
        check uid_separation fail "$drive"
        check principal_job_chain fail "$drive" ;;
esac

if [ "$checks_failed" -eq 0 ]; then
    printf 'coding_principal_path=accepted checks=%s\n' "$checks_total"
    exit 0
fi
printf 'coding_principal_path=rejected failed=%s of=%s\n' \
    "$checks_failed" "$checks_total" >&2
exit 1
