"""Run approved Graft builds as bounded jobs behind CLI and stdio MCP.

The operator config owns repository roots, scope ceilings, executables, the
loopback model endpoint and output storage. A start grant binds the normalized
request, configuration digest, repository inode and Git HEAD. Working-tree
bytes remain live inputs; HEAD identity does not establish their immutability.
Bubblewrap mounts source read-only and exposes writable graph/scratch mounts.
The detached supervisor owns deadlines and cancellation. llama-server owns the
GPU compute lease; the supervisor must never acquire that lease.

Invoke through the caller's selected PYTHON with --config CONFIG followed by
start, status, cancel or mcp. The _worker entry is the detached supervisor's
internal protocol, authenticated by an inherited repository lock descriptor.
"""

from __future__ import annotations

import argparse
import base64
import fcntl
import hashlib
import hmac
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import selectors
import signal
import stat
import subprocess
import sys
import time
from urllib.parse import urlsplit


IDENTIFIER = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}\Z")
JOB_IDENTIFIER = re.compile(r"[a-f0-9]{32}\Z")
TERMINAL = {"completed", "partial", "failed", "cancelled", "timed_out"}
CHILDREN: list[subprocess.Popen] = []
INPUT_LIMIT = 65536


class Refusal(ValueError):
    """A bounded refusal safe to return through MCP."""


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def read_json(path):
    with Path(path).open(encoding="utf-8") as handle:
        return json.load(handle)


