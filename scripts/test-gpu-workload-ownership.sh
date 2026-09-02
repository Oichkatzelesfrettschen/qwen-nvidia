#!/bin/sh
set -eu

# Prove the three device-ownership authorities decide the cases that separate a
# name from a CUDA context, a held lock from a free one, and an inherited locked
# descriptor from every forgery of one. Every case runs against a fake nvidia-smi and a
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

# 9. An Electron embedder's GPU process records rather than refusing. The
# application name reaches no entry in the desktop pattern; the
# `--type=gpu-process` argv shape every Chromium-derived embedder spawns it
# with is what classifies it, so a desktop application this list has never seen
# is a covariate rather than a refusal.
mkdir -p "$work/embedder/proc"
printf '1942, kwin_wayland, 316 MiB\n8801, /opt/SomeChatApp/SomeChatApp --type=gpu-process --ozone-platform=wayland, 594 MiB\n' \
    >"$work/embedder/clients.csv"
make_proc_entry "$work/embedder/proc" 1942 /usr/bin/kwin_wayland kwin_wayland
make_proc_entry "$work/embedder/proc" 8801 /opt/SomeChatApp/SomeChatApp SomeChatApp
status=$(SELF_PIDS='' run_case embedder)
if [ "$status" = '0' ] &&
    [ "$(grep -c 'verdict=record-desktop' "$work/embedder/stdout")" = '2' ]; then
    report accepted electron-gpu-process-records
else
    report refused electron-gpu-process-records
fi

# The inherited-descriptor capability replaces a boolean marker, so each case
# below runs the authority as its own process with descriptor 9 in one
# controlled state and reads the exit status and the named reason.
require_case() {
    require_case_name=$1
    require_case_root=$work/$require_case_name
    mkdir -p "$require_case_root"
    set +e
    QWEN_GPU_OWNERSHIP_FIXTURE=$work/compositor \
    QWEN_GPU_OWNERSHIP_NVIDIA_SMI=$work/nvidia-smi \
    QWEN_GPU_OWNERSHIP_PROCFS=$work/compositor/proc \
    QWEN_GPU_OWNERSHIP_FD=${REQUIRE_FD:-} \
        "$authority" require "$2" \
        >"$require_case_root/stdout" 2>"$require_case_root/stderr"
    require_case_status=$?
    set -e
}

fd_lock=$work/fd-campaign.lock
: >"$fd_lock"
fd_other=$work/fd-other.file
: >"$fd_other"

# 10. The variable names a descriptor this process never opened, which is the
# bare marker the boolean was.
REQUIRE_FD=9 require_case fd-absent "$fd_lock"
if [ "$require_case_status" -eq 75 ] &&
    grep -q 'descriptor 9 is closed in this process' "$work/fd-absent/stderr"; then
    report accepted inherited-fd-absent-refuses
else
    report refused inherited-fd-absent-refuses
fi

# 11. The descriptor is open and locked, on another file entirely.
(
    exec 9>"$fd_other"
    flock -n 9
    REQUIRE_FD=9 require_case fd-foreign-file "$fd_lock"
    [ "$require_case_status" -eq 75 ] &&
        grep -q 'inode mismatch' "$work/fd-foreign-file/stderr"
) && report accepted inherited-fd-wrong-inode-refuses ||
    report refused inherited-fd-wrong-inode-refuses

# 12. The descriptor was opened and locked, then closed before the nested call.
(
    exec 9>"$fd_lock"
    flock -n 9
    exec 9>&-
    REQUIRE_FD=9 require_case fd-closed "$fd_lock"
    [ "$require_case_status" -eq 75 ] &&
        grep -q 'descriptor 9 is closed in this process' "$work/fd-closed/stderr"
) && report accepted inherited-fd-closed-refuses ||
    report refused inherited-fd-closed-refuses

# 13. The inherited descriptor is open on the lock file and holds it, which is
# the one state a nested stage runs in.
(
    exec 9>"$fd_lock"
    flock -n 9
    REQUIRE_FD=9 require_case fd-inherited "$fd_lock"
    [ "$require_case_status" -eq 0 ] &&
        grep -q 'gpu_ownership_lock=inherited fd=9' "$work/fd-inherited/stdout"
) && report accepted inherited-fd-locked-accepted ||
    report refused inherited-fd-locked-accepted

