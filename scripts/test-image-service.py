#!/usr/bin/env python3
"""Drive image-service.py as a subprocess against the fake image runtime.

The service is spawned the way a launch spawns it and every check runs over
the two wires it serves rather than against an imported function: a JSON line
on the Unix control socket and an HTTP request on the loopback artifact
listener. The fake runtime stands in for the pinned Vulkan binary, so the
success arm, every refusal, the timeout, and the cancellation all run without a
device and without a downloaded checkpoint.
"""

import hashlib
import http.client
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

SERVICE_DIRECTORY = os.path.dirname(os.path.abspath(__file__))
SERVICE_PATH = os.path.join(SERVICE_DIRECTORY, "image-service.py")
FAKE_RUNTIME_PATH = os.path.join(
    SERVICE_DIRECTORY, "test-fixtures", "fake-image-runtime.sh"
)
TEARDOWN_CHECK_PATH = os.path.join(SERVICE_DIRECTORY, "image-teardown-check.sh")
sys.path.insert(0, SERVICE_DIRECTORY)

API_KEY = "image-api-key-TESTONLY7Q2X"
PAGE_ORIGIN = "http://127.0.0.1:8080"
STARTUP_SECONDS = 20.0
REQUEST_SECONDS = 60.0


def load_module():
    """Import image-service.py under a name a dash keeps out of `import`."""
    import importlib.util

    specification = importlib.util.spec_from_file_location(
        "qwen_image_service", SERVICE_PATH
    )
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


service_module = load_module()


def build_profile(runtime_path, execution_policy="validator-gated", **overrides):
    profile = {
        "profile_id": "sdxs-512-a",
        "model_id": "sdxs-512-0.9",
        "placement": "A",
        "width": 64,
        "height": 64,
        "steps": 1,
        "sampler": "euler_a",
        "cfg": 1.0,
        "max_steps": 8,
        "max_dimension": 512,
        "timeout_s": 20,
        "execution_policy": execution_policy,
        "validated_evidence": "evidence/image-service-fake.md",
        "runtime_path": runtime_path,
        "model_path": "",
        "model_sha256": "-",
        "runtime_argv": [
            "--output",
            "{output}",
            "--width",
            "{width}",
            "--height",
            "{height}",
            "--seed",
            "{seed}",
            "--steps",
            "{steps}",
            "--sampler",
            "{sampler}",
            "--cfg",
            "{cfg}",
            "--prompt",
            "{prompt}",
            "--negative-prompt",
            "{negative_prompt}",
        ],
    }
    profile.update(overrides)
    return profile


class ServiceSession:
    """One running service, its control socket, and its artifact listener."""

    def __init__(
        self,
        directory,
        profiles,
        runtime_environment=None,
        vulkan_icd_path=None,
        lease_wait_seconds=None,
    ):
        self.directory = directory
        self.state_directory = os.path.join(directory, "state")
        os.makedirs(self.state_directory, mode=0o700, exist_ok=True)
        self.api_key_path = os.path.join(directory, "api.key")
        with open(self.api_key_path, "w", encoding="ascii") as handle:
            handle.write(API_KEY + "\n")
        os.chmod(self.api_key_path, 0o600)
        self.profiles_path = os.path.join(directory, "profiles.json")
        with open(self.profiles_path, "w", encoding="utf-8") as handle:
            json.dump(profiles, handle)
        argv = [
            sys.executable,
            SERVICE_PATH,
            "--state-dir",
            self.state_directory,
            "--profiles-json",
            self.profiles_path,
            "--api-key-file",
            self.api_key_path,
            "--origin",
            PAGE_ORIGIN,
            "--http-host",
            "127.0.0.1",
            "--http-port",
            "0",
        ]
        for name, value in (runtime_environment or {}).items():
            argv.extend(["--runtime-env", f"{name}={value}"])
        # image-service.py derives VK_DRIVER_FILES and VK_ICD_FILENAMES from
        # QWEN_VULKAN_ICD the way scripts/vulkan-runtime-env.sh derives the
        # identical pair for a shell caller, and refuses to start against an
        # unreadable ICD file. This workstation carries no pinned Vulkan ICD,
        # so every session supplies one unless a test asks for the refusal
        # explicitly.
        if vulkan_icd_path is None:
            vulkan_icd_path = os.path.join(directory, "fake-vulkan-icd.json")
            with open(vulkan_icd_path, "w", encoding="ascii") as handle:
                handle.write("{}\n")
        self.vulkan_icd_path = vulkan_icd_path
        environment = dict(os.environ)
        environment["QWEN_VULKAN_ICD"] = vulkan_icd_path
        # The lease wait is bounded rather than immediate, so a test that means
        # to observe the refusal names a deadline it can afford to reach.
        if lease_wait_seconds is not None:
            environment["QWEN_IMAGE_LEASE_WAIT_S"] = str(lease_wait_seconds)
        self.process = subprocess.Popen(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment,
        )
        self.socket_path = ""
        self.http_port = 0
        self.pid = 0
        self.read_startup()

    def read_startup(self):
        deadline = time.time() + STARTUP_SECONDS
        while time.time() < deadline and not self.pid:
            line = self.process.stdout.readline()
            if not line:
                raise AssertionError(
                    "the service exited before it announced its addresses: "
                    f"{self.process.stderr.read()}"
                )
            key, _, rest = line.strip().partition(" ")
            if key == "socket":
                self.socket_path = rest
            elif key == "listening":
                self.http_port = int(rest.split()[1])
            elif key == "pid":
                self.pid = int(rest)
        if not self.pid:
            raise AssertionError("the service announced no pid")

    def control(self, payload, timeout=REQUEST_SECONDS):
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(timeout)
        connection.connect(self.socket_path)
        try:
            connection.sendall(json.dumps(payload).encode("utf-8") + b"\n")
            with connection.makefile("rb") as handle:
                line = handle.readline()
        finally:
            connection.close()
        if not line:
            raise AssertionError("the control socket closed without a response")
        return json.loads(line.decode("utf-8"))

    def http(self, path, headers=None, method="GET"):
        connection = http.client.HTTPConnection("127.0.0.1", self.http_port, timeout=10)
        connection.request(method, path, headers=headers or {})
        response = connection.getresponse()
        body = response.read()
        connection.close()
        return response.status, dict(response.getheaders()), body

    def authorized_http(self, path, extra=None, method="GET"):
        headers = {"Authorization": f"Bearer {API_KEY}"}
        headers.update(extra or {})
        return self.http(path, headers, method)

    def artifact_directory(self):
        return os.path.join(self.state_directory, "images", "artifacts")

    def lease_path(self):
        return os.path.join(self.state_directory, "vulkan-workload.lock")

    def lease_is_free(self):
        """Return whether the workload lease can be taken right now.

        The kernel lock is the authority, so the check acquires and releases it
        rather than reading the text status line beside it.
        """
        import fcntl

        descriptor = os.open(self.lease_path(), os.O_RDWR | os.O_CREAT, 0o644)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return False
        else:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            return True
        finally:
            os.close(descriptor)

    def stop(self, timeout=20.0):
        if self.process.poll() is None:
            self.process.send_signal(signal.SIGTERM)
        try:
            stdout, stderr = self.process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.process.kill()
            stdout, stderr = self.process.communicate()
            raise AssertionError("the service outlived its SIGTERM")
        return self.process.returncode, stdout, stderr


