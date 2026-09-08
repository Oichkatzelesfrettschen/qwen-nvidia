#!/usr/bin/env python3
# gpu-ownership: delegates the recorded telemetry launch to telemetry-owner-launch.py.
"""Capture and restore one telemetry service without reconstructing shell text."""

import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import time
import urllib.request


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def process_stat_identity(pid, proc_root):
    stat = (pathlib.Path(proc_root) / str(pid) / "stat").read_text(encoding="utf-8")
    close = stat.rfind(")")
    if close < 0:
        raise ValueError("process stat has no closing command delimiter")
    stat_fields = stat[close + 2:].split()
    return int(stat_fields[1]), stat_fields[19]


def process_record(pid, proc_root):
    root = pathlib.Path(proc_root) / str(pid)
    executable = os.readlink(root / "exe")
    argv = (root / "cmdline").read_bytes().split(b"\0")
    if argv and not argv[-1]:
        argv.pop()
    status = (root / "status").read_text(encoding="utf-8")
    affinity = next(line.split(":", 1)[1].strip() for line in status.splitlines()
                    if line.startswith("Cpus_allowed_list:"))
    stat = (root / "stat").read_text(encoding="utf-8")
    close = stat.rfind(")")
    if close < 0:
        raise ValueError("process stat has no closing command delimiter")
    stat_fields = stat[close + 2:].split()
    return {
        "pid": pid,
        "parent_pid": int(stat_fields[1]),
        "start_ticks": stat_fields[19],
        "executable": executable,
        "executable_sha256": sha256(executable),
        "cwd": os.readlink(root / "cwd"),
        "argv": [item.decode("utf-8", "surrogateescape") for item in argv],
        "cpu_affinity": sorted(os.sched_getaffinity(pid)),
        "cpu_affinity_list": affinity,
        "nice": os.getpriority(os.PRIO_PROCESS, pid),
    }


def read_environment(pid, names, proc_root):
    entries = (pathlib.Path(proc_root) / str(pid) / "environ").read_bytes().split(b"\0")
    values = {}
    for entry in entries:
        if b"=" in entry:
            name, value = entry.split(b"=", 1)
            values[name.decode()] = value.decode("utf-8", "surrogateescape")
    return {name: values.get(name) for name in names}


def mapped_libraries(pid, proc_root):
    paths = set()
    for line in (pathlib.Path(proc_root) / str(pid) / "maps").read_text().splitlines():
        fields = line.split(None, 5)
        if len(fields) == 6 and fields[5].startswith("/") and ".so" in fields[5]:
            paths.add(fields[5])
    return [{"path": path, "sha256": sha256(path)} for path in sorted(paths)]


def listener_owned(pid, listener, proc_root):
    host, port_text = listener.rsplit(":", 1)
    port = int(port_text)
    expected_ipv4 = "".join(f"{byte:02X}" for byte in reversed(
        bytes(int(part) for part in host.split(".")))) if "." in host else None
    listening_inodes = set()
    for table_name in ("tcp", "tcp6"):
        table = pathlib.Path(proc_root) / "net" / table_name
        for line in table.read_text(encoding="ascii").splitlines()[1:]:
            fields = line.split()
            if len(fields) >= 10 and fields[3] == "0A":
                local_port = int(fields[1].rsplit(":", 1)[1], 16)
                local_address = fields[1].split(":", 1)[0]
                address_matches = expected_ipv4 is None or local_address == expected_ipv4
                if local_port == port and address_matches:
                    listening_inodes.add(fields[9])
    descriptor_root = pathlib.Path(proc_root) / str(pid) / "fd"
    for descriptor in descriptor_root.iterdir():
        try:
            target = os.readlink(descriptor)
        except OSError:
            continue
        if target.startswith("socket:[") and target[8:-1] in listening_inodes:
            return True
    return False


def atomic_private_json(destination, payload):
    destination = pathlib.Path(destination)
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(destination.parent, 0o700)
    temporary = destination.with_name(destination.name + ".new")
    temporary.unlink(missing_ok=True)
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(temporary, destination)
    os.chmod(destination, 0o600)


