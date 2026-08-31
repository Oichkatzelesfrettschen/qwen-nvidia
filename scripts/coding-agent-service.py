#!/usr/bin/env python3
"""The bounded coding-agent service.

The service, not the agent runtime, owns job identity, repository
selection, the base commit, the worktree path, model selection, timeouts,
the process group, resource limits, cancellation, result retention, and
teardown. It listens on a mode-0600 Unix socket for one JSON object per
line and answers one JSON object per line; the browser-facing coding MCP is
its only intended client, and every job opens against a single-use HMAC
grant bound to the exact operation a human approved.

A job imports one approved base revision into the bare mirror under the
qwen-coder principal, creates an ephemeral detached worktree there, runs
the pinned agent runtime inside it under a fresh process group with
resource limits and a wall deadline, and exports the patch, diffstat,
changed-file list, test log, event stream, base commit, and result tree
hash. The authoritative checkout changes only when a human applies the
exported patch.
"""

import argparse
import hashlib
import hmac
import json
import os
import pathlib
import resource
import secrets
import signal
import socketserver
import stat
import subprocess
import threading
import time

GRANT_FIELDS = [
    "action", "workspace_id", "repository_identity", "base_commit",
    "model_id", "profile_id", "instruction_sha256", "allowed_test_profile",
    "maximum_files_changed", "maximum_patch_bytes", "maximum_job_seconds",
    "conversation_generation", "expiry_epoch", "nonce",
]

# The one command set each allowed_test_profile resolves to. The mapping
# lives here rather than in a request, so code.run_tests executes what the
# profile names and nothing a caller composes.
TEST_PROFILES = {
    "repository-quality-gates": ["sh", "scripts/repository-quality-gates.sh"],
    "fixture-echo": ["sh", "-c", "echo test-profile-ran"],
}

INSPECT_BYTE_CEILING = 262144


def parse_tsv(path):
    rows = []
    header = None
    for line in pathlib.Path(path).read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            candidate = line.lstrip("#").strip()
            if "\t" in candidate and candidate.split("\t")[0].isidentifier():
                header = [c.strip() for c in candidate.split("\t")]
            continue
        parts = [c.strip() for c in line.split("\t")]
        if header is None or len(parts) != len(header):
            raise ValueError("%s row has %d fields, header has %s"
                             % (path, len(parts),
                                len(header) if header else "none"))
        rows.append(dict(zip(header, parts)))
    return rows


class Refusal(Exception):
    def __init__(self, code, detail=""):
        super().__init__(code)
        self.code = code
        self.detail = detail


class Authorities:
    """One validated snapshot of every coding authority, read per request
    so a replacement between requests cannot separate admission from the
    rows acted on."""

    def __init__(self, arguments):
        self.profiles = {r["profile_id"]: r
                         for r in parse_tsv(arguments.profiles)}
        self.workspaces = {r["workspace_id"]: r
                           for r in parse_tsv(arguments.workspaces)}
        self.models = {r["model_id"]: r for r in parse_tsv(arguments.models)}
        self.quarantine = parse_tsv(arguments.quarantine)
        registry_rows = parse_tsv(arguments.registry)
        self.registry = {r["id"]: r for r in registry_rows}
        runtime_rows = parse_tsv(arguments.runtimes)
        self.runtimes = {r["id"]: r for r in runtime_rows}

    def quarantined(self, scope, subject):
        return any(r["scope"] == scope and r["subject"] == subject
                   for r in self.quarantine)

    def admit_profile(self, profile_id, model_id, workspace_id):
        profile = self.profiles.get(profile_id)
        if profile is None:
            raise Refusal("unknown_profile", profile_id)
        if profile["execution_policy"] != "validator-gated":
            raise Refusal("execution_refused", profile["execution_policy"])
        if profile["model_id"] != model_id:
            raise Refusal("model_outside_profile",
                          "%s vs %s" % (model_id, profile["model_id"]))
        if profile["workspace_id"] != workspace_id:
            raise Refusal("workspace_outside_profile", workspace_id)
        runtime = self.runtimes.get(profile["runtime_id"])
        if runtime is None:
            raise Refusal("unknown_runtime", profile["runtime_id"])
        for scope, subject in (("profile", profile_id), ("model", model_id),
                               ("workspace", workspace_id),
                               ("runtime", profile["runtime_id"])):
            if self.quarantined(scope, subject):
                raise Refusal("quarantined", "%s %s" % (scope, subject))
        coding_model = self.models.get(model_id)
        if coding_model is None:
            raise Refusal("model_outside_coding_lane", model_id)
        registry_row = self.registry.get(model_id)
        if registry_row is None:
            raise Refusal("model_outside_registry", model_id)
        validated_depth = registry_row.get("validated_filled_depth", "-")
        floor = int(coding_model["minimum_validated_depth"])
        if not validated_depth.isdigit() or int(validated_depth) < floor:
            raise Refusal("validated_depth_below_floor",
                          "%s < %d" % (validated_depth, floor))
        if int(profile["maximum_context"]) > int(validated_depth):
            raise Refusal("profile_context_exceeds_validated_depth",
                          profile["maximum_context"])
        workspace = self.workspaces.get(workspace_id)
        if workspace is None:
            raise Refusal("unknown_workspace", workspace_id)
        if profile["allowed_test_profile"] not in TEST_PROFILES:
            raise Refusal("unknown_test_profile",
                          profile["allowed_test_profile"])
        return profile, workspace


