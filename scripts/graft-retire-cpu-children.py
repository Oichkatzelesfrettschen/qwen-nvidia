"""Attribute configured Graft CPU children and retire their bounded build jobs.

The caller retains its full process-tree snapshot for escalation. Only exact
MCP identities and verified, fully retired job trees are returned as identities
whose CPU work cannot supply another server GPU teardown observation.
"""

# gpu-ownership: non-gpu-helper; executes no device binary.

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

import admission_barrier


class Refusal(Exception):
    pass


def process(pid):
    try:
        root = Path(f"/proc/{pid}")
        fields = (root / "stat").read_text().rsplit(")", 1)[1].split()
        return {"pid": pid, "start_ticks": fields[19], "parent": int(fields[1]),
                "state": fields[0], "args": (root / "cmdline").read_bytes().split(b"\0")[:-1]}
    except (OSError, IndexError, ValueError):
        return None


def identity(record):
    return {"pid": record["pid"], "start_ticks": record["start_ticks"]}


def live(record):
    observed = process(record["pid"])
    return observed and identity(observed) == identity(record) and observed["state"] not in {"Z", "X"}


def children(pid):
    result = {}
    for path in Path(f"/proc/{pid}/task").glob("*/children"):
        try:
            identifiers = path.read_text().split()
        except OSError:
            continue
        for identifier in identifiers:
            observed = process(int(identifier))
            if observed:
                result[observed["pid"]] = observed
    return list(result.values())


def tree(record):
    result = [record]
    for child in children(record["pid"]):
        result.extend(tree(child))
    return result


def exact_command(record, command, executable=None):
    try:
        return (record["args"] == [os.fsencode(argument) for argument in command]
                and Path(f"/proc/{record['pid']}/exe").samefile(executable or command[0]))
    except OSError:
        return False


def read_json(path):
    return json.loads(Path(path).read_text())


def process_environment(pid):
    try:
        fields = (Path(f"/proc/{pid}") / "environ").read_bytes().split(b"\0")
    except OSError as error:
        raise Refusal("mcp_environment_unavailable") from error
    return {os.fsdecode(key): os.fsdecode(value)
            for field in fields if b"=" in field
            for key, value in [field.split(b"=", 1)]}


def retained_mcp_command(entry, server_environment):
    command = entry.get("command")
    arguments = entry.get("args", [])
    environment = entry.get("env", {})
    if (not isinstance(command, str) or not command
            or not isinstance(arguments, list) or any(not isinstance(value, str) for value in arguments)
            or not isinstance(environment, dict)
            or any(not isinstance(key, str) or not isinstance(value, str)
                   for key, value in environment.items())):
        raise Refusal("configured_retained_mcp_invalid")
    if Path(command).is_absolute():
        executable = command
    elif "/" not in command:
        executable = shutil.which(command, path=environment.get("PATH", server_environment.get("PATH", "")))
    else:
        raise Refusal("configured_retained_mcp_command_unresolvable")
    if not executable or not Path(executable).is_absolute():
        raise Refusal("configured_retained_mcp_command_unresolvable")
    return [command, *arguments], executable, environment


def require_closed_publication(candidate, entry, config):
    barrier = str(Path(config["model"]["api_key_file"]).parent)
    environment = process_environment(candidate["pid"])
    for name in ("QWEN_GRAFT_SESSION_BARRIER", "QWEN_GPU_ADMISSION_BARRIER"):
        if entry.get("env", {}).get(name) != barrier or environment.get(name) != barrier:
            raise Refusal("mcp_publication_barrier_mismatch")
    barrier_environment = {"QWEN_GPU_ADMISSION_BARRIER": barrier}
    if (os.environ.get("QWEN_DRAIN_MODE") != "orderly"
            or os.environ.get("QWEN_GPU_ADMISSION_BARRIER") != barrier
            or admission_barrier.verify_session_identity(barrier_environment) != "match"
            or admission_barrier.read_state(barrier_environment) != "quiescing"):
        raise Refusal("mcp_publication_not_drained")


def source_descriptors(workflow, request, directory, worker):
    descriptors = read_json(directory / "source-fds.json")
    expected = workflow.source_directory_identities(request)
    if not isinstance(descriptors, dict) or descriptors.keys() != expected.keys():
        raise Refusal("worker_source_descriptors_mismatch")
    for name, descriptor in descriptors.items():
        if type(descriptor) is not int or descriptor < 0:
            raise Refusal("worker_source_descriptor_invalid")
        observed = Path(f"/proc/{worker['pid']}/fd/{descriptor}").stat()
        if {"device": observed.st_dev, "inode": observed.st_ino} != expected[name]:
            raise Refusal("worker_source_descriptor_identity_mismatch")
    return descriptors