def capture_ancestry_identities(record, owner, proc_root):
    record_identity = record["parent_pid"], record["start_ticks"]
    owner_identity = owner["parent_pid"], owner["start_ticks"]
    if record["pid"] == owner["pid"] and record_identity != owner_identity:
        raise RuntimeError("telemetry owner identity changed during capture")
    capture_identities = {record["pid"]: record_identity, owner["pid"]: owner_identity}
    ancestor = record["parent_pid"]
    while ancestor > 1 and ancestor != owner["pid"]:
        ancestor_identity = process_stat_identity(ancestor, proc_root)
        recorded_identity = capture_identities.get(ancestor)
        if recorded_identity is not None and recorded_identity != ancestor_identity:
            raise RuntimeError(f"process identity changed during ancestry scan for pid {ancestor}")
        capture_identities[ancestor] = ancestor_identity
        ancestor = ancestor_identity[0]
    if ancestor != owner["pid"] and record["pid"] != owner["pid"]:
        raise SystemExit("recorded owner is outside the telemetry process ancestry")
    return capture_identities


def capture(arguments):
    record = process_record(arguments.pid, arguments.proc_root)
    owner = process_record(arguments.owner_pid, arguments.proc_root)
    capture_identities = capture_ancestry_identities(record, owner, arguments.proc_root)
    owner_holder_pid = lineage_holds_file(
        arguments.pid, arguments.owner_pid, arguments.owner_lock,
        arguments.proc_root, capture_identities)
    if not listener_owned(arguments.pid, arguments.listener, arguments.proc_root):
        raise SystemExit("captured process does not own the declared listener")
    for name in arguments.environment:
        if any(fragment in name.upper() for fragment in
               ("TOKEN", "SECRET", "PASSWORD", "CREDENTIAL", "API_KEY", "PRIVATE_KEY")):
            raise SystemExit(f"credential-like environment name is refused: {name}")
    if arguments.owner_kind == "tmux" and not arguments.owner_id:
        raise SystemExit("tmux capture requires --owner-id with the session name")
    record.update({
        "schema": 1,
        "owner": {"kind": arguments.owner_kind, "id": arguments.owner_id,
                  "socket": arguments.owner_socket,
                  "lock_holder_pid": owner_holder_pid,
                  "lock_state_at_capture": ("held-by-owner-ancestry"
                                            if owner_holder_pid else "unheld-by-owner-ancestry"),
                  "observed_process": {key: owner[key] for key in
                                       ("pid", "start_ticks", "executable",
                                        "executable_sha256", "parent_pid")}},
        "environment": read_environment(arguments.pid, arguments.environment, arguments.proc_root),
        "environment_scope": "explicit allowlist",
        "configuration_references": [
            {"path": path, "sha256": sha256(path)} for path in arguments.config_reference
        ],
        "model": {"path": arguments.model, "sha256": sha256(arguments.model)},
        "projector": ({"path": arguments.projector, "sha256": sha256(arguments.projector)}
                      if arguments.projector else None),
        "owner_lock": {"path": arguments.owner_lock,
                       "identity": file_identity(arguments.owner_lock)},
        "compute_lease": {"path": arguments.compute_lease,
                          "identity": file_identity(arguments.compute_lease)},
        "latch": {"program": arguments.latch_program,
                  "program_sha256": sha256(arguments.latch_program),
                  "state_directory": arguments.latch_state_directory},
        "ownership_authority": {
            "program": arguments.ownership_program,
            "program_sha256": sha256(arguments.ownership_program),
            "nvidia_smi": arguments.ownership_nvidia_smi,
        },
        "listener": arguments.listener,
        "health_url": arguments.health_url,
        "health_field": arguments.health_field,
        "health_value": arguments.health_value,
        "model_url": arguments.model_url,
        "served_model_id": arguments.served_model_id,
        "loaded_libraries": mapped_libraries(arguments.pid, arguments.proc_root),
        "restore_execution": "not_run",
    })
    health = health_json(arguments.health_url)
    models = health_json(arguments.model_url)
    value = health
    for field in arguments.health_field.split("."):
        value = value[field]
    if str(value) != arguments.health_value:
        raise SystemExit("captured health value disagrees with the declaration")
    if arguments.served_model_id not in [row.get("id") for row in models.get("data", [])]:
        raise SystemExit("captured service does not report the declared model")
    atomic_private_json(arguments.snapshot, record)


def block(record_path, reason, **details):
    payload = {"restoration": "blocked", "reason": reason}
    payload.update(details)
    atomic_private_json(record_path, payload)
    print(f"restoration=blocked reason={reason}", file=sys.stderr)
    return 4


def health_json(url):
    with urllib.request.urlopen(url, timeout=1) as response:
        return json.load(response)


