#!/usr/bin/env python3
"""Apply recorded scheduling and exec one telemetry argv without shell parsing."""

import json
import fcntl
import os
import pathlib
import subprocess
import sys


if len(sys.argv) != 3:
    raise SystemExit("usage: telemetry-owner-launch.py SNAPSHOT PID_FILE")
pid_file = pathlib.Path(sys.argv[2])
blocked_file = pid_file.with_name(pid_file.name + ".blocked")


def refuse(reason):
    temporary = blocked_file.with_name(blocked_file.name + ".new")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w", encoding="ascii") as handle:
        handle.write(reason + "\n")
    os.replace(temporary, blocked_file)
    raise SystemExit(75)


launch_stage = "snapshot"
try:
    snapshot = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
    launch_stage = "lock_configuration"
    owner_path = snapshot["owner_lock"]["path"]
    lease_path = snapshot["compute_lease"]["path"]
    try:
        owner_fd = os.open(owner_path, os.O_RDWR | os.O_NOFOLLOW)
        if f"{os.fstat(owner_fd).st_dev}:{os.fstat(owner_fd).st_ino}" != snapshot["owner_lock"]["identity"]:
            refuse("campaign_owner_identity_mismatch")
        try:
            fcntl.flock(owner_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            refuse("campaign_owner_held")
        lease_fd = os.open(lease_path, os.O_RDWR | os.O_NOFOLLOW)
        if f"{os.fstat(lease_fd).st_dev}:{os.fstat(lease_fd).st_ino}" != snapshot["compute_lease"]["identity"]:
            refuse("compute_lease_identity_mismatch")
        try:
            fcntl.flock(lease_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            refuse("compute_lease_held")
        fcntl.flock(lease_fd, fcntl.LOCK_UN)
        os.close(lease_fd)
    except OSError as error:
        refuse(f"lock_acquire_failed_{type(error).__name__}")
    if owner_fd != 9:
        os.dup2(owner_fd, 9, inheritable=True)
        os.close(owner_fd)
    else:
        os.set_inheritable(9, True)
    launch_stage = "ownership_authority"
    authority = snapshot["ownership_authority"]
    if __import__("hashlib").sha256(pathlib.Path(authority["program"]).read_bytes()).hexdigest() != authority["program_sha256"]:
        refuse("gpu_ownership_authority_program_mismatch")
    authority_environment = {
        "PATH": "/usr/bin:/bin",
        "QWEN_GPU_OWNERSHIP_FD": "9",
        "QWEN_GPU_OWNERSHIP_LOCK": owner_path,
        "QWEN_GPU_COMPUTE_LEASE": lease_path,
        "QWEN_GPU_OWNERSHIP_NVIDIA_SMI": authority["nvidia_smi"],
    }
    authority_result = subprocess.run(
        ["/bin/sh", "-c", '. "$1"; gpu_ownership_require "$2"', "sh",
         authority["program"], owner_path], stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL, env=authority_environment, pass_fds=(9,), check=False)
    if authority_result.returncode:
        refuse(f"gpu_ownership_authority_refused_{authority_result.returncode}")
    launch_stage = "latch"
    latch = snapshot["latch"]
    if __import__("hashlib").sha256(pathlib.Path(latch["program"]).read_bytes()).hexdigest() != latch["program_sha256"]:
        refuse("gpu_state_latch_program_mismatch")
    latch_result = subprocess.run(
        [latch["program"], "require-clear"], stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL, check=False,
        env={"PATH": "/usr/bin:/bin", "QWEN_WEBUI_STATE_DIRECTORY": latch["state_directory"]})
    if latch_result.returncode:
        refuse(f"gpu_state_latch_refused_{latch_result.returncode}")
    launch_stage = "scheduling_affinity"
    os.sched_setaffinity(0, set(snapshot["cpu_affinity"]))
    launch_stage = "scheduling_priority"
    os.setpriority(os.PRIO_PROCESS, 0, snapshot["nice"])
    launch_stage = "pid_receipt"
    temporary = pid_file.with_name(pid_file.name + ".new")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="ascii") as handle:
        handle.write(f"{os.getpid()}\n")
    os.replace(temporary, pid_file)
    launch_stage = "working_directory"
    os.chdir(snapshot["cwd"])
    environment = {name: value for name, value in snapshot["environment"].items()
                   if value is not None}
    environment["QWEN_GPU_OWNERSHIP_FD"] = "9"
    launch_stage = "exec"
    os.execve(snapshot["executable"], snapshot["argv"], environment)
except (OSError, ValueError, KeyError, TypeError) as error:
    refuse(f"{launch_stage}_failed_{type(error).__name__}")
