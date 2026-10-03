"""Run one bounded Graft arm through the guarded, nonce-owned serving chain.

Wire capture grades the installed client's requests, including retries, rather
than a hand-written prompt replica. Graph completion and source accuracy remain
separate gates. Raw captures belong in the repository's local artifact area.
"""

# gpu-ownership: delegated to the serving chain.

import argparse
import concurrent.futures
import importlib.util
import json
import hashlib
import os
from pathlib import Path
import re
import signal
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import urllib.error
import urllib.request
import uuid


SCRIPTS = Path(__file__).resolve().parent
specification = importlib.util.spec_from_file_location(
    "contract", SCRIPTS / "record-symbols-contract.py"
)
CONTRACT = importlib.util.module_from_spec(specification)
specification.loader.exec_module(CONTRACT)
SOURCE_COMMIT = "0c85040e3bda01913d687fca538b3fa49f6af82b"
SCOPE_DENOMINATORS = {"pilot": (22, 243), "contract": (3, 7)}


def validate_graph_scope(graph_path, scope):
    graph = json.loads(graph_path.read_text())
    counts = (sum(node.get("kind") == "file" for node in graph["nodes"]),
              sum(node.get("kind") in ("function", "class", "type") for node in graph["nodes"]))
    if counts != SCOPE_DENOMINATORS[scope]:
        raise ValueError(f"structural scope mismatch: {counts} != {SCOPE_DENOMINATORS[scope]}")
    return {"files": counts[0], "describable_symbols": counts[1]}


def write_accuracy_sample(output, graph_path):
    fixed_sample = SCRIPTS.parent / "evidence/ada/graft-deep-pilot/accuracy-sample.txt"
    identifiers = re.findall(r"^(sys/[^\s]+#[^\s]+)\s+L", fixed_sample.read_text(), re.MULTILINE)
    if len(identifiers) != 10 or len(set(identifiers)) != 10:
        raise ValueError("fixed source-accuracy sample must contain ten distinct IDs")
    nodes = {node["id"]: node for node in json.loads(graph_path.read_text())["nodes"]}
    rows = []
    for identifier in identifiers:
        node = nodes.get(identifier)
        if node is None:
            raise ValueError(f"fixed accuracy ID absent from structural graph: {identifier}")
        rows.append({"id": identifier, "span": node.get("span"),
                     "summary_state": node.get("summary_state"), "summary": node.get("summary"),
                     "semantic_verdict": "requires_source_review"})
    write_json(output / "accuracy-sample.json", rows)


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def run_command(command, output, environment, deadline):
    with output.open("wb") as log:
        child = subprocess.Popen(
            command, stdout=log, stderr=subprocess.STDOUT,
            env=environment, start_new_session=True,
        )
        try:
            return child.wait(timeout=deadline)
        except BaseException:
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
            raise


def output_is_owned(output, repository=SCRIPTS.parent):
    common = Path(subprocess.check_output(
        ["git", "-C", str(repository), "rev-parse", "--git-common-dir"], text=True,
    ).strip())
    common = (repository / common).resolve() if not common.is_absolute() else common.resolve()
    roots = {repository.resolve() / ".local-artifacts", common.parent / ".local-artifacts"}
    resolved = output.resolve()
    return any(resolved != root and resolved.is_relative_to(root.resolve()) for root in roots)


def fixed_environment(environment, options, nonce):
    for name in list(environment):
        if name.startswith(("QWEN_SPEC_", "QWEN_DRAFT_")):
            environment.pop(name)
    environment.update(
        QWEN_MODEL_PATH=str(options.model.resolve()), QWEN_CHAT_TOOLS="on",
        QWEN_CHAT_REASONING=options.reasoning, QWEN_CHAT_REASONING_BUDGET="512",
        QWEN_CONTEXT_SIZE=str(options.context), QWEN_REQUIRE_API_KEY="1",
        QWEN_GRAFT_EXPERIMENT_SLOTS=str(options.slots), QWEN_BIND_HOST="127.0.0.1",
        QWEN_LAUNCH_ATTEMPT_NONCE=nonce, QWEN_MMPROJ="",
        QWEN_BATCH_SIZE="128", QWEN_UBATCH_SIZE="32", QWEN_SERVING_THREADS="6",
        QWEN_BACKEND_SAMPLING="0", QWEN_SPEC_TYPE="",
    )