def file_identity(path):
    status = os.stat(path, follow_symlinks=True)
    return f"{status.st_dev}:{status.st_ino}"


def lineage_holds_file(pid, owner_pid, path, proc_root, expected_identities):
    expected = file_identity(path)
    observed_pid = pid
    while observed_pid > 1:
        identity_before = process_stat_identity(observed_pid, proc_root)
        expected_identity = expected_identities.get(observed_pid)
        if expected_identity is not None and identity_before != expected_identity:
            raise RuntimeError(f"process identity changed before lock scan for pid {observed_pid}")
        descriptors = pathlib.Path(proc_root) / str(observed_pid) / "fd"
        descriptor_observation_error = None
        holder_observed = False
        for descriptor in descriptors.iterdir():
            try:
                status = os.stat(descriptor, follow_symlinks=True)
            except OSError as error:
                descriptor_observation_error = error
                continue
            if f"{status.st_dev}:{status.st_ino}" == expected:
                holder_observed = True
                break
        identity_after = process_stat_identity(observed_pid, proc_root)
        if identity_after != identity_before:
            raise RuntimeError(f"process identity changed during lock scan for pid {observed_pid}")
        if holder_observed:
            return observed_pid
        if descriptor_observation_error is not None:
            raise descriptor_observation_error
        if observed_pid == owner_pid:
            return None
        observed_pid = identity_after[0]
    raise ValueError("declared owner was not reached during lock-holder traversal")


