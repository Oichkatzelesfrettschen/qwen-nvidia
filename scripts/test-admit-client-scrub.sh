#!/bin/sh
set -eu

# Admit scripts/compute-client-record.sh, the during-run record both device
# admission harnesses retain. The scrub decides whether a run can prove the
# runtime reached the card: each harness counts the ticks whose record names
# the runtime, so a scrub that loses the name reports every run as rejected
# whatever the device did, and it fails that way silently because the count
# simply reads zero.
#
# The fixtures are recorded nvidia-smi rows rather than invented ones. Driver
# 615.71.09 answers --query-compute-apps=pid,process_name,used_memory as three
# csv fields with the whole command line in the second; an earlier driver on
# this host answered with two, which is why the field count rather than a fixed
# index selects the name. Reading the pid as the name is the known-bad this
# gate exists for: it passed a physics admission's other twenty-nine checks and
# failed only the one that proves the device was touched.

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
work_directory=$(mktemp -d "${TMPDIR:-/tmp}/admit-client-scrub.XXXXXX")
trap 'rm -rf "$work_directory"' EXIT INT TERM

. "$script_directory/compute-client-record.sh"

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

compare() {
    if [ "$(cat "$2")" = "$3" ]; then
        check "$1" pass
    else
        check "$1" fail "$(tr '\n' '|' <"$2")"
    fi
}

# Three-field driver output: a plain path, a command line carrying arguments,
# and the runtime the tick count is taken over.
cat >"$work_directory/three.raw" <<'RAW'
1789964169.121	free	2065, /usr/bin/kwin_wayland, 173 MiB
1789964169.121	free	2823371, /opt/microsoft/msedge/msedge --type=gpu-process --shared-files, 161 MiB
1789964169.121	free	tick
1789964169.249	held	481295, /tmp/out/physx-rigid-runtime, 288 MiB
1789964169.249	held	tick
RAW
qwen_compute_client_record <"$work_directory/three.raw" >"$work_directory/three.out"
compare three_field_rows "$work_directory/three.out" '1789964169.121	free	kwin_wayland 173 MiB
1789964169.121	free	msedge 161 MiB
1789964169.121	free	tick
1789964169.249	held	physx-rigid-runtime 288 MiB
1789964169.249	held	tick'

# The pid is what the record drops. A scrub reading it as the name prints the
# pid, and the runtime count then reads zero on a run that reached the device.
if grep -qE '(^|[^0-9.])(2065|2823371|481295)([^0-9]|$)' "$work_directory/three.out"; then
    check pid_dropped fail "$(grep -E '2065|2823371|481295' "$work_directory/three.out" | tr '\n' '|')"
else
    check pid_dropped pass
fi

if grep -q -- '--type=gpu-process' "$work_directory/three.out"; then
    check arguments_dropped fail "command line retained"
else
    check arguments_dropped pass
fi

# An earlier driver on this host answered without the pid. One scrub reads both
# forms, so a driver change does not silently empty the count.
cat >"$work_directory/two.raw" <<'RAW'
1788544929.614	free	/usr/bin/kwin_wayland, 224 MiB
1788544929.731	held	/tmp/out/physx-rigid-runtime, 10 MiB
1788544929.731	held	tick
RAW
qwen_compute_client_record <"$work_directory/two.raw" >"$work_directory/two.out"
compare two_field_rows "$work_directory/two.out" '1788544929.614	free	kwin_wayland 224 MiB
1788544929.731	held	physx-rigid-runtime 10 MiB
1788544929.731	held	tick'

# The geometry sampler writes its own runtime lines beside each tick. They are
# not csv, so they travel through unchanged.
cat >"$work_directory/geometry.raw" <<'RAW'
1789964170.001	held	479000, /tmp/out/optix-ray-runtime, 96 MiB
1789964170.001	held	runtime pid=479000 device_fds=3 libnvoptix_maps=4
1789964170.001	held	tick
RAW
qwen_compute_client_record <"$work_directory/geometry.raw" >"$work_directory/geometry.out"
compare sampler_lines_pass_through "$work_directory/geometry.out" '1789964170.001	held	optix-ray-runtime 96 MiB
1789964170.001	held	runtime pid=479000 device_fds=3 libnvoptix_maps=4
1789964170.001	held	tick'

# Both harnesses read the library rather than carrying a copy, which is what
# keeps one fix reaching both.
for harness in admit-physics-runtime.sh admit-geometry-runtime.sh; do
    if grep -q 'qwen_compute_client_record' "$script_directory/$harness" &&
       ! grep -q 'split(\$3, row' "$script_directory/$harness"; then
        check "${harness}_reads_the_library" pass
    else
        check "${harness}_reads_the_library" fail "carries its own scrub"
    fi
done

printf 'admit_client_scrub checks_total=%s checks_failed=%s\n' "$checks_total" "$checks_failed"
[ "$checks_failed" -eq 0 ]
