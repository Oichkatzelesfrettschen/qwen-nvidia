#!/bin/sh
# Resolve which driver client list reports the graphics-latency probe.
#
# scripts/gpu-workloads.tsv classifies vulkan-graphics-service-probe.c as an
# authorized-monitor whose submissions are project-generated traffic even on the
# graphics queue, and gpu_ownership_inspect refuses a run by reading
# nvidia-smi --query-compute-apps. Those two facts leave one question open: a
# client the compute-app query never lists cannot be excluded by that query, so
# the owner lock is the only mechanism that reaches it. This harness answers the
# question by observation rather than by argument.
#
# `nvidia-smi -q -d PIDS` is the primary surface because its Type field names
# C, G, or C+G directly and no --query-graphics-apps counterpart exists. The
# compute-app CSV and `nvidia-smi pmon` corroborate it, and a disagreement among
# the three is retained rather than collapsed into one verdict.
#
# The prediction is written before the probe runs. On driver 610.57.04 the
# compute-app query returned the three C+G clients and omitted every type-G
# client that -q -d PIDS and pmon both reported, so a probe submitting on the
# graphics queue alone is predicted to read driver_visibility=graphics. A
# C+G result is the deviation that would matter, because the compute-client
# inspection would then identify the probe on its own.
#
# The arm runs under the daily desktop. The client roster is retained as the
# covariate it is rather than being reduced to a compositor-only session, since
# the verdict asks whether one pid appears in one list and a second client
# changes no part of that.
set -eu

usage() {
    cat >&2 <<'USAGE'
usage: classify-graphics-latency-probe.sh OUTPUT_DIRECTORY

Takes the top-level GPU owner authority, runs one graphics-latency probe as an
authorized monitor, samples the three driver client surfaces while it submits,
and reports which of them name the probe.

  QWEN_VULKAN_LATENCY_PROBE  probe binary, default build/vulkan-graphics-service-probe
  QWEN_CLASSIFY_LOCK         owner lock path, default /tmp/qwen-ad104-gpu-0.lock
  QWEN_CLASSIFY_SAMPLES      sampling seconds, default 10
USAGE
    exit 2
}

[ "$#" -eq 1 ] || usage
output_directory=$1

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
probe=${QWEN_VULKAN_LATENCY_PROBE:-"$script_directory/../build/vulkan-graphics-service-probe"}
samples=${QWEN_CLASSIFY_SAMPLES:-10}

[ -x "$probe" ] || {
    printf 'refused: the graphics-latency probe is unavailable: %s\n' "$probe" >&2
    printf 'build it with scripts/build-vulkan-graphics-service-probe.sh\n' >&2
    exit 1
}
command -v nvidia-smi >/dev/null 2>&1 || {
    printf 'refused: nvidia-smi is unavailable\n' >&2
    exit 1
}
case $samples in
    '' | *[!0-9]* | 0) printf 'refused: sampling seconds must be a positive integer: %s\n' "$samples" >&2; exit 2 ;;
esac

mkdir -p "$output_directory"
output_directory=$(CDPATH='' cd -- "$output_directory" && pwd)
probe_log=$output_directory/probe.log
summary=$output_directory/classification-summary.tsv

# The prediction is retained before the device is touched, so a result that
# agrees with it and a result that deviates from it are read the same way.
cat > "$output_directory/prediction.txt" <<'PREDICTION'
prediction=graphics
reasoning=the compute-app query on driver 610.57.04 returned only C+G clients
    and omitted every type-G client that -q -d PIDS and pmon reported, so a
    probe submitting on the graphics queue alone is predicted to be absent from
    the compute-app list and present in the other two.
falsifier_compute=the probe appears in --query-compute-apps, which would make
    the existing compute-client inspection able to identify it without the lock.
falsifier_absent=the probe appears in none of the three surfaces, which would
    leave the owner lock as the only mechanism that reaches it.
PREDICTION