# 14. A workload child that retains the descriptor retains the lock with it, so
# the claim outlives the campaign that took it. The subshell holding descriptor 9
# exits and the lock still refuses the next campaign, which is the leak `9>&-`
# exists to prevent.
leak_lock=$work/leaked-child.lock
(
    exec 9>"$leak_lock"
    flock -n 9
    sleep 30 &
    printf '%s\n' "$!" >"$work/leak.pid"
)
set +e
QWEN_GPU_OWNERSHIP_NVIDIA_SMI=$work/nvidia-smi \
QWEN_GPU_OWNERSHIP_FIXTURE=$work/compositor \
QWEN_GPU_OWNERSHIP_PROCFS=$work/compositor/proc \
    "$authority" acquire "$leak_lock" >"$work/leak-stdout" 2>"$work/leak-stderr"
leak_status=$?
set -e
kill "$(cat "$work/leak.pid")" 2>/dev/null || :
wait "$(cat "$work/leak.pid")" 2>/dev/null || :
if [ "$leak_status" -eq 75 ] &&
    grep -q 'another qwen CUDA campaign owns GPU 0' "$work/leak-stderr"; then
    report accepted retained-descriptor-child-holds-the-lock
else
    report refused retained-descriptor-child-holds-the-lock
fi

# 15. The same child launched with `9>&-` holds no descriptor, so the lock
# releases with the campaign and the next one is admitted.
closed_lock=$work/closed-child.lock
(
    exec 9>"$closed_lock"
    flock -n 9
    sleep 30 9>&- &
    printf '%s\n' "$!" >"$work/closed.pid"
)
set +e
QWEN_GPU_OWNERSHIP_NVIDIA_SMI=$work/nvidia-smi \
QWEN_GPU_OWNERSHIP_FIXTURE=$work/compositor \
QWEN_GPU_OWNERSHIP_PROCFS=$work/compositor/proc \
    "$authority" acquire "$closed_lock" >"$work/closed-stdout" 2>"$work/closed-stderr"
closed_status=$?
set -e
kill "$(cat "$work/closed.pid")" 2>/dev/null || :
wait "$(cat "$work/closed.pid")" 2>/dev/null || :
if [ "$closed_status" -eq 0 ] &&
    grep -q 'gpu_ownership_lock=held' "$work/closed-stdout"; then
    report accepted closing-child-releases-the-lock
else
    report refused closing-child-releases-the-lock
fi

# 16. The lock order is owner lock outer, Vulkan workload lease inner. A
# process already holding a descriptor on the lease and then asking for the
# owner lock is the inversion, and the acquire path refuses it by name.
order_lock=$work/order-campaign.lock
order_lease=$work/order-lease.lock
: >"$order_lease"
set +e
(
    exec 8>"$order_lease"
    flock -n 8
    QWEN_GPU_OWNERSHIP_NVIDIA_SMI=$work/nvidia-smi \
    QWEN_GPU_OWNERSHIP_FIXTURE=$work/compositor \
    QWEN_GPU_OWNERSHIP_PROCFS=$work/compositor/proc \
    QWEN_GPU_COMPUTE_LEASE=$order_lease \
        "$authority" acquire "$order_lock"
) >"$work/order-stdout" 2>"$work/order-stderr"
order_status=$?
set -e
if [ "$order_status" -eq 75 ] &&
    grep -q 'lock order inversion' "$work/order-stderr"; then
    report accepted lease-held-refuses-the-campaign-lock
else
    report refused lease-held-refuses-the-campaign-lock
fi

# 17. The sanctioned sequence is the reverse one: the owner lock is taken
# first and the lease opened inside it, which is what llama-server and
# image-service.py do. The order check runs on the acquire path alone, so an
# inherited claim beside an open lease descriptor is admitted.
inherit_lock=$work/order-inherit.lock
: >"$inherit_lock"
(
    exec 9>"$inherit_lock"
    flock -n 9
    exec 8>"$order_lease"
    QWEN_GPU_COMPUTE_LEASE=$order_lease \
    REQUIRE_FD=9 require_case order-inherited "$inherit_lock"
    [ "$require_case_status" -eq 0 ] &&
        grep -q 'gpu_ownership_lock=inherited fd=9' "$work/order-inherited/stdout"
) && report accepted campaign-first-then-lease-accepted ||
    report refused campaign-first-then-lease-accepted

# 18. A lease file that was never created is no inversion, because a workstation
# that has never served has nothing to invert against.
absent_lock=$work/order-absent.lock
if QWEN_GPU_OWNERSHIP_NVIDIA_SMI=$work/nvidia-smi \
    QWEN_GPU_OWNERSHIP_FIXTURE=$work/compositor \
    QWEN_GPU_OWNERSHIP_PROCFS=$work/compositor/proc \
    QWEN_GPU_COMPUTE_LEASE=$work/never-created.lock \
    "$authority" acquire "$absent_lock" >/dev/null 2>&1; then
    report accepted absent-lease-file-is-no-inversion