class Job:
    def __init__(self, job_id, profile, workspace, request):
        self.job_id = job_id
        self.profile = profile
        self.workspace = workspace
        self.model_id = request["model_id"]
        self.base_commit = request["base_commit"]
        self.instruction = request["instruction"]
        self.opened_epoch = time.time()
        self.deadline_epoch = (self.opened_epoch
                               + int(profile["maximum_job_seconds"]))
        self.state = "open"
        self.worktree = None
        self.mirror = None
        self.process_group = None
        self.events = []
        self.test_log = ""
        self.patch = None
        self.lock = threading.Lock()


class Service:
    def __init__(self, arguments):
        self.arguments = arguments
        self.state_directory = pathlib.Path(arguments.state_dir)
        self.state_directory.mkdir(parents=True, exist_ok=True)
        os.chmod(self.state_directory, 0o700)
        self.export_directory = self.state_directory / "export"
        self.export_directory.mkdir(exist_ok=True)
        self.spent_nonces = self.state_directory / "spent-nonces"
        self.spent_nonces.touch()
        key_path = pathlib.Path(arguments.grant_key_file)
        key_stat = key_path.stat()
        if not stat.S_ISREG(key_stat.st_mode):
            raise SystemExit("grant key %s is not a regular file" % key_path)
        if stat.S_IMODE(key_stat.st_mode) != 0o600:
            raise SystemExit("grant key %s carries mode %o, required 0600"
                             % (key_path, stat.S_IMODE(key_stat.st_mode)))
        self.grant_key = key_path.read_bytes().strip()
        if not self.grant_key:
            raise SystemExit("grant key %s is empty" % key_path)
        self.jobs = {}
        self.jobs_lock = threading.Lock()
        self.principal = arguments.principal

    # -- principal execution -------------------------------------------
    def principal_prefix(self):
        if self.principal == "current":
            return []
        return ["sudo", "-n", "-u", self.principal]

    def principal_run(self, command, **kwargs):
        return subprocess.run(self.principal_prefix() + command,
                              capture_output=True, text=True, **kwargs)

    # -- grants ---------------------------------------------------------
    def grant_signature(self, claim):
        message = "\n".join("%s=%s" % (field, claim[field])
                            for field in GRANT_FIELDS)
        return hmac.new(self.grant_key, message.encode(),
                        hashlib.sha256).hexdigest()

    def verify_grant(self, request):
        grant = request.get("grant")
        if not isinstance(grant, dict):
            raise Refusal("grant_missing")
        claim = grant.get("claim")
        signature = grant.get("signature", "")
        if not isinstance(claim, dict):
            raise Refusal("grant_missing_claim")
        missing = [f for f in GRANT_FIELDS if f not in claim]
        if missing:
            raise Refusal("grant_incomplete", ",".join(missing))
        if not hmac.compare_digest(self.grant_signature(claim),
                                   str(signature)):
            raise Refusal("grant_signature_invalid")
        if float(claim["expiry_epoch"]) < time.time():
            raise Refusal("grant_expired")
        # A changed model, workspace, base commit, instruction, or test
        # profile invalidates the grant: the claim is compared against the
        # request rather than trusted alone.
        instruction_sha256 = hashlib.sha256(
            request.get("instruction", "").encode()).hexdigest()
        bindings = {
            "action": "open_job",
            "workspace_id": request.get("workspace_id"),
            "model_id": request.get("model_id"),
            "profile_id": request.get("profile_id"),
            "base_commit": request.get("base_commit"),
            "instruction_sha256": instruction_sha256,
        }
        for field, expected in bindings.items():
            if claim[field] != expected:
                raise Refusal("grant_binding_mismatch", field)
        nonce = str(claim["nonce"])
        with self.jobs_lock:
            spent = self.spent_nonces.read_text().split()
            if nonce in spent:
                raise Refusal("grant_replayed")
            with self.spent_nonces.open("a") as handle:
                handle.write(nonce + "\n")
        return claim

    # -- worktree lifecycle --------------------------------------------
    def import_base(self, workspace, base_commit, job_id):
        repository = os.path.expandvars(workspace["repository_path"])
        probe = subprocess.run(
            ["git", "-C", repository, "cat-file", "-t", base_commit],
            capture_output=True, text=True)
        if probe.returncode != 0 or probe.stdout.strip() != "commit":
            raise Refusal("base_commit_unknown", base_commit)
        principal_home = pathlib.Path(self.arguments.principal_home)
        mirror = principal_home / "repos" / workspace["mirror"]
        result = self.principal_run(
            ["git", "init", "--bare", "-q", str(mirror)])
        if result.returncode != 0:
            raise Refusal("mirror_init_failed", result.stderr.strip())
        # The bundle is the hand-off across the ownership boundary: the
        # service reads the authoritative checkout, the principal reads
        # only the bundle, and the mirror gains exactly the approved
        # revision under a job-scoped ref.
        bundle_directory = pathlib.Path(self.arguments.bundle_dir)
        bundle_directory.mkdir(parents=True, exist_ok=True)
        os.chmod(bundle_directory, 0o755)
        bundle = bundle_directory / ("%s.bundle" % job_id)
        # git bundle writes refs rather than raw objects, so the approved
        # commit gets a job-scoped export ref for the duration of the
        # bundle write.
        export_ref = "refs/coding-export/%s" % job_id
        subprocess.run(["git", "-C", repository, "update-ref",
                        export_ref, base_commit],
                       capture_output=True, text=True)
        made = subprocess.run(
            ["git", "-C", repository, "bundle", "create", str(bundle),
             export_ref], capture_output=True, text=True)
        subprocess.run(["git", "-C", repository, "update-ref", "-d",
                        export_ref], capture_output=True, text=True)
        if made.returncode != 0:
            raise Refusal("bundle_failed", made.stderr.strip())
        os.chmod(bundle, 0o644)
        fetched = self.principal_run(
            ["git", "-C", str(mirror), "fetch", "-q", str(bundle),
             "%s:refs/import/%s" % (base_commit, job_id)])
        bundle.unlink(missing_ok=True)
        if fetched.returncode != 0:
            raise Refusal("mirror_import_failed", fetched.stderr.strip())
        worktree = principal_home / "worktrees" / job_id
        added = self.principal_run(
            ["git", "-C", str(mirror), "worktree", "add", "-q", "--detach",
             str(worktree), base_commit])
        if added.returncode != 0:
            raise Refusal("worktree_add_failed", added.stderr.strip())
        return mirror, worktree

    def remove_worktree(self, job):
        if job.worktree is None:
            return
        self.principal_run(["git", "-C", str(job.mirror), "worktree",
                            "remove", "--force", str(job.worktree)])
        self.principal_run(["rm", "-rf", str(job.worktree)])
        job.worktree = None

    # -- contained execution -------------------------------------------
    def contained_run(self, job, command, extra_env=None):
        """Run one command inside the job worktree: fresh process group,
        scrubbed environment, resource limits, and the job deadline with
        SIGTERM then SIGKILL of the whole group."""
        remaining = job.deadline_epoch - time.time()
        if remaining <= 0:
            raise Refusal("job_deadline_passed")
        environment = {
            "PATH": "/usr/bin:/bin",
            "HOME": str(job.worktree),
            "TMPDIR": str(job.worktree / ".job-tmp"),
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_SYSTEM": "/dev/null",
        }
        if extra_env:
            environment.update(extra_env)
        (job.worktree / ".job-tmp").mkdir(exist_ok=True)

        def limits():
            os.setsid()
            resource.setrlimit(resource.RLIMIT_CPU, (600, 600))
            resource.setrlimit(resource.RLIMIT_NOFILE, (1024, 1024))
            resource.setrlimit(resource.RLIMIT_FSIZE,
                               (1 << 30, 1 << 30))

        process = subprocess.Popen(
            self.principal_prefix() + command,
            cwd=str(job.worktree), env=environment,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, preexec_fn=limits)
        with job.lock:
            job.process_group = process.pid
        try:
            output, _ = process.communicate(timeout=remaining)
            returncode = process.returncode
            timed_out = False
        except subprocess.TimeoutExpired:
            self.kill_group(process.pid)
            output, _ = process.communicate()
            returncode = -9
            timed_out = True
        with job.lock:
            job.process_group = None
        return returncode, output[-262144:], timed_out

    @staticmethod
    def kill_group(process_group):
        """SIGTERM the group, then SIGKILL survivors: a child that traps
        SIGTERM leaves on SIGKILL, and the group id covers every fork."""
        for signal_number in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(process_group, signal_number)
            except ProcessLookupError:
                return
            deadline = time.time() + 2
            while time.time() < deadline:
                try:
                    os.killpg(process_group, 0)
                except ProcessLookupError:
                    return
                time.sleep(0.05)

    # -- path containment ----------------------------------------------
    @staticmethod
    def contain_path(worktree, requested):
        if requested.startswith("/") or requested.startswith("~"):
            raise Refusal("absolute_path_refused", requested)
        if ".." in pathlib.PurePosixPath(requested).parts:
            raise Refusal("traversal_refused", requested)
        # resolve() follows symlinks, so a link pointing outside the
        # worktree lands outside the containment check and is refused the
        # same way a traversal is.
        candidate = (worktree / requested).resolve()
        root = worktree.resolve()
        if candidate != root and root not in candidate.parents:
            raise Refusal("path_escapes_worktree", requested)
        return candidate

    # -- actions --------------------------------------------------------
    def action_open_job(self, request):
        authorities = Authorities(self.arguments)
        profile, workspace = authorities.admit_profile(
            request.get("profile_id", ""), request.get("model_id", ""),
            request.get("workspace_id", ""))
        claim = self.verify_grant(request)
        if claim["allowed_test_profile"] != profile["allowed_test_profile"]:
            raise Refusal("grant_binding_mismatch", "allowed_test_profile")
        for bound in ("maximum_files_changed", "maximum_patch_bytes",
                      "maximum_job_seconds"):
            if str(claim[bound]) != profile[bound]:
                raise Refusal("grant_binding_mismatch", bound)
        job_id = "job-%d-%s" % (int(time.time()), secrets.token_hex(4))
        job = Job(job_id, profile, workspace, request)
        job.mirror, job.worktree = self.import_base(
            workspace, job.base_commit, job_id)
        with self.jobs_lock:
            self.jobs[job_id] = job
        (self.export_directory / job_id).mkdir(exist_ok=True)
        return {"job_id": job_id, "worktree": str(job.worktree),
                "base_commit": job.base_commit,
                "deadline_epoch": job.deadline_epoch}

    def get_job(self, request, states=("open",), check_deadline=True):
        job = self.jobs.get(str(request.get("job_id")))
        if job is None:
            raise Refusal("unknown_job")
        if job.state not in states:
            raise Refusal("job_not_open", job.state)
        if check_deadline and time.time() > job.deadline_epoch:
            raise Refusal("job_deadline_passed")
        return job

    def action_inspect(self, request):
        job = self.get_job(request)
        target = self.contain_path(job.worktree,
                                   str(request.get("path", ".")))
        if target.is_dir():
            listing = sorted(
                str(p.relative_to(job.worktree))
                for p in target.iterdir() if p.name != ".job-tmp")
            return {"kind": "directory", "entries": listing}
        if not target.is_file():
            raise Refusal("path_absent", str(request.get("path")))
        data = target.read_bytes()[:INSPECT_BYTE_CEILING]
        return {"kind": "file",
                "content": data.decode("utf-8", "replace"),
                "bytes": target.stat().st_size}

    def agent_command(self, job, mode):
        override = self.arguments.agent_command
        if override:
            return [override, mode]
        runtime = Authorities(self.arguments).runtimes[
            job.profile["runtime_id"]]
        install_root = os.path.expandvars(self.arguments.runtime_root)
        executable = os.path.join(install_root, "candidate",
                                  runtime["executable"])
        return [executable, "--model", job.model_id,
                "--output-format", "stream-json", "--prompt",
                job.instruction if mode == "apply" else
                "Plan only, change nothing: %s" % job.instruction]

    def run_agent(self, job, mode):
        returncode, output, timed_out = self.contained_run(
            job, self.agent_command(job, mode),
            extra_env={"QWEN_CODING_JOB_ID": job.job_id})
        job.events.append({"mode": mode, "returncode": returncode,
                           "timed_out": timed_out, "output": output})
        if timed_out:
            job.state = "expired"
            raise Refusal("job_timed_out")
        return returncode, output

    def action_plan(self, request):
        job = self.get_job(request)
        returncode, output = self.run_agent(job, "plan")
        return {"returncode": returncode, "plan": output}

    def action_apply_patch(self, request):
        job = self.get_job(request)
        returncode, output = self.run_agent(job, "apply")
        diff = self.job_diff(job)
        changed = [line[2:] for line in diff["name_status"].splitlines()
                   if line]
        if len(changed) > int(job.profile["maximum_files_changed"]):
            self.reset_worktree(job)
            raise Refusal("files_changed_over_bound",
                          "%d > %s" % (len(changed),
                                       job.profile["maximum_files_changed"]))
        if len(diff["patch"].encode()) > int(
                job.profile["maximum_patch_bytes"]):
            self.reset_worktree(job)
            raise Refusal("patch_bytes_over_bound",
                          str(len(diff["patch"].encode())))
        job.patch = diff
        return {"returncode": returncode, "diffstat": diff["diffstat"],
                "changed_files": changed}

    def reset_worktree(self, job):
        # reset --hard clears the intent-to-add entries job_diff planted,
        # so the clean that follows sees the new files as untracked and
        # removes them.
        self.principal_run(["git", "-C", str(job.worktree), "reset", "-q",
                            "--hard", job.base_commit])
        self.principal_run(["git", "-C", str(job.worktree), "clean",
                            "-qfdx"])

    def job_diff(self, job):
        def read(git_arguments):
            result = self.principal_run(
                ["git", "-C", str(job.worktree)] + git_arguments)
            return result.stdout
        self.principal_run(["git", "-C", str(job.worktree), "add", "-N",
                            "--", "."])
        return {
            "patch": read(["diff", "--binary", job.base_commit, "--"]),
            "diffstat": read(["diff", "--stat", job.base_commit, "--"]),
            "name_status": read(["diff", "--name-status", job.base_commit,
                                 "--"]),
        }

    def action_run_tests(self, request):
        job = self.get_job(request)
        command = TEST_PROFILES[job.profile["allowed_test_profile"]]
        returncode, output, timed_out = self.contained_run(job, command)
        if timed_out:
            job.state = "expired"
            raise Refusal("job_timed_out")
        job.test_log = output
        return {"returncode": returncode, "log": output[-65536:]}

    def action_review_diff(self, request):
        job = self.get_job(request)
        diff = job.patch or self.job_diff(job)
        return {"patch": diff["patch"], "diffstat": diff["diffstat"],
                "changed_files": [line[2:] for line
                                  in diff["name_status"].splitlines()
                                  if line]}

    def action_finish(self, request):
        job = self.get_job(request)
        diff = job.patch or self.job_diff(job)
        tree = self.principal_run(
            ["git", "-C", str(job.worktree), "write-tree"])
        if tree.returncode != 0:
            self.principal_run(["git", "-C", str(job.worktree), "add",
                                "-A", "--", "."])
            tree = self.principal_run(
                ["git", "-C", str(job.worktree), "write-tree"])
        export = self.export_directory / job.job_id
        (export / "patch.diff").write_text(diff["patch"])
        (export / "diffstat.txt").write_text(diff["diffstat"])
        (export / "changed-files.txt").write_text(diff["name_status"])
        (export / "test.log").write_text(job.test_log)
        (export / "events.jsonl").write_text(
            "".join(json.dumps(e) + "\n" for e in job.events))
        (export / "base-commit").write_text(job.base_commit + "\n")
        (export / "result-tree").write_text(tree.stdout.strip() + "\n")
        self.remove_worktree(job)
        job.state = "finished"
        return {"export": str(export),
                "result_tree": tree.stdout.strip()}

    def action_cancel(self, request):
        job = self.get_job(request, states=("open", "expired"),
                           check_deadline=False)
        with job.lock:
            group = job.process_group
        if group:
            self.kill_group(group)
        self.remove_worktree(job)
        job.state = "cancelled"
        return {"state": "cancelled"}

    def handle(self, request):
        action = request.get("action")
        handlers = {
            "open_job": self.action_open_job,
            "inspect": self.action_inspect,
            "plan": self.action_plan,
            "apply_patch": self.action_apply_patch,
            "run_tests": self.action_run_tests,
            "review_diff": self.action_review_diff,
            "finish": self.action_finish,
            "cancel": self.action_cancel,
            "health": lambda _: {"state": "listening",
                                 "principal": self.principal,
                                 "pid": os.getpid()},
        }
        handler = handlers.get(action)
        if handler is None:
            raise Refusal("unknown_action", str(action))
        return handler(request)


