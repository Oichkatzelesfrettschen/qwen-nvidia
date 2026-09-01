#!/bin/sh
set -eu

# Prove the two device-ownership authorities decide the seven cases that separate
# a name from a CUDA context. Every case runs against a fake nvidia-smi and a
# fake /proc, so the harness answers on a host with no device and never depends
# on what the workstation happens to be running.

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
authority=$script_directory/gpu-workload-ownership.sh
[ -x "$authority" ] || { printf 'missing: %s\n' "$authority" >&2; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/qwen-gpu-ownership-test.XXXXXX")
trap 'rm -rf "$work"' EXIT

failures=0
report() {
    printf '%s case=%s\n' "$1" "$2"
    [ "$1" = 'accepted' ] || failures=$((failures + 1))
}

# A fake nvidia-smi prints whatever the case wrote into clients.csv, so the
# driver's answer is the single input each case varies.
cat >"$work/nvidia-smi" <<'SMI'
#!/bin/sh
cat "$QWEN_GPU_OWNERSHIP_FIXTURE/clients.csv" 2>/dev/null || :
SMI
chmod +x "$work/nvidia-smi"

# A fake /proc carries exe, stat, and cgroup for each declared pid, which is the
# identity resolution the authority performs before it classifies.
make_proc_entry() {
    entry_root=$1/$2
    mkdir -p "$entry_root"
    # The link target is the declared path itself and is deliberately dangling:
    # readlink reports the string, and a target placed inside this harness's own
    # temporary directory would carry that directory's name into the classified
    # identity and match the project pattern for every case.
    ln -sf "$3" "$entry_root/exe"
    printf '%s (%s) S' "$2" "$4" >"$entry_root/stat"
    i=4
    while [ "$i" -lt 22 ]; do printf ' 0' >>"$entry_root/stat"; i=$((i + 1)); done
    printf ' 998877\n' >>"$entry_root/stat"
    printf '0::/user.slice/fixture.scope\n' >"$entry_root/cgroup"
}

run_case() {
    case_name=$1
    case_root=$work/$case_name
    shift
    QWEN_GPU_OWNERSHIP_FIXTURE=$case_root \
    QWEN_GPU_OWNERSHIP_NVIDIA_SMI=$work/nvidia-smi \
    QWEN_GPU_OWNERSHIP_PROCFS=$case_root/proc \
    QWEN_GPU_OWNERSHIP_SELF_PIDS=${SELF_PIDS:-} \
        "$authority" inspect >"$case_root/stdout" 2>"$case_root/stderr" &&
        printf '0' || printf '%s' "$?"
}

# 1. The compositor alone is the covariate this host always carries.
mkdir -p "$work/compositor/proc"
printf '4101, kwin_wayland, 2510 MiB\n' >"$work/compositor/clients.csv"
make_proc_entry "$work/compositor/proc" 4101 /usr/bin/kwin_wayland kwin_wayland
status=$(SELF_PIDS='' run_case compositor)
if [ "$status" = '0' ] &&
    grep -q 'verdict=record-desktop' "$work/compositor/stdout"; then
    report accepted compositor-only-records
else
    report refused compositor-only-records
fi

# 2. Another project workload holding a context ends the run.
mkdir -p "$work/project/proc"
printf '4101, kwin_wayland, 2510 MiB\n5200, llama-server, 5307 MiB\n' \
    >"$work/project/clients.csv"
make_proc_entry "$work/project/proc" 4101 /usr/bin/kwin_wayland kwin_wayland
make_proc_entry "$work/project/proc" 5200 /opt/qwen/bin/llama-server llama-server
status=$(SELF_PIDS='' run_case project)
if [ "$status" != '0' ] &&
    grep -q 'verdict=refuse-project' "$work/project/stdout"; then
    report accepted foreign-project-workload-refuses
else
    report refused foreign-project-workload-refuses
fi

# 3. An unnamed CUDA compute client refuses and its identity is reported.
mkdir -p "$work/unknown/proc"
printf '7300, some-solver, 900 MiB\n' >"$work/unknown/clients.csv"
make_proc_entry "$work/unknown/proc" 7300 /usr/local/bin/some-solver some-solver
status=$(SELF_PIDS='' run_case unknown)
if [ "$status" != '0' ] &&
    grep -q 'verdict=refuse-unknown' "$work/unknown/stdout" &&
    grep -q 'some-solver' "$work/unknown/stderr"; then
    report accepted unknown-cuda-client-refuses-and-reports
else
    report refused unknown-cuda-client-refuses-and-reports
fi

# 4. The harness's own child is accepted rather than read as interference.
mkdir -p "$work/selfchild/proc"
printf '8100, llama-server, 5307 MiB\n' >"$work/selfchild/clients.csv"
make_proc_entry "$work/selfchild/proc" 8100 /opt/qwen/bin/llama-server llama-server
status=$(SELF_PIDS='8100' run_case selfchild)
if [ "$status" = '0' ] &&
    grep -q 'verdict=accept-self' "$work/selfchild/stdout"; then
    report accepted harness-child-accepted
else
    report refused harness-child-accepted
fi

# 5. A process named llama-server that holds no context is a name alone. The
# driver lists nothing, so the run proceeds while the name is still recorded.
mkdir -p "$work/nameonly/proc"
: >"$work/nameonly/clients.csv"
status=$(SELF_PIDS='' run_case nameonly)
if [ "$status" = '0' ] &&
    grep -q 'cuda_clients=none' "$work/nameonly/stdout" &&
    grep -q 'named_llama_server_pids=' "$work/nameonly/stdout"; then
    report accepted named-process-without-context-records
else
    report refused named-process-without-context-records
fi

# 6. A stale pid the driver still lists resolves to a gone identity and refuses,
# because a client this harness cannot name must not pass silently.
mkdir -p "$work/stale/proc"
printf '99321, gone-process, 100 MiB\n' >"$work/stale/clients.csv"
status=$(SELF_PIDS='' run_case stale)
if [ "$status" != '0' ] &&
    grep -q 'exe=gone' "$work/stale/stdout"; then
    report accepted stale-pid-refuses-with-gone-identity
else
    report refused stale-pid-refuses-with-gone-identity
fi

# 7. The exclusive lock is what serializes two probes, and it answers 75 rather
# than the classification's own refusal status.
lock_path=$work/campaign.lock
flock --close "$lock_path" sleep 30 &
holder=$!
attempts=0
while [ "$attempts" -lt 50 ]; do
    if ! flock -n -x "$lock_path" true 2>/dev/null; then break; fi
    attempts=$((attempts + 1))
    sleep 0.1
done
set +e
QWEN_GPU_OWNERSHIP_NVIDIA_SMI=$work/nvidia-smi \
QWEN_GPU_OWNERSHIP_FIXTURE=$work/compositor \
    "$authority" acquire "$lock_path" >"$work/lock-stdout" 2>"$work/lock-stderr"
lock_status=$?
set -e
kill "$holder" 2>/dev/null || :
wait "$holder" 2>/dev/null || :
if [ "$lock_status" -eq 75 ] &&
    grep -q 'another qwen CUDA campaign owns GPU 0' "$work/lock-stderr"; then
    report accepted held-lock-refuses-with-75
else
    report refused held-lock-refuses-with-75
fi

# The lock releases with its holder, so a second attempt succeeds.
if QWEN_GPU_OWNERSHIP_NVIDIA_SMI=$work/nvidia-smi \
    QWEN_GPU_OWNERSHIP_FIXTURE=$work/compositor \
    QWEN_GPU_OWNERSHIP_PROCFS=$work/compositor/proc \
    "$authority" acquire "$lock_path" >/dev/null 2>&1; then
    report accepted released-lock-admits-the-next-campaign
else
    report refused released-lock-admits-the-next-campaign
fi

[ "$failures" -eq 0 ] || exit 1
printf 'gpu_workload_ownership=accepted cases=8 lock=flock-exclusive clients=driver-resolved\n'