def generate_request(**overrides):
    request = {
        "protocol_version": 1,
        "request_id": "req-0001",
        "action": "image_generate",
        "authorization": "opaque-grant-string",
        "profile_id": "sdxs-512-a",
        "prompt": "a measured raven",
        "negative_prompt": "blurry",
        "seed": 4242,
        "aspect": "square",
        "width": 64,
        "height": 64,
        "steps": 1,
    }
    request.update(overrides)
    return request


class ImageServiceTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="image-service-test-")
        self.addCleanup(self.temporary.cleanup)
        self.sessions = []

    def start(
        self,
        profiles=None,
        runtime_environment=None,
        vulkan_icd_path=None,
        lease_wait_seconds=None,
    ):
        directory = tempfile.mkdtemp(dir=self.temporary.name)
        if profiles is None:
            profiles = {"sdxs-512-a": build_profile(FAKE_RUNTIME_PATH)}
        session = ServiceSession(
            directory,
            profiles,
            runtime_environment,
            vulkan_icd_path,
            lease_wait_seconds,
        )
        self.sessions.append(session)
        self.addCleanup(self.quiet_stop, session)
        return session

    @staticmethod
    def quiet_stop(session):
        try:
            session.stop()
        except (AssertionError, ValueError):
            pass

    def test_success_names_the_artifact_by_its_own_digest(self):
        """A completed job renames the .part.png to the SHA-256 of its own bytes."""
        session = self.start()
        response = session.control(generate_request())
        self.assertEqual(response["status"], "completed", response)
        self.assertEqual(response["protocol_version"], 1)
        self.assertEqual(response["request_id"], "req-0001")
        self.assertNotIn(
            "error",
            response,
            "a completed reply omits the key rather than nulling it",
        )
        digest = response["sha256"]
        artifact = os.path.join(session.artifact_directory(), f"{digest}.png")
        with open(artifact, "rb") as handle:
            body = handle.read()
        self.assertEqual(
            hashlib.sha256(body).hexdigest(),
            digest,
            "the artifact name is the digest of the artifact's own bytes",
        )
        # The digest names the artifact, so both routes are derived from it and
        # the reply carries no origin: image_protocol admits exactly this one
        # spelling of a provenance URL.
        self.assertEqual(response["provenance_url"], f"/artifacts/{digest}.json")
        self.assertEqual(response["artifact_url"], f"/artifacts/{digest}.png")
        self.assertEqual(
            [name for name in os.listdir(session.artifact_directory())
             if name.endswith((".part", ".part.png"))],
            [],
            "a completed job leaves no partial file",
        )

    def test_provenance_records_what_the_service_observed(self):
        """Provenance carries the observed fields and `-` for the rest."""
        session = self.start()
        response = session.control(generate_request())
        digest = response["sha256"]
        with open(
            os.path.join(session.artifact_directory(), f"{digest}.json"),
            encoding="utf-8",
        ) as handle:
            record = json.load(handle)
        self.assertEqual(record["schema"], "qwen-image-provenance/1")
        self.assertEqual(record["png_sha256"], digest)
        self.assertEqual(record["seed"], 4242)
        self.assertEqual(record["width"], 64)
        self.assertEqual(record["height"], 64)
        # The wire names the shape by label and the record names it as a
        # reduced ratio, which is the more informative of the two where the
        # record is read on its own.
        self.assertEqual(record["aspect"], "1:1")
        self.assertEqual(record["profile_id"], "sdxs-512-a")
        self.assertEqual(record["exit_status"], 0)
        self.assertEqual(record["nice"], 19, "the runtime priority is read back")
        self.assertEqual(record["timeout_s_applied"], 20)
        self.assertEqual(
            record["prompt_sha256"],
            hashlib.sha256("a measured raven".encode("utf-8")).hexdigest(),
            "the record carries the prompt digest rather than the prompt",
        )
        self.assertNotIn("a measured raven", json.dumps(record))
        with open(FAKE_RUNTIME_PATH, "rb") as handle:
            self.assertEqual(
                record["runtime_sha256"],
                hashlib.sha256(handle.read()).hexdigest(),
            )
        self.assertIn(
            f"sha256:{record['prompt_sha256']}",
            record["runtime_argv"],
            "the retained argv names the prompt by its digest",
        )
        for field in (
            "load_seconds",
            "diffusion_seconds",
            "vae_seconds",
            "ring_resets",
            "vm_faults",
            "device_loss",
        ):
            self.assertEqual(
                record[field], "-", f"{field} is reported by the runtime, not here"
            )

    def test_same_seed_reproduces_one_artifact_name(self):
        """Two runs at one seed agree on the digest, on this host."""
        session = self.start()
        first = session.control(generate_request())
        second = session.control(generate_request(request_id="req-0002"))
        self.assertEqual(first["sha256"], second["sha256"])

    def test_runtime_records_nice_19_at_its_first_instruction(self):
        """The runtime holds the priority before it parses an argument.

        The record is written by the runtime itself ahead of its argument
        parse, so it reports the state the process started in rather than a
        state a parent reached afterwards. That distinction is the whole point
        of executing through scripts/qwen-exec-idle-priority.sh: the parent's
        own read-back cannot tell an early priority from a late one.
        """
        record_path = os.path.join(self.temporary.name, "runtime-priority.txt")
        session = self.start(
            runtime_environment={"QWEN_FAKE_IMAGE_PRIORITY_RECORD": record_path}
        )
        session.control(generate_request())
        with open(record_path, encoding="ascii") as handle:
            self.assertEqual(handle.read().strip(), "nice=19 ioclass=idle")

    def test_priority_readback_separates_a_wrapped_child_from_a_bare_one(self):
        """The read-back reports the wrapper's value and the caller's without it.

        `wait_for_process_nice` is the input the spawn's refusal branch decides
        on. A child executed through the wrapper reads 19 whatever the caller
        holds; the same child executed directly reads the caller's own value,
        which is what the branch refuses. A pid that has left reads as
        unreadable rather than as a number.
        """
        wrapper = os.path.join(SERVICE_DIRECTORY, "qwen-exec-idle-priority.sh")
        sleeper = ["/bin/sh", "-c", "sleep 5"]
        wrapped = subprocess.Popen(
            [wrapper, *sleeper], stderr=subprocess.DEVNULL
        )
        try:
            self.assertEqual(
                service_module.wait_for_process_nice(wrapped.pid, 19, 2.0),
                19,
                "a wrapped child reaches nice 19",
            )
        finally:
            wrapped.kill()
            wrapped.wait()
        bare = subprocess.Popen(sleeper)
        try:
            self.assertEqual(
                service_module.wait_for_process_nice(bare.pid, 19, 0.2),
                os.getpriority(os.PRIO_PROCESS, 0),
                "an unwrapped child holds the caller's own nice value",
            )
        finally:
            bare.kill()
            bare.wait()
        self.assertIsNone(
            service_module.wait_for_process_nice(bare.pid, 19, 0.05),
            "a departed child reads as unreadable rather than as a value",
        )

    def test_runtime_environment_carries_the_vulkan_icd_pin(self):
        """The spawned runtime inherits VK_DRIVER_FILES and VK_ICD_FILENAMES.

        image-service.py derives the pair from QWEN_VULKAN_ICD the way
        scripts/vulkan-runtime-env.sh derives it for a shell caller, and pins
        both names into the runtime's own environment ahead of every
        generation, so the Vulkan loader the runtime process sees enumerates
        one driver alone. The fake runtime records what it actually received
        rather than what the service intended to send.
        """
        argv_log = os.path.join(self.temporary.name, "argv.log")
        session = self.start(
            runtime_environment={"QWEN_FAKE_IMAGE_ARGV_LOG": argv_log}
        )
        response = session.control(generate_request())
        self.assertEqual(response["status"], "completed", response)
        with open(argv_log, encoding="utf-8") as handle:
            recorded = dict(
                line.rstrip("\n").split("=", 1) for line in handle if "=" in line
            )
        self.assertEqual(recorded["vk_driver_files"], session.vulkan_icd_path)
        self.assertEqual(recorded["vk_icd_filenames"], session.vulkan_icd_path)

    def test_unreadable_vulkan_icd_refuses_before_the_server_starts(self):
        """A missing Vulkan ICD file stops the service before it spawns anything.

        derive_vulkan_icd_environment runs while ServiceSettings is built,
        ahead of the control socket and the artifact listener, so a bad
        QWEN_VULKAN_ICD never reaches a point where a job could run against an
        unrestricted Vulkan loader.
        """
        directory = tempfile.mkdtemp(dir=self.temporary.name)
        missing_icd = os.path.join(directory, "no-such-vulkan-icd.json")
        profiles_path = os.path.join(directory, "profiles.json")
        with open(profiles_path, "w", encoding="utf-8") as handle:
            json.dump({"sdxs-512-a": build_profile(FAKE_RUNTIME_PATH)}, handle)
        api_key_path = os.path.join(directory, "api.key")
        with open(api_key_path, "w", encoding="ascii") as handle:
            handle.write(API_KEY + "\n")
        os.chmod(api_key_path, 0o600)
        state_directory = os.path.join(directory, "state")
        os.makedirs(state_directory, mode=0o700)
        environment = dict(os.environ)
        environment["QWEN_VULKAN_ICD"] = missing_icd
        completed = subprocess.run(
            [
                sys.executable,
                SERVICE_PATH,
                "--state-dir",
                state_directory,
                "--profiles-json",
                profiles_path,
                "--api-key-file",
                api_key_path,
                "--origin",
                PAGE_ORIGIN,
                "--http-host",
                "127.0.0.1",
                "--http-port",
                "0",
            ],
            env=environment,
            capture_output=True,
            text=True,
            timeout=STARTUP_SECONDS,
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("Vulkan ICD is not readable", completed.stderr)
        self.assertIn(missing_icd, completed.stderr)

    def test_dimension_mismatch_is_refused(self):
        """A runtime that ignores the requested geometry produces no artifact."""
        session = self.start(runtime_environment={"QWEN_FAKE_IMAGE_MODE": "dimension"})
        response = session.control(generate_request())
        self.assertEqual(response["status"], "failed", response)
        self.assertEqual(response["reason"], "png_invalid")
        self.assertEqual(response["png_detail"], "dimension")
        self.assertEqual(os.listdir(session.artifact_directory()), [])

    def test_truncated_png_is_refused(self):
        """A half-written file fails the chunk walk rather than being named."""
        session = self.start(runtime_environment={"QWEN_FAKE_IMAGE_MODE": "truncated"})
        response = session.control(generate_request())
        self.assertEqual(response["status"], "failed", response)
        self.assertEqual(response["reason"], "png_invalid")
        self.assertIn(response["png_detail"], ("truncated", "checksum", "decode"))
        self.assertEqual(os.listdir(session.artifact_directory()), [])

    def test_runtime_failure_is_reported_and_leaves_the_lease_free(self):
        """A non-zero runtime exit fails the job and releases the lease."""
        session = self.start(runtime_environment={"QWEN_FAKE_IMAGE_MODE": "fail"})
        response = session.control(generate_request())
        self.assertEqual(response["status"], "failed", response)
        self.assertEqual(response["reason"], "runtime_failed")
        self.assertTrue(session.lease_is_free())

    def test_hang_reaches_the_timeout_and_the_kill(self):
        """A runtime ignoring SIGTERM is ended by SIGKILL after the grace."""
        profiles = {"sdxs-512-a": build_profile(FAKE_RUNTIME_PATH, timeout_s=2)}
        session = self.start(
            profiles=profiles,
            runtime_environment={"QWEN_FAKE_IMAGE_MODE": "hang"},
        )
        started = time.time()
        response = session.control(generate_request())
        elapsed = time.time() - started
        self.assertEqual(response["status"], "failed", response)
        self.assertEqual(response["reason"], "runtime_timeout")
        self.assertGreaterEqual(elapsed, 2.0)
        self.assertLess(elapsed, 40.0)
        self.assertTrue(session.lease_is_free())
        self.assertEqual(
            [name for name in os.listdir(session.artifact_directory())
             if name.endswith((".part", ".part.png"))],
            [],
        )

    def test_cancel_ends_the_owned_child_and_removes_the_part(self):
        """Cancellation kills the runtime and the partial file goes with it."""
        session = self.start(
            runtime_environment={"QWEN_FAKE_IMAGE_SLEEP_SECONDS": "10"}
        )
        result = {}

        def run_generate():
            result["response"] = session.control(generate_request())

        import threading

        worker = threading.Thread(target=run_generate)
        worker.start()
        self.wait_for_running(session)
        cancel = session.control(
            {"protocol_version": 1, "request_id": "req-0001", "action": "cancel"}
        )
        self.assertEqual(cancel["status"], "accepted", cancel)
        worker.join(timeout=30)
        self.assertFalse(worker.is_alive(), "the cancelled generate returned")
        self.assertEqual(result["response"]["status"], "cancelled", result)
        self.assertTrue(session.lease_is_free())
        self.assertEqual(
            [name for name in os.listdir(session.artifact_directory())
             if name.endswith((".part", ".part.png"))],
            [],
        )

    def test_cancel_without_a_job_is_refused(self):
        session = self.start()
        response = session.control(
            {"protocol_version": 1, "request_id": "req-idle", "action": "cancel"}
        )
        self.assertEqual(response["status"], "refused")
        self.assertEqual(response["reason"], "not_running")

    def test_cancel_naming_another_job_is_refused(self):
        """A cancel reaches the generation it names and no other.

        The protocol frame gives a cancel one identifier, so the running job's
        own request_id is the target; a cancel carrying any other identifier
        answers not_running and the generation it did not name completes.
        """
        session = self.start(
            runtime_environment={"QWEN_FAKE_IMAGE_SLEEP_SECONDS": "5"}
        )
        result = {}

        def run_generate():
            result["response"] = session.control(generate_request())

        import threading

        worker = threading.Thread(target=run_generate)
        worker.start()
        try:
            status = self.wait_for_running(session)
            self.assertEqual(status["job_request_id"], "req-0001")
            response = session.control(
                {
                    "protocol_version": 1,
                    "request_id": "req-elsewhere",
                    "action": "cancel",
                }
            )
            self.assertEqual(response["status"], "refused", response)
            self.assertEqual(response["reason"], "not_running")
        finally:
            worker.join(timeout=60)
        self.assertEqual(result["response"]["status"], "completed", result)

    def test_second_generate_is_refused_while_one_runs(self):
        """One Vulkan workload at a time, with no queue behind it."""
        session = self.start(
            runtime_environment={"QWEN_FAKE_IMAGE_SLEEP_SECONDS": "5"}
        )
        result = {}

        def run_generate():
            result["response"] = session.control(generate_request())

        import threading

        worker = threading.Thread(target=run_generate)
        worker.start()
        try:
            self.wait_for_running(session)
            second = session.control(generate_request(request_id="req-second"))
            self.assertEqual(second["status"], "refused", second)
            self.assertEqual(second["reason"], "busy")
        finally:
            worker.join(timeout=60)
        self.assertEqual(result["response"]["status"], "completed")

    def test_lease_is_held_during_the_job_and_released_after(self):
        session = self.start(
            runtime_environment={"QWEN_FAKE_IMAGE_SLEEP_SECONDS": "5"}
        )
        result = {}

        def run_generate():
            result["response"] = session.control(generate_request())

        import threading

        worker = threading.Thread(target=run_generate)
        worker.start()
        try:
            status = self.wait_for_running(session)
            self.assertTrue(status["lease_held"])
            self.assertFalse(
                session.lease_is_free(),
                "the kernel lock is taken while the runtime executes",
            )
        finally:
            worker.join(timeout=60)
        self.assertEqual(result["response"]["status"], "completed")
        self.assertTrue(session.lease_is_free())
        idle = session.control(
            {"protocol_version": 1, "request_id": "req-idle2", "action": "status"}
        )
        self.assertEqual(idle["state"], "idle")
        self.assertFalse(idle["lease_held"])

    def test_refused_profile_leaves_the_lease_untouched(self):
        """A policy refusal happens above the lease, so the lock stays free."""
        profiles = {
            "sdxs-512-a": build_profile(FAKE_RUNTIME_PATH, execution_policy="refused")
        }
        session = self.start(profiles=profiles)
        response = session.control(generate_request())
        self.assertEqual(response["status"], "refused", response)
        self.assertEqual(response["reason"], "profile_refused")
        self.assertTrue(session.lease_is_free())
        # Acquisition writes `state=held` beside the lock, so the absence of
        # that line proves the refusal happened before flock rather than after
        # a lease was taken and given back.
        status_path = os.path.join(
            session.state_directory, "vulkan-workload.status"
        )
        self.assertFalse(
            os.path.exists(status_path),
            "a refusal above the lease writes no lease status line",
        )

    def test_lease_held_past_the_deadline_refuses_the_job(self):
        """A holder that outlasts the wait keeps the same refusal reason."""
        import fcntl

        session = self.start(lease_wait_seconds=0)
        descriptor = os.open(session.lease_path(), os.O_RDWR | os.O_CREAT, 0o644)
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            response = session.control(generate_request())
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)
        self.assertEqual(response["status"], "refused", response)
        self.assertEqual(response["reason"], "lease_unavailable")

    def test_lease_released_inside_the_deadline_admits_the_job(self):
        """A chat turn still releasing the lease delays a job rather than failing it.

        llama-server holds the same lock from its first busy slot to the last
        idle one, so the request that follows an approved tool call meets a
        lease that is about to be released. The wait is what turns that race
        into a delay.
        """
        import fcntl

        hold_seconds = 3.0
        session = self.start(lease_wait_seconds=30)

        # The round trip covers verification, the fake runtime, the PNG write,
        # the hash, and the rename beside the lease, so an uncontended job in
        # the same session is the baseline the wait is measured against.
        started = time.monotonic()
        baseline_response = session.control(generate_request())
        uncontended = time.monotonic() - started
        self.assertEqual(baseline_response["status"], "completed", baseline_response)

        descriptor = os.open(session.lease_path(), os.O_RDWR | os.O_CREAT, 0o644)
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        released = threading.Event()

        def release_after_delay():
            time.sleep(hold_seconds)
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            released.set()

        releaser = threading.Thread(target=release_after_delay)
        releaser.start()
        try:
            started = time.monotonic()
            request = generate_request()
            request["request_id"] = "req-0002"
            response = session.control(request)
            contended = time.monotonic() - started
        finally:
            releaser.join()
            os.close(descriptor)
        self.assertTrue(released.is_set())
        self.assertEqual(response["status"], "completed", response)
        self.assertGreaterEqual(
            contended,
            uncontended + hold_seconds - 0.5,
            "the job spends the holder's term waiting rather than racing it: "
            f"uncontended={uncontended:.2f}s contended={contended:.2f}s",
        )
        self.assertTrue(session.lease_is_free())

    def test_missing_seed_is_refused(self):
        """Randomness is chosen before approval rather than by the service."""
        request = generate_request()
        del request["seed"]
        session = self.start()
        response = session.control(request)
        self.assertEqual(response["status"], "refused")
        self.assertEqual(response["reason"], "invalid_argument")
        self.assertIn("seed", response["error"])

    def test_caller_supplied_path_is_refused(self):
        session = self.start()
        response = session.control(
            generate_request(**{"output": "/tmp/steered.png"})
        )
        self.assertEqual(response["status"], "refused")
        self.assertEqual(response["reason"], "invalid_argument")

    def test_steps_above_the_profile_ceiling_are_refused(self):
        session = self.start()
        response = session.control(generate_request(steps=99))
        self.assertEqual(response["status"], "refused")
        self.assertEqual(response["reason"], "profile_refused")

    def test_oversized_control_line_is_refused(self):
        session = self.start()
        response = session.control(
            generate_request(prompt="x" * (70 * 1024))
        )
        self.assertEqual(response["status"], "refused")
        self.assertEqual(response["reason"], "invalid_argument")

    def test_wrong_protocol_version_is_refused(self):
        session = self.start()
        response = session.control(generate_request(protocol_version=2))
        self.assertEqual(response["status"], "refused")
        self.assertIn("protocol_version", response["error"])

    def test_unauthenticated_artifact_read_is_refused(self):
        """A present hash and an absent one answer 401 to an anonymous reader."""
        session = self.start()
        digest = session.control(generate_request())["sha256"]
        absent = "0" * 64
        for name in (f"{digest}.png", f"{absent}.png"):
            status, headers, _ = session.http(f"/artifacts/{name}")
            self.assertEqual(status, 401, name)
            self.assertIn("WWW-Authenticate", headers)
        status, _, _ = session.http("/health")
        self.assertEqual(status, 401, "health carries the same credential gate")
        status, _, _ = session.http(
            f"/artifacts/{digest}.png?key={API_KEY}"
        )
        self.assertEqual(
            status, 401, "a query parameter carries no authorization"
        )

    def test_authenticated_read_serves_the_artifact_immutably(self):
        session = self.start()
        response = session.control(generate_request())
        digest = response["sha256"]
        status, headers, body = session.authorized_http(f"/artifacts/{digest}.png")
        self.assertEqual(status, 200)
        self.assertEqual(headers["Content-Type"], "image/png")
        self.assertEqual(
            headers["Cache-Control"], "private, max-age=31536000, immutable"
        )
        self.assertEqual(headers["ETag"], f'"{digest}"')
        self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
        self.assertEqual(hashlib.sha256(body).hexdigest(), digest)
        status, headers, body = session.authorized_http(f"/artifacts/{digest}.json")
        self.assertEqual(status, 200)
        self.assertEqual(headers["Content-Type"], "application/json")
        self.assertEqual(json.loads(body)["png_sha256"], digest)

    def test_artifact_path_outside_the_digest_form_is_refused(self):
        session = self.start()
        for path in (
            "/artifacts/../../etc/passwd",
            "/artifacts/%2e%2e%2fetc%2fpasswd",
            "/artifacts/report.png",
            "/artifacts/" + "0" * 63 + ".png",
        ):
            status, _, _ = session.authorized_http(path)
            self.assertEqual(status, 404, path)

    def test_admitted_origin_answers_the_preflight(self):
        session = self.start()
        status, headers, _ = session.http(
            "/health", {"Origin": PAGE_ORIGIN}, method="OPTIONS"
        )
        self.assertEqual(status, 204)
        self.assertEqual(headers["Access-Control-Allow-Origin"], PAGE_ORIGIN)
        self.assertIn("Authorization", headers["Access-Control-Allow-Headers"])
        status, headers, _ = session.http(
            "/health", {"Origin": "http://elsewhere.example"}, method="OPTIONS"
        )
        self.assertEqual(status, 403)
        self.assertNotIn("Access-Control-Allow-Origin", headers)

    def test_health_reports_the_service_state(self):
        session = self.start()
        status, _, body = session.authorized_http("/health")
        self.assertEqual(status, 200)
        payload = json.loads(body)
        self.assertEqual(payload["protocol"], "qwen-image-service/1")
        self.assertEqual(payload["state"], "idle")
        self.assertFalse(payload["lease_held"])
        self.assertEqual(payload["pid"], session.pid)

    def test_shutdown_proves_no_child_no_part_and_a_free_lease(self):
        """SIGTERM during a job leaves no runtime, no .part.png, and no lease."""
        session = self.start(
            runtime_environment={"QWEN_FAKE_IMAGE_SLEEP_SECONDS": "20"}
        )
        result = {}

        def run_generate():
            try:
                result["response"] = session.control(generate_request())
            except Exception as error:  # noqa: BLE001 -- the socket closes on stop
                result["error"] = error

        import threading

        worker = threading.Thread(target=run_generate)
        worker.start()
        status = self.wait_for_running(session)
        self.assertTrue(status["job_id"], "a job is running when the signal arrives")
        code, stdout, stderr = session.stop()
        worker.join(timeout=30)
        self.assertIn("shutdown", stdout, stderr)
        residue_line = [
            line for line in stdout.splitlines() if line.startswith("shutdown ")
        ][-1]
        self.assertIn("child=absent", residue_line)
        self.assertIn("part_files=0", residue_line)
        self.assertIn("lease=released", residue_line)
        self.assertIn("socket=removed", residue_line)
        self.assertEqual(code, 0, residue_line)
        self.assertFalse(os.path.exists(session.socket_path))
        self.assertTrue(session.lease_is_free())
        self.assertEqual(
            [name for name in os.listdir(session.artifact_directory())
             if name.endswith((".part", ".part.png"))],
            [],
        )

    def test_fixture_appends_png_for_an_unrecognized_output_extension(self):
        """The fixture mirrors sd-cli's own encoder-selection rule.

        examples/cli/main.cpp at the pinned stable-diffusion.cpp commit
        (de298c225bed97c3f9026b73cd7b71e7879bd41b) resolves the output
        format from the requested path's extension and, when that lookup
        stays UNKNOWN, appends ".png" to the unmodified path rather than
        refusing (lines 458-472 and 549-557; the recognized set is
        .jpg/.jpeg/.jpe/.png/.webp, examples/common/media_io.cpp:684-698).
        A caller that hands the runtime an extensionless path gets a file
        one component longer than the path it waited on, which is the
        defect this fixture must reproduce to be a faithful stand-in.
        """
        directory = tempfile.mkdtemp(dir=self.temporary.name)
        requested_output = os.path.join(directory, "5b1cb18e266db788.part")
        subprocess.run(
            [
                FAKE_RUNTIME_PATH,
                "--output", requested_output,
                "--width", "4",
                "--height", "4",
                "--seed", "1",
            ],
            check=True,
            timeout=20,
        )
        self.assertFalse(
            os.path.exists(requested_output),
            "the runtime writes to its own resolved path, not the bare one",
        )
        self.assertTrue(
            os.path.exists(requested_output + ".png"),
            "an unrecognized extension makes the runtime append .png",
        )

    def test_generation_completes_because_the_partial_name_carries_a_recognized_extension(
        self,
    ):
        """The naming fix keeps the runtime's write and the service's wait aligned.

        image-service.py names its partial file `<job>.part.png` rather than
        `<job>.part`. `.png` is one of the extensions the runtime's own
        encoder-selection rule recognizes (examples/common/media_io.cpp:684-698
        at the pinned commit), so the rule the previous test proves the
        fixture applies leaves this path unchanged and the runtime writes
        exactly where the service is waiting. Before the fix, the service
        named an extensionless `<job>.part`, the runtime (mirroring the real
        binary) wrote `<job>.part.png`, and the service read "the runtime
        exited successfully and wrote no file" against a file that existed
        one component away.
        """
        session = self.start()
        response = session.control(generate_request())
        self.assertEqual(response["status"], "completed", response)
        self.assertEqual(
            [name for name in os.listdir(session.artifact_directory())
             if name.endswith((".part", ".part.png"))],
            [],
            "the runtime wrote to the exact path the service named",
        )

    def test_shutdown_sweep_removes_a_stray_part_png(self):
        """`shutdown_residue`'s own sweep matches the `.part.png` suffix.

        test_shutdown_proves_no_child_no_part_and_a_free_lease already proves
        `part_files=0` after a SIGTERM taken mid-job, but the fixture's own
        TERM trap removes that job's partial file before shutdown_residue
        ever lists the directory, so that assertion passes whether the
        sweep's own endswith check names `.part` alone or both suffixes. A
        stray file planted ahead of an otherwise idle shutdown is what
        discriminates the two: only a sweep that recognizes `.part.png`
        removes it and reports it swept.
        """
        session = self.start()
        # A status round trip proves the control loop is serving before the
        # signal lands: `read_startup` returns once the service has printed
        # its `pid` line, ahead of the point in `run()` where the SIGTERM
        # handler is installed, so a stop() sent immediately after start()
        # races that installation on an otherwise idle service.
        status = session.control(
            {"protocol_version": 1, "request_id": "req-status", "action": "status"}
        )
        self.assertEqual(status["state"], "idle", status)
        residue_path = os.path.join(
            session.artifact_directory(), "deadbeefcafef00d.part.png"
        )
        with open(residue_path, "wb") as handle:
            handle.write(b"\x89PNG\r\n\x1a\n")
        code, stdout, stderr = session.stop()
        self.assertEqual(code, 0, stderr)
        residue_line = [
            line for line in stdout.splitlines() if line.startswith("shutdown ")
        ][-1]
        self.assertIn("part_files=0", residue_line)
        self.assertFalse(
            os.path.exists(residue_path), "the sweep removes a .part.png stray"
        )

    def test_teardown_check_flags_a_part_png_residue(self):
        """A stray `.part.png` is what image-teardown-check.sh must catch.

        The naming fix moved the partial file's suffix from `.part` to
        `.part.png`, so the residue proof's own glob has to move with it or
        an interrupted generation would pass a teardown check that never
        looked at the file the service actually leaves behind. No service
        runs here: a live service's own shutdown path already clears a
        `.part.png` on a graceful SIGTERM (test_shutdown_proves_no_child_no
        _part_and_a_free_lease proves that), so this proof needs a state
        directory left over from something less orderly than that, and
        image-teardown-check.sh reads process and filesystem state alone.
        """
        state_directory = os.path.join(
            tempfile.mkdtemp(dir=self.temporary.name), "state"
        )
        artifact_directory = os.path.join(state_directory, "images", "artifacts")
        os.makedirs(artifact_directory)
        residue_path = os.path.join(artifact_directory, "deadbeefcafef00d.part.png")
        with open(residue_path, "wb") as handle:
            handle.write(b"\x89PNG\r\n\x1a\n")
        result = subprocess.run(
            [TEARDOWN_CHECK_PATH, state_directory],
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertNotEqual(
            result.returncode, 0, "a stray .part.png must fail the teardown check"
        )
        self.assertIn("partial artifacts survive", result.stderr)
        self.assertIn(residue_path, result.stderr)

    def wait_for_running(self, session, timeout=20.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            status = session.control(
                {
                    "protocol_version": 1,
                    "request_id": "req-status",
                    "action": "status",
                }
            )
            if status["state"] == "running":
                return status
            time.sleep(0.05)
        raise AssertionError("no generation reached the running state")


class PngValidatorTest(unittest.TestCase):
    """The PNG rules, exercised against bytes rather than through a runtime."""

    def valid_png(self, width=4, height=3):
        import binascii
        import struct
        import zlib

        def chunk(kind, body):
            return (
                struct.pack(">I", len(body))
                + kind
                + body
                + struct.pack(">I", binascii.crc32(kind + body) & 0xFFFFFFFF)
            )

        raw = bytearray()
        for _ in range(height):
            raw.append(0)
            raw.extend(b"\x10\x20\x30" * width)
        return (
            b"\x89PNG\r\n\x1a\x0a"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw)))
            + chunk(b"IEND", b"")
        )

    def test_valid_png_reports_its_geometry(self):
        header = service_module.parse_png(self.valid_png(), 4, 3)
        self.assertEqual((header["width"], header["height"]), (4, 3))

    def test_signature_is_required(self):
        with self.assertRaises(service_module.PngInvalid) as caught:
            service_module.parse_png(b"not a png at all", 4, 3)
        self.assertEqual(caught.exception.detail, "signature")

    def test_truncation_is_named(self):
        raw = self.valid_png()
        with self.assertRaises(service_module.PngInvalid) as caught:
            service_module.parse_png(raw[: len(raw) - 20], 4, 3)
        self.assertEqual(caught.exception.detail, "truncated")

    def test_dimension_disagreement_is_named(self):
        with self.assertRaises(service_module.PngInvalid) as caught:
            service_module.parse_png(self.valid_png(), 8, 3)
        self.assertEqual(caught.exception.detail, "dimension")

    def test_corrupt_chunk_fails_its_crc(self):
        raw = bytearray(self.valid_png())
        raw[-5] ^= 0xFF
        with self.assertRaises(service_module.PngInvalid) as caught:
            service_module.parse_png(bytes(raw), 4, 3)
        self.assertIn(caught.exception.detail, ("checksum", "truncated"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