# Sample all three surfaces once into one named prefix. A repeated sample
# appends under its own marker rather than opening a file per second, so the
# retained record is three files whatever the sampling count is.
sample_surfaces() {
    sample_prefix=$1
    sample_marker=$2
    {
        printf '# sample %s\n' "$sample_marker"
        nvidia-smi --query-compute-apps=pid,process_name,used_memory \
            --format=csv,noheader 2>&1 || :
    } >> "$sample_prefix-compute-apps.csv"
    {
        printf '# sample %s\n' "$sample_marker"
        nvidia-smi -q -d PIDS 2>&1 || :
    } >> "$sample_prefix-pids.txt"
    {
        printf '# sample %s\n' "$sample_marker"
        nvidia-smi pmon -c 1 2>&1 || :
    } >> "$sample_prefix-pmon.txt"
}

# Report whether one pid appears in one retained surface, and with which type.
surface_type() {
    surface_pids_file=$1
    surface_pid=$2
    awk -v want="$surface_pid" '
        /^ *Process ID/ { split($0, field, ":"); gsub(/ /, "", field[2]); pid = field[2] }
        /^ *Type/ && pid == want { split($0, field, ":"); gsub(/ /, "", field[2]); print field[2]; exit }
    ' "$surface_pids_file"
}

. "$script_directory/gpu-workload-ownership.sh"

gpu_ownership_require "${QWEN_CLASSIFY_LOCK:-}" > "$output_directory/ownership-before.txt" || {
    status=$?
    cat "$output_directory/ownership-before.txt" >&2
    exit "$status"
}
cat "$output_directory/ownership-before.txt"

sample_surfaces "$output_directory/before" 0

# The watched process is the probe's own lifetime argument and opens no device.
# Both children close descriptor 9, because an inherited owner descriptor keeps
# the claim alive past this arm and locks out the next session against a device
# nothing is using.
sleep $((samples + 30)) 9>&- &
watched_pid=$!

ionice -c 3 "$probe" \
    --log "$probe_log" \
    --watch-pid "$watched_pid" \
    --interval-ms 16 \
    --deadline-us 20000 \
    --observe 9>&- &
probe_pid=$!

probe_ready=0
ready_attempt=0
while [ "$ready_attempt" -lt 100 ]; do
    if grep -F 'probe_start ' "$probe_log" >/dev/null 2>&1; then
        probe_ready=1
        break
    fi
    kill -0 "$probe_pid" 2>/dev/null || break
    ready_attempt=$((ready_attempt + 1))
    sleep 0.1
done

if [ "$probe_ready" -ne 1 ]; then
    kill "$watched_pid" 2>/dev/null || :
    wait "$probe_pid" 2>/dev/null || :
    wait "$watched_pid" 2>/dev/null || :
    printf 'refused: the graphics-latency probe never reported probe_start\n' >&2
    exit 1
fi

# Durable identity of the process the verdict is about.
{
    printf 'probe_pid=%s\n' "$probe_pid"
    printf 'probe_sha256=%s\n' "$(sha256sum "$probe" | awk '{ print $1 }')"
    printf 'probe_exe=%s\n' "$(readlink "/proc/$probe_pid/exe" 2>/dev/null || printf 'unreadable')"
    printf 'probe_cmdline=%s\n' "$(tr '\0' ' ' < "/proc/$probe_pid/cmdline" 2>/dev/null || printf 'unreadable')"
    printf 'probe_start_time=%s\n' "$(awk '{ print $22 }' "/proc/$probe_pid/stat" 2>/dev/null || printf 'unreadable')"
    printf 'probe_cgroup=%s\n' "$(head -1 "/proc/$probe_pid/cgroup" 2>/dev/null || printf 'unreadable')"
    printf 'watched_pid=%s\n' "$watched_pid"
    printf 'driver_version=%s\n' "$(nvidia-smi --query-gpu=driver_version --format=csv,noheader)"
} > "$output_directory/probe-identity.txt"
sed "s#$HOME#\$HOME#g" "$output_directory/probe-identity.txt" > "$output_directory/probe-identity.tmp"
mv "$output_directory/probe-identity.tmp" "$output_directory/probe-identity.txt"
cat "$output_directory/probe-identity.txt"

nvidia-smi pmon -c "$samples" > "$output_directory/during-pmon-series.txt" 2>&1 &
pmon_pid=$!