def atomic_json(path, value):
    path = Path(path)
    temporary = path.with_name(path.name + "." + secrets.token_hex(8))
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(canonical(value) + b"\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def closed_fields(value, allowed, required):
    if not isinstance(value, dict) or set(value) - set(allowed):
        raise Refusal("unexpected_fields")
    if set(required) - set(value):
        raise Refusal("missing_fields")


def absolute_path(value, kind=None):
    if not isinstance(value, str) or not Path(value).is_absolute():
        raise Refusal("absolute_operator_path_required")
    path = Path(value).resolve(strict=kind is not None)
    if kind == "directory" and not path.is_dir():
        raise Refusal("operator_directory_required")
    if kind == "file" and not path.is_file():
        raise Refusal("operator_file_required")
    return str(path)


def integer(value, minimum, maximum):
    if type(value) is not int or not minimum <= value <= maximum:
        raise Refusal("limit_out_of_range")
    return value


def scoped_path(root, value):
    if not isinstance(value, str) or not value or len(value) > 512:
        raise Refusal("invalid_scope")
    path = Path(value)
    if path.is_absolute() or ".." in path.parts or value.startswith("-"):
        raise Refusal("scope_leaves_repository")
    resolved = (Path(root) / path).resolve(strict=True)
    if not resolved.is_relative_to(root) or not resolved.is_dir():
        raise Refusal("scope_leaves_repository")
    return path.as_posix()


def load_config(path):
    config = read_json(path)
    fields = {"version", "artifact_root", "graft_executable", "bwrap_executable",
              "repositories", "model", "limits", "authorization_key_file",
              "graft_package_root"}
    closed_fields(config, fields, fields - {"graft_package_root"})
    if config["version"] != 1:
        raise Refusal("unsupported_configuration_version")
    config["artifact_root"] = absolute_path(config["artifact_root"])
    artifact = Path(config["artifact_root"])
    if ".local-artifacts" not in artifact.parts:
        raise Refusal("artifact_root_requires_local_artifacts")
    if artifact.name == ".local-artifacts":
        raise Refusal("artifact_root_requires_named_subdirectory")
    script_path = Path(__file__).resolve()
    ancestors = [parent for parent in script_path.parents if parent.name == ".local-artifacts"]
    output_boundary = ancestors[-1] if ancestors else script_path.parent.parent / ".local-artifacts"
    if not artifact.is_relative_to(output_boundary):
        raise Refusal("artifact_root_outside_qwen_output_boundary")
    for name in ("graft_executable", "bwrap_executable"):
        config[name] = absolute_path(config[name], "file")
        if not os.access(config[name], os.X_OK):
            raise Refusal("operator_executable_required")
    if "graft_package_root" in config:
        config["graft_package_root"] = absolute_path(config["graft_package_root"], "directory")
        package = Path(config["graft_package_root"])
        if (not (package / "dist/mcp/tools.js").is_file()
                or read_json(package / "package.json").get("name") != "@nanonets/graft"):
            raise Refusal("graft_package_root_invalid")
    config["authorization_key_file"] = absolute_path(
        config["authorization_key_file"], "file")
    model = config["model"]
    closed_fields(model, {"base_url", "name", "api_key_file"},
                  {"base_url", "name", "api_key_file"})
    if not isinstance(model["base_url"], str):
        raise Refusal("loopback_model_endpoint_required")
    endpoint = urlsplit(model["base_url"])
    try:
        loopback = ipaddress.ip_address(endpoint.hostname or "").is_loopback
        port = endpoint.port
    except ValueError:
        raise Refusal("loopback_model_endpoint_required") from None
    if (endpoint.scheme != "http" or not loopback or port is None
            or endpoint.username or endpoint.password or endpoint.query
            or endpoint.fragment or endpoint.path.rstrip("/") != "/v1"):
        raise Refusal("loopback_model_endpoint_required")
    if not isinstance(model["name"], str) or not re.fullmatch(
            r"[a-zA-Z0-9][a-zA-Z0-9_./:-]{0,127}", model["name"]):
        raise Refusal("invalid_model_name")
    model["api_key_file"] = absolute_path(model["api_key_file"], "file")
    limits = config["limits"]
    closed_fields(limits, {"seconds", "log_bytes", "maximum_paths"},
                  {"seconds", "log_bytes", "maximum_paths"})
    integer(limits["seconds"], 1, 86400)
    integer(limits["log_bytes"], 1024, 16777216)
    integer(limits["maximum_paths"], 1, 64)
    repositories = config["repositories"]
    if not isinstance(repositories, dict) or not 1 <= len(repositories) <= 64:
        raise Refusal("repository_registry_required")
    for identifier, repository in repositories.items():
        if not isinstance(identifier, str) or not IDENTIFIER.fullmatch(identifier):
            raise Refusal("invalid_repository_identifier")
        closed_fields(repository, {"path", "allowed_paths"},
                      {"path", "allowed_paths"})
        repository["path"] = absolute_path(repository["path"], "directory")
        root = Path(repository["path"])
        if artifact.is_relative_to(root) or root.is_relative_to(artifact):
            raise Refusal("source_and_artifact_roots_overlap")
        paths = repository["allowed_paths"]
        if not isinstance(paths, list) or len(paths) > limits["maximum_paths"]:
            raise Refusal("invalid_allowed_paths")
        repository["allowed_paths"] = sorted(set(
            scoped_path(root, value) for value in paths))
    return config


def source_head(root, root_descriptor=None):
    checkout = str(root) if root_descriptor is None else f"/proc/self/fd/{root_descriptor}"
    result = subprocess.run(
        ["/usr/bin/git", "--no-optional-locks", "-C", checkout,
         "rev-parse", "--verify", "HEAD"], check=False, capture_output=True,
        pass_fds=() if root_descriptor is None else (root_descriptor,),
        timeout=10, env={"PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1",
                         "GIT_CONFIG_GLOBAL": "/dev/null"})
    head = result.stdout.decode("ascii", errors="replace").strip()
    if result.returncode or not re.fullmatch(r"[a-f0-9]{40,64}", head):
        raise Refusal("repository_head_unavailable")
    return head


def descriptor_identity(descriptor):
    metadata = os.fstat(descriptor)
    return {"device": metadata.st_dev, "inode": metadata.st_ino}


def close_source_fds(descriptors):
    for descriptor in descriptors.values():
        os.close(descriptor)


def open_source_fds(config, repository_id, paths):
    """Pin source directories and Git metadata before deriving their identities."""
    repository = config["repositories"][repository_id]
    descriptors = {}
    git_mounts = {}
    try:
        root_descriptor = os.open(repository["path"], os.O_PATH | os.O_DIRECTORY | os.O_NOFOLLOW)
        descriptors["."] = root_descriptor
        root_path = Path(os.readlink(f"/proc/self/fd/{root_descriptor}"))
        for path in paths:
            if path == ".":
                continue
            descriptor = os.open(path, os.O_PATH | os.O_DIRECTORY, dir_fd=root_descriptor)
            descriptors[path] = descriptor
            resolved = Path(os.readlink(f"/proc/self/fd/{descriptor}"))
            if not resolved.is_relative_to(root_path):
                raise Refusal("scope_leaves_repository")
            allowed = repository["allowed_paths"]
            if allowed and not any(resolved.is_relative_to((root_path / prefix).resolve())
                                   for prefix in allowed):
                raise Refusal("scope_symlink_outside_operator_allowlist")
        if (paths and "." not in paths) or (root_path / ".git").is_file():
            try:
                git_descriptor = os.open(".git", os.O_PATH | os.O_NOFOLLOW, dir_fd=root_descriptor)
            except FileNotFoundError:
                git_descriptor = None
            if git_descriptor is not None:
                descriptors["/git"] = git_descriptor
                metadata = os.fstat(git_descriptor)
                if not (stat.S_ISREG(metadata.st_mode) or stat.S_ISDIR(metadata.st_mode)):
                    raise Refusal("git_metadata_requires_regular_file_or_directory")
                git_mounts["/git"] = {"destination": "/repo/.git",
                                      "identity": descriptor_identity(git_descriptor)}
                if stat.S_ISREG(metadata.st_mode):
                    gitdir_text = Path(f"/proc/self/fd/{git_descriptor}").read_text().strip()
                    if not gitdir_text.startswith("gitdir: "):
                        raise Refusal("worktree_gitdir_invalid")
                    gitdir = (root_path / gitdir_text[8:]).resolve(strict=True)
                    descriptors["/gitdir"] = os.open(gitdir, os.O_PATH | os.O_DIRECTORY | os.O_NOFOLLOW)
                    git_mounts["/gitdir"] = {"destination": str(gitdir),
                                            "identity": descriptor_identity(descriptors["/gitdir"])}
                    common_file = Path(f"/proc/self/fd/{descriptors['/gitdir']}/commondir")
                    if common_file.is_file():
                        common = (gitdir / common_file.read_text().strip()).resolve(strict=True)
                        descriptors["/commondir"] = os.open(common, os.O_PATH | os.O_DIRECTORY | os.O_NOFOLLOW)
                        git_mounts["/commondir"] = {"destination": str(common),
                                                   "identity": descriptor_identity(descriptors["/commondir"])}
        return descriptors, git_mounts
    except BaseException:
        close_source_fds(descriptors)
        raise


def source_directory_identities(request):
    """Return the signed identity of every descriptor retained by a worker."""
    return {".": {"device": request["repository_device"], "inode": request["repository_inode"]},
            **request["scope_identities"],
            **{name: mount["identity"] for name, mount in request["git_mounts"].items()}}


def pin_request_sources(config, request, check_head=False):
    try:
        descriptors, git_mounts = open_source_fds(config, request["repository"], request["paths"])
    except OSError as error:
        raise Refusal("approved_source_identity_changed") from error
    try:
        measured = {name: descriptor_identity(descriptor) for name, descriptor in descriptors.items()}
        if measured != source_directory_identities(request) or git_mounts != request["git_mounts"]:
            raise Refusal("approved_source_identity_changed")
        if check_head and source_head(config["repositories"][request["repository"]]["path"],
                                      descriptors["."]) != request["source_head"]:
            raise Refusal("approved_source_or_configuration_changed")
        return descriptors
    except BaseException:
        close_source_fds(descriptors)
        raise


def normalize_start(config, arguments):
    closed_fields(arguments, {"repository", "mode", "paths"},
                  {"repository", "mode"})
    repository_id = arguments["repository"]
    if not isinstance(repository_id, str) or repository_id not in config["repositories"]:
        raise Refusal("repository_unregistered")
    mode = arguments["mode"]
    if mode not in ("structural", "deep"):
        raise Refusal("invalid_build_mode")
    repository = config["repositories"][repository_id]
    supplied = arguments.get("paths", [])
    if not isinstance(supplied, list) or len(supplied) > config["limits"]["maximum_paths"]:
        raise Refusal("scope_count_exceeded")
    paths = sorted(set(scoped_path(repository["path"], item) for item in supplied))
    allowed = repository["allowed_paths"]
    if not paths:
        paths = allowed.copy()
    for path in paths:
        if allowed and not any(Path(path).is_relative_to(prefix) for prefix in allowed):
            raise Refusal("scope_outside_operator_allowlist")
        resolved = (Path(repository["path"]) / path).resolve()
        if allowed and not any(resolved.is_relative_to(
                (Path(repository["path"]) / prefix).resolve()) for prefix in allowed):
            raise Refusal("scope_symlink_outside_operator_allowlist")
    descriptors, git_mounts = open_source_fds(config, repository_id, paths)
    try:
        identity = descriptor_identity(descriptors["."])
        return {"repository": repository_id, "mode": mode, "paths": paths,
                "config_sha256": hashlib.sha256(canonical(config)).hexdigest(),
                "repository_device": identity["device"], "repository_inode": identity["inode"],
                "scope_identities": {path: descriptor_identity(descriptors[path])
                                     for path in paths if path != "."},
                "git_mounts": git_mounts,
                "source_head": source_head(repository["path"], descriptors["."])}
    finally:
        close_source_fds(descriptors)


def read_key(path, strip=False):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as handle:
        metadata = os.fstat(handle.fileno())
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_mode & 0o077:
            raise Refusal("key_file_requires_private_permissions")
        key = handle.read(8193)
        if len(key) > 8192:
            raise Refusal("key_file_length_invalid")
        if strip:
            key = key.strip()
    if not 16 <= len(key) <= 8192:
        raise Refusal("key_file_length_invalid")
    return key


def issue_start_authorization(config, arguments, key):
    return issue_authorization({"action": "start", **normalize_start(config, arguments)}, key)


def issue_authorization(request, key):
    claim = {"request": request,
             "expires": int(time.time()) + 120, "nonce": secrets.token_hex(16)}
    encoded = base64.urlsafe_b64encode(canonical(claim)).rstrip(b"=")
    signature = hmac.new(key, encoded, hashlib.sha256).hexdigest()
    return encoded.decode() + "." + signature


def verify_authorization(config, normalized, token):
    if not isinstance(token, str) or len(token) > 16384:
        raise Refusal("start_authorization_required")
    try:
        encoded, signature = token.split(".")
        expected = hmac.new(read_key(config["authorization_key_file"]),
                            encoded.encode(), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(signature, expected):
            raise ValueError
        claim = json.loads(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)))
        if (claim["request"] != normalized or type(claim["expires"]) is not int
                or not time.time() < claim["expires"] <= time.time() + 121
                or not JOB_IDENTIFIER.fullmatch(claim["nonce"])):
            raise ValueError
        return claim["nonce"]
    except (ValueError, KeyError, TypeError):
        raise Refusal("start_authorization_invalid_or_stale") from None


