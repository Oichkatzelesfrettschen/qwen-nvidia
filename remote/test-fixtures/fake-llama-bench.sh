#!/bin/sh
set -eu

# Stand in for llama-bench so the trace campaign's ledger, ordering, and halt
# behaviour run without a device. The arm is identified by the depth, the
# submission geometry, and the trace variable the environment carries, which is
# the same tuple the campaign's summary row states.
#
# QWEN_FAKE_BENCH_INVOCATIONS   file each invocation appends its arm signature to
# QWEN_FAKE_BENCH_FAIL          space-separated signatures that fail
# QWEN_FAKE_BENCH_FAIL_STATUS   exit status those use, default 124
# QWEN_FAKE_BENCH_TRACE_DUMP    signatures that print the submission trace dump
# QWEN_FAKE_BENCH_DISPLACE_LINK symlink the arm repoints at DISPLACE_TARGET

depth=0
batch=0
ubatch=0
while [ "$#" -gt 0 ]; do
    case $1 in
        -d) depth=$2; shift 2 ;;
        -b) batch=$2; shift 2 ;;
        -ub) ubatch=$2; shift 2 ;;
        *) shift ;;
    esac
done

signature=d$depth-b$batch-ub$ubatch-trace${GGML_VK_SUBMIT_TRACE:-off}
if [ -n "${QWEN_FAKE_BENCH_INVOCATIONS:-}" ]; then
    printf '%s profile=%s nodes=%s serialize=%s\n' "$signature" \
        "${QWEN_VULKAN_PROFILE:-unset}" \
        "${GGML_VK_MAX_NODES_PER_SUBMIT:-unset}" \
        "${GGML_VK_SERIALIZE_SUBMISSIONS:-unset}" \
        >>"$QWEN_FAKE_BENCH_INVOCATIONS"
fi

# A campaign whose promotion link moves while an arm runs is what the restore's
# relink exists for, so the fixture can move it from inside the arm.
if [ -n "${QWEN_FAKE_BENCH_DISPLACE_LINK:-}" ]; then
    ln -sfn "${QWEN_FAKE_BENCH_DISPLACE_TARGET:?}" "$QWEN_FAKE_BENCH_DISPLACE_LINK"
fi

prints_trace_dump=0
for traced_signature in ${QWEN_FAKE_BENCH_TRACE_DUMP:-}; do
    [ "$traced_signature" != "$signature" ] || prints_trace_dump=1
done
if [ "$prints_trace_dump" -eq 1 ]; then
    printf 'ggml_vulkan: submission trace, 3 unretired of 812 dispatches (last submitted serial 41, last retired serial 40):\n' >&2
    printf '  serial 41 node 118: kqv_out (MUL_MAT) src0=v pipeline=matmul_f16 grid=(64,1,1) workgroup=(64,1,1) fence=submitted\n' >&2
fi

for failing_signature in ${QWEN_FAKE_BENCH_FAIL:-}; do
    if [ "$failing_signature" = "$signature" ]; then
        printf 'ggml_vulkan: vk::Queue::submit: ErrorDeviceLost\n' >&2
        exit "${QWEN_FAKE_BENCH_FAIL_STATUS:-124}"
    fi
done

label=tg32
[ "$depth" -eq 0 ] || label="tg32 @ d$depth"
printf '| model | size | params | backend | ngl | test | t/s |\n'
printf '| --- | --- | --- | --- | --- | --- | --- |\n'
printf '| qwen35 4B Q4_K_M | 2.58 GiB | 4.02 B | Vulkan | 99 | %s | 3.07 +/- 0.01 |\n' \
    "$label"