sample_index=1
while [ "$sample_index" -le "$samples" ]; do
    sample_surfaces "$output_directory/during" "$sample_index"
    sample_index=$((sample_index + 1))
    sleep 1
done
wait "$pmon_pid" 2>/dev/null || :

kill "$watched_pid" 2>/dev/null || :
wait "$watched_pid" 2>/dev/null || :
wait "$probe_pid" 2>/dev/null || :

sample_surfaces "$output_directory/after" 0

# Read each surface across every sample. A pid seen in any sample counts as
# reported by that surface, because the question is presence rather than rate.
compute_hits=$(awk -F, -v want="$probe_pid" \
    '/^# sample / { next } $1 + 0 == want { count++ } END { print count + 0 }' \
    "$output_directory/during-compute-apps.csv")
pmon_hits=$(awk -v want="$probe_pid" \
    '$2 + 0 == want { count++ } END { print count + 0 }' \
    "$output_directory/during-pmon.txt" "$output_directory/during-pmon-series.txt")
pids_type=$(surface_type "$output_directory/during-pids.txt" "$probe_pid")
[ -n "$pids_type" ] || pids_type=absent

case $pids_type in
    'C+G') driver_visibility=compute-and-graphics ;;
    C) driver_visibility=compute ;;
    G) driver_visibility=graphics ;;
    *)
        if [ "$compute_hits" -gt 0 ]; then
            driver_visibility=compute
        elif [ "$pmon_hits" -gt 0 ]; then
            driver_visibility=graphics
        else
            driver_visibility=not-observed
        fi
        ;;
esac

# The three surfaces agree when each one's presence matches the Type field.
surfaces_agree=yes
case $driver_visibility in
    compute | compute-and-graphics)
        [ "$compute_hits" -gt 0 ] || surfaces_agree=no ;;
    graphics)
        [ "$compute_hits" -eq 0 ] || surfaces_agree=no ;;
    not-observed)
        { [ "$compute_hits" -eq 0 ] && [ "$pmon_hits" -eq 0 ]; } || surfaces_agree=no ;;
esac

residue=none
for residue_surface in compute-apps.csv pids.txt pmon.txt; do
    if grep -Eq "(^| )$probe_pid( |,|\$)" "$output_directory/after-$residue_surface"; then
        residue=driver-client
    fi
done
if kill -0 "$probe_pid" 2>/dev/null; then
    residue=process
fi
if kill -0 "$watched_pid" 2>/dev/null; then
    residue=watched-process
fi

submissions=$(grep -c '^sample ' "$probe_log" 2>/dev/null || printf 0)

{
    printf 'field\tvalue\n'
    printf 'driver_visibility\t%s\n' "$driver_visibility"
    printf 'pids_type_field\t%s\n' "$pids_type"
    printf 'compute_app_samples\t%s/%s\n' "$compute_hits" "$samples"
    printf 'pmon_samples\t%s\n' "$pmon_hits"
    printf 'surfaces_agree\t%s\n' "$surfaces_agree"
    printf 'probe_submissions\t%s\n' "$submissions"
    printf 'residue\t%s\n' "$residue"
    printf 'desktop_clients\t%s\n' \
        "$(awk -F, '/^# sample / { next } NF { gsub(/^ /, "", $1); printf "%s%s", sep, $1; sep = "," }' \
            "$output_directory/before-compute-apps.csv")"
} > "$summary"
cat "$summary"

for scrub_file in "$output_directory"/*.csv "$output_directory"/*.txt \
    "$output_directory"/*.tsv "$probe_log"; do
    [ -f "$scrub_file" ] || continue
    sed "s#$HOME#\$HOME#g" "$scrub_file" > "$scrub_file.scrubbed"
    mv "$scrub_file.scrubbed" "$scrub_file"
done

printf 'graphics_probe_classification=complete visibility=%s agree=%s residue=%s\n' \
    "$driver_visibility" "$surfaces_agree" "$residue"

[ "$residue" = none ] || exit 1
[ "$surfaces_agree" = yes ] || exit 1