def serve(service, arguments):
    socket_path = pathlib.Path(arguments.socket)
    socket_path.unlink(missing_ok=True)

    class Handler(socketserver.StreamRequestHandler):
        def handle(self):
            line = self.rfile.readline(1 << 20)
            try:
                request = json.loads(line)
                if not isinstance(request, dict):
                    raise ValueError("request is not an object")
                reply = {"ok": True, "result": service.handle(request)}
            except Refusal as refusal:
                reply = {"ok": False, "error": refusal.code,
                         "detail": refusal.detail}
            except Exception as error:  # sanitized internal error
                reply = {"ok": False, "error": "internal",
                         "detail": type(error).__name__}
            self.wfile.write((json.dumps(reply) + "\n").encode())

    class ThreadedServer(socketserver.ThreadingMixIn,
                         socketserver.UnixStreamServer):
        daemon_threads = True

    server = ThreadedServer(str(socket_path), Handler)
    os.chmod(socket_path, 0o600)
    print("coding_agent_service=listening socket=%s principal=%s pid=%d"
          % (socket_path, service.principal, os.getpid()), flush=True)

    def terminate(_signal, _frame):
        for job in list(service.jobs.values()):
            with job.lock:
                group = job.process_group
            if group:
                service.kill_group(group)
            service.remove_worktree(job)
        socket_path.unlink(missing_ok=True)
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)
    server.serve_forever()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--socket", required=True)
    parser.add_argument("--profiles", required=True)
    parser.add_argument("--workspaces", required=True)
    parser.add_argument("--models", required=True)
    parser.add_argument("--quarantine", required=True)
    parser.add_argument("--registry", required=True)
    parser.add_argument("--runtimes", required=True)
    parser.add_argument("--grant-key-file", required=True)
    parser.add_argument("--principal", default="qwen-coder")
    parser.add_argument("--principal-home", default="/var/lib/qwen-coder")
    parser.add_argument("--bundle-dir", default="/tmp/qwen-coding-bundles")
    parser.add_argument("--runtime-root",
                        default="$HOME/tools/qwen-code")
    parser.add_argument("--agent-command", default="")
    arguments = parser.parse_args()
    Authorities(arguments)  # startup validation of every authority
    service = Service(arguments)
    serve(service, arguments)


if __name__ == "__main__":
    main()