else
    report refused absent-lease-file-is-no-inversion
fi

# 19. The serving session launches every child with `9>&-`, including the broker
# and the telemetry sampler that open no CUDA context. An inherited descriptor
# keeps the owner claim alive after the session exits, so a child that outlives
# teardown would lock out the next session and every campaign against a device
# nothing is using. Case 14 proves the mechanism; this reads the session's own
# launch sites, since a single missed `9>&-` is silent until the next run.
session_source=$script_directory/qwen-webui-session.sh
# grep -n prefixes a line number, so the comment filter matches after it.
unclosed=$(grep -n '&$' "$session_source" |
    grep -v '9>&-' | grep -v '&&$' | grep -v '^[0-9]*: *#' || :)
if [ -z "$unclosed" ]; then
    report accepted session-children-close-the-owner-descriptor
else
    printf 'session child launched without 9>&-:\n%s\n' "$unclosed" >&2
    report refused session-children-close-the-owner-descriptor
fi

# 20. The serving chain below the session opens no second claim. The session is
# the owner and llama-server holds a closed descriptor, so a capacity server that
# took the lock itself would refuse the session that started it.
for chain_link in run-qwen-capacity-server.sh qwen-capacity-policy.sh \
    cuda-runtime-env.sh vulkan-runtime-env.sh qwen-router-exec-guard.sh; do
    if grep -q 'gpu_ownership_acquire\|gpu_ownership_require' \
        "$script_directory/$chain_link"; then
        printf '%s opens a second owner claim under the session\n' \
            "$chain_link" >&2
        report refused serving-chain-opens-no-second-claim
        chain_faulted=1
        break
    fi
done
[ "${chain_faulted:-0}" = 1 ] ||
    report accepted serving-chain-opens-no-second-claim

# 21. scripts/gpu-workloads.tsv is the coverage authority and the gate enumerates
# it. Every listed entry point exists, every top-level owner takes the authority,
# every nested capability verifies an inherited descriptor rather than opening a
# second claim, a workload child closes the descriptor, an active-compute row
# names the lease, and a delegating row states the lane holding the claim in its
# place.
ledger=$script_directory/gpu-workloads.tsv
[ -r "$ledger" ] || { printf 'missing ledger: %s\n' "$ledger" >&2; exit 1; }
ledger_faults=$work/ledger-faults
: >"$ledger_faults"
ledger_rows=0
# backend and overlap are read to consume their columns; the ledger's own
# column count is what this loop asserts, so every field is named.
# shellcheck disable=SC2034
while IFS="$(printf '\t')" read -r entrypoint role backend top_level nested \
    lease overlap closes_fd policy; do
    case $entrypoint in '' | '#'* | entrypoint) continue ;; esac
    ledger_rows=$((ledger_rows + 1))
    entry_path=$script_directory/$entrypoint
    if [ ! -r "$entry_path" ]; then
        printf '%s absent\n' "$entrypoint" >>"$ledger_faults"
        continue
    fi
    case $role in
        serving-session | measurement-campaign | nested-orchestrator | \
        active-workload | authorized-monitor | non-gpu-helper) ;;
        *) printf '%s unknown role %s\n' "$entrypoint" "$role" >>"$ledger_faults" ;;
    esac
    case $policy in
        acquires | inherits | delegates | monitored | none) ;;
        *) printf '%s unknown execution_policy %s\n' "$entrypoint" "$policy" \
            >>"$ledger_faults" ;;
    esac
    if [ "$top_level" = yes ] &&
        ! grep -q 'gpu_ownership_require\|gpu_ownership_acquire' "$entry_path"; then
        printf '%s claims top_level_owner and takes no authority\n' \
            "$entrypoint" >>"$ledger_faults"
    fi
    # gpu_ownership_require is the one call that verifies an inherited
    # descriptor, so a row claiming the capability without naming it is a row
    # that would open a second claim under a parent campaign.
    if [ "$nested" = yes ] && [ "$role" != active-workload ] &&
        ! grep -q 'gpu_ownership_require' "$entry_path"; then
        printf '%s claims nested_owner_capability and verifies nothing\n' \
            "$entrypoint" >>"$ledger_faults"
    fi
    if [ "$closes_fd" = yes ] && ! grep -q '9>&-' "$entry_path"; then
        printf '%s claims child_closes_owner_fd and closes nothing\n' \
            "$entrypoint" >>"$ledger_faults"
    fi
    case $lease in
        yes | exports)
            grep -q 'QWEN_GPU_COMPUTE_LEASE' "$entry_path" ||
                printf '%s claims the compute lease and names none\n' \
                    "$entrypoint" >>"$ledger_faults"
            ;;
    esac
    if [ "$policy" = delegates ] &&
        ! grep -q '^# gpu-ownership:' "$entry_path"; then
        printf '%s delegates and names no lane\n' "$entrypoint" >>"$ledger_faults"
    fi