def validate_server_argv(argv, options):
    for flag, expected in (("--parallel", str(options.slots)), ("--reasoning", options.reasoning),
                           ("--ctx-size", str(options.context)), ("--device", "CUDA0"),
                           ("--batch-size", "128"), ("--ubatch-size", "32"),
                           ("--threads", "6"), ("--threads-batch", "6")):
        if flag not in argv or argv[argv.index(flag) + 1] != expected:
            raise RuntimeError(f"live server argument mismatch: {flag}")
    if "--jinja" not in argv:
        raise RuntimeError("live server omitted --jinja")
    if any(argument == "--mmproj" or argument.startswith("--mmproj=") for argument in argv):
        raise RuntimeError("text-only arm loaded a projector")
    if any(argument.startswith(("--spec-", "--draft", "--model-draft"))
           or argument.split("=", 1)[0] in ("-md", "--backend-sampling") for argument in argv):
        raise RuntimeError("fixed arm loaded speculative decoding or backend sampling")


def validate_geometry(slots, context):
    if slots not in (1, 2) or context != 16384 * slots:
        raise ValueError("fixed geometry requires 16384 context per slot: 16384 or 32768 total")


def graft_identity(executable):
    resolved = executable.resolve(strict=True)
    if resolved.name != "cli.js" or resolved.parent.name != "dist":
        raise ValueError("Graft executable must resolve to the npm package dist/cli.js")
    package_root = resolved.parent.parent
    package_metadata = package_root / "package.json"
    package = json.loads(package_metadata.read_text())
    if package.get("name") != "@nanonets/graft" or not package.get("version"):
        raise ValueError("Graft package metadata identity mismatch")
    return {"executable": str(executable.absolute()), "resolved_executable": str(resolved),
            "executable_sha256": hashlib.sha256(resolved.read_bytes()).hexdigest(),
            "package_root": str(package_root), "package_name": package["name"],
            "package_version": package["version"],
            "package_metadata_sha256": hashlib.sha256(package_metadata.read_bytes()).hexdigest()}


def finalize_completion(metadata, session_owned):
    if metadata.get("state") != "completed":
        return
    if not session_owned:
        metadata.update(state="void", completion_error="final session ownership lost")
    elif metadata.get("teardown_status") != 0:
        metadata.update(state="failed", completion_error="successful owned teardown receipt required")


def completion_state(deep_status, session_owned):
    if deep_status != 0:
        return "failed"
    return "completed" if session_owned else "void"


def classify_guards(metadata, output):
    telemetry = output / "telemetry.log"
    session = output / "session.status"
    kernel = output / "kernel-hazards.log"
    if ((telemetry.exists() and "abort_utc=" in telemetry.read_text())
            or (session.exists() and re.search(r"(?:kernel_hazard|monitor)_status=[1-9]", session.read_text()))
            or (kernel.exists() and re.search(r"^hazard_utc=", kernel.read_text(), re.MULTILINE))):
        metadata["state"] = "void"


def record_teardown(metadata, status):
    metadata["teardown_status"] = status
    if status != 0:
        metadata.update(state="failed", teardown_error="owned teardown failed")
        metadata.setdefault("error", metadata["teardown_error"])


def summarize_usage(output, records):
    """Keep omitted usage distinct from a measured zero."""
    totals = {name: 0 for name in ("prompt_tokens", "completion_tokens", "reasoning_tokens")}
    available = {name: 0 for name in totals}
    for record in records:
        if record.get("status") != 200:
            continue
        response = json.loads((output / f"wire-{record['request_id']:04d}.response.json").read_text())
        usage = response.get("usage") or {}
        values = {"prompt_tokens": usage.get("prompt_tokens"),
                  "completion_tokens": usage.get("completion_tokens"),
                  "reasoning_tokens": (usage.get("completion_tokens_details") or {}).get("reasoning_tokens")}
        for name, value in values.items():
            if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
                available[name] += 1
                totals[name] += value
    return {name: {"sum_available": totals[name], "requests_available": available[name],
                   "requests_missing": sum(record.get("status") == 200 for record in records) - available[name]}
            for name in totals}


