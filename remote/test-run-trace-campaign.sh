#!/bin/sh
set -eu

# The trace campaign spends the device and leaves an instrumented binary behind
# if its restore fails, so the properties checked here are the ones that decide
# what the laptop is left running: the refusals that happen before any arm, the
# order the arms run in, the halt at the first failure, whether the ledger names
# the retained trace, and the EXIT trap's restore of the production closure.
#
# Every device-touching input is a fixture. The bench, the Vulkan environment
# wrapper, the clock sampler, the kernel reader, the patch verifier, and the
# device probe are all replaced, so the run exercises the campaign's own logic
# on a workstation.

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
campaign=$script_directory/run-trace-campaign.sh
fixtures=$script_directory/test-fixtures
work_directory=$(mktemp -d)
trap 'rm -rf "$work_directory"' EXIT INT TERM
failures=0

report() {
    printf '%s=%s\n' "$1" "$2"
    [ "$2" = accepted ] || failures=$((failures + 1))
}

# One fixture appliance: a trace build with a manifest, a promoted production
# build whose manifest matches its own load closure, and the promotion symlink
# between them.
trace_build=$work_directory/build-trace
mkdir -p "$trace_build/bin"
cp "$fixtures/fake-llama-bench.sh" "$trace_build/bin/llama-bench"
chmod +x "$trace_build/bin/llama-bench"
printf 'preset\traven2-vulkan-production\ncommit\tf280b26983ad0fdb705a0d9ebf0503e76f2899b0\n' \
    >"$trace_build/artifact-manifest.tsv"

appliance_source=$work_directory/llama.cpp-qwen-nvidia
production_build=$appliance_source/build-raven2-vulkan-production
mkdir -p "$production_build/bin"
cat >"$production_build/bin/llama-server" <<'SERVER'
#!/bin/sh
printf 'version 0 (fixture)\n'
SERVER
chmod +x "$production_build/bin/llama-server"
"$script_directory/hash-load-closure.sh" "$production_build/bin/llama-server" |
    sed 1d >"$production_build/artifact-manifest.tsv"
ln -sfn "$production_build" "$appliance_source/build-appliance-current"

model_file=$work_directory/model.gguf
printf 'GGUF fixture\n' >"$model_file"

cat >"$work_directory/fake-clock-sampler.sh" <<'SAMPLER'
#!/bin/sh
printf '933\t1100\t74000\t0\t1048576\t2097152\n' >"$1"
sleep 30
SAMPLER
cat >"$work_directory/fake-kernel-reader.sh" <<'KERNEL'
#!/bin/sh
exit 1
KERNEL
cat >"$work_directory/fake-patch-verifier.sh" <<'VERIFIER'
#!/bin/sh
[ "${QWEN_TEST_PATCH_SERIES_FAILS:-0}" != 1 ] || exit 1
printf 'patch_series=accepted\n'
VERIFIER
cat >"$work_directory/fake-device-probe.sh" <<'PROBE'
#!/bin/sh
printf '%s' "${QWEN_TEST_DEVICE_HOLDER:-}"
PROBE
chmod +x "$work_directory/fake-clock-sampler.sh" \
    "$work_directory/fake-kernel-reader.sh" \
    "$work_directory/fake-patch-verifier.sh" \
    "$work_directory/fake-device-probe.sh"