done <"$ledger"
if [ ! -s "$ledger_faults" ] && [ "$ledger_rows" -gt 0 ]; then
    report accepted ledger-rows-hold-their-claims
else
    cat "$ledger_faults" >&2
    report refused ledger-rows-hold-their-claims
fi

# 22. An entry point that names a CUDA-opening command and appears in no ledger
# row is an undocumented GPU entry point, which is the drift the ledger replaces
# a regular expression to catch. Fixture harnesses are outside the set by
# construction: a `test-` script runs against fakes and opens no context.
device_commands='llama-server|llama-bench|llama-cli|llama-mtmd-cli|llama-quantize|nsys|ncu|vulkan-graphics-service-probe'
undocumented=''
for candidate in "$script_directory"/*.sh "$script_directory"/*.py \
    "$script_directory"/*.c; do
    [ -r "$candidate" ] || continue
    candidate_name=${candidate##*/}
    case $candidate_name in test-*) continue ;; esac
    grep -Eq "$device_commands" "$candidate" || continue
    if awk -F'\t' -v want="$candidate_name" \
        '$1 == want { found = 1 } END { exit found ? 0 : 1 }' "$ledger"; then
        continue
    fi
    undocumented="$undocumented $candidate_name"
done
if [ -z "$undocumented" ]; then
    report accepted every-device-entrypoint-is-declared
else
    printf 'undocumented device entry points:%s\n' "$undocumented" >&2
    report refused every-device-entrypoint-is-declared
fi

# 23. Two lease names resolving to two files is the split the rename exists to
# prevent, so gpu_ownership_lease_path refuses it rather than serializing on one.
split_a=$work/lease-split-a
split_b=$work/lease-split-b
: >"$split_a"
: >"$split_b"
set +e
(
    # shellcheck source=scripts/gpu-workload-ownership.sh
    . "$authority"
    QWEN_GPU_COMPUTE_LEASE=$split_a QWEN_VULKAN_WORKLOAD_LOCK=$split_b \
        gpu_ownership_lease_path
) >/dev/null 2>"$work/lease-split.stderr"
split_status=$?
set -e
if [ "$split_status" -ne 0 ] &&
    grep -q 'name two files' "$work/lease-split.stderr"; then
    report accepted two-lease-paths-refuse
else
    report refused two-lease-paths-refuse
fi

# 24. One file under both names is the transition configuration and resolves.
if (
    # shellcheck source=scripts/gpu-workload-ownership.sh
    . "$authority"
    QWEN_GPU_COMPUTE_LEASE=$split_a QWEN_VULKAN_WORKLOAD_LOCK=$split_a \
        gpu_ownership_lease_path
) >/dev/null 2>&1; then
    report accepted one-file-under-both-lease-names-resolves
else
    report refused one-file-under-both-lease-names-resolves
fi

# 25. The serving session refuses when a campaign owns the device, and it does so
# before it starts the broker or any control service. The paths below are absent:
# reaching them at all would prove the gate ran too late.
session_script=$script_directory/qwen-webui-session.sh
session_lock=$work/session-campaign.lock
flock --close "$session_lock" sleep 30 &
session_holder=$!
attempts=0
while [ "$attempts" -lt 50 ]; do
    if ! flock -n -x "$session_lock" true 2>/dev/null; then break; fi
    attempts=$((attempts + 1))
    sleep 0.1
done
set +e
QWEN_GPU_OWNERSHIP_LOCK=$session_lock \
QWEN_GPU_OWNERSHIP_NVIDIA_SMI=$work/nvidia-smi \
QWEN_GPU_OWNERSHIP_FIXTURE=$work/compositor \
QWEN_GPU_OWNERSHIP_PROCFS=$work/compositor/proc \
QWEN_GPU_COMPUTE_LEASE=$work/never-created.lock \
    "$session_script" "$work/absent-server" "$work/absent-model" \
    "$work/absent-static" 4096 4096 18999 "$work/session-state" default \
    >"$work/session-stdout" 2>"$work/session-stderr"
