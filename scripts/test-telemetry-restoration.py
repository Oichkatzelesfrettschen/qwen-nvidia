#!/usr/bin/env python3
"""Exercise exact telemetry capture and restoration against an isolated service."""

import contextlib
import fcntl
import importlib.util
import json
import os
import pathlib
import signal
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest.mock
import urllib.request


ROOT = pathlib.Path(__file__).resolve().parent
PROGRAM = ROOT / "telemetry-restoration.py"
CLEANUP_PROGRAM = ROOT / "campaign-cleanup-record.py"
SERVER = ROOT / "test-fixtures" / "fake-telemetry-server.py"
FIXTURE_OWNER = ROOT / "test-fixtures" / "fake-telemetry-owner.py"


def load_restoration_module():
    specification = importlib.util.spec_from_file_location("telemetry_restoration", PROGRAM)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def write_fake_stat(proc_root, pid, parent_pid, start_ticks):
    stat_fields = ["S", str(parent_pid)] + ["0"] * 20
    stat_fields[19] = start_ticks
    (proc_root / str(pid) / "stat").write_text(
        f"{pid} (fixture process) {' '.join(stat_fields)}\n", encoding="utf-8")


def write_fake_process(proc_root, pid, parent_pid, descriptor_target=None, start_ticks="100"):
    process_root = proc_root / str(pid)
    (process_root / "fd").mkdir(parents=True)
    write_fake_stat(proc_root, pid, parent_pid, start_ticks)
    if descriptor_target is not None:
        (process_root / "fd" / "9").symlink_to(descriptor_target)


def fake_identities(*rows):
    return {pid: (parent_pid, start_ticks) for pid, parent_pid, start_ticks in rows}


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def wait_health(url):
    for _ in range(100):
        try:
            with urllib.request.urlopen(url, timeout=0.2) as response:
                if json.load(response).get("status") == "ok":
                    return
        except OSError:
            time.sleep(0.02)
    raise AssertionError(f"service did not answer {url}")


def stop_pid(pid):
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    for _ in range(100):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.01)
    os.kill(pid, signal.SIGKILL)


def run_restore(snapshot, record, pid_file, lease, owner_lock, latch, campaign_record,
                program=PROGRAM, timeout="2"):
    command = [sys.executable, str(program), "restore", "--snapshot", str(snapshot),
               "--record", str(record), "--compute-lease", str(lease),
               "--owner-lock", str(owner_lock),
               "--restored-pid-file", str(pid_file), "--campaign-record",
               str(campaign_record), "--campaign-nonce", "fixture-nonce",
               "--campaign-revision", "fixture-revision",
               "--campaign-script-sha256", "fixture-script-digest", f"--timeout={timeout}"]
    return subprocess.run(command, text=True, capture_output=True, check=False)


def assert_blocked(result, record, reason):
    assert result.returncode == 4, result.stderr
    payload = json.loads(record.read_text())
    assert payload["restoration"] == "blocked" and payload["reason"] == reason, payload


def extracted_finalizer_fixture(root, snapshot, restored_pid_file, owner_lock,
                                mode, exit_status=0, restore_timeout="300"):
    source = (ROOT / "run-closure-identity-ab.sh").read_text(encoding="utf-8")
    begin = source.index("server_pid=''\n")
    end_marker = "trap 'exit 143' TERM\n"
    end = source.index(end_marker, begin) + len(end_marker)
    exact_block = source[begin:end]
    fixture_output = root / f"finalizer-{mode}"
    fixture_output.mkdir()
    lifecycle = fixture_output / "campaign-lifecycle.tsv"
    lifecycle.write_text("run_nonce\trevision\tscript_sha256\tsession_id\tpid\tstart_ticks\trole\n",
                         encoding="utf-8")
    cleanup = fixture_output / "campaign-cleanup.json"
    restore_record = fixture_output / "telemetry-restoration.json"
    fixture = fixture_output / "run.sh"
    fixture.write_text(
        "#!/bin/sh\nset -eu\n"
        "sleep() { :; }\n"
        f"script_directory={str(ROOT)!r}\noutput_directory={str(fixture_output)!r}\n"
        f"campaign_lifecycle={str(lifecycle)!r}\ncampaign_cleanup_record={str(cleanup)!r}\n"
        "campaign_run_nonce=fixture-nonce\ncampaign_revision=fixture-revision\n"
        "campaign_script_sha256=fixture-script-digest\n"
        f"QWEN_TELEMETRY_RESTORE_SNAPSHOT={str(snapshot)!r}\n"
        f"QWEN_TELEMETRY_RESTORED_PID_FILE={str(restored_pid_file)!r}\n"
        f"QWEN_TELEMETRY_RESTORE_RECORD={str(restore_record)!r}\n"
        f"telemetry_restore_ready_seconds={str(restore_timeout)!r}\n"
        "export QWEN_TELEMETRY_RESTORE_SNAPSHOT QWEN_TELEMETRY_RESTORED_PID_FILE QWEN_TELEMETRY_RESTORE_RECORD\n"
        + exact_block +
        f"exec 9>{str(owner_lock)!r}\nflock -n 9\n"
        + ("setsid sh -c 'trap \"\" TERM; /usr/bin/sleep 30 & wait' &\n" if mode == "residue"
           else "setsid /usr/bin/sleep 30 &\n") +
        "server_pid=$!\nserver_start_ticks=$(sed 's/.*) //' /proc/$server_pid/stat | awk '{ print $20 }')\n"
        "while [ \"$(sed 's/.*) //' /proc/$server_pid/stat | awk '{ print $4 }')\" != \"$server_pid\" ]; do /usr/bin/sleep 0.01; done\n"
        "server_session_id=$server_pid\n"
        "record_process_identity \"$server_pid\" server\n"
        + ("server_start_ticks=forged-start\n" if mode == "identity-mismatch" else "") +
        "sleep 0.05\nrecord_process_tree \"$server_pid\"\n"
        f"exit {exit_status}\n",
        encoding="utf-8")
    fixture.chmod(0o700)
    result = subprocess.run([str(fixture)], text=True, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, check=False)
    return result, cleanup, restore_record


