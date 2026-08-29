# Qwen Runtime Guard Policy

Long prompt ingestion uses independent resource, queue-service, and kernel-log
monitors so one failed observer cannot silently remove the other stop paths.

`remote/monitor-qwen-runtime.sh` samples every second on CPU 1 at normal CPU
priority and idle I/O priority. It records server RSS and peak RSS, MemAvailable, swap-in
bytes, the highest hwmon temperature, GPU busy percentage, GTT and VRAM usage,
and current GPU memory and core clock states. It sends SIGTERM when:

- server affinity differs from CPU 0;
- server nice differs from 19;
- MemAvailable falls below 4 GiB;
- swap-in exceeds 64 MiB in one one-second sample;
- any readable hwmon temperature reaches 90 C; or
- sampled GPU busy percentage exceeds the selected profile's ceiling; or
- the amdgpu busy, GTT, or VRAM telemetry paths become unreadable.

Every resource-guard termination sends SIGTERM, waits two seconds against the
recorded process start time, and sends SIGKILL if the same server process still
exists. This prevents a Vulkan request from deferring a stop indefinitely and
prevents PID reuse from redirecting the escalation.

`paced-60` retains the fail-closed 75% aggregate ceiling. The serialized and
async LOW profiles permit an observed value through 100% because GPU busy is
not a service-latency measurement. Both profiles require the separate MEDIUM
graphics-family watcher from `vulkan-graphics-service-probe.c`. The watcher
submits every 16 ms, sends SIGTERM when one fence exceeds 20 ms, and causes the
shell monitor to stop the server if the watcher disappears. Source:
`evidence/vulkan-priority-first-policy.md`.

The model server remains on CPU 0 at nice 19. The guards use CPU 1 at normal
CPU priority so the server cannot delay its own responsiveness oracle.

Each launcher and guard applies its scheduling policy directly. Environment
sentinels no longer authorize skipping `renice`, `taskset`, or `ionice`, and
`radv-low-priority-env.sh` removes both legacy sentinel names before starting
the target. The policy test injects both names and requires the model process
to report CPU 0, nice 19, and idle I/O. The guard test injects its former name
and requires the monitor and kernel watcher to report CPU 1 and nice 0.

`remote/watch-qwen-kernel-hazards.sh` uses the host's read-only `/dev/kmsg`
access through one continuous `dmesg --follow-new` reader. It sends SIGTERM
on a ring timeout, GPU reset, VM fault, device loss, OOM, or oom-kill record.
The watcher retains every observed line and the termination reason.

GPU jobs run through a separate tmux server selected with
`tmux -L qwen-runtime`. The original `qwen-admin` tmux server predates the
render/video permission repair and lacks those supplementary groups. A new
session on its default socket would inherit that stale group set. The separate
runtime socket is created from fresh SSH and carries groups `video` and
`render`.

`remote/test-qwen-runtime-guards.sh` proves normal target exit, forced
termination when nice differs from 19, forced termination at 76% under the
paced profile, acceptance of an observed 100% under both LOW profiles,
watchdog-loss termination, and termination from a synthetic amdgpu ring timeout.
All guard scripts pass warning-clean ShellCheck and shell syntax validation.
Production kernel watching remains a benchmark-time gate because it requires
the live server PID.

The first remote sentinel test exposed a fixture defect: a 30-second synthetic
server exited before the watchdog-loss case reached the monitor, so the monitor
correctly returned the missing-server setup status instead of the expected
watchdog termination status. The fixture now uses explicitly terminated
persistent processes for negative cases. The retained failed log records that
falsifier, and the final full gate records the direct scheduling policy, real
Qwen3.5-4B LOW-priority initialization, strict Vulkan placement, patch replay,
and graphics-service controls with status 0.