def owns_session(nonce):
    observed = subprocess.run(
        ["tmux", "-L", "qwen-runtime", "show-environment", "-t",
         "qwen-webui", "QWEN_LAUNCH_ATTEMPT_NONCE"],
        capture_output=True, text=True, check=False,
    )
    return observed.returncode == 0 and observed.stdout.strip() == (
        "QWEN_LAUNCH_ATTEMPT_NONCE=" + nonce
    )


class Capture:
    def __init__(self, output, upstream, key, deadline=None):
        self.output = output
        self.upstream = upstream
        self.key = key
        self.lock = threading.Lock()
        self.records = []
        self.deadline = deadline if deadline is not None else time.monotonic() + 240

    def handler(self):
        capture = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_arguments):
                pass

            def do_POST(self):
                if self.path != "/v1/chat/completions":
                    self.send_error(404)
                    return
                if self.headers.get("Authorization") != "Bearer " + capture.key:
                    self.send_error(401)
                    return
                payload = self.rfile.read(int(self.headers["Content-Length"]))
                with capture.lock:
                    request_id = len(capture.records)
                    record = {"request_id": request_id, "started": time.monotonic()}
                    capture.records.append(record)
                stem = capture.output / f"wire-{request_id:04d}"
                stem.with_suffix(".request.json").write_bytes(payload)
                request = urllib.request.Request(
                    capture.upstream + self.path, payload,
                    {"Content-Type": "application/json",
                     "Authorization": "Bearer " + capture.key},
                )
                try:
                    remaining = capture.deadline - time.monotonic()
                    record["upstream_timeout_seconds"] = remaining
                    if remaining <= 0:
                        raise TimeoutError("arm deadline reached")
                    with urllib.request.urlopen(request, timeout=remaining) as response:
                        status, body = response.status, response.read()
                except urllib.error.HTTPError as error:
                    status, body = error.code, error.read()
                except (urllib.error.URLError, TimeoutError, OSError) as error:
                    status = 502
                    body = json.dumps({"error": type(error).__name__}).encode()
                stem.with_suffix(".response.json").write_bytes(body)
                record.update(status=status, ended=time.monotonic())
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                try:
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass

        return Handler


def grade_wire(output, graph, records, label):
    grades = ["\t".join(CONTRACT.COLUMNS)]
    for record in records:
        stem = output / f"wire-{record['request_id']:04d}"
        request = json.loads(stem.with_suffix(".request.json").read_text())
        if request.get("tool_choice") != {
            "type": "function", "function": {"name": "record_symbols"}
        }:
            continue
        user_text = request["messages"][-1]["content"]
        file_match = re.search(r"^FILE: (.+)$", user_text, re.MULTILINE)
        if file_match is None:
            raise ValueError("record_symbols request omitted FILE attribution")
        relative_path = file_match.group(1)
        selected_ids = re.findall(r"^- id=(.*?) \|", user_text, re.MULTILINE)
        reference = {row["id"]: row for row in CONTRACT.load_targets(graph, relative_path)}
        # The installed Graft client requests a file record beside its symbols.
        # The whole-file range supports shape, while focal-span fidelity remains
        # withheld because a file is not one describable definition.
        graph_data = json.loads(Path(graph).read_text())
        for node in graph_data["nodes"]:
            if node.get("path") == relative_path and node.get("kind") == "file":
                start, end = CONTRACT.parse_span(node)
                reference[node["id"]] = {
                    "id": node["id"], "kind": "file", "start": start, "end": end,
                    "signature": "", "gradeable": False,
                }
        rows = [reference[identifier] for identifier in selected_ids]
        if not rows or len(set(selected_ids)) != len(rows):
            raise ValueError("record_symbols request has empty or duplicated targets")
        grades.append(CONTRACT.check(
            stem.with_suffix(".response.json"), rows, label, relative_path,
            str(round(1000 * (record["ended"] - record["started"]))),
            str(record["status"]),
        ))
    (output / "symbols.tsv").write_text("\n".join(grades) + "\n")
    return len(grades) - 1