run_campaign() {
    campaign_output=$1
    shift
    QWEN_TRACE_FOREGROUND=1 \
    QWEN_TRACE_BUILD_DIR=$trace_build \
    QWEN_TRACE_MODEL_PATH=$model_file \
    QWEN_TRACE_APPLIANCE_SOURCE=$appliance_source \
    QWEN_TRACE_ENV_WRAPPER=$fixtures/fake-vulkan-env-wrapper.sh \
    QWEN_TRACE_CLOCK_SAMPLER=$work_directory/fake-clock-sampler.sh \
    QWEN_TRACE_KERNEL_READER=$work_directory/fake-kernel-reader.sh \
    QWEN_TRACE_PATCH_VERIFIER=$work_directory/fake-patch-verifier.sh \
    QWEN_TRACE_DEVICE_PROBE=$work_directory/fake-device-probe.sh \
    QWEN_TRACE_SKIP_TRACE_SOURCE_GATE=1 \
    QWEN_TRACE_SKIP_PRODUCTION_SOURCE_GATE=1 \
    QWEN_TRACE_ARM_TIMEOUT_S=20 \
    QWEN_TRACE_ARM_KILL_AFTER_S=5 \
    QWEN_FAKE_BENCH_INVOCATIONS=$campaign_output.invocations \
    env "$@" \
        "$campaign" "$campaign_output" >"$campaign_output.stdout" \
            2>"$campaign_output.stderr"
}

summary_field() {
    awk -F'\t' -v label="$2" -v field="$3" \
        '$1 == label { print $field; exit }' "$1/trace-campaign-summary.tsv"
}

# Argument errors. One operand is the whole interface, and the usage exit is 2
# so a caller can tell a refused invocation from a halted campaign.
argument_state=accepted
set +e
"$campaign" >/dev/null 2>&1
zero_argument_status=$?
"$campaign" one two >/dev/null 2>&1
two_argument_status=$?
set -e
[ "$zero_argument_status" -eq 2 ] || argument_state="zero arguments exited $zero_argument_status"
[ "$two_argument_status" -eq 2 ] || argument_state="two arguments exited $two_argument_status"
report argument_errors "$argument_state"

# The trace build is named rather than defaulted, and it is refused unless it
# holds an executable bench.
set +e
QWEN_TRACE_FOREGROUND=1 QWEN_TRACE_MODEL_PATH=$model_file \
    "$campaign" "$work_directory/out-nobuild" >/dev/null 2>&1
missing_build_status=$?
QWEN_TRACE_FOREGROUND=1 QWEN_TRACE_MODEL_PATH=$model_file \
    QWEN_TRACE_BUILD_DIR=$work_directory/absent-build \
    "$campaign" "$work_directory/out-emptybuild" >/dev/null 2>&1
empty_build_status=$?
set -e
missing_build_state=accepted
[ "$missing_build_status" -eq 2 ] ||
    missing_build_state="unnamed trace build exited $missing_build_status"
[ "$empty_build_status" -eq 2 ] ||
    missing_build_state="trace build without a bench exited $empty_build_status"
report missing_trace_build "$missing_build_state"

# A live server holds the device for the whole run, so the campaign refuses
# before it spends anything.
set +e
QWEN_TEST_DEVICE_HOLDER=llama-server \
    run_campaign "$work_directory/out-held"
held_status=$?
set -e
held_state=accepted
[ "$held_status" -eq 2 ] || held_state="a held device exited $held_status"
grep -q 'held by llama-server' "$work_directory/out-held.stderr" ||
    held_state='the refusal did not name the holder'
[ ! -e "$work_directory/out-held.invocations" ] ||
    held_state='an arm ran while the device was held'
report refuses_while_server_runs "$held_state"

# The trace-source gate refuses a build whose tree is not the six-patch replay,
# which is what keeps a diagnostic binary from an earlier revision off an arm.
stale_source=$work_directory/stale-trace-source
mkdir -p "$stale_source/.git" "$stale_source/tools/server" \
    "$stale_source/ggml/src/ggml-vulkan"
printf 'stale server\n' >"$stale_source/tools/server/server.cpp"
set +e
QWEN_TRACE_FOREGROUND=1 QWEN_TRACE_BUILD_DIR=$trace_build \
    QWEN_TRACE_MODEL_PATH=$model_file \
    QWEN_TRACE_SOURCE_DIR=$stale_source \
    QWEN_TRACE_DEVICE_PROBE=$work_directory/fake-device-probe.sh \
    QWEN_TRACE_ENV_WRAPPER=$fixtures/fake-vulkan-env-wrapper.sh \
    QWEN_TRACE_CLOCK_SAMPLER=$work_directory/fake-clock-sampler.sh \
    QWEN_TRACE_PATCH_VERIFIER=$work_directory/fake-patch-verifier.sh \
    "$campaign" "$work_directory/out-stale" \
        >"$work_directory/out-stale.stdout" 2>"$work_directory/out-stale.stderr"