def terminal_worker(workflow, config, worker, deadline):
    """Attribute an exited worker through its retained job-owner generation."""
    observed = process(worker["pid"])
    if observed and (identity(observed) != identity(worker) or observed["state"] not in {"Z", "X"}):
        return False
    digest = workflow.hashlib.sha256(workflow.canonical(config)).hexdigest()
    for owner_path in (Path(config["artifact_root"]) / "jobs").glob("*/owner.json"):
        if time.monotonic() >= deadline:
            raise Refusal("job_retirement_deadline")
        if read_json(owner_path) != identity(worker):
            continue
        directory = workflow.job_directory(config, owner_path.parent.name)
        status = read_json(directory / "status.json")
        return (status.get("job_id") == directory.name and status.get("state") in workflow.TERMINAL
                and workflow.load_config(directory / "config.json") == config
                and read_json(directory / "request.json").get("config_sha256") == digest)
    return False


def source_head_child(request, worker, child):
    """Recognize only Git HEAD reads over the worker's approved root descriptor."""
    arguments = [os.fsdecode(argument) for argument in child["args"]]
    if (len(arguments) != 7 or arguments[:3] != ["/usr/bin/git", "--no-optional-locks", "-C"]
            or arguments[4:] != ["rev-parse", "--verify", "HEAD"]):
        return False
    match = re.fullmatch(r"/proc/self/fd/([0-9]+)", arguments[3])
    if not match or not exact_command(child, arguments):
        return False
    descriptor = int(match[1])
    if descriptor < 3:
        return False
    expected = (request["repository_device"], request["repository_inode"])
    for record in (worker, child):
        metadata = Path(f"/proc/{record['pid']}/fd/{descriptor}").stat()
        if (metadata.st_dev, metadata.st_ino) != expected:
            raise Refusal("startup_git_source_descriptor_mismatch")
    if children(child["pid"]):
        raise Refusal("unrecognized_startup_git_children")
    return True


def observe_worker_publication(workflow, config, request, directory, worker, deadline):
    """Wait for a known startup child to publish its sandbox identity or exit."""
    captured = {(worker["pid"], worker["start_ticks"]): worker}
    while time.monotonic() < deadline:
        observed = process(worker["pid"])
        if not observed or observed["state"] in {"Z", "X"}:
            if terminal_worker(workflow, config, worker, deadline):
                return list(captured.values())
            raise Refusal("worker_terminal_identity_unproven")
        if identity(observed) != identity(worker):
            raise Refusal("worker_identity_changed_during_publication")
        # A recognized Git probe can remain a zombie until the worker reaps it.
        # Its generation stays attributed while publication advances past it.
        descendants = [child for child in children(worker["pid"])
                       if not ((child["pid"], child["start_ticks"]) in captured and not live(child))]
        if len(descendants) > 1:
            raise Refusal("unrecognized_worker_children")
        if descendants:
            child = descendants[0]
            if ((not child["args"] and child["state"] not in {"Z", "X"})
                    or (child["args"] == worker["args"] and exact_command(
                        child, [os.fsdecode(argument) for argument in worker["args"]]))):
                if children(child["pid"]):
                    raise Refusal("unrecognized_worker_fork_children")
                # fork() inherits the worker image; exec() can expose empty
                # argv. Attribution waits for the exact Git or sandbox image.
                time.sleep(min(0.02, max(0, deadline - time.monotonic())))
                continue
            try:
                published = read_json(directory / "child.json")
            except FileNotFoundError:
                published = None
            if published is None and source_head_child(request, worker, child):
                captured[(child["pid"], child["start_ticks"])] = child
            else:
                if not (directory / "source-fds.json").exists():
                    refreshed = process(child["pid"])
                    if (refreshed and identity(refreshed) == identity(child)
                            and refreshed["args"] != child["args"]):
                        continue
                    raise Refusal("unrecognized_worker_startup_child")
                descriptors = source_descriptors(workflow, request, directory, worker)
                if not exact_command(child, workflow.sandbox_command(
                        config, request, directory, source_fds=descriptors)):
                    refreshed = process(child["pid"])
                    if (refreshed and identity(refreshed) == identity(child)
                            and (refreshed["args"] != child["args"]
                                 or ((child["pid"], child["start_ticks"]) in captured
                                     and refreshed["state"] in {"Z", "X"}))):
                        continue
                    raise Refusal("sandbox_identity_or_command_mismatch")
                for record in tree(child):
                    captured[(record["pid"], record["start_ticks"])] = record
                if published is not None:
                    if published != identity(child):
                        raise Refusal("sandbox_identity_or_command_mismatch")
                    return list(captured.values())
        elif read_json(directory / "status.json")["state"] == "queued":
            # Queued cancellation publishes cancel.json before sandbox launch.
            return list(captured.values())
        time.sleep(min(0.02, max(0, deadline - time.monotonic())))
    raise Refusal("worker_publication_deadline")