session_status=$?
set -e
kill "$session_holder" 2>/dev/null || :
wait "$session_holder" 2>/dev/null || :
if [ "$session_status" -eq 75 ] &&
    grep -q 'another qwen CUDA campaign owns GPU 0' "$work/session-stderr"; then
    report accepted serving-session-refuses-a-held-campaign
else
    report refused serving-session-refuses-a-held-campaign
fi

# 26. A campaign refuses when the driver reports the serving session's own
# llama-server, which is the reverse direction of case 25 and the half that was
# missing while the serving chain took no authority.
mkdir -p "$work/serving/proc"
printf '4101, kwin_wayland, 2510 MiB\n5300, llama-server, 5307 MiB\n' \
    >"$work/serving/clients.csv"
make_proc_entry "$work/serving/proc" 4101 /usr/bin/kwin_wayland kwin_wayland
make_proc_entry "$work/serving/proc" 5300 /opt/qwen/bin/llama-server llama-server
status=$(SELF_PIDS='' run_case serving)
if [ "$status" != '0' ] &&
    grep -q 'verdict=refuse-project' "$work/serving/stdout"; then
    report accepted campaign-refuses-a-serving-session
else
    report refused campaign-refuses-a-serving-session
fi

# 27. The kernel releases the lock when its owner dies, with no unlock in the
# owner's own code. An owner killed outright leaves the next campaign admitted.
kernel_lock=$work/kernel-release.lock
(
    exec 9>"$kernel_lock"
    flock -n 9
    sleep 30 9>&- &
    printf '%s\n' "$!" >"$work/kernel-sleep.pid"
    printf '%s\n' "$$" >"$work/kernel-owner.pid"
    sleep 30
) &
kernel_owner=$!
attempts=0
while [ "$attempts" -lt 50 ]; do
    if ! flock -n -x "$kernel_lock" true 2>/dev/null; then break; fi
    attempts=$((attempts + 1))
    sleep 0.1
done
kill -9 "$kernel_owner" 2>/dev/null || :
wait "$kernel_owner" 2>/dev/null || :
attempts=0
kernel_released=0
while [ "$attempts" -lt 50 ]; do
    if flock -n -x "$kernel_lock" true 2>/dev/null; then kernel_released=1; break; fi
    attempts=$((attempts + 1))
    sleep 0.1
done
kill "$(cat "$work/kernel-sleep.pid" 2>/dev/null)" 2>/dev/null || :
if [ "$kernel_released" -eq 1 ]; then
    report accepted kernel-releases-the-lock-on-owner-death
else
    report refused kernel-releases-the-lock-on-owner-death
fi

# 28. An orphan CUDA child that survives its owner's death holds no lock, since
# the owner closed the descriptor on it, and the driver is what still reports it.
# The next campaign therefore refuses on classification rather than on the lock,
# which is the reason both authorities run and neither substitutes for the other.
mkdir -p "$work/orphan/proc"
printf '6200, llama-server, 5307 MiB\n' >"$work/orphan/clients.csv"
make_proc_entry "$work/orphan/proc" 6200 /opt/qwen/bin/llama-server llama-server
orphan_lock=$work/orphan.lock
set +e
QWEN_GPU_OWNERSHIP_NVIDIA_SMI=$work/nvidia-smi \
QWEN_GPU_OWNERSHIP_FIXTURE=$work/orphan \
QWEN_GPU_OWNERSHIP_PROCFS=$work/orphan/proc \
QWEN_GPU_COMPUTE_LEASE=$work/never-created.lock \
    "$authority" acquire "$orphan_lock" \
    >"$work/orphan-stdout" 2>"$work/orphan-stderr"
orphan_status=$?
set -e
if [ "$orphan_status" -ne 0 ] &&
    grep -q 'verdict=refuse-project' "$work/orphan-stdout" &&
    ! grep -q 'another qwen CUDA campaign owns GPU 0' "$work/orphan-stderr"; then
    report accepted orphan-cuda-child-refuses-on-the-driver
else
    report refused orphan-cuda-child-refuses-on-the-driver
fi

[ "$failures" -eq 0 ] || exit 1
printf 'gpu_workload_ownership=accepted cases=28 lock=flock-exclusive-inherited-fd order=owner-lease-job-artifact coverage=gpu-workloads.tsv clients=driver-resolved\n'