stale_status=$?
set -e
stale_state=accepted
[ "$stale_status" -eq 2 ] || stale_state="a stale trace source exited $stale_status"
grep -q 'six-patch replay' "$work_directory/out-stale.stderr" ||
    stale_state='the refusal did not name the six-patch replay'
report refuses_stale_trace_source "$stale_state"

# The router-tools digest is what separates a current diagnostic tree from one
# built before that patch, so the campaign carries the earlier digest by value
# and reports which patch is missing rather than reporting a generic mismatch.
router_state=accepted
grep -q 'pre_router_server_sha256=2833d9d237e77a70a75736426f11432b964bc66f8e85c5751451f77444338703' \
    "$campaign" || router_state='the pre-router digest is absent'
grep -q 'predates llama-router-tools-proxy.patch' "$campaign" ||
    router_state='no refusal names the router tools patch'
report names_pre_router_digest "$router_state"

# A clean campaign runs P0, P1, T1 in that order, each followed by its control,
# and every arm carries the resolved submission triple.
clean_output=$work_directory/out-clean
set +e
run_campaign "$clean_output"
clean_status=$?
set -e
clean_state=accepted
[ "$clean_status" -eq 0 ] || clean_state="a clean campaign exited $clean_status"
expected_invocations='d16384-b128-ub32-traceoff
d0-b128-ub32-traceoff
d16384-b128-ub32-trace1
d0-b128-ub32-traceoff
d16384-b2048-ub32-trace1
d0-b128-ub32-traceoff'
actual_invocations=$(awk '{ print $1 }' "$clean_output.invocations")
[ "$actual_invocations" = "$expected_invocations" ] ||
    clean_state="arm order was $(printf '%s' "$actual_invocations" | tr '\n' ' ')"
recorded_arms=$(awk -F'\t' 'NR > 1 { print $1 }' \
    "$clean_output/trace-campaign-summary.tsv" | tr '\n' ' ')
[ "$recorded_arms" = 'p0 p1 t1 ' ] ||
    clean_state="the ledger recorded $recorded_arms"
grep -q 'profile=custom nodes=16 serialize=1' "$clean_output.invocations" ||
    clean_state='an arm ran outside the resolved submission triple'
[ "$(summary_field "$clean_output" p1 6)" = 16 ] &&
    [ "$(summary_field "$clean_output" p1 7)" = 1 ] ||
    clean_state='the ledger omits the resolved submission triple'
grep -q 'trace_campaign=completed' "$clean_output.stdout" ||
    clean_state='a clean campaign did not report completion'
[ "$(summary_field "$clean_output" p1 22)" = not-triggered ] ||
    clean_state='a completed traced arm did not read not-triggered'
report clean_campaign_arm_order "$clean_state"

# The trace build's own load closure is recorded beside the arms.
closure_state=accepted
[ -s "$clean_output/trace-build-closure.tsv" ] ||
    closure_state='the trace build closure is absent'
grep -q '^executable	llama-bench' "$clean_output/trace-build-closure.tsv" ||
    closure_state='the closure does not name the bench'
report records_trace_build_closure "$closure_state"

# A resumed campaign reads its recorded rows rather than re-running the device.
resume_state=accepted
set +e
run_campaign "$clean_output"
resume_status=$?
set -e
[ "$resume_status" -eq 0 ] || resume_state="a resumed campaign exited $resume_status"
resume_skips=$(grep -c 'arm_resume_skip' "$clean_output.stdout" || true)
[ "$resume_skips" -eq 3 ] || resume_state="the resume skipped $resume_skips arms"
report resumes_recorded_arms "$resume_state"