def retire(server_pid, server_start, config_path, mcp_path, deadline_ms):
    started = time.monotonic()
    deadline = started + deadline_ms / 1000
    server = process(server_pid)
    if not server or server["start_ticks"] != server_start:
        raise Refusal("server_identity_changed")
    workflow_path = Path(__file__).resolve().with_name("graft-workflow.py")
    mcp_servers = read_json(mcp_path)["mcpServers"]
    entry = mcp_servers["qwen_graft"]
    expected_args = [str(workflow_path), "--config", str(Path(config_path).resolve()), "mcp"]
    if entry["args"] != expected_args or not Path(entry["command"]).is_absolute():
        raise Refusal("configured_mcp_command_mismatch")
    command = [entry["command"], *expected_args]
    direct_children = children(server_pid)
    candidates = [child for child in direct_children if exact_command(child, command)]
    retained_commands = []
    if len(mcp_servers) > 1:
        server_environment = process_environment(server_pid)
        for name, retained_entry in mcp_servers.items():
            if name == "qwen_graft":
                continue
            if not isinstance(retained_entry, dict):
                raise Refusal("configured_retained_mcp_invalid")
            retained_command = retained_mcp_command(retained_entry, server_environment)
            if retained_command[0] == command:
                raise Refusal("configured_retained_mcp_command_ambiguous")
            retained_commands.append(retained_command)
    spec = importlib.util.spec_from_file_location("qwen_graft_retirement_workflow", workflow_path)
    workflow = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(workflow)
    config = workflow.load_config(config_path)
    admitted = []
    for candidate in candidates:
        if not live(candidate) or not exact_command(candidate, command):
            raise Refusal("mcp_identity_changed")
        require_closed_publication(candidate, entry, config)
        jobs = []
        for worker in children(candidate["pid"]):
            # A finished worker remains a zombie until its MCP parent reaps it;
            # /proc then exposes identity but removes argv and executable data.
            if not live(worker) and terminal_worker(workflow, config, worker, deadline):
                admitted.append(worker)
                continue
            arguments = [os.fsdecode(argument) for argument in worker["args"]]
            if (len(arguments) != 8 or arguments[1] != str(workflow_path)
                    or arguments[2] != "--config" or arguments[4] != "_worker"
                    or arguments[6] != "--lock-fd" or not arguments[7].isdigit()
                    or not exact_command(worker, [entry["command"], *arguments[1:]])):
                raise Refusal("unrecognized_mcp_child")
            identifier = arguments[5]
            directory = workflow.job_directory(config, identifier)
            if (arguments[3] != str(directory / "config.json")
                    or read_json(directory / "owner.json") != identity(worker)
                    or workflow.load_config(directory / "config.json") != config):
                raise Refusal("worker_identity_or_configuration_mismatch")
            request = read_json(directory / "request.json")
            captured = observe_worker_publication(workflow, config, request, directory, worker, deadline)
            jobs.append((identifier, captured))
        # Validate the complete MCP child set before issuing any cancellation.
        for identifier, captured in jobs:
            if not live(candidate):
                raise Refusal("mcp_identity_changed")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise Refusal("job_retirement_deadline")
            result = subprocess.run(
                [entry["command"], str(workflow_path), "--config", str(config_path), "cancel", identifier],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                timeout=remaining, check=False,
                env={"PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"},
            )
            if result.returncode:
                raise Refusal("job_cancellation_refused")
            while any(live(record) for record in captured):
                if time.monotonic() >= deadline:
                    raise Refusal("job_retirement_deadline")
                time.sleep(0.02)
            if workflow.build_status(config, identifier)["state"] not in workflow.TERMINAL:
                raise Refusal("job_terminal_state_unproven")
            admitted.extend(captured)
        admitted.append(candidate)
    for child in direct_children:
        matches = [(expected, executable, environment)
                   for expected, executable, environment in retained_commands
                   if exact_command(child, expected, executable)]
        if len(matches) > 1:
            raise Refusal("configured_retained_mcp_command_ambiguous")
        if not matches:
            continue
        expected, executable, environment = matches[0]
        if not live(child) or not exact_command(child, expected, executable):
            raise Refusal("retained_mcp_identity_changed")
        observed_environment = process_environment(child["pid"])
        if any(observed_environment.get(key) != value for key, value in environment.items()):
            raise Refusal("retained_mcp_environment_mismatch")
        admitted.append(child)
    return admitted


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("server_pid", type=int)
    parser.add_argument("server_start")
    parser.add_argument("--deadline-ms", type=int, required=True)
    arguments = parser.parse_args()
    try:
        admitted = retire(arguments.server_pid, arguments.server_start,
                          os.environ["QWEN_GRAFT_CONFIG"], os.environ["QWEN_GRAFT_MCP_CONFIG"],
                          arguments.deadline_ms)
        for record in admitted:
            print(f"graft_cpu_identity={record['pid']}:{record['start_ticks']}")
        return 0
    except Exception as error:
        reason = str(error) if isinstance(error, Refusal) else type(error).__name__
        print(f"graft_cpu_retirement=refused reason={reason}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