def restore(arguments):
    try:
        snapshot = json.loads(pathlib.Path(arguments.snapshot).read_text(encoding="utf-8"))
        campaign = json.loads(pathlib.Path(arguments.campaign_record).read_text(encoding="utf-8"))
    except (OSError, ValueError, json.JSONDecodeError) as error:
        return block(arguments.record, f"required_record_unreadable_{type(error).__name__}")
    if campaign.get("state") != "reaped":
        return block(arguments.record, "campaign_cleanup_unproven")
    expected_binding = (arguments.campaign_nonce, arguments.campaign_revision,
                        arguments.campaign_script_sha256)
    observed_binding = (campaign.get("run_nonce"), campaign.get("revision"),
                        campaign.get("campaign_script_sha256"))
    if observed_binding != expected_binding:
        return block(arguments.record, "campaign_cleanup_binding_mismatch")
    for process in campaign.get("processes", []):
        try:
            observed = process_record(int(process["pid"]), arguments.proc_root)
        except (FileNotFoundError, ProcessLookupError):
            continue
        if observed["start_ticks"] == str(process["start_ticks"]):
            return block(arguments.record, f"campaign_residue_pid_{process['pid']}")
    try:
        if file_identity(arguments.compute_lease) != snapshot["compute_lease"]["identity"]:
            return block(arguments.record, "compute_lease_identity_mismatch")
        if file_identity(arguments.owner_lock) != snapshot["owner_lock"]["identity"]:
            return block(arguments.record, "campaign_owner_identity_mismatch")
    except OSError as error:
        return block(arguments.record, f"lock_identity_unreadable_{type(error).__name__}")
    if sha256(snapshot["latch"]["program"]) != snapshot["latch"]["program_sha256"]:
        return block(arguments.record, "gpu_state_latch_program_mismatch")
    latch_environment = {"PATH": "/usr/bin:/bin", "QWEN_WEBUI_STATE_DIRECTORY":
                         snapshot["latch"]["state_directory"]}
    latch = subprocess.run([snapshot["latch"]["program"], "require-clear"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           text=True, check=False, env=latch_environment)
    if latch.returncode:
        return block(arguments.record, f"gpu_state_latch_refused_{latch.returncode}")
    executable = snapshot["executable"]
    if sha256(executable) != snapshot["executable_sha256"]:
        return block(arguments.record, "recorded_executable_digest_mismatch")
    for reference in snapshot["configuration_references"]:
        if not os.path.isfile(reference["path"]) or sha256(reference["path"]) != reference["sha256"]:
            return block(arguments.record, "configuration_reference_digest_mismatch")
    for subject in (snapshot["model"], snapshot.get("projector")):
        if subject and (not os.path.isfile(subject["path"]) or
                        sha256(subject["path"]) != subject["sha256"]):
            return block(arguments.record, "model_or_projector_digest_mismatch")
    for library in snapshot["loaded_libraries"]:
        if (not os.path.isfile(library["path"]) or
                sha256(library["path"]) != library["sha256"]):
            return block(arguments.record, "loaded_library_preflight_mismatch")
    if pathlib.Path(arguments.restored_pid_file).exists():
        return block(arguments.record, "restored_pid_receipt_preexists")
    blocked_receipt = pathlib.Path(arguments.restored_pid_file + ".blocked")
    if blocked_receipt.exists():
        return block(arguments.record, "restored_block_receipt_preexists")
    adapter = str(pathlib.Path(__file__).with_name("telemetry-owner-launch.py"))
    if snapshot["owner"]["kind"] == "tmux":
        command = [arguments.tmux, "-S", snapshot["owner"]["socket"],
                   "new-window", "-d", "-t", snapshot["owner"]["id"], "-n",
                   "telemetry-restored", sys.executable, adapter,
                   arguments.snapshot, arguments.restored_pid_file]
    elif snapshot["owner"]["kind"] == "fixture-direct":
        command = [sys.executable, adapter, arguments.snapshot, arguments.restored_pid_file]
    else:
        return block(arguments.record, "unsupported_owner_kind")
    try:
        owner = subprocess.Popen(command, cwd=snapshot["cwd"], env={}, close_fds=True,
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL)
    except OSError as error:
        return block(arguments.record, f"owner_launch_failed_{type(error).__name__}")
    deadline = time.monotonic() + arguments.timeout
    restored_pid = None
    while time.monotonic() < deadline:
        if blocked_receipt.exists():
            return block(arguments.record, blocked_receipt.read_text().strip())
        if (owner.poll() is not None and owner.returncode != 0 and
                not pathlib.Path(arguments.restored_pid_file).exists()):
            return block(arguments.record, f"owner_exited_{owner.returncode}")
        try:
            candidate_pid = int(pathlib.Path(arguments.restored_pid_file).read_text().strip())
            if pathlib.Path(arguments.proc_root, str(candidate_pid)).exists():
                candidate = process_record(candidate_pid, arguments.proc_root)
                if (candidate["executable"] == snapshot["executable"] and
                        candidate["argv"] == snapshot["argv"]):
                    restored_pid = candidate_pid
                    break
        except (FileNotFoundError, ValueError):
            pass
        time.sleep(0.02)
    else:
        receipt = pathlib.Path(arguments.restored_pid_file)
        receipt_pid = receipt.read_text().strip() if receipt.exists() else "absent"
        return block(arguments.record, "restored_process_absent", receipt_pid=receipt_pid)
    restored = process_record(restored_pid, arguments.proc_root)
    arguments.restored_identity = {
        "restored_pid": restored_pid,
        "restored_start_ticks": restored["start_ticks"],
        "restored_executable_sha256": restored["executable_sha256"],
        "restored_service_disposition": "retained_pending_identity_bound_teardown",
        "launch_owner": {"kind": snapshot["owner"]["kind"],
                         "socket": snapshot["owner"].get("socket"),
                         "session": snapshot["owner"].get("id"),
                         "window": "telemetry-restored"},
    }

    def restored_block(reason, **details):
        details.update(arguments.restored_identity)
        return block(arguments.record, reason, **details)

    expected = {key: snapshot[key] for key in
                ("executable", "executable_sha256", "cwd", "argv",
                 "cpu_affinity", "cpu_affinity_list", "nice")}
    observed = {key: restored[key] for key in expected}
    if observed != expected:
        return restored_block( "restored_runtime_identity_mismatch")
    restored_environment = read_environment(restored_pid, snapshot["environment"],
                                            arguments.proc_root)
    if restored_environment != snapshot["environment"]:
        return restored_block( "restored_environment_mismatch")
    if (restored_pid == snapshot["pid"] and
            restored["start_ticks"] == snapshot["start_ticks"]):
        return restored_block( "restored_process_identity_not_new")
    health = models = None
    last_health_error = None
    while time.monotonic() < deadline:
        try:
            health = health_json(snapshot["health_url"])
            models = health_json(snapshot["model_url"])
            break
        except Exception as error:
            last_health_error = error
            time.sleep(0.02)
    if health is None or models is None:
        return restored_block(
                     f"health_request_failed_{type(last_health_error).__name__}")
    value = health
    for field in snapshot["health_field"].split("."):
        value = value[field]
    if str(value) != snapshot["health_value"]:
        return restored_block( "health_identity_mismatch")
    served_ids = [row.get("id") for row in models.get("data", [])]
    if snapshot["served_model_id"] not in served_ids:
        return restored_block( "served_model_identity_mismatch")
    if not listener_owned(restored_pid, snapshot["listener"], arguments.proc_root):
        return restored_block( "listener_process_attribution_mismatch")
    if snapshot["owner"]["kind"] == "tmux":
        pane = subprocess.run(
            [arguments.tmux, "-S", snapshot["owner"]["socket"], "display-message",
             "-p", "-t", f'{snapshot["owner"]["id"]}:telemetry-restored',
             "#{pane_pid}"], text=True, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, check=False)
        if pane.returncode or pane.stdout.strip() != str(restored_pid):
            return restored_block( "tmux_owner_attribution_mismatch")
    if mapped_libraries(restored_pid, arguments.proc_root) != snapshot["loaded_libraries"]:
        return restored_block( "loaded_library_identity_mismatch")
    atomic_private_json(arguments.record, {
        "restoration": "accepted", "owner_pid": owner.pid,
        "restored_pid": restored_pid, "restored_start_ticks": restored["start_ticks"],
        "runtime_identity": "matched", "configuration": "matched",
        "health": "matched", "served_model": "matched",
    })
    print(f"restoration=accepted restored_pid={restored_pid}")
    return 0


def parser():
    top = argparse.ArgumentParser()
    subparsers = top.add_subparsers(dest="action", required=True)
    blocked_parser = subparsers.add_parser("blocked")
    blocked_parser.add_argument("--record", required=True)
    blocked_parser.add_argument("--reason", required=True)
    capture_parser = subparsers.add_parser("capture")
    capture_parser.add_argument("--pid", type=int, required=True)
    capture_parser.add_argument("--snapshot", required=True)
    capture_parser.add_argument("--proc-root", default="/proc")
    capture_parser.add_argument("--owner-kind", required=True)
    capture_parser.add_argument("--owner-id", default="")
    capture_parser.add_argument("--owner-socket", default="")
    capture_parser.add_argument("--owner-pid", type=int, required=True)
    capture_parser.add_argument("--owner-lock", required=True)
    capture_parser.add_argument("--compute-lease", required=True)
    capture_parser.add_argument(
        "--latch-program",
        default=str(pathlib.Path(__file__).with_name("gpu-state-latch.sh")),
    )
    capture_parser.add_argument("--latch-state-directory", required=True)
    capture_parser.add_argument(
        "--ownership-program",
        default=str(pathlib.Path(__file__).with_name("gpu-workload-ownership.sh")),
    )
    capture_parser.add_argument("--ownership-nvidia-smi", default="nvidia-smi")
    capture_parser.add_argument("--environment", action="append", default=[])
    capture_parser.add_argument("--config-reference", action="append", default=[])
    capture_parser.add_argument("--model", required=True)
    capture_parser.add_argument("--projector")
    capture_parser.add_argument("--listener", required=True)
    capture_parser.add_argument("--health-url", required=True)
    capture_parser.add_argument("--health-field", default="status")
    capture_parser.add_argument("--health-value", default="ok")
    capture_parser.add_argument("--model-url", required=True)
    capture_parser.add_argument("--served-model-id", required=True)
    restore_parser = subparsers.add_parser("restore")
    restore_parser.add_argument("--snapshot", required=True)
    restore_parser.add_argument("--record", required=True)
    restore_parser.add_argument("--proc-root", default="/proc")
    restore_parser.add_argument("--campaign-record", required=True)
    restore_parser.add_argument("--campaign-nonce", required=True)
    restore_parser.add_argument("--campaign-revision", required=True)
    restore_parser.add_argument("--campaign-script-sha256", required=True)
    restore_parser.add_argument("--compute-lease", required=True)
    restore_parser.add_argument("--owner-lock", required=True)
    restore_parser.add_argument("--restored-pid-file", required=True)
    restore_parser.add_argument("--timeout", type=float, default=10)
    restore_parser.add_argument("--tmux", default="tmux")
    return top


def main():
    arguments = parser().parse_args()
    if arguments.action == "capture":
        return capture(arguments)
    if arguments.action == "blocked":
        return block(arguments.record, arguments.reason)
    try:
        return restore(arguments)
    except (OSError, ValueError, KeyError, TypeError, IndexError) as error:
        return block(arguments.record, f"restore_validation_failed_{type(error).__name__}",
                     **getattr(arguments, "restored_identity", {}))


if __name__ == "__main__":
    sys.exit(main())