# P0 failing ends the campaign before any trace exists, which the terminal
# summary states rather than leaving to inference.
p0_output=$work_directory/out-p0-fail
set +e
QWEN_FAKE_BENCH_FAIL=d16384-b128-ub32-traceoff \
    run_campaign "$p0_output"
p0_status=$?
set -e
p0_state=accepted
[ "$p0_status" -eq 1 ] || p0_state="a halted campaign exited $p0_status"
p0_arms=$(awk -F'\t' 'NR > 1 { print $1 }' \
    "$p0_output/trace-campaign-summary.tsv" | tr '\n' ' ')
[ "$p0_arms" = 'p0 ' ] || p0_state="the ledger recorded $p0_arms after a P0 failure"
grep -q 'trace_campaign=halted arm=p0 reason=arm-timed-out' "$p0_output.stdout" ||
    p0_state='the halt did not name the timed-out P0 arm'
[ "$(summary_field "$p0_output" p0 22)" = off ] ||
    p0_state='an untraced arm claimed a trace state'
report halts_at_first_failure "$p0_state"

# T1 failing with a trace names the retained log, which is where the submission
# serial, the last completed serial, the node, the pipeline, and the dispatch
# geometry are read.
t1_output=$work_directory/out-t1-trace
set +e
QWEN_FAKE_BENCH_FAIL=d16384-b2048-ub32-trace1 \
    QWEN_FAKE_BENCH_TRACE_DUMP=d16384-b2048-ub32-trace1 \
    run_campaign "$t1_output"
t1_status=$?
set -e
t1_state=accepted
[ "$t1_status" -eq 1 ] || t1_state="a halted campaign exited $t1_status"
[ "$(summary_field "$t1_output" t1 22)" = present ] ||
    t1_state='the ledger did not record the trace dump'
[ "$(summary_field "$t1_output" t1 23)" = "$t1_output/t1.log" ] ||
    t1_state='the ledger did not name the retained trace log'
grep -q "trace_record=$t1_output/t1.log" "$t1_output.stdout" ||
    t1_state='the halt did not name the trace record'
grep -q 'submission trace' "$t1_output/t1.log" ||
    t1_state='the retained log carries no trace dump'
report t1_failure_names_trace "$t1_state"

# A T1 failure that printed no trace is a different ledger row, because an
# instrumentation failure and a graph that never lost the device are otherwise
# the same record.
t1_bare_output=$work_directory/out-t1-bare
set +e
QWEN_FAKE_BENCH_FAIL=d16384-b2048-ub32-trace1 \
    run_campaign "$t1_bare_output"
t1_bare_status=$?
set -e
t1_bare_state=accepted
[ "$t1_bare_status" -eq 1 ] || t1_bare_state="a halted campaign exited $t1_bare_status"
[ "$(summary_field "$t1_bare_output" t1 22)" = absent ] ||
    t1_bare_state='a traceless failure did not record an absent trace'
grep -q 'trace_record=absent' "$t1_bare_output.stdout" ||
    t1_bare_state='the halt did not report the absent trace'
report t1_failure_without_trace "$t1_bare_state"

# The EXIT trap restores the production closure on every path, and the restore
# line is the proof. A campaign that halted still ends restored.
restore_state=accepted
grep -q 'production_closure=restored action=unchanged' "$clean_output.stdout" ||
    restore_state='a clean campaign did not report a restored closure'
grep -q 'production_closure=restored' "$t1_output.stdout" ||
    restore_state='a halted campaign did not report a restored closure'
report restores_on_every_path "$restore_state"

# A promotion link moved while the campaign ran is relinked to the recorded
# target rather than left where the arm put it.
relink_output=$work_directory/out-relink
displaced_build=$work_directory/displaced-build
mkdir -p "$displaced_build"
set +e
QWEN_FAKE_BENCH_DISPLACE_LINK=$appliance_source/build-appliance-current \
    QWEN_FAKE_BENCH_DISPLACE_TARGET=$displaced_build \
    run_campaign "$relink_output"