def initialize_storage(config):
    root = Path(config["artifact_root"])
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    if root.stat().st_uid != os.getuid() or root.stat().st_mode & 0o077:
        raise Refusal("artifact_root_requires_private_permissions")
    for name in ("jobs", "locks", "grants"):
        (root / name).mkdir(mode=0o700, exist_ok=True)
    return root


def process_identity(process_id):
    try:
        content = Path(f"/proc/{process_id}/stat").read_text()
        fields = content[content.rfind(")") + 2:].split()
        return {"pid": process_id, "start_ticks": fields[19]}
    except (OSError, IndexError):
        return None


def identity_matches(identity, require_live=False):
    if not identity or process_identity(identity["pid"]) != identity:
        return False
    if require_live:
        try:
            content = Path(f"/proc/{identity['pid']}/stat").read_text()
            if content[content.rfind(")") + 2:].split()[0] == "Z":
                return False
        except (OSError, IndexError):
            return False
    return True


def job_directory(config, identifier):
    if not isinstance(identifier, str) or not JOB_IDENTIFIER.fullmatch(identifier):
        raise Refusal("invalid_job_identifier")
    root = Path(config["artifact_root"]) / "jobs"
    directory = root / identifier
    if directory.is_symlink() or not directory.is_dir():
        raise Refusal("job_unavailable")
    return directory