def main():
    def interrupt(_signal_number, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGHUP, interrupt)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--reasoning", choices=["on", "off"], required=True)
    parser.add_argument("--slots", type=int, choices=[1, 2], default=1)
    parser.add_argument("--context", type=int, default=16384)
    parser.add_argument("--deadline", type=int, default=1200)
    parser.add_argument("--scope", choices=list(SCOPE_DENOMINATORS), default="pilot")
    parser.add_argument("--graft-executable", type=Path, default=Path("/usr/bin/graft"))
    options = parser.parse_args()
    try:
        validate_geometry(options.slots, options.context)
    except ValueError as error:
        parser.error(str(error))
    if options.deadline < 1:
        parser.error("arm deadline must be positive")
    if not options.model.is_file() or not options.source.is_dir():
        parser.error("source directory and verified model file must exist")
    if not output_is_owned(options.output):
        parser.error("raw output belongs under the owning repository .local-artifacts")
    environment = os.environ.copy()
    if not environment.get("PYTHON"):
        parser.error("select PYTHON in the caller")
    options.output.mkdir(parents=True, exist_ok=False)
    source_commit = subprocess.check_output(
        ["git", "-C", str(options.source), "rev-parse", "HEAD"], text=True,
    ).strip()
    if source_commit != SOURCE_COMMIT:
        parser.error("benchmark source must match the fixed pilot revision")
    source_status = subprocess.check_output(
        ["git", "-C", str(options.source), "status", "--porcelain", "--untracked-files=all"], text=True,
    )
    if source_status:
        parser.error("fixed benchmark source requires a clean detached worktree")
    state = Path(environment.get("QWEN_WEBUI_STATE_DIRECTORY", str(Path.home() / "qwen-webui-state")))
    nonce = uuid.uuid4().hex
    fixed_environment(environment, options, nonce)
    metadata = vars(options).copy()
    metadata = {key: str(value) if isinstance(value, Path) else value for key, value in metadata.items()}
    metadata.update(source_commit=source_commit, nonce=nonce, state="running")
    write_json(options.output / "arm.json", metadata)
    sampler = proxy = executor = None
    capture = None
    try:
        client = graft_identity(options.graft_executable)
        metadata["graft_identity"] = client
        write_json(options.output / "graft-identity.json", client)
        executable = client["resolved_executable"]
        if run_command([executable, "--dir", str(options.output / "graph"), "build", str(options.source)],
                       options.output / "structural.log", environment, 60) != 0:
            raise RuntimeError("bounded structural build failed")
        graph = options.output / "graph" / ".graph" / "wiring.json"
        metadata["denominator"] = validate_graph_scope(graph, options.scope)
        registry = subprocess.check_output(
            [str(SCRIPTS / "model-registry.sh"), "path", str(options.model.resolve())], text=True,
        )
        fields = dict(line.split("=", 1) for line in registry.splitlines())
        if fields["id"] not in ("qwen38-4b-distill", "qwen35-4b-base", "granite40-micro"):
            raise RuntimeError("model falls outside the requested three-artifact matrix")
        metadata["model_id"] = fields["id"]
        if run_command([str(SCRIPTS / fields["fetch_script"]), str(options.model.resolve().parent)],
                       options.output / "model-verification.log", environment, 120) != 0:
            raise RuntimeError("pinned model verification failed")
        reader_ready = False
        for command in (["dmesg", "--color=never"], ["sudo", "-n", "dmesg", "--color=never"]):
            result = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                    timeout=10, check=False)
            if result.returncode == 0:
                reader_ready = True
                break
        if not reader_ready:
            raise RuntimeError("kernel guard requires a readable dmesg; renew sudo with sudo -v")
        with options.model.open("rb") as model_file:
            metadata["model_sha256"] = hashlib.file_digest(model_file, "sha256").hexdigest()
        status = run_command([str(SCRIPTS / "qwen-launch.sh"), "default"],
                             options.output / "launch.log", environment, 360)
        if status != 0 or not owns_session(nonce):
            raise RuntimeError(f"launch refused or ownership unproven: {status}")
        session_status = (state / "session.status").read_text()
        if "gpu_owner" not in session_status:
            raise RuntimeError("serving session omitted GPU ownership receipt")
        server_pid = int((state / "server.pid").read_text().strip())
        arguments = Path(f"/proc/{server_pid}/cmdline").read_bytes().split(b"\0")
        argv = [value.decode() for value in arguments if value]
        write_json(options.output / "server-argv.json", argv)
        metadata["server_pid"] = server_pid
        for command, receipt in (([str(SCRIPTS / "hash-load-closure.sh"), argv[0]], "closure.tsv"),
                                 ([str(SCRIPTS / "device-environment-identity.sh")], "device-environment.tsv")):
            if run_command(command, options.output / receipt, environment, 30) != 0:
                raise RuntimeError(f"identity probe failed: {receipt}")
        validate_server_argv(argv, options)
        sampler = subprocess.Popen([str(SCRIPTS / "sample-nvidia-clocks.sh"),
                                    str(options.output / "gpu.tsv"), "1"], env=environment)
        key = (state / "api.key").read_text().strip()
        port = environment.get("QWEN_SERVER_PORT", "8080")
        capture = Capture(options.output, "http://127.0.0.1:" + port, key,
                          deadline=time.monotonic() + options.deadline)
        metadata["proxy_timeout_policy"] = "remaining_arm_deadline"
        proxy = ThreadingHTTPServer(("127.0.0.1", 0), capture.handler())
        executor = concurrent.futures.ThreadPoolExecutor(max_workers=1)
        executor.submit(proxy.serve_forever)
        environment.update(GRAFT_PROVIDER="openai", GRAFT_MODEL="qwen-nvidia", GRAFT_API_KEY=key,
                           GRAFT_BASE_URL=f"http://127.0.0.1:{proxy.server_port}/v1", GRAFT_NO_IGNORE="1")
        started = time.monotonic()
        if graft_identity(options.graft_executable) != client:
            raise RuntimeError("Graft client identity changed after structural admission")
        status = run_command([executable, "--dir", str(options.output / "graph"), "build", "--deep",
                              "--allow-partial", "-j", str(options.slots), str(options.source)],
                             options.output / "deep.log", environment, options.deadline)
        elapsed = time.monotonic() - started
        proxy.shutdown()
        executor.shutdown(wait=True)
        executor = None
        write_json(options.output / "requests.json", capture.records)
        completed_requests = sum(record.get("status") == 200 for record in capture.records)
        metadata.update(deep_status=status, elapsed_seconds=elapsed,
                        total_requests=len(capture.records), completed_requests=completed_requests,
                        failed_requests=len(capture.records) - completed_requests,
                        requests_per_second=completed_requests / elapsed)
        metadata["usage"] = summarize_usage(options.output, capture.records)
        graph = options.output / "graph" / ".graph" / "wiring.json"
        metadata["contract_requests"] = grade_wire(options.output, graph, capture.records, options.label)
        if options.scope == "pilot":
            write_accuracy_sample(options.output, graph)
        if run_command([environment["PYTHON"], str(SCRIPTS / "graft-deep-evidence.py"),
                        str(options.output / "graph")], options.output / "graph-evidence.tsv", environment, 30) != 0:
            raise RuntimeError("graph evidence probe failed")
        metadata["state"] = completion_state(status, owns_session(nonce))
        if status != 0:
            metadata["error"] = f"deep build failed with status {status}"
    except (Exception, KeyboardInterrupt) as error:
        metadata.update(state="failed", error=f"{type(error).__name__}: {error}")
        raise
    finally:
        if proxy is not None:
            proxy.shutdown()
            proxy.server_close()
        if executor is not None:
            executor.shutdown(wait=True)
        if capture is not None:
            write_json(options.output / "requests.json", capture.records)
        if sampler is not None:
            sampler.terminate()
            sampler.wait(timeout=10)
        session_owned = owns_session(nonce)
        if session_owned:
            for name in ("server.log", "telemetry.log", "session.status", "kernel-hazards.log"):
                source = state / name
                if source.exists():
                    (options.output / name).write_bytes(source.read_bytes())
            teardown_status = run_command([str(SCRIPTS / "qwen-teardown.sh")],
                                          options.output / "teardown.log", environment, 60)
            record_teardown(metadata, teardown_status)
        for name in ("server.log", "telemetry.log", "session.status", "kernel-hazards.log"):
            source = state / name
            if source.exists() and metadata.get("teardown_status") is not None:
                (options.output / name).write_bytes(source.read_bytes())
        classify_guards(metadata, options.output)
        finalize_completion(metadata, session_owned)
        write_json(options.output / "arm.json", metadata)
    if metadata["state"] != "completed":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
