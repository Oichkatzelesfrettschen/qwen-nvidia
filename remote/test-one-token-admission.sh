#!/bin/sh
set -eu

# The sweep decides which rows reach the device and what a refusal is recorded
# against, so its failure modes are silent ones: a row skipped without a line, a
# refusal recorded as a pass, or a control that never runs and leaves every
# later refusal unattributable. These checks drive it with a fetch and a
# placement check that answer on command.

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM
failures=0

report() {
    printf '%s=%s\n' "$1" "$2"
    [ "$2" = accepted ] || failures=$((failures + 1))
}

fake_fetch=$temporary_directory/fake-fetch.sh
printf '%s\n' '#!/bin/sh' 'set -eu' \
    'case $3 in' \
    '    *unfetchable*) printf "fetch failed\\n" >&2; exit 1 ;;' \
    'esac' \
    'mkdir -p "$(dirname -- "$4/$3")"' \
    ': >"$4/$3"' \
    'printf "%s\\n" "$3" >>"${QWEN_TEST_FETCH_CALLS:?}"' \
    'digest_label=observed_sha256' \
    'case $3 in *alpha*) digest_label=verified_sha256 ;; esac' \
    'printf "artifact_status=fetched path=%s/%s bytes=1 %s=%s repository=%s revision=%s\\n" \' \
    '    "$4" "$3" "$digest_label" "0000000000000000000000000000000000000000000000000000000000000000" "$1" "$2"' \
    >"$fake_fetch"
chmod +x "$fake_fetch"

fake_placement=$temporary_directory/fake-placement.sh
printf '%s\n' '#!/bin/sh' 'set -eu' \
    'model=""' \
    'while [ "$#" -gt 0 ]; do' \
    '    case $1 in --model) model=$2; shift 2 ;; *) shift ;; esac' \
    'done' \
    'case $model in' \
    '    *rejects*) printf "strict Vulkan completion returned HTTP 500\\n" >&2; exit 1 ;; ' \
    'esac' \
    'printf "strict_vulkan_completion=accepted\\n"' \
    >"$fake_placement"
chmod +x "$fake_placement"

control_model=$temporary_directory/control.gguf
: >"$control_model"
fake_server=$temporary_directory/llama-server
printf '#!/bin/sh\nexit 0\n' >"$fake_server"
chmod +x "$fake_server"

# Two rows of one architecture, one of another, one that fails to parse
# statically, one whose artifact cannot be fetched, one the device refuses, and
# one parsed row outside the candidate ledger's runtime-admission scope.
record=$temporary_directory/static-admission.tsv
{
    printf 'candidate_id\trepository\trevision\tadmission\tarchitecture\tblock_count\tnextn_layers\tvocabulary_size\ttokenizer_pre\tchat_template_sha256\tchat_template_bytes\ttokens_sha256\tartifact\tartifact_bytes\tloaded_tensor_bytes\tskipped_mtp_bytes\tsplit_shards\tgguf_file_count\tselection_rule\theader_window_bytes\tenable_thinking\tthinking_block\ttools\ttool_calls\tarchitecture_fingerprint\n'
    printf 'alpha\towner/alpha\taaa\tparsed\tqwen35\t24\t0\t1\tq\th\t1\tt\talpha-Q4_K_M.gguf\t1\t1\t0\t1\t1\tpreference:q4_k_m\t16\tTrue\tTrue\tTrue\tTrue\tqwen35/block_count=24/embedding_length=2048/feed_forward_length=6144/attention.head_count=8/attention.head_count_kv=2\n'
    printf 'beta\towner/beta\tbbb\tparsed\tqwen35\t25\t0\t1\tq\th\t1\tt\tbeta-Q4_K_M.gguf\t1\t1\t0\t1\t1\tpreference:q4_k_m\t16\tTrue\tTrue\tTrue\tTrue\tqwen35/block_count=25/embedding_length=2048/feed_forward_length=6144/attention.head_count=8/attention.head_count_kv=2\n'
    printf 'gamma\towner/gamma\tccc\tparsed\tqwen35\t24\t0\t1\tq\th\t1\tt\tgamma-Q4_K_M.gguf\t1\t1\t0\t1\t1\tpreference:q4_k_m\t16\tFalse\tFalse\tFalse\tFalse\tqwen35/block_count=24/embedding_length=2048/feed_forward_length=6144/attention.head_count=16/attention.head_count_kv=4\n'
    printf 'delta\towner/delta\tddd\tfailed\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\n'
    printf 'epsilon\towner/epsilon\teee\tparsed\tqwen35\t24\t0\t1\tq\th\t1\tt\tunfetchable-Q4_K_M.gguf\t1\t1\t0\t1\t1\tpreference:q4_k_m\t16\tTrue\tTrue\tTrue\tTrue\tqwen35/block_count=24/embedding_length=2048/feed_forward_length=6144/attention.head_count=8/attention.head_count_kv=2\n'
    printf 'zeta\towner/zeta\tfff\tparsed\tqwen35\t24\t0\t1\tq\th\t1\tt\tzeta-rejects-Q4_K_M.gguf\t1\t1\t0\t1\t1\tpreference:q4_k_m\t16\tTrue\tTrue\tTrue\tTrue\tqwen35/block_count=24/embedding_length=2048/feed_forward_length=6144/attention.head_count=8/attention.head_count_kv=2\n'
    printf 'eta\towner/eta\tggg\tparsed\tqwen35\t24\t0\t1\tq\th\t1\tt\teta-Q4_K_M.gguf\t1\t1\t0\t1\t1\tpreference:q4_k_m\t16\tTrue\tTrue\tTrue\tTrue\tqwen35/block_count=24/embedding_length=2048/feed_forward_length=6144/attention.head_count=8/attention.head_count_kv=2\n'
    printf 'theta\towner/theta\thhh\tparsed\tqwen35\t24\t0\t1\tq\th\t1\tt\tnested/theta-00001-of-00002.gguf\t2\t2\t0\t2\t2\tpreference:q4_k_m\t16\tTrue\tTrue\tTrue\tTrue\tqwen35/block_count=24/embedding_length=2048/feed_forward_length=6144/attention.head_count=8/attention.head_count_kv=2\n'
} >"$record"