def build_status(config, identifier):
    for process in CHILDREN[:]:
        if process.poll() is not None:
            CHILDREN.remove(process)
    directory = job_directory(config, identifier)
    state = read_json(directory / "status.json")
    if state["state"] not in TERMINAL:
        owner_path = directory / "owner.json"
        if owner_path.exists() and not identity_matches(read_json(owner_path), require_live=True):
            state = {**state, "state": "failed", "reason": "supervisor_exited"}
    return state


def start_build(config, arguments, authorization):
    normalized = normalize_start(config, arguments)
    nonce = verify_authorization(config, {"action": "start", **normalized}, authorization)
    root = initialize_storage(config)
    lock_path = root / "locks" / (normalized["repository"] + ".lock")
    lock_descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(lock_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Refusal("repository_build_busy") from None
        try:
            nonce_descriptor = os.open(root / "grants" / nonce,
                                       os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            raise Refusal("start_authorization_spent") from None
        os.close(nonce_descriptor)
        identifier = secrets.token_hex(16)
        directory = root / "jobs" / identifier
        directory.mkdir(mode=0o700)
        for name in ("graph", "scratch"):
            (directory / name).mkdir(mode=0o700)
        atomic_json(directory / "config.json", config)
        atomic_json(directory / "request.json", normalized)
        initial = {"job_id": identifier, "repository": normalized["repository"],
                   "mode": normalized["mode"], "paths": normalized["paths"],
                   "source_head": normalized["source_head"], "state": "queued",
                   "graph_directory": str(directory / "graph")}
        atomic_json(directory / "status.json", initial)
        process = subprocess.Popen(
            [sys.executable, str(Path(__file__).resolve()), "--config",
             str(directory / "config.json"), "_worker", identifier,
             "--lock-fd", str(lock_descriptor)], start_new_session=True,
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, pass_fds=(lock_descriptor,),
            env={"PATH": "/usr/bin:/bin", "PYTHONUNBUFFERED": "1"})
        atomic_json(directory / "owner.json", process_identity(process.pid))
        CHILDREN.append(process)
        return initial
    finally:
        os.close(lock_descriptor)


def normalize_cancel(config, arguments):
    closed_fields(arguments, {"job_id"}, {"job_id"})
    directory = job_directory(config, arguments["job_id"])
    return {"action": "cancel", "job_id": arguments["job_id"],
            "config_sha256": hashlib.sha256(canonical(config)).hexdigest(),
            "request_sha256": hashlib.sha256((directory / "request.json").read_bytes()).hexdigest()}


def issue_cancel_authorization(config, arguments, key):
    return issue_authorization(normalize_cancel(config, arguments), key)


def cancel_build(config, identifier, authorization):
    nonce = verify_authorization(config, normalize_cancel(config, {"job_id": identifier}), authorization)
    directory = job_directory(config, identifier)
    try:
        descriptor = os.open(Path(config["artifact_root"]) / "grants" / nonce,
                             os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        raise Refusal("cancellation_authorization_spent") from None
    os.close(descriptor)
    state = build_status(config, identifier)
    if state["state"] in TERMINAL:
        return state
    owner = read_json(directory / "owner.json")
    if not identity_matches(owner, require_live=True):
        raise Refusal("supervisor_identity_changed")
    atomic_json(directory / "cancel.json", {"requested": True})
    if state["state"] == "queued":
        return {**state, "cancellation": "requested"}
    # pidfd binds signalling to one process lifetime after the start-time check.
    descriptor = os.pidfd_open(owner["pid"])
    try:
        if not identity_matches(owner, require_live=True):
            raise Refusal("supervisor_identity_changed")
        signal.pidfd_send_signal(descriptor, signal.SIGTERM)
    except ProcessLookupError:
        pass
    finally:
        os.close(descriptor)
    return {**state, "cancellation": "requested"}


def sandbox_base(config, request, directory, graph_read_only=False, source_fds=None):
    expected = source_directory_identities(request)
    if (not isinstance(source_fds, dict) or set(source_fds) != set(expected)
            or any(type(descriptor) is not int or descriptor < 3 for descriptor in source_fds.values())
            or len(set(source_fds.values())) != len(source_fds)):
        raise Refusal("sandbox_source_descriptors_required")
    command = [config["bwrap_executable"], "--unshare-all", "--die-with-parent",
               "--new-session", "--ro-bind", "/usr", "/usr"]
    for name in ("bin", "sbin", "lib", "lib64"):
        if Path("/" + name).exists():
            command.extend(["--symlink", "usr/" + name, "/" + name])
    executable = Path(config["graft_executable"])
    package = config.get("graft_package_root")
    if package and not Path(package).is_relative_to("/usr"):
        command.extend(["--ro-bind", package, package])
    if not executable.is_relative_to("/usr") and not (package and executable.is_relative_to(package)):
        command.extend(["--ro-bind", str(executable), "/graft-executable"])
    command.extend(["--proc", "/proc", "--dev", "/dev", "--dir", "/etc",
                    "--ro-bind", "/etc/ssl", "/etc/ssl"])
    if request["paths"] and "." not in request["paths"]:
        command.extend(["--dir", "/repo"])
        for prefix in request["paths"]:
            command.extend(["--ro-bind-fd", str(source_fds[prefix]), "/repo/" + prefix])
    else:
        command.extend(["--ro-bind-fd", str(source_fds["."]), "/repo"])
    for name, mount in request["git_mounts"].items():
        command.extend(["--ro-bind-fd", str(source_fds[name]), mount["destination"]])
    command.extend(["--ro-bind" if graph_read_only else "--bind",
                    str(directory / "graph"), "/graph",
                    "--bind", str(directory / "scratch"), "/work",
                    "--symlink", "/work/tmp", "/tmp", "--chdir", "/repo",
                    "--remount-ro", "/"])
    if request["mode"] == "deep" and not graph_read_only:
        command.append("--share-net")
    return command


def sandbox_pass_fds(request, source_fds):
    """Pass only mount-consumed FDs; an unused root FD bypasses scope mounts."""
    if request["paths"] and "." not in request["paths"]:
        return tuple(source_fds[name] for name in (*request["paths"], *request["git_mounts"]))
    return (source_fds["."], *(source_fds[name] for name in request["git_mounts"]))


def sandbox_command(config, request, directory, source_fds=None):
    command = sandbox_base(config, request, directory, source_fds=source_fds)
    executable = Path(config["graft_executable"])
    package = config.get("graft_package_root")
    launched = str(executable) if executable.is_relative_to("/usr") or (
        package and executable.is_relative_to(package)) else "/graft-executable"
    command.extend(["--", launched, "--dir", "/graph",
                    "build", "/repo", "-j", "1", "--no-gitignore", "--no-ignore"])
    if request["mode"] == "deep":
        command.append("--deep")
    for path in request["paths"]:
        command.extend(["--only-dir", path])
    return command


def graph_coverage(directory):
    try:
        graph = read_json(directory / "graph" / ".graph" / "wiring.json")
        nodes = graph["nodes"]
        if not isinstance(nodes, list) or any(not isinstance(node, dict) for node in nodes):
            raise ValueError
        counts = {"nodes": len(nodes), "ready": 0, "pending": 0, "stale": 0,
                  "other_state": 0, "empty_ready": 0}
        for node in nodes:
            state = node.get("summary_state")
            counts[state if state in ("ready", "pending", "stale") else "other_state"] += 1
            if state == "ready" and not str(node.get("summary") or "").strip():
                counts["empty_ready"] += 1
        return counts
    except (OSError, ValueError, KeyError, TypeError):
        return None


def stop_child(process, identity):
    # The supervisor retains the child until wait(), preventing leader PID reuse.
    if identity_matches(identity):
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        # Keep the group leader unreaped during the grace interval so a
        # surviving descendant cannot hide behind reuse of the leader's PID.
        time.sleep(0.2)
        if identity_matches(identity):
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        process.wait(timeout=3)


def run_worker(config, identifier, lock_descriptor):
    directory = job_directory(config, identifier)
    request = read_json(directory / "request.json")
    lock_path = Path(config["artifact_root"]) / "locks" / (request["repository"] + ".lock")
    descriptor_stat, path_stat = os.fstat(lock_descriptor), lock_path.stat()
    if (descriptor_stat.st_dev, descriptor_stat.st_ino) != (path_stat.st_dev, path_stat.st_ino):
        raise Refusal("worker_lock_identity_invalid")
    fcntl.flock(lock_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    cancelled = False

    def request_cancel(_signum, _frame):
        nonlocal cancelled
        cancelled = True

    signal.signal(signal.SIGTERM, request_cancel)
    signal.signal(signal.SIGINT, request_cancel)
    state = read_json(directory / "status.json")
    state.update(state="running", started_at=int(time.time()))
    atomic_json(directory / "status.json", state)
    child = None
    identity = None
    source_fds = {}
    try:
        arguments = {name: request[name] for name in ("repository", "mode", "paths")}
        if normalize_start(config, arguments) != request:
            raise Refusal("approved_source_or_configuration_changed")
        if cancelled or (directory / "cancel.json").exists():
            state.update(state="cancelled")
            return
        source_fds = pin_request_sources(config, request, check_head=True)
        atomic_json(directory / "source-fds.json", source_fds)
        for name in ("home", "tmp"):
            (directory / "scratch" / name).mkdir(mode=0o700, exist_ok=True)
        environment = {"PATH": "/usr/bin:/bin", "HOME": "/work/home", "TMPDIR": "/work/tmp",
                       "XDG_CONFIG_HOME": "/work/home/config", "XDG_CACHE_HOME": "/work/home/cache",
                       "CI": "1", "DO_NOT_TRACK": "1", "NO_COLOR": "1",
                       "GRAFT_NO_GITIGNORE": "1", "GRAFT_NO_IGNORE": "1"}
        key = b""
        if request["mode"] == "deep":
            key = read_key(config["model"]["api_key_file"], strip=True)
            environment.update(GRAFT_PROVIDER="openai", GRAFT_BASE_URL=config["model"]["base_url"],
                               GRAFT_MODEL=config["model"]["name"], GRAFT_API_KEY=key.decode())
        child = subprocess.Popen(sandbox_command(config, request, directory, source_fds=source_fds),
                                 stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, env=environment,
                                 start_new_session=True, close_fds=True,
                                 pass_fds=sandbox_pass_fds(request, source_fds))
        identity = process_identity(child.pid)
        atomic_json(directory / "child.json", identity)
        deadline = time.monotonic() + config["limits"]["seconds"]
        reason = None
        stored = 0
        pending = b""
        selector = selectors.DefaultSelector()
        selector.register(child.stdout, selectors.EVENT_READ)
        with (directory / "build.log").open("wb") as log:
            while selector.get_map():
                if cancelled or (directory / "cancel.json").exists():
                    reason = "cancelled"
                elif time.monotonic() >= deadline:
                    reason = "timed_out"
                if reason:
                    stop_child(child, identity)
                events = selector.select(timeout=0.1)
                for selection, _mask in events:
                    chunk = os.read(selection.fileobj.fileno(), 65536)
                    if chunk:
                        pending += chunk
                    else:
                        selector.unregister(selection.fileobj)
                    # Keep a tail so a credential split across pipe reads stays redacted.
                    boundary = max(0, len(pending) - max(0, len(key) - 1)) if chunk else len(pending)
                    if key:
                        pending = pending.replace(key, b"[redacted]")
                        boundary = min(boundary, max(0, len(pending) - len(key) + 1)) if chunk else len(pending)
                    output, pending = pending[:boundary], pending[boundary:]
                    allowance = max(0, config["limits"]["log_bytes"] - stored)
                    log.write(output[:allowance])
                    stored += min(allowance, len(output))
                if reason and not events:
                    break
            selector.close()
        child.wait(timeout=3)
        child.stdout.close()
        coverage = graph_coverage(directory)
        if reason:
            outcome = reason
        elif child.returncode != 0:
            outcome = "partial" if coverage else "failed"
        elif not coverage or not coverage["nodes"] or coverage["other_state"] or coverage["empty_ready"]:
            outcome = "failed"
        elif request["mode"] == "deep" and (coverage["pending"] or coverage["stale"]):
            outcome = "partial"
        else:
            outcome = "completed"
        state.update(state=outcome, exit_code=child.returncode, coverage=coverage,
                     log_bytes=stored, log_limit=config["limits"]["log_bytes"])
    except Exception as error:
        if child is not None:
            stop_child(child, identity)
        state.update(state="failed", reason=str(error) if isinstance(error, Refusal)
                     else type(error).__name__)
    finally:
        state["finished_at"] = int(time.time())
        try:
            atomic_json(directory / "status.json", state)
        finally:
            close_source_fds(source_fds)
            os.close(lock_descriptor)


QUERY_FIELDS = {
    "graft_find_code": ({"query", "limit", "full", "in"}, {"query"}),
    "graft_file_api": ({"file"}, {"file"}),
    "graft_check_freshness": (set(), set()),
    "graft_trace_calls": ({"symbol", "direction", "depth", "in"}, {"symbol"}),
    "graft_find_all": ({"pattern", "in", "ignore_case", "fixed"}, {"pattern"}),
    "graft_repo_map": ({"max_dirs"}, set()),
}
QUERY_PROGRAM = """
import fs from 'node:fs';
import {pathToFileURL} from 'node:url';
const {callTool} = await import(pathToFileURL(process.env.WORKFLOW_GRAFT_TOOLS));
const request = JSON.parse(fs.readFileSync(0, 'utf8'));
const result = await callTool('/repo', request.operation, request.arguments, '/graph');
process.stdout.write(JSON.stringify(result));
"""


def query_graph(config, arguments):
    closed_fields(arguments, {"job_id", "operation", "arguments"},
                  {"job_id", "operation", "arguments"})
    operation = arguments["operation"]
    if not isinstance(operation, str) or operation not in QUERY_FIELDS:
        raise Refusal("unknown_query_operation")
    params = arguments["arguments"]
    closed_fields(params, *QUERY_FIELDS[operation])
    for name, value in params.items():
        if name in ("full", "ignore_case", "fixed"):
            if type(value) is not bool:
                raise Refusal("query_boolean_required")
        elif name in ("limit", "max_dirs"):
            integer(value, 1, 32)
        elif name == "depth":
            if value != "all":
                integer(value, 1, 8)
        elif not isinstance(value, str) or not value or len(value) > 1024:
            raise Refusal("query_text_invalid")
    if "direction" in params and params["direction"] not in ("in", "out"):
        raise Refusal("query_direction_invalid")
    if not config.get("graft_package_root"):
        raise Refusal("query_requires_graft_package_root")
    directory = job_directory(config, arguments["job_id"])
    state = build_status(config, arguments["job_id"])
    if state["state"] not in ("completed", "partial") or not graph_coverage(directory):
        raise Refusal("query_requires_terminal_graph")
    request = read_json(directory / "request.json")
    if request["config_sha256"] != hashlib.sha256(canonical(config)).hexdigest():
        raise Refusal("query_configuration_changed")
    repository = config["repositories"][request["repository"]]["path"]
    for name in ("in", "file"):
        if name in params:
            target = Path(params[name])
            if name == "file" and len(target.parts) == 1 and request["paths"]:
                graph = read_json(directory / "graph/.graph/wiring.json")
                matches = [node["path"] for node in graph["nodes"]
                           if node.get("kind") == "file" and Path(node.get("path", "")).name == str(target)]
                if len(matches) != 1:
                    raise Refusal("query_file_ambiguous")
                target = Path(matches[0])
                params = {**params, name: str(target)}
            if (target.is_absolute() or ".." in target.parts
                    or not (Path(repository) / target).resolve().is_relative_to(repository)):
                raise Refusal("query_path_leaves_repository")
            if request["paths"] and not any(target.is_relative_to(prefix) for prefix in request["paths"]):
                raise Refusal("query_path_outside_job_scope")
    source_fds = pin_request_sources(config, request)
    environment = {"PATH": "/usr/bin:/bin", "HOME": "/work/home", "TMPDIR": "/work/tmp",
                   "CI": "1", "DO_NOT_TRACK": "1", "GRAFT_NO_REFRESH": "1",
                   "WORKFLOW_GRAFT_TOOLS": str(Path(config["graft_package_root"]) / "dist/mcp/tools.js")}
    process = None
    identity = None
    selector = None
    try:
        command = sandbox_base(config, request, directory, graph_read_only=True, source_fds=source_fds)
        command.extend(["--", "/usr/bin/node", "--input-type=module", "-e", QUERY_PROGRAM])
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, env=environment,
                                   start_new_session=True, close_fds=True,
                                   pass_fds=sandbox_pass_fds(request, source_fds))
        identity = process_identity(process.pid)
        selector = selectors.DefaultSelector()
        process.stdin.write(canonical({"operation": operation, "arguments": params}))
        process.stdin.close()
        selector.register(process.stdout, selectors.EVENT_READ)
        deadline = time.monotonic() + 20
        output = bytearray()
        while selector.get_map():
            if time.monotonic() > deadline:
                raise Refusal("query_deadline_exceeded")
            for selection, _mask in selector.select(0.1):
                chunk = os.read(selection.fileobj.fileno(), 65536)
                if not chunk:
                    selector.unregister(selection.fileobj)
                output.extend(chunk)
                if len(output) > 1048576:
                    raise Refusal("query_output_limit_exceeded")
        process.wait(timeout=3)
        if process.returncode:
            raise Refusal("query_process_failed")
        result = json.loads(output)
        return {"job_id": arguments["job_id"], "operation": operation,
                "source_view": "live_read_only", "graph_refresh": "disabled",
                "graph_source_head": request["source_head"],
                "current_source_head": source_head(repository, source_fds["."]), "result": result}
    finally:
        try:
            if process is not None:
                stop_child(process, identity)
        finally:
            if process is not None:
                process.stdin.close()
                process.stdout.close()
            if selector is not None:
                selector.close()
            close_source_fds(source_fds)


def tool_definitions(config):
    job_schema = {"type": "object", "properties": {"job_id": {"type": "string"}},
                  "required": ["job_id"], "additionalProperties": False}
    return [
        {"name": "graft_start_build", "description":
         "Start one approved asynchronous repository graph build. Deep mode uses the configured local model. Return the job ID and poll status; source mounts are read-only.",
         "inputSchema": {"type": "object", "properties": {
             "repository": {"type": "string", "enum": sorted(config["repositories"])},
             "mode": {"type": "string", "enum": ["structural", "deep"]},
             "paths": {"type": "array", "items": {"type": "string"},
                       "maxItems": config["limits"]["maximum_paths"]},
             "authorization": {"type": "string", "description": "Single-use approval supplied by the UI executor."}},
             "required": ["repository", "mode", "authorization"], "additionalProperties": False}},
        {"name": "graft_build_status", "description": "Read build state and retained graph coverage by job ID.",
         "inputSchema": job_schema},
        {"name": "graft_cancel_build", "description": "Cancel the approved build and retain its partial output.",
         "inputSchema": {"type": "object", "properties": {
             "job_id": {"type": "string"}, "authorization": {"type": "string"}},
             "required": ["job_id", "authorization"], "additionalProperties": False}},
        {"name": "graft_query", "description":
         "Query a completed job through six Graft operations: find_code requires query; file_api requires file; trace_calls requires symbol; find_all requires pattern; check_freshness and repo_map take empty arguments. Graph and source mounts are read-only; source excerpts use live bytes.",
         "inputSchema": {"type": "object", "properties": {
             "job_id": {"type": "string"}, "operation": {"type": "string", "enum": sorted(QUERY_FIELDS)},
             "arguments": {"type": "object", "properties": {
                 "query": {"type": "string"}, "file": {"type": "string"},
                 "symbol": {"type": "string"}, "pattern": {"type": "string"},
                 "in": {"type": "string", "description": "Repository-relative scope prefix."},
                 "limit": {"type": "integer", "minimum": 1, "maximum": 32},
                 "max_dirs": {"type": "integer", "minimum": 1, "maximum": 32},
                 "direction": {"type": "string", "enum": ["in", "out"]},
                 "depth": {"anyOf": [{"type": "integer", "minimum": 1, "maximum": 8},
                                      {"type": "string", "enum": ["all"]}]},
                 "full": {"type": "boolean"}, "ignore_case": {"type": "boolean"},
                 "fixed": {"type": "boolean"}}, "additionalProperties": False}},
             "required": ["job_id", "operation", "arguments"], "additionalProperties": False}},
    ]


def with_mcp_admission(config, operation):
    """Count CPU child admission in the session drain without a GPU lease."""
    import importlib.util

    directory = os.environ.get("QWEN_GRAFT_SESSION_BARRIER", "")
    expected = str(Path(config["model"]["api_key_file"]).parent)
    if directory != expected or os.environ.get("QWEN_GPU_ADMISSION_BARRIER") != directory:
        raise Refusal("mcp_session_barrier_binding_required")
    specification = importlib.util.spec_from_file_location(
        "qwen_graft_admission", Path(__file__).with_name("admission_barrier.py")
    )
    barrier = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(barrier)
    environment = {"QWEN_GPU_ADMISSION_BARRIER": directory}
    if barrier.verify_session_identity(environment) != "match":
        raise Refusal("mcp_session_barrier_identity_required")
    try:
        with barrier.require_admission(environment) as share:
            # The common barrier is optional for legacy callers. MCP execution
            # requires the actual held descriptor to match an armed session.
            if share._descriptor is None or barrier.verify_descriptor_identity(
                    share._descriptor, environment) != "match":
                raise Refusal("mcp_session_barrier_identity_required")
            return operation()
    except barrier.AdmissionRefused as error:
        raise Refusal("mcp_session_" + error.reason) from None


def call_tool(config, name, arguments):
    if name == "graft_start_build":
        closed_fields(arguments, {"repository", "mode", "paths", "authorization"},
                      {"repository", "mode", "authorization"})
        request = {field: value for field, value in arguments.items() if field != "authorization"}
        return with_mcp_admission(
            config, lambda: start_build(config, request, arguments["authorization"])
        )
    if name == "graft_cancel_build":
        closed_fields(arguments, {"job_id", "authorization"}, {"job_id", "authorization"})
        return cancel_build(config, arguments["job_id"], arguments["authorization"])
    if name == "graft_query":
        return with_mcp_admission(config, lambda: query_graph(config, arguments))
    closed_fields(arguments, {"job_id"}, {"job_id"})
    if name == "graft_build_status":
        return build_status(config, arguments["job_id"])
    raise Refusal("unknown_tool")


def serve_mcp(config):
    while True:
        line = sys.stdin.buffer.readline(INPUT_LIMIT + 1)
        if not line:
            return
        if len(line) > INPUT_LIMIT:
            return
        identifier = None
        try:
            message = json.loads(line)
            identifier = message.get("id")
            method = message.get("method")
            if identifier is None:
                continue
            if method == "initialize":
                result = {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}},
                          "serverInfo": {"name": "qwen-graft-workflow", "version": "1.0.0"}}
            elif method == "ping":
                result = {}
            elif method == "tools/list":
                result = {"tools": tool_definitions(config)}
            elif method == "tools/call":
                params = message.get("params", {})
                try:
                    value = call_tool(config, params.get("name"), params.get("arguments", {}))
                    result = {"content": [{"type": "text", "text": json.dumps(value)}], "isError": False}
                except Exception as error:
                    result = {"content": [{"type": "text", "text": str(error) if isinstance(error, Refusal)
                                            else type(error).__name__}], "isError": True}
            else:
                raise Refusal("method_unavailable")
            reply = {"jsonrpc": "2.0", "id": identifier, "result": result}
        except Exception:
            reply = {"jsonrpc": "2.0", "id": identifier,
                     "error": {"code": -32600, "message": "invalid_request"}}
        print(json.dumps(reply), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    commands = parser.add_subparsers(dest="command", required=True)
    start = commands.add_parser("start")
    start.add_argument("--repository", required=True)
    start.add_argument("--mode", choices=("structural", "deep"), required=True)
    start.add_argument("--path", action="append", default=[])
    for name in ("status", "cancel"):
        commands.add_parser(name).add_argument("job_id")
    query = commands.add_parser("query")
    query.add_argument("job_id")
    query.add_argument("operation", choices=sorted(QUERY_FIELDS))
    query.add_argument("--arguments", default="{}", help="JSON operation arguments")
    commands.add_parser("mcp")
    worker = commands.add_parser("_worker", help=argparse.SUPPRESS)
    worker.add_argument("job_id")
    worker.add_argument("--lock-fd", type=int, required=True)
    arguments = parser.parse_args()
    try:
        config = load_config(arguments.config)
        if arguments.command == "_worker":
            run_worker(config, arguments.job_id, arguments.lock_fd)
            return 0
        if arguments.command == "mcp":
            serve_mcp(config)
            return 0
        if arguments.command == "start":
            request = {"repository": arguments.repository, "mode": arguments.mode, "paths": arguments.path}
            token = issue_start_authorization(config, request, read_key(config["authorization_key_file"]))
            result = start_build(config, request, token)
        elif arguments.command == "status":
            result = build_status(config, arguments.job_id)
        elif arguments.command == "query":
            result = query_graph(config, {"job_id": arguments.job_id,
                                         "operation": arguments.operation,
                                         "arguments": json.loads(arguments.arguments)})
        else:
            token = issue_cancel_authorization(config, {"job_id": arguments.job_id},
                                               read_key(config["authorization_key_file"]))
            result = cancel_build(config, arguments.job_id, token)
        print(json.dumps(result))
        return 0
    except Exception as error:
        print(str(error) if isinstance(error, Refusal) else type(error).__name__, file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
