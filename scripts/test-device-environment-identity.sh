#!/bin/sh
set -eu

# The identity block is what makes a retained measurement comparable to a later
# one, so its field set is a contract rather than a convenience: a harness that
# emits eight fields today and seven tomorrow leaves the reader unable to tell a
# missing driver from a removed column. These cases check the field set, the
# `unavailable` convention that keeps an absent source distinguishable from an
# unwritten field, and the exclusion of the GPU UUID that this tree scrubs
# beside MAC addresses and private hostnames.

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM
failures=0
report() {
    if [ "$1" -eq 0 ]; then
        printf 'ok %s\n' "$2"
    else
        printf 'FAIL %s\n' "$2"
        failures=$((failures + 1))
    fi
}

expected_fields='gpu_name gpu_uuid_sha256 driver_version kernel_module_version
vbios_version cuda_driver_version cuda_toolkit_version kernel_release'

# A fake nvidia-smi answers every query with a known value, so the block is
# checked against what the driver said rather than against this host.
cat >"$temporary_directory/nvidia-smi" <<'FAKE'
#!/bin/sh
for argument in "$@"; do
    case $argument in
    --query-gpu=name) printf 'FAKE GeForce\n'; exit 0 ;;
    --query-gpu=driver_version) printf '  610.57.04  \n'; exit 0 ;;
    --query-gpu=vbios_version) printf '95.04.31.00.A4\n'; exit 0 ;;
    --query-gpu=uuid) printf 'GPU-00000000-0000-0000-0000-000000000000\n'; exit 0 ;;
    -q) printf '    CUDA Version                    : 13.3 [Deprecated]\n'; exit 0 ;;
    esac
done
exit 0
FAKE
chmod +x "$temporary_directory/nvidia-smi"

block=$temporary_directory/identity.tsv
QWEN_IDENTITY_NVIDIA_SMI="$temporary_directory/nvidia-smi" \
    "$script_directory/device-environment-identity.sh" "$block"

missing=''
for field in $expected_fields; do
    awk -F'\t' -v f="$field" '$1 == f { found = 1 } END { exit !found }' "$block" ||
        missing="$missing $field"
done
if [ -z "$missing" ]; then
    report 0 'the block carries every contracted field'
else
    report 1 "the block carries every contracted field (missing:$missing)"
fi

field_value() { awk -F'\t' -v f="$1" '$1 == f { print $2 }' "$2"; }

if [ "$(field_value driver_version "$block")" = '610.57.04' ]; then
    report 0 'the driver version is trimmed of the surrounding spaces nvidia-smi emits'
else
    report 1 "the driver version is trimmed ($(field_value driver_version "$block"))"
fi

if [ "$(field_value cuda_driver_version "$block")" = '13.3' ]; then
    report 0 'the CUDA runtime version is cut from the deprecation notice beside it'
else
    report 1 "the CUDA runtime version is cut from the notice ($(field_value cuda_driver_version "$block"))"
fi

# The digest stands in for the board so two records can be compared for the same
# device, and the UUID itself never reaches a retained file.
digest=$(field_value gpu_uuid_sha256 "$block")
expected_digest=$(printf 'GPU-00000000-0000-0000-0000-000000000000' | sha256sum | cut -c1-16)
if [ "$digest" = "$expected_digest" ]; then
    report 0 'the UUID is retained as the first sixteen hex of its digest'
else
    report 1 "the UUID is retained as its digest ($digest against $expected_digest)"
fi
if grep -q 'GPU-00000000' "$block"; then
    report 1 'the raw UUID stays out of the block'
else
    report 0 'the raw UUID stays out of the block'
fi

# A host with no driver writes the same eight fields, so a reader tells an
# absent source from a column a harness never wrote.
cat >"$temporary_directory/absent-smi" <<'ABSENT'
#!/bin/sh
exit 1
ABSENT
chmod +x "$temporary_directory/absent-smi"
absent=$temporary_directory/absent.tsv
QWEN_IDENTITY_NVIDIA_SMI="$temporary_directory/absent-smi" \
    "$script_directory/device-environment-identity.sh" "$absent"
if [ "$(wc -l <"$absent")" = "$(wc -l <"$block")" ] &&
    [ "$(field_value driver_version "$absent")" = unavailable ] &&
    [ "$(field_value gpu_uuid_sha256 "$absent")" = unavailable ]; then
    report 0 'a driverless host writes the same fields reading unavailable'
else
    report 1 'a driverless host writes the same fields reading unavailable'
fi

# Every harness that admits an observation through the ownership authority
# writes the block beside it, so no retained campaign states a rate without
# stating the stack that produced it.
for harness in run-mmvq-width-request-tails.sh run-mmvq-paired-crossover.sh \
    run-ncu-kernel-baseline.sh run-decode-node-trace.sh run-cuda-baseline-sweep.sh \
    probe-backend-sampling-reach.sh; do
    if grep -q 'device-environment-identity.sh' "$script_directory/$harness"; then
        report 0 "$harness writes the device environment block"
    else
        report 1 "$harness writes the device environment block"
    fi
done

if [ "$failures" -ne 0 ]; then
    printf '%s failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'device_environment_identity=accepted\n'