candidate_ledger=$temporary_directory/candidate-ledger.tsv
{
    printf 'candidate_id\tadmission_stage\n'
    printf 'alpha\tserved\n'
    printf 'beta\tstatic-admitted\n'
    printf 'gamma\tstatic-admitted\n'
    printf 'delta\tstatic-admitted\n'
    printf 'epsilon\tstatic-admitted\n'
    printf 'zeta\tstatic-admitted\n'
    printf 'eta\tphase-1\n'
    printf 'theta\tstatic-admitted\n'
} >"$candidate_ledger"

output_directory=$temporary_directory/out
fetch_calls=$temporary_directory/fetch-calls
QWEN_LLAMA_SERVER=$fake_server QWEN_CONTROL_MODEL=$control_model \
QWEN_CANDIDATE_ROOT=$temporary_directory/candidates \
QWEN_PLACEMENT_CHECK=$fake_placement QWEN_CANDIDATE_FETCH=$fake_fetch \
QWEN_CANDIDATE_LEDGER=$candidate_ledger QWEN_TEST_FETCH_CALLS=$fetch_calls \
    "$script_directory/run-one-token-admission.sh" "$record" "$output_directory" \
    >"$temporary_directory/sweep.stdout" 2>"$temporary_directory/sweep.stderr" || true

summary=$output_directory/admission-summary.tsv
column() { awk -F'\t' -v id="$1" -v n="$2" '$1 == id { print $n }' "$summary"; }

# Every in-scope parsed row appears exactly once. The unparsed row and the
# rows outside served and static-admitted stay outside the runtime sweep.
if [ "$(awk 'NR > 1' "$summary" | wc -l | tr -d ' ')" = 6 ] &&
   [ -z "$(column delta 1)" ] && [ -z "$(column eta 1)" ]; then
    report row_coverage accepted
else
    report row_coverage rejected
    cat "$summary" >&2
fi

if [ "$(column alpha 4)" = \
        0000000000000000000000000000000000000000000000000000000000000000 ]; then
    report publisher_verified_digest_retained accepted
else
    report publisher_verified_digest_retained rejected
fi

if grep -Fx 'nested/theta-00001-of-00002.gguf' "$fetch_calls" >/dev/null && \
   grep -Fx 'nested/theta-00002-of-00002.gguf' "$fetch_calls" >/dev/null && \
   [ -f "$temporary_directory/candidates/theta/nested/theta-00002-of-00002.gguf" ]; then
    report split_checkpoint_fetches_every_shard accepted
else
    report split_checkpoint_fetches_every_shard rejected
fi

if [ "$(column alpha 6)" = accepted ] && [ "$(column beta 6)" = accepted ] &&
   [ "$(column gamma 6)" = accepted ]; then
    report loads_recorded accepted
else
    report loads_recorded rejected
fi

# A refused load is recorded as rejected rather than folded into a pass, and it
# carries a detail a reader can act on.
if [ "$(column zeta 6)" = rejected ] && [ "$(column zeta 9)" != '-' ]; then
    report refusal_recorded accepted