relink_status=$?
set -e
relink_state=accepted
[ "$relink_status" -eq 0 ] || relink_state="a relinking campaign exited $relink_status"
grep -q 'production_closure=restored action=relinked' "$relink_output.stdout" ||
    relink_state='the displaced link was left where the arm put it'
[ "$(readlink "$appliance_source/build-appliance-current")" = "$production_build" ] ||
    relink_state='the promotion link does not name the production build'
report relinks_displaced_promotion "$relink_state"

# A closure that no longer matches its manifest leaves the closure unrestored,
# and that outranks the campaign's own status.
drift_output=$work_directory/out-drift
printf 'drifted\n' >>"$production_build/bin/llama-server"
set +e
run_campaign "$drift_output"
drift_status=$?
set -e
printf '#!/bin/sh\nprintf %s\n' "'version 0 (fixture)\n'" \
    >"$production_build/bin/llama-server"
"$script_directory/hash-load-closure.sh" "$production_build/bin/llama-server" |
    sed 1d >"$production_build/artifact-manifest.tsv"
drift_state=accepted
[ "$drift_status" -eq 70 ] ||
    drift_state="an unrestored closure exited $drift_status"
grep -q 'production_closure=UNRESTORED reason=closure-drift' \
    "$drift_output.stderr" || drift_state='the closure drift was not reported'
report reports_unrestored_closure "$drift_state"

# The serving tree carrying the trace header is the diagnostic tree in the
# production tree's place, which the restore refuses by name.
traced_appliance=$work_directory/llama.cpp-traced-appliance
mkdir -p "$traced_appliance/ggml/src/ggml-vulkan" \
    "$traced_appliance/build-raven2-vulkan-production/bin"
: >"$traced_appliance/ggml/src/ggml-vulkan/ggml-vulkan-submit-trace.h"
cp "$production_build/bin/llama-server" \
    "$traced_appliance/build-raven2-vulkan-production/bin/llama-server"
cp "$production_build/artifact-manifest.tsv" \
    "$traced_appliance/build-raven2-vulkan-production/artifact-manifest.tsv"
ln -sfn "$traced_appliance/build-raven2-vulkan-production" \
    "$traced_appliance/build-appliance-current"
traced_output=$work_directory/out-traced-appliance
set +e
run_campaign "$traced_output" \
    QWEN_TRACE_APPLIANCE_SOURCE="$traced_appliance" \
    QWEN_TRACE_SKIP_PRODUCTION_SOURCE_GATE=0
traced_status=$?
set -e
traced_state=accepted
[ "$traced_status" -eq 70 ] ||
    traced_state="a traced serving tree exited $traced_status"
grep -q 'production_closure=UNRESTORED reason=production-source-carries-trace-header' \
    "$traced_output.stderr" ||
    traced_state='the serving tree was not refused for carrying the trace header'
report refuses_traced_production_source "$traced_state"

# A bypassed gate is recorded rather than silent.
bypass_state=accepted
grep -q 'trace_source_gate=bypassed' "$clean_output.stderr" ||
    bypass_state='a bypassed trace source gate was silent'
grep -q 'production_source_gate=bypassed' "$clean_output.stderr" ||
    bypass_state='a bypassed production source gate was silent'
report records_bypassed_gates "$bypass_state"

# The patch series is the other half of the restore proof, and its refusal has
# its own reason.
series_output=$work_directory/out-series
set +e
QWEN_TEST_PATCH_SERIES_FAILS=1 run_campaign "$series_output"
series_status=$?
set -e
series_state=accepted
[ "$series_status" -eq 70 ] ||
    series_state="a refused patch series exited $series_status"
grep -q 'production_closure=UNRESTORED reason=patch-series-refused' \
    "$series_output.stderr" || series_state='the patch series refusal was not reported'
report reports_patch_series_refusal "$series_state"

if [ "$failures" -ne 0 ]; then
    printf 'test_run_trace_campaign=failed checks=%s\n' "$failures" >&2
    exit 1
fi
printf 'test_run_trace_campaign=passed\n'