with (tempfile.TemporaryDirectory(prefix="telemetry-restore-", dir=os.environ.get("TMPDIR")) as temporary,
      contextlib.ExitStack() as resources):
    root = pathlib.Path(temporary)
    restoration = load_restoration_module()
    owner_boundary_lock = root / "owner-boundary.lock"
    owner_boundary_lock.touch()

    holder_proc = root / "holder-proc"
    write_fake_process(holder_proc, 410, 420, owner_boundary_lock)
    write_fake_process(holder_proc, 420, 430)
    write_fake_process(holder_proc, 430, 1)
    assert restoration.lineage_holds_file(
        410, 420, owner_boundary_lock, holder_proc,
        fake_identities((410, 420, "100"), (420, 430, "100"))) == 410
    (holder_proc / "410" / "fd" / "9").unlink()
    (holder_proc / "420" / "fd" / "9").symlink_to(owner_boundary_lock)
    assert restoration.lineage_holds_file(
        410, 420, owner_boundary_lock, holder_proc,
        fake_identities((410, 420, "100"), (420, 430, "100"))) == 420

    bounded_proc = root / "bounded-proc"
    write_fake_process(bounded_proc, 510, 520)
    write_fake_process(bounded_proc, 520, 530)
    write_fake_process(bounded_proc, 530, 1)
    (bounded_proc / "530" / "fd").rmdir()
    (bounded_proc / "530" / "fd").write_text("outside boundary", encoding="utf-8")
    assert restoration.lineage_holds_file(
        510, 520, owner_boundary_lock, bounded_proc,
        fake_identities((510, 520, "100"), (520, 530, "100"))) is None

    missing_proc = root / "missing-proc"
    write_fake_process(missing_proc, 610, 620)
    try:
        restoration.lineage_holds_file(
            610, 620, owner_boundary_lock, missing_proc,
            fake_identities((610, 620, "100"), (620, 1, "100")))
    except FileNotFoundError:
        pass
    else:
        raise AssertionError("missing declared owner produced an unheld lock claim")

    unreadable_proc = root / "unreadable-proc"
    write_fake_process(unreadable_proc, 710, 720)
    write_fake_process(unreadable_proc, 720, 1)
    (unreadable_proc / "720" / "fd").rmdir()
    (unreadable_proc / "720" / "fd").write_text("unreadable boundary", encoding="utf-8")
    try:
        restoration.lineage_holds_file(
            710, 720, owner_boundary_lock, unreadable_proc,
            fake_identities((710, 720, "100"), (720, 1, "100")))
    except NotADirectoryError:
        pass
    else:
        raise AssertionError("unreadable declared owner produced an unheld lock claim")
    changed_proc = root / "changed-proc"
    write_fake_process(changed_proc, 810, 1, owner_boundary_lock)
    changed_descriptor = changed_proc / "810" / "fd" / "9"
    original_stat = os.stat

    def change_identity_during_descriptor_scan(path, *args, **kwargs):
        if pathlib.Path(path) == changed_descriptor:
            write_fake_stat(changed_proc, 810, 1, "101")
        return original_stat(path, *args, **kwargs)

    with unittest.mock.patch.object(
            restoration.os, "stat", side_effect=change_identity_during_descriptor_scan):
        try:
            restoration.lineage_holds_file(
                810, 810, owner_boundary_lock, changed_proc,
                fake_identities((810, 1, "100")))
        except RuntimeError as error:
            assert "changed during lock scan" in str(error)
        else:
            raise AssertionError("replaced holder retained positive lock attribution")

    exited_proc = root / "exited-proc"
    write_fake_process(exited_proc, 910, 1, owner_boundary_lock)
    exited_descriptor = exited_proc / "910" / "fd" / "9"

    def exit_during_descriptor_scan(path, *args, **kwargs):
        if pathlib.Path(path) == exited_descriptor:
            shutil.rmtree(exited_proc / "910")
        return original_stat(path, *args, **kwargs)

    with unittest.mock.patch.object(
            restoration.os, "stat", side_effect=exit_during_descriptor_scan):
        try:
            restoration.lineage_holds_file(
                910, 910, owner_boundary_lock, exited_proc,
                fake_identities((910, 1, "100")))
        except FileNotFoundError:
            pass
        else:
            raise AssertionError("exited holder retained positive lock attribution")

    rebound_proc = root / "rebound-proc"
    write_fake_process(rebound_proc, 1010, 1)
    try:
        restoration.lineage_holds_file(
            1010, 1010, owner_boundary_lock, rebound_proc,
            fake_identities((1010, 1, "99")))
    except RuntimeError as error:
        assert "changed before lock scan" in str(error)
    else:
        raise AssertionError("replacement process matched the captured telemetry identity")

    for outcome, descriptor_target in (("unheld", None), ("holder", owner_boundary_lock)):
        intermediate_proc = root / f"intermediate-{outcome}-proc"
        write_fake_process(intermediate_proc, 1110, 1120)
        write_fake_process(intermediate_proc, 1120, 1130, descriptor_target)
        write_fake_process(intermediate_proc, 1130, 1)
        telemetry_record = {"pid": 1110, "parent_pid": 1120, "start_ticks": "100"}
        owner_record = {"pid": 1130, "parent_pid": 1, "start_ticks": "100"}
        ancestry_identities = restoration.capture_ancestry_identities(
            telemetry_record, owner_record, intermediate_proc)
        assert ancestry_identities[1120] == (1130, "100")
        write_fake_stat(intermediate_proc, 1120, 1130, "101")
        try:
            restoration.lineage_holds_file(
                1110, 1130, owner_boundary_lock, intermediate_proc,
                ancestry_identities)
        except RuntimeError as error:
            assert "changed before lock scan for pid 1120" in str(error)
        else:
            raise AssertionError(
                f"replaced intermediate process produced a false {outcome} result")

    print("telemetry_owner_boundary=accepted holder=descendant,owner outside_boundary=unread unreadable_inside=refused missing_inside=refused changed_holder=refused exited_holder=refused rebound_identity=refused intermediate_replacement=unheld,holder_refused")

    exited_child = subprocess.Popen(["/usr/bin/true"])
    exited_child.wait(timeout=2)
    campaign_text = (ROOT / "run-closure-identity-ab.sh").read_text()
    stop_begin = campaign_text.index("stop_server() {\n")
    stop_end = campaign_text.index("\nwrite_campaign_cleanup_record()", stop_begin)
    stop_source = campaign_text[stop_begin:stop_end]
    missing_identity = subprocess.run(
        ["sh", "-c", "set -eu\nrecord_process_tree() { :; }\n" + stop_source +
         f"\nserver_pid={exited_child.pid}\nserver_start_ticks=''\nserver_session_id=''\nstop_server\n"],
        text=True, capture_output=True, check=False)
    assert missing_identity.returncode == 1, "unrecorded exited launch was accepted as cleaned"
    assert "server launch identity is unrecorded" in missing_identity.stderr
    print("campaign_unrecorded_start=refused branch=leader_exited_before_identity_capture")
    config = root / "configuration with spaces.json"
    config.write_text('{"profile":"fixture"}\n', encoding="utf-8")
    model = root / "fixture model.gguf"
    model.write_bytes(b"fixture-model-bytes")
    snapshot = root / "private" / "snapshot.json"
    initial_pid_file = root / "initial.pid"
    restored_pid_file = root / "restored.pid"
    lease = root / "compute.lease"
    owner_lock = root / "owner.lock"
    lease.touch()
    owner_lock.touch()
    campaign_record = root / "campaign-cleanup.json"
    clean_campaign = {"state": "reaped", "processes": [],
                      "run_nonce": "fixture-nonce", "revision": "fixture-revision",
                      "campaign_script_sha256": "fixture-script-digest"}
    campaign_record.write_text(json.dumps(clean_campaign) + "\n", encoding="utf-8")
    lifecycle = root / "producer-lifecycle.tsv"
    producer_child = subprocess.Popen(["sleep", "30"], start_new_session=True)
    producer_stat = pathlib.Path(f"/proc/{producer_child.pid}/stat").read_text()
    producer_fields = producer_stat[producer_stat.rfind(")") + 2:].split()
    producer_start = producer_fields[19]
    producer_session = producer_fields[3]
    lifecycle.write_text(
        "run_nonce\trevision\tscript_sha256\tsession_id\tpid\tstart_ticks\trole\n"
        f"fixture-nonce\tfixture-revision\tfixture-script-digest\t{producer_session}\t{producer_child.pid}\t{producer_start}\tserver\n",
        encoding="utf-8")
    producer_record = root / "producer-cleanup.json"
    producer_incomplete = subprocess.run(
        [sys.executable, str(CLEANUP_PROGRAM), str(lifecycle), str(producer_record),
         "fixture-nonce", "fixture-revision", "fixture-script-digest"], check=False)
    assert producer_incomplete.returncode == 1
    assert json.loads(producer_record.read_text())["state"] == "incomplete"
    with lifecycle.open("a", encoding="utf-8") as handle:
        handle.write(
            f"fixture-nonce\tfixture-revision\tfixture-script-digest\t{producer_session}\t-\t-\tboundary_complete\n")
    producer_live = subprocess.run([sys.executable, str(CLEANUP_PROGRAM), str(lifecycle),
                                    str(producer_record), "fixture-nonce",
                                    "fixture-revision", "fixture-script-digest"], check=False)
    assert producer_live.returncode == 1
    assert json.loads(producer_record.read_text())["state"] == "residue"
    producer_child.terminate()
    producer_child.wait(timeout=2)
    producer_done = subprocess.run([sys.executable, str(CLEANUP_PROGRAM), str(lifecycle),
                                    str(producer_record), "fixture-nonce",
                                    "fixture-revision", "fixture-script-digest"], check=False)
    assert producer_done.returncode == 0
    assert json.loads(producer_record.read_text())["state"] == "reaped"

    # A process created by a TERM handler after the initial tree census remains
    # in the launch-time session boundary and therefore prevents a reaped claim.
    late_pid_file = root / "late-descendant.pid"
    late_ready = root / "late-parent.ready"
    late_parent = subprocess.Popen(
        [sys.executable, "-c",
         "import pathlib,signal,subprocess,sys,time\n"
         "def stop(_signal, _frame):\n"
         " child=subprocess.Popen(['sleep','30'])\n"
         " pathlib.Path(sys.argv[1]).write_text(str(child.pid))\n"
         " raise SystemExit(0)\n"
         "signal.signal(signal.SIGTERM, stop)\n"
         "pathlib.Path(sys.argv[2]).touch()\n"
         "while True: time.sleep(0.05)\n",
         str(late_pid_file), str(late_ready)], start_new_session=True)
    for _ in range(100):
        if late_ready.exists():
            break
        time.sleep(0.01)
    assert late_ready.exists()
    late_stat = pathlib.Path(f"/proc/{late_parent.pid}/stat").read_text()
    late_fields = late_stat[late_stat.rfind(")") + 2:].split()
    late_lifecycle = root / "late-lifecycle.tsv"
    late_lifecycle.write_text(
        "run_nonce\trevision\tscript_sha256\tsession_id\tpid\tstart_ticks\trole\n"
        f"fixture-nonce\tfixture-revision\tfixture-script-digest\t{late_fields[3]}\t{late_parent.pid}\t{late_fields[19]}\tserver\n"
        f"fixture-nonce\tfixture-revision\tfixture-script-digest\t{late_fields[3]}\t-\t-\tboundary_complete\n",
        encoding="utf-8")
    late_parent.terminate()
    late_parent.wait(timeout=2)
    for _ in range(100):
        if late_pid_file.exists():
            break
        time.sleep(0.01)
    assert late_pid_file.exists()
    late_record = root / "late-cleanup.json"
    late_result = subprocess.run(
        [sys.executable, str(CLEANUP_PROGRAM), str(late_lifecycle), str(late_record),
         "fixture-nonce", "fixture-revision", "fixture-script-digest"], check=False)
    assert late_result.returncode == 1
    late_payload = json.loads(late_record.read_text())
    assert late_payload["state"] == "residue"
    late_pid = int(late_pid_file.read_text())
    assert any(row["pid"] == late_pid and row["role"] == "boundary_member"
               for row in late_payload["residue"])
    stop_pid(late_pid)
    (root / "state").mkdir()
    latch = root / "latch-clear"
    latch.write_text('#!/bin/sh\n[ ! -e "$QWEN_WEBUI_STATE_DIRECTORY/tainted" ]\n', encoding="utf-8")
    latch.chmod(0o755)
    nvidia_smi = root / "nvidia-smi-empty"
    nvidia_smi.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    nvidia_smi.chmod(0o755)
    port = free_port()
    boundary = "argument with spaces and ; $()"
    argv = [sys.executable, str(SERVER), "--port", str(port), "--model-id",
            "fixture-9b", "--config", str(config), "--boundary", boundary]
    environment = dict(os.environ)
    environment["QWEN_FIXTURE_RUNTIME"] = "selected-runtime"
    environment["HOME"] = str(root / "fixture-home")
    environment["DISPLAY"] = ":fixture"
    environment["XDG_DATA_DIRS"] = "/fixture/data"
    environment.pop("VK_ICD_FILENAMES", None)
    # The directory descriptor keeps repository-local sockets below AF_UNIX path limits.
    socket_directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    resources.callback(os.close, socket_directory)
    tmux_socket = pathlib.Path(f"/proc/{os.getpid()}/fd/{socket_directory}/tmux.sock")
    subprocess.run(["tmux", "-S", str(tmux_socket), "new-session", "-d", "-s",
                    "telemetry-fixture", "sleep", "300"], cwd=root, env=environment,
                   check=True)
    assert tmux_socket.resolve(strict=True) == root.resolve() / "tmux.sock"
    print("telemetry_socket_address=accepted branch=directory_descriptor repository_local=verified")
    subprocess.run(["tmux", "-S", str(tmux_socket), "new-window", "-d", "-t",
                    "telemetry-fixture", "-n", "telemetry-initial",
                    sys.executable, str(FIXTURE_OWNER),
                    str(initial_pid_file), str(owner_lock), "--", *argv], cwd=root,
                   env=environment,
                   check=True)
    for _ in range(100):
        if initial_pid_file.exists():
            break
        time.sleep(0.02)
    initial_pid = int(initial_pid_file.read_text())
    wait_health(f"http://127.0.0.1:{port}/health")
    capture = subprocess.run([
        sys.executable, str(PROGRAM), "capture", "--pid", str(initial_pid),
        "--snapshot", str(snapshot), "--owner-kind", "tmux",
        "--owner-id", "telemetry-fixture", "--owner-socket", str(tmux_socket),
        "--owner-pid", str(initial_pid),
        "--owner-lock", str(owner_lock), "--compute-lease", str(lease),
        "--latch-program", str(latch), "--latch-state-directory", str(root / "state"),
        "--ownership-nvidia-smi", str(nvidia_smi),
        "--environment", "QWEN_FIXTURE_RUNTIME", "--environment", "QWEN_EXPLICIT_UNSET",
        "--config-reference", str(config), "--model", str(model),
        "--listener", f"127.0.0.1:{port}", "--health-url", f"http://127.0.0.1:{port}/health",
        "--model-url", f"http://127.0.0.1:{port}/v1/models", "--served-model-id", "fixture-9b",
    ], text=True, capture_output=True, check=False)
    assert capture.returncode == 0, capture.stderr
    saved = json.loads(snapshot.read_text())
    assert saved["argv"] == argv
    expected_environment = {
        name: environment.get(name)
        for name in restoration.RESTORATION_ENVIRONMENT_BASELINE
    }
    expected_environment.update({"QWEN_EXPLICIT_UNSET": None,
                                 "QWEN_FIXTURE_RUNTIME": "selected-runtime"})
    assert saved["environment"] == expected_environment
    assert saved["environment"]["HOME"] == str(root / "fixture-home")
    assert saved["environment"]["DISPLAY"] == ":fixture"
    assert saved["environment"]["XDG_DATA_DIRS"] == "/fixture/data"
    assert saved["environment"]["VK_ICD_FILENAMES"] is None
    assert saved["environment_scope"] == (
        "required restoration baseline plus explicit allowlist")
    assert snapshot.stat().st_mode & 0o777 == 0o600
    assert snapshot.parent.stat().st_mode & 0o777 == 0o700
    stop_pid(initial_pid)

    # Execute the campaign's exact EXIT function bytes with a real owner FD,
    # server lifetime, cleanup producer, tmux restoration, and exit trap.
    finalizer_result, finalizer_cleanup, finalizer_restore = extracted_finalizer_fixture(
        root, snapshot, restored_pid_file, owner_lock, "accepted")
    assert finalizer_result.returncode == 0, finalizer_result.stderr
    assert json.loads(finalizer_cleanup.read_text())["state"] == "reaped"
    assert json.loads(finalizer_restore.read_text())["restoration"] == "accepted"
    finalizer_pid = int(restored_pid_file.read_text())
    stop_pid(finalizer_pid)
    restored_pid_file.unlink()

    no_restore_snapshot = os.environ.pop("QWEN_TELEMETRY_RESTORE_SNAPSHOT", None)
    failure_result, failure_cleanup, _ = extracted_finalizer_fixture(
        root, snapshot, restored_pid_file, owner_lock, "original-failure", 23)
    assert failure_result.returncode == 23
    assert json.loads(failure_cleanup.read_text())["state"] == "reaped"
    assert json.loads((root / "finalizer-original-failure" /
                       "telemetry-restoration.json").read_text())["restoration"] == "accepted"
    stop_pid(int(restored_pid_file.read_text()))
    restored_pid_file.unlink()
    if no_restore_snapshot is not None:
        os.environ["QWEN_TELEMETRY_RESTORE_SNAPSHOT"] = no_restore_snapshot

    residue_result, residue_cleanup, residue_restore = extracted_finalizer_fixture(
        root, snapshot, restored_pid_file, owner_lock, "residue")
    assert residue_result.returncode != 0
    assert json.loads(residue_cleanup.read_text())["state"] == "residue"
    assert json.loads(residue_restore.read_text()) == {
        "restoration": "blocked", "reason": "campaign_residue"}
    for process in json.loads(residue_cleanup.read_text())["residue"]:
        stop_pid(process["pid"])

    identity_result, identity_cleanup, identity_restore = extracted_finalizer_fixture(
        root, snapshot, restored_pid_file, owner_lock, "identity-mismatch")
    assert identity_result.returncode != 0
    assert json.loads(identity_restore.read_text()) == {
        "restoration": "blocked", "reason": "teardown_failed"}
    for process in json.loads(identity_cleanup.read_text())["residue"]:
        stop_pid(process["pid"])

    (root / "state" / "tainted").touch()
    latch_result, _, latch_restore = extracted_finalizer_fixture(
        root, snapshot, restored_pid_file, owner_lock, "latch")
    assert latch_result.returncode != 0
    assert json.loads(latch_restore.read_text()) == {
        "restoration": "blocked", "reason": "gpu_state_latch_refused"}
    assert not restored_pid_file.exists()
    (root / "state" / "tainted").unlink()

    record = root / "restore.json"
    result = run_restore(snapshot, record, restored_pid_file, lease, owner_lock,
                         latch, campaign_record)
    assert result.returncode == 0, result.stderr
    restored_pid = int(restored_pid_file.read_text())
    accepted = json.loads(record.read_text())
    assert accepted["restoration"] == "accepted"
    assert accepted["runtime_identity"] == accepted["configuration"] == "matched"
    restored_argv = pathlib.Path(f"/proc/{restored_pid}/cmdline").read_bytes().split(b"\0")[:-1]
    assert [part.decode() for part in restored_argv] == argv
    assert boundary.encode() in restored_argv
    stop_pid(restored_pid)
    restored_pid_file.unlink()

    for invalid_timeout in ("0", "-1", "nan", "inf", "-inf"):
        invalid_record = root / f"invalid-timeout-{invalid_timeout}.json"
        invalid_result = run_restore(
            snapshot, invalid_record, restored_pid_file, lease, owner_lock,
            latch, campaign_record, timeout=invalid_timeout)
        assert invalid_result.returncode == 2, invalid_result.stderr
        assert "timeout must be a positive finite number" in invalid_result.stderr, invalid_result.stderr
        assert not invalid_record.exists() and not restored_pid_file.exists()

    incomplete_environment = root / "incomplete-environment.json"
    incomplete_environment_snapshot = json.loads(json.dumps(saved))
    del incomplete_environment_snapshot["environment"]["HOME"]
    incomplete_environment.write_text(
        json.dumps(incomplete_environment_snapshot), encoding="utf-8")
    incomplete_environment_record = root / "incomplete-environment-record.json"
    assert_blocked(
        run_restore(incomplete_environment, incomplete_environment_record,
                    restored_pid_file, lease, owner_lock, latch, campaign_record),
        incomplete_environment_record, "restoration_environment_baseline_incomplete")
    incomplete_environment_payload = json.loads(incomplete_environment_record.read_text())
    assert incomplete_environment_payload["missing_environment"] == ["HOME"]
    assert not restored_pid_file.exists()

    delayed_success = root / "delayed-success.json"
    delayed_success_snapshot = json.loads(json.dumps(saved))
    delayed_success_snapshot["argv"] = [*saved["argv"], "--health-delay", "0.25"]
    delayed_success.write_text(json.dumps(delayed_success_snapshot), encoding="utf-8")
    delayed_success_record = root / "delayed-success-record.json"
    delayed_success_result = run_restore(
        delayed_success, delayed_success_record, restored_pid_file, lease,
        owner_lock, latch, campaign_record, timeout="2")
    assert delayed_success_result.returncode == 0, delayed_success_result.stderr
    delayed_success_pid = int(restored_pid_file.read_text())
    assert json.loads(delayed_success_record.read_text())["restoration"] == "accepted"
    stop_pid(delayed_success_pid)
    restored_pid_file.unlink()

    delayed_failure = root / "delayed-failure.json"
    delayed_failure_snapshot = json.loads(json.dumps(saved))
    delayed_failure_snapshot["argv"] = [*saved["argv"], "--health-delay", "1.0"]
    delayed_failure.write_text(json.dumps(delayed_failure_snapshot), encoding="utf-8")
    delayed_failure_record = root / "delayed-failure-record.json"
    delayed_failure_result = run_restore(
        delayed_failure, delayed_failure_record, restored_pid_file, lease,
        owner_lock, latch, campaign_record, timeout="0.5")
    assert_blocked(
        delayed_failure_result, delayed_failure_record, "health_request_failed_HTTPError")
    delayed_failure_payload = json.loads(delayed_failure_record.read_text())
    delayed_failure_pid = int(restored_pid_file.read_text())
    assert delayed_failure_payload["restored_pid"] == delayed_failure_pid
    assert (delayed_failure_payload["restored_service_disposition"] ==
            "retained_pending_identity_bound_teardown")
    os.kill(delayed_failure_pid, 0)
    stop_pid(delayed_failure_pid)
    restored_pid_file.unlink()
    print("telemetry_readiness_timeout=accepted default=300 delayed_success_bound=2 delayed_failure_bound=0.5 retained_identity=verified invalid=zero,negative,nan,infinity")

    # Mutation: a recorded executable different from the argv executable cannot
    # acquire an accepted runtime identity merely because its digest is valid.
    wrong = root / "wrong-executable.json"
    changed = dict(saved)
    changed["executable"] = "/usr/bin/true"
    changed["executable_sha256"] = __import__("hashlib").sha256(pathlib.Path("/usr/bin/true").read_bytes()).hexdigest()
    wrong.write_text(json.dumps(changed), encoding="utf-8")
    restored_pid_file.unlink(missing_ok=True)
    assert_blocked(run_restore(wrong, root / "wrong.json", restored_pid_file,
                               lease, owner_lock, latch, campaign_record), root / "wrong.json",
                   "restored_process_absent")
    if restored_pid_file.exists():
        stop_pid(int(restored_pid_file.read_text()))

    restored_pid_file.unlink(missing_ok=True)
    for changed_field, changed_value, expected_reason in (
            ("cpu_affinity", [], "scheduling_affinity_failed_OSError"),
            ("argv", [], "exec_failed_ValueError"),
            ("owner_lock", {}, "restore_validation_failed_KeyError")):
        changed = dict(saved)
        changed[changed_field] = changed_value
        failed_snapshot = root / f"failed-{changed_field}.json"
        failed_snapshot.write_text(json.dumps(changed), encoding="utf-8")
        failed_record = root / f"failed-{changed_field}-receipt.json"
        assert_blocked(run_restore(failed_snapshot, failed_record, restored_pid_file,
                                   lease, owner_lock, latch, campaign_record),
                       failed_record, expected_reason)
        restored_pid_file.unlink(missing_ok=True)
        pathlib.Path(str(restored_pid_file) + ".blocked").unlink(missing_ok=True)
    print("telemetry_launch_failures=accepted branches=affinity,exec,malformed_snapshot")

    changed = dict(saved)
    changed["served_model_id"] = "mismatched-restored-model"
    failed_snapshot = root / "failed-health-identity.json"
    failed_snapshot.write_text(json.dumps(changed), encoding="utf-8")
    failed_record = root / "failed-health-identity-receipt.json"
    assert_blocked(run_restore(failed_snapshot, failed_record, restored_pid_file,
                               lease, owner_lock, latch, campaign_record),
                   failed_record, "served_model_identity_mismatch")
    failure = json.loads(failed_record.read_text())
    assert failure["restored_pid"] == int(restored_pid_file.read_text())
    assert failure["restored_start_ticks"].isdigit()
    assert failure["restored_service_disposition"] == "retained_pending_identity_bound_teardown"
    retained_stat = pathlib.Path(f"/proc/{failure['restored_pid']}/stat").read_text()
    retained_start = retained_stat[retained_stat.rfind(")") + 2:].split()[19]
    assert retained_start == failure["restored_start_ticks"]
    retained_executable = pathlib.Path(f"/proc/{failure['restored_pid']}/exe").resolve()
    retained_digest = __import__("hashlib").sha256(retained_executable.read_bytes()).hexdigest()
    assert retained_digest == failure["restored_executable_sha256"]
    owner_target = failure["launch_owner"]
    assert owner_target == {"kind": "tmux", "socket": str(tmux_socket),
                            "session": "telemetry-fixture", "window": "telemetry-restored"}
    subprocess.run(
        ["tmux", "-S", owner_target["socket"], "kill-window", "-t",
         f'{owner_target["session"]}:{owner_target["window"]}'], check=True)
    for _ in range(100):
        if not pathlib.Path(f"/proc/{failure['restored_pid']}").exists():
            break
        time.sleep(0.01)
    assert not pathlib.Path(f"/proc/{failure['restored_pid']}").exists()
    teardown_owner_fd = os.open(owner_lock, os.O_RDWR)
    fcntl.flock(teardown_owner_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    os.close(teardown_owner_fd)
    restored_pid_file.unlink()
    print("telemetry_postlaunch_failure=accepted identity_receipt=retained teardown=identity-bound owner_window=absent owner_lock=free")

    # Mutation: each unsafe precondition blocks before the owner writes a PID.
    sleeper = subprocess.Popen(["sleep", "30"])
    start_ticks = pathlib.Path(f"/proc/{sleeper.pid}/stat").read_text().rsplit(")", 1)[1].split()[19]
    residue_campaign = dict(clean_campaign)
    residue_campaign["processes"] = [{"pid": sleeper.pid, "start_ticks": start_ticks}]
    campaign_record.write_text(json.dumps(residue_campaign) + "\n", encoding="utf-8")
    restored_pid_file.unlink(missing_ok=True)
    assert_blocked(run_restore(snapshot, root / "residue.json", restored_pid_file,
                               lease, owner_lock, latch, campaign_record),
                   root / "residue.json", f"campaign_residue_pid_{sleeper.pid}")
    assert not restored_pid_file.exists()
    sleeper.terminate()
    sleeper.wait(timeout=2)
    campaign_record.write_text(json.dumps(clean_campaign) + "\n", encoding="utf-8")

    lease_fd = os.open(lease, os.O_RDWR)
    fcntl.flock(lease_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    assert_blocked(run_restore(snapshot, root / "lease.json", restored_pid_file,
                               lease, owner_lock, latch, campaign_record), root / "lease.json",
                   "compute_lease_held")
    assert not restored_pid_file.exists()
    pathlib.Path(str(restored_pid_file) + ".blocked").unlink()
    os.close(lease_fd)

    owner_fd = os.open(owner_lock, os.O_RDWR)
    fcntl.flock(owner_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    assert_blocked(run_restore(snapshot, root / "owner.json", restored_pid_file,
                               lease, owner_lock, latch, campaign_record), root / "owner.json",
                   "campaign_owner_held")
    assert not restored_pid_file.exists()
    pathlib.Path(str(restored_pid_file) + ".blocked").unlink()
    os.close(owner_fd)

    (root / "state" / "tainted").touch()
    assert_blocked(run_restore(snapshot, root / "latch.json", restored_pid_file,
                               lease, owner_lock, latch, campaign_record), root / "latch.json",
                   "gpu_state_latch_refused_1")
    assert not restored_pid_file.exists()
    subprocess.run(["tmux", "-S", str(tmux_socket), "kill-server"], check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    # Mutated source must invert a decisive oracle. The wrong-executable
    # mutation makes a valid restore fail; bypassing owner acquisition makes a
    # held-owner restore succeed. Each result would fail its corresponding
    # unmutated assertion above.
    (root / "state" / "tainted").unlink()
    mutation_directory = root / "mutations"
    mutation_directory.mkdir()
    mutated_program = mutation_directory / PROGRAM.name
    mutated_adapter = mutation_directory / "telemetry-owner-launch.py"
    shutil.copy2(PROGRAM, mutated_program)
    adapter_source = (ROOT / "telemetry-owner-launch.py").read_text(encoding="utf-8")
    mutated_adapter.write_text(
        adapter_source.replace(
            'os.execve(snapshot["executable"], snapshot["argv"], environment)',
            'os.execve("/usr/bin/true", snapshot["argv"], environment)'),
        encoding="utf-8")
    mutated_adapter.chmod(0o755)
    subprocess.run(["tmux", "-S", str(tmux_socket), "new-session", "-d", "-s",
                    "telemetry-fixture", "sleep", "300"], check=True)
    wrong_source = run_restore(snapshot, root / "mutation-wrong.json",
                               restored_pid_file, lease, owner_lock, latch,
                               campaign_record, mutated_program)
    assert wrong_source.returncode != 0
    restored_pid_file.unlink(missing_ok=True)

    mutated_adapter.write_text(
        adapter_source.replace(
            "fcntl.flock(owner_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)",
            "None  # mutation bypasses owner acquisition"), encoding="utf-8")
    mutated_adapter.chmod(0o755)
    owner_fd = os.open(owner_lock, os.O_RDWR)
    fcntl.flock(owner_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    unsafe_source = run_restore(snapshot, root / "mutation-unsafe.json",
                                restored_pid_file, lease, owner_lock, latch,
                                campaign_record, mutated_program)
    assert_blocked(unsafe_source, root / "mutation-unsafe.json",
                   "gpu_ownership_authority_refused_75")
    os.close(owner_fd)
    pathlib.Path(str(restored_pid_file) + ".blocked").unlink()

    mutated_program.write_text(
        PROGRAM.read_text(encoding="utf-8").replace(
            "if latch.returncode:", "if False and latch.returncode:"),
        encoding="utf-8")
    mutated_adapter.write_text(
        adapter_source.replace(
            "if latch_result.returncode:",
            "if False and latch_result.returncode:"), encoding="utf-8")
    mutated_adapter.chmod(0o755)
    (root / "state" / "tainted").touch()
    latch_bypass = run_restore(snapshot, root / "mutation-latch.json",
                               restored_pid_file, lease, owner_lock, latch,
                               campaign_record, mutated_program)
    try:
        assert_blocked(latch_bypass, root / "mutation-latch.json",
                       "gpu_state_latch_refused_1")
    except AssertionError:
        pass
    else:
        raise AssertionError("latch-bypass mutation survived the tainted restart oracle")
    assert latch_bypass.returncode == 0, latch_bypass.stderr
    stop_pid(int(restored_pid_file.read_text()))
    restored_pid_file.unlink()
    (root / "state" / "tainted").unlink()
    subprocess.run(["tmux", "-S", str(tmux_socket), "kill-server"], check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print("telemetry_source_mutations=wrong_executable:killed,unsafe_latch_bypass:killed unsafe_owner_guard=redundant refusal_preserved=gpu_ownership_authority_refused_75")

print("telemetry_restoration=accepted argv_boundaries=preserved runtime_identity=matched unsafe_preconditions=residue,lease,owner,latch wrong_executable=refused gpu_execution=not_run")

campaign_source = (ROOT / "run-closure-identity-ab.sh").read_text(encoding="utf-8")
close_position = campaign_source.index("exec 9>&-")
restore_position = campaign_source.index('"$script_directory/telemetry-restoration.py" restore')
assert close_position < restore_position
assert 'write_campaign_cleanup_record || cleanup_status=$?' in campaign_source
assert 'telemetry_restore_ready_seconds=${QWEN_TELEMETRY_RESTORE_READY_SECONDS:-300}' in campaign_source
assert '--timeout "$telemetry_restore_ready_seconds"' in campaign_source
print("campaign_cleanup_wiring=accepted producer=incomplete,residue,reaped late_descendant=detected binding=nonce,revision,script-digest owner_release_before_restore=accepted")