else
    report refusal_recorded rejected
fi

# A row whose artifact never arrives never reaches the device.
if [ "$(column epsilon 5)" = failed ] && [ "$(column epsilon 6)" = not-run ]; then
    report unfetchable_row_skips_the_device accepted
else
    report unfetchable_row_skips_the_device rejected
fi

# One control per new runtime class, plus one after the refusal.
control_logs=$(find "$output_directory" -name 'control-*.log' | wc -l | tr -d ' ')
if [ "$control_logs" = 3 ] && [ -f "$output_directory/control-after-zeta.log" ]; then
    report control_per_class_and_failure accepted
else
    report control_per_class_and_failure rejected
    find "$output_directory" -name 'control-*.log' >&2
fi

# Selecting rows restricts the sweep rather than reordering it.
selected_output=$temporary_directory/selected
QWEN_LLAMA_SERVER=$fake_server QWEN_CONTROL_MODEL=$control_model \
QWEN_CANDIDATE_ROOT=$temporary_directory/candidates \
QWEN_PLACEMENT_CHECK=$fake_placement QWEN_CANDIDATE_FETCH=$fake_fetch \
QWEN_CANDIDATE_LEDGER=$candidate_ledger QWEN_TEST_FETCH_CALLS=$fetch_calls \
QWEN_ADMISSION_ROWS=beta \
    "$script_directory/run-one-token-admission.sh" "$record" "$selected_output" \
    >/dev/null 2>&1 || true
if [ "$(awk 'NR > 1 { print $1 }' "$selected_output/admission-summary.tsv" |
        tr '\n' ' ')" = "beta " ]; then
    report row_selection accepted
else
    report row_selection rejected
fi

# The fetch stage alone leaves the device untouched, which is what lets the
# transfers run while the appliance is still serving.
fetch_only=$temporary_directory/fetch-only
QWEN_CANDIDATE_ROOT=$temporary_directory/candidates-fetch-only \
QWEN_PLACEMENT_CHECK=$fake_placement QWEN_CANDIDATE_FETCH=$fake_fetch \
QWEN_CANDIDATE_LEDGER=$candidate_ledger QWEN_TEST_FETCH_CALLS=$fetch_calls \
QWEN_ADMISSION_STAGES=fetch \
    "$script_directory/run-one-token-admission.sh" "$record" "$fetch_only" \
    >/dev/null 2>&1 || true
# Every row records the vision path as not run until a projector arm exists.
if [ "$(awk -F'\t' 'NR > 1 && $7 != "not-run" { print }' "$summary" | wc -l | tr -d ' ')" = 0 ]; then
    report projector_recorded_not_run accepted
else
    report projector_recorded_not_run rejected
fi

if [ "$(awk -F'\t' 'NR > 1 && $6 != "not-run" { print }' \
        "$fetch_only/admission-summary.tsv" | wc -l | tr -d ' ')" = 0 ] &&
   [ -z "$(find "$fetch_only" -name 'control-*.log')" ]; then
    report fetch_stage_touches_no_device accepted
else
    report fetch_stage_touches_no_device rejected
fi

nonexecuting_fetch=$temporary_directory/nonexecuting-fetch.sh
cp "$fake_fetch" "$nonexecuting_fetch"
chmod 600 "$nonexecuting_fetch"
helper_output=$temporary_directory/nonexecuting-helper
if QWEN_LLAMA_SERVER=$fake_server QWEN_CONTROL_MODEL=$control_model \
    QWEN_CANDIDATE_ROOT=$temporary_directory/candidates-helper \
    QWEN_PLACEMENT_CHECK=$fake_placement QWEN_CANDIDATE_FETCH=$nonexecuting_fetch \
    QWEN_CANDIDATE_LEDGER=$candidate_ledger QWEN_TEST_FETCH_CALLS=$fetch_calls \
    "$script_directory/run-one-token-admission.sh" "$record" "$helper_output" \
    >"$temporary_directory/helper.stdout" 2>"$temporary_directory/helper.stderr"; then
    report nonexecuting_helper_refused rejected
elif grep -F 'admission helper is not executable:' \
        "$temporary_directory/helper.stderr" >/dev/null && \
     [ ! -e "$helper_output/admission-summary.tsv" ]; then
    report nonexecuting_helper_refused accepted
else
    report nonexecuting_helper_refused rejected
fi

if [ "$failures" -eq 0 ]; then
    printf 'one_token_admission_driver=accepted\n'
    exit 0
fi
printf 'one_token_admission_driver=rejected failures=%s\n' "$failures" >&2
exit 1
