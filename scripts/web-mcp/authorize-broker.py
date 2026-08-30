#!/usr/bin/env python3
"""Issue one search grant per human approval, over a loopback HTTP service.

`server.py authorize` signs a grant from a command line, which suits an
operator and suits nothing that runs while a session is open. This broker
gives the same signing path a request interface for the browser front end: a
user interface that has just shown a human the exact proposed `search_exa`
arguments posts those arguments here, plus a required `profile_id` naming the
web profile the human selected, and receives the signed grant that admits
them, so the model receives a token bound to the query the human read rather
than the query a note in the context rewrote. `POST /grant` refuses a request
naming no `profile_id`, or one that does not match this process's own
`--profile`, with HTTP 400 before it signs anything.

The service holds three boundaries. It binds a loopback literal alone and
refuses any other host before the socket exists, so the grant endpoint reaches
the machine that runs the router and nothing on the network; a browser on the
SSH client machine reaches it through `ssh -L PORT:127.0.0.1:PORT` rather than
through a wider bind. Every grant request carries a per-launch session secret
in a header and the broker compares the value with `hmac.compare_digest`.
`GET /session` releases the secret only to an admitted Origin presenting the
existing Web UI bearer API key. The signing key travels from its file into
`sign_claim` and into no response, log line, or audit row.

`POST /grant-image` signs the second context this broker serves. The
approving page posts the prompt digests rather than the prompt text, so the
approved words stay in the browser and the broker signs an identity.
`qwen-image-generate-v1` binds one generation -- language profile, image
profile, prompt and negative-prompt digests, seed, aspect, maximum pixel
dimension and steps, conversation generation, expiry, and a single-use nonce
-- through `image_grant`. The claim joins two profiles, so two arguments bind
them: `--profile` is the language profile a section serves and the request's
`language_profile` must equal it, and `--image-profile` is the image profile
the ledger armed and the request's `image_profile` must equal that. One
argument for both would sign a claim naming the language profile twice, which
`image_grant.enforce_image_authorization` then refuses at the child against
`QWEN_IMAGE_PROFILE`; a launch that armed no image lane leaves
`--image-profile` empty and every generation grant is refused. The seed is a
required request field, so the trusted user interface generates and displays it
before approval and this broker chooses no randomness after one.

One approval issues one grant. The claim carries `max_uses` of one and the
serving path spends it under the ledger's primary key, so this service offers
one grade of approval and holds no standing permission.
"""

import argparse
import hashlib
import hmac
import http.server
import json
import os
import secrets
import signal
import socket
import socketserver
import stat
import sys
import threading
import time

BROKER_DIRECTORY = os.path.dirname(os.path.abspath(__file__))
if BROKER_DIRECTORY not in sys.path:
    sys.path.insert(0, BROKER_DIRECTORY)

import server  # noqa: E402
import image_grant  # noqa: E402

LOOPBACK_HOSTS = ("127.0.0.1", "::1")
SESSION_SECRET_FILE_NAME = "authorize-session.secret"
SESSION_SECRET_BYTES = 32
SESSION_HEADER = "X-Qwen-Web-Session"
REQUEST_BODY_BYTE_CAP = 16384
REQUEST_READ_TIMEOUT_DEFAULT_SECONDS = 5.0
REQUEST_READ_TIMEOUT_MAX_SECONDS = 30.0
AUTHORIZE_PER_MINUTE_DEFAULT = 6
GRANT_PATH = "/grant"
IMAGE_GRANT_PATH = "/grant-image"
SESSION_PATH = "/session"
HEALTH_PATH = "/health"
KEY_MODE_FORBIDDEN_BITS = 0o077
STALE_SESSION_SECRET_CODE = "stale_session_secret"


def loopback_host(value):
    """Return a host string this service admits, or raise for any other.

    The refusal runs against the configured string before the socket is
    created, so a wider bind fails at startup rather than serving until
    somebody reads the listening address. The name `localhost` is refused
    beside every routable literal: it resolves through the resolver, and
    `require_public_host` refuses it in the result-URL position for the same
    reason.
    """
    if value not in LOOPBACK_HOSTS:
        raise argparse.ArgumentTypeError(
            f"the broker binds a loopback literal alone; {value!r} is refused. "
            f"Admitted hosts: {', '.join(LOOPBACK_HOSTS)}"
        )
    return value


def host_header_is_loopback(header):
    """Return whether a Host header names a loopback literal and no other name.

    A browser that resolves an attacker-controlled name to 127.0.0.1 reaches
    this socket with that name in the Host header, so the bind alone leaves
    DNS rebinding open. Comparing the header against the same literals closes
    it: a request whose Host is a name rather than an address is refused.
    """
    if not header:
        return False
    value = header.strip()
    if value.startswith("["):
        closing = value.find("]")
        if closing < 0:
            return False
        return value[1:closing] in LOOPBACK_HOSTS
    return value.split(":", 1)[0] in LOOPBACK_HOSTS


def write_session_secret(state_directory):
    """Return the per-launch secret after placing it in a file the owner reads.

    The value in memory is the authority and `GET /session` is the browser
    delivery channel. The private file gives the process supervisor a precise
    cleanup target; stale file bytes left by a killed broker authorize nothing
    against the next launch's in-memory secret. O_EXCL creates the file at
    mode 0600 after predecessor removal and refuses a pre-planted symlink.
    """
    path = os.path.join(state_directory, SESSION_SECRET_FILE_NAME)
    secret = secrets.token_urlsafe(SESSION_SECRET_BYTES)
    if os.path.lexists(path):
        os.unlink(path)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.write(descriptor, (secret + "\n").encode("ascii"))
    finally:
        os.close(descriptor)
    return secret, path


def validate_signing_key(path):
    """Return the SHA-256 of the signing key file after checking every rule.

    The signing path (`server.issue_grant`) reads this file itself, so this
    function never opens it for signing; it opens it once to compute a
    digest the broker can report without exposing the key. Each rule names
    the failure it refuses on stderr and never echoes the path's contents:
    an absent or blank `--token-key-file`, a missing file, a symlink (the
    `lstat` mode bit `S_IFLNK` rather than the resolved target), an owner
    other than this process's own `os.getuid()`, a mode carrying any of the
    group or other bits `0o077`, an unreadable file, or a file of zero
    bytes.
    """
    if not path:
        sys.stderr.write(
            "the broker signs every grant from a key file, so "
            "QWEN_WEB_TOKEN_KEY_FILE or --token-key-file names it\n"
        )
        return None
    try:
        status = os.lstat(path)
    except OSError as error:
        sys.stderr.write(f"the signing key file is unreadable: {error}\n")
        return None
    if not stat.S_ISREG(status.st_mode):
        sys.stderr.write(
            "the signing key path names a symlink or another non-regular "
            "file, and the broker refuses to follow it\n"
        )
        return None
    if status.st_uid != os.getuid():
        sys.stderr.write(
            "the signing key file belongs to another user, and the broker "
            "refuses a key it does not own\n"
        )
        return None
    if status.st_mode & KEY_MODE_FORBIDDEN_BITS:
        sys.stderr.write(
            "the signing key file is readable or writable outside its "
            "owner; chmod 0600 or stricter before the broker will start\n"
        )
        return None
    try:
        with open(path, "rb") as handle:
            content = handle.read()
    except OSError as error:
        sys.stderr.write(f"the signing key file is unreadable: {error}\n")
        return None
    if not content:
        sys.stderr.write("the signing key file is empty\n")
        return None
    try:
        server.read_secret_file(path, "token signing")
    except server.ToolError as error:
        sys.stderr.write(f"{error}\n")
        return None
    return hashlib.sha256(content).hexdigest()


def process_start_time(fallback):
    """Return field 22 of `/proc/self/stat`, the start time in clock ticks.

    The value identifies this process against a later holder of the same
    pid: qwen-webui-session.sh records it beside the pid and
    qwen-teardown.sh compares it with the live field before signalling. Ticks
    since boot are what the kernel exposes, so the raw integer is served and
    both sides compare the same number. A kernel without `/proc` leaves the
    file unreadable and the caller's own clock sample stands in.
    """
    try:
        with open("/proc/self/stat", encoding="ascii") as handle:
            fields = handle.read().rsplit(")", 1)[1].split()
        return int(fields[19])
    except (OSError, IndexError, ValueError):
        return int(fallback)


def raise_interrupt(number, frame):
    """Turn a terminating signal into the exception the accept loop unwinds on."""
    raise KeyboardInterrupt(f"signal {number}")


class BrokerSettings:
    """What one broker launch signs, meters, and admits."""

    def __init__(self, arguments):
        self.token_key_file = arguments.token_key_file
        self.api_key = ""
        self.state_directory = arguments.state_dir
        self.provider = arguments.provider
        self.profile = arguments.profile
        self.image_profile = arguments.image_profile
        self.lifetime = arguments.lifetime
        self.origins = tuple(arguments.origin)
        self.per_minute = arguments.per_minute
        self.request_read_timeout = arguments.request_read_timeout
        self.session_secret = ""
        self.signing_key_sha256 = ""
        self.start_time = 0


def parse_request_arguments(payload):
    """Return the exact search fields a grant request names.

    The broker validates shape here and leaves every cap, hostname rule, and
    date form to `issue_grant`, which applies the helpers the serving path
    applies, so an approved argument and a served argument pass one validator.
    A field the request omits takes the same default the subcommand takes, so
    an approval dialog that shows nothing under a field approves the absence
    the search then sends.
    """
    if not isinstance(payload, dict):
        raise server.InvalidArgument("the request body is not an object")
    profile_id = payload.get("profile_id")
    if not isinstance(profile_id, str) or not profile_id:
        raise server.InvalidArgument(
            "profile_id must name the web profile the grant is signed for"
        )
    query = payload.get("query")
    if not isinstance(query, str):
        raise server.InvalidArgument("query must be a string")
    fields = {"query": query, "profile_id": profile_id}
    for key in ("include_domains", "exclude_domains"):
        value = payload.get(key) or []
        if not isinstance(value, list) or not all(
            isinstance(entry, str) for entry in value
        ):
            raise server.InvalidArgument(f"{key} must be a list of strings")
        fields[key] = value
    for key in ("published_after", "published_before"):
        value = payload.get(key) or ""
        if not isinstance(value, str):
            raise server.InvalidArgument(f"{key} must be a string")
        fields[key] = server.require_iso_date(payload, key)
    if (
        fields["published_after"]
        and fields["published_before"]
        and fields["published_after"] > fields["published_before"]
    ):
        raise server.InvalidArgument(
            "published_after falls after published_before"
        )
    max_age_hours = payload.get("max_age_hours")
    if max_age_hours is not None and (
        not isinstance(max_age_hours, int) or isinstance(max_age_hours, bool)
    ):
        raise server.InvalidArgument("max_age_hours must be an integer or absent")
    fields["max_age_hours"] = max_age_hours
    max_results = payload.get("max_results")
    if max_results is None:
        max_results = 5
    if not isinstance(max_results, int) or isinstance(max_results, bool):
        raise server.InvalidArgument("max_results must be an integer")
    fields["max_results"] = max_results
    return fields


def audit_row(settings, fields, status, started_at):
    """Return the audit row one grant request writes.

    The trail carries the SHA-256 of the query and the domain filters rather
    than the query itself, which is the vocabulary `Ledger.record` already
    holds, and it carries neither the signing key nor the issued grant: a row
    retaining the token would hand a reader the authorization whose single use
    the ledger exists to spend.
    """
    query_digest = ""
    domains = ""
    result_count = 0
    if fields is not None:
        query_digest = hashlib.sha256(
            fields["query"].strip().encode("utf-8")
        ).hexdigest()
        domains = ",".join(
            sorted(fields["include_domains"])
            + [f"-{entry}" for entry in sorted(fields["exclude_domains"])]
        )
        result_count = fields["max_results"]
    now = time.time()
    return {
        "recorded_at": server.utc_timestamp(now),
        "profile": settings.profile,
        "operation": "authorize",
        "query_sha256": query_digest,
        "domains": domains,
        "result_count": result_count,
        "fetched_host": "",
        "provider_bytes": 0,
        "returned_characters": 0,
        "latency_ms": int((now - started_at) * 1000),
        "status": status,
        "recorded_epoch": int(now),
    }


def issue_for_request(settings, fields):
    """Sign the grant for exactly these arguments.

    `do_POST` charges the `authorize-minute` bucket ahead of every other check,
    including the session-header and body validation this function assumes
    already passed, so the meter here would double-charge one request.

    The requested `profile_id` names the web profile the browser selected;
    `settings.profile` names the profile this broker process was launched
    for and is what `enforce_search_authorization` on the MCP child compares
    a spent grant's `profile_id` against. Signing the requested name instead
    of the launch name would issue a grant that reads as authorized here and
    is refused at the child, so a mismatch is refused here instead, against
    the same name the grant is actually signed with.
    """
    if fields["profile_id"] != settings.profile:
        raise server.InvalidArgument(
            f"the broker process serves profile {settings.profile!r}; "
            f"the request named {fields['profile_id']!r}"
        )
    return server.issue_grant(
        settings.token_key_file,
        fields["query"],
        fields["include_domains"],
        fields["exclude_domains"],
        fields["published_after"],
        fields["published_before"],
        fields["max_age_hours"],
        fields["max_results"],
        settings.provider,
        settings.profile,
        settings.lifetime,
    )


def image_audit_row(settings, fields, status, started_at):
    """Return the audit row one image grant request writes.

    The row fills the same twelve-column vocabulary the search trail uses, so
    one table answers what a session authorized. `query_sha256` carries the
    prompt digest, which is the value the column is shaped for and the value
    the claim itself binds, and `domains` carries the language and image
    profile pair, so a reader separates the two grant contexts by `operation`
    and reads the profiles a grant joined without recovering the prompt.
    """
    prompt_sha256 = ""
    profiles = ""
    if fields is not None:
        prompt_sha256 = fields["prompt_hash"]
        profiles = f"{fields['language_profile']}>{fields['image_profile']}"
    now = time.time()
    return {
        "recorded_at": server.utc_timestamp(now),
        "profile": settings.profile,
        "operation": "authorize-image",
        "query_sha256": prompt_sha256,
        "domains": profiles,
        "result_count": 0,
        "fetched_host": "",
        "provider_bytes": 0,
        "returned_characters": 0,
        "latency_ms": int((now - started_at) * 1000),
        "status": status,
        "recorded_epoch": int(now),
    }


def issue_image_for_request(settings, fields):
    """Sign the generation grant for exactly these approved fields.

    The claim joins the language profile a section serves to the image profile
    the ledger armed, and `image_grant.enforce_image_authorization` compares
    each against a separate setting the MCP child reads --
    `QWEN_IMAGE_LANGUAGE_PROFILE` and `QWEN_IMAGE_PROFILE`. Both names are
    therefore bound here, against `--profile` and `--image-profile`, so a
    mismatch is refused against the name the grant would carry rather than at
    the child against a token that already left the machine. An empty
    `--image-profile` is a launch that armed no image lane, and every
    generation grant is refused rather than signed for a profile no ledger row
    admitted.
    """
    if not settings.image_profile:
        raise server.InvalidArgument(
            "this broker serves no image profile, so it signs no generation grant"
        )
    if fields["language_profile"] != settings.profile:
        raise server.InvalidArgument(
            f"the broker process serves profile {settings.profile!r}; "
            f"the request named language profile {fields['language_profile']!r}"
        )
    if fields["image_profile"] != settings.image_profile:
        raise server.InvalidArgument(
            f"the broker process serves image profile "
            f"{settings.image_profile!r}; the request named "
            f"{fields['image_profile']!r}"
        )
    return image_grant.issue_image_grant(
        settings.token_key_file, fields, settings.lifetime
    )


HTTP_STATUS_FOR_TERM = {
    "authorization_denied": 403,
    "rate_limited": 429,
    "budget_exhausted": 429,
    "expired_result": 403,
}


class StaleSessionSecret(server.AuthorizationDenied):
    """A grant request presents authority from another broker launch."""


def record_audit(
    ledger, row, coalesce_window_seconds=None, coalesce_epoch=None
):
    """Record an outcome, coalescing repeated bucket refusals atomically.

    An exhausted caller can continue opening connections without consuming a
    bucket unit. Recording every refusal would make the audit table grow at
    the caller's connection rate after the limiter has already stopped useful
    work. The immediate transaction makes the presence check and insert one
    state transition across independently connected request handlers.
    """
    if coalesce_window_seconds is None:
        ledger.record(row)
        return
    recorded_epoch = int(row["recorded_epoch"])
    bucket_epoch = int(
        recorded_epoch if coalesce_epoch is None else coalesce_epoch
    )
    window_start = bucket_epoch - bucket_epoch % coalesce_window_seconds
    window_end = window_start + coalesce_window_seconds
    connection = ledger.connection
    connection.execute("BEGIN IMMEDIATE")
    try:
        existing = connection.execute(
            "SELECT 1 FROM audit WHERE operation = ? AND status = ?"
            " AND recorded_epoch >= ? AND recorded_epoch < ? LIMIT 1",
            (row["operation"], row["status"], window_start, window_end),
        ).fetchone()
        if existing is None:
            connection.execute(
                # The audit table gained provenance columns for a metasearch
                # answer, so the insert names the twelve an approval fills
                # rather than counting on the table's width.
                "INSERT INTO audit (recorded_at, profile, operation,"
                " query_sha256, domains, result_count, fetched_host,"
                " provider_bytes, returned_characters, latency_ms, status,"
                " recorded_epoch) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    row["recorded_at"],
                    row["profile"],
                    row["operation"],
                    row["query_sha256"],
                    row["domains"],
                    row["result_count"],
                    row["fetched_host"],
                    row["provider_bytes"],
                    row["returned_characters"],
                    row["latency_ms"],
                    row["status"],
                    recorded_epoch,
                ),
            )
        connection.execute("COMMIT")
    except BaseException:
        connection.execute("ROLLBACK")
        raise


class BrokerHandler(http.server.BaseHTTPRequestHandler):
    """Serve health, session capability, and one-use search and image grants."""

    protocol_version = "HTTP/1.1"
    server_version = "qwen-web-authorize-broker/1.0"
    sys_version = ""

    def setup(self):
        super().setup()
        self.request_read_lock = threading.Lock()
        self.request_read_timer = None
        self.request_read_token = None

    def handle_one_request(self):
        """Bound the complete header and body read by one wall-clock timer."""
        deadline_token = object()
        self.request_read_timer = threading.Timer(
            self.settings.request_read_timeout,
            self.expire_request_read,
            args=(deadline_token,),
        )
        self.request_read_token = deadline_token
        self.request_read_timer.daemon = True
        self.request_read_timer.start()
        try:
            super().handle_one_request()
        finally:
            self.finish_request_read()

    def expire_request_read(self, deadline_token):
        """End a connection whose request has not arrived by its deadline."""
        with self.request_read_lock:
            if self.request_read_token is not deadline_token:
                return
            self.request_read_token = None
            self.request_read_timer = None
        try:
            self.connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

    def finish_request_read(self):
        """Cancel the active request-read deadline after parsing completes."""
        with self.request_read_lock:
            timer = self.request_read_timer
            self.request_read_timer = None
            self.request_read_token = None
        if timer is not None:
            timer.cancel()

    def log_message(self, fmt, *args):
        """Drop the default access log.

        A request line reaching stderr would carry the query an audit row
        deliberately reduces to a digest, so the ledger is the trail and this
        handler writes none of its own.
        """

    @property
    def settings(self):
        return self.server.broker_settings

    def allowed_origin(self):
        """Return the request Origin when the launch admits it, or an empty string."""
        origin = self.headers.get("Origin", "")
        return origin if origin and origin in self.settings.origins else ""

    def send_json(self, http_status, payload, origin=""):
        self.finish_request_read()
        body = json.dumps(payload).encode("utf-8")
        self.send_response(http_status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        if origin:
            # The echoed value is one entry of the configured allowlist, so a
            # wildcard never reaches a response, and credentials stay
            # unallowed because the session header rather than a cookie
            # carries the authority.
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")
        self.end_headers()
        self.wfile.write(body)

    def require_loopback_host(self):
        if not host_header_is_loopback(self.headers.get("Host", "")):
            raise server.AuthorizationDenied(
                "the request Host names something other than a loopback literal"
            )

    def require_session_secret(self):
        presented = self.headers.get(SESSION_HEADER, "")
        if not presented or not hmac.compare_digest(
            presented, self.settings.session_secret
        ):
            raise StaleSessionSecret(
                f"the request carries no valid {SESSION_HEADER} header"
            )

    def require_api_key(self):
        authorization = self.headers.get("Authorization", "")
        expected = f"Bearer {self.settings.api_key}"
        if not authorization or not hmac.compare_digest(authorization, expected):
            raise server.AuthorizationDenied(
                "the session request carries no valid bearer API key"
            )

    def read_body(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            raise server.InvalidArgument(
                "Content-Length is not an integer"
            ) from None
        if length < 0 or length > REQUEST_BODY_BYTE_CAP:
            raise server.InvalidArgument(
                f"the request body exceeds the {REQUEST_BODY_BYTE_CAP} byte cap"
            )
        try:
            body = self.rfile.read(length)
            if len(body) != length:
                raise ValueError
            payload = json.loads(body.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise server.InvalidArgument(
                "the request body is not UTF-8 JSON"
            ) from None
        self.finish_request_read()
        return payload

    def do_OPTIONS(self):  # noqa: N802 -- BaseHTTPRequestHandler names the verb
        """Answer the preflight a custom header and a JSON body force.

        A browser sends this ahead of every grant request and a Python client
        sends it ahead of none, so the arm lives here and in the test rather
        than being discovered by a front end that fails while every test
        passes.
        """
        origin = self.allowed_origin()
        self.finish_request_read()
        self.send_response(204 if origin else 403)
        self.send_header("Content-Length", "0")
        if origin:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header(
                "Access-Control-Allow-Headers",
                f"Authorization, Content-Type, {SESSION_HEADER}",
            )
            self.send_header("Access-Control-Max-Age", "60")
            self.send_header("Vary", "Origin")
        self.end_headers()

    def do_GET(self):  # noqa: N802 -- BaseHTTPRequestHandler names the verb
        """Hand the per-launch secret to an admitted page with the API key.

        The secret travels in a response body rather than a URL, so it stays
        out of the browser history, the Referer header, and any intermediary
        log. The Origin allowlist and Web UI bearer API key form the gate; an
        absent Origin or bearer value releases no secret.
        """
        origin = self.allowed_origin()
        path = self.path.split("?", 1)[0]
        if path == HEALTH_PATH:
            self.handle_health()
            return
        if path != SESSION_PATH:
            self.send_json(404, {"error": "no such endpoint"}, origin)
            return
        try:
            self.require_loopback_host()
            if not origin:
                raise server.AuthorizationDenied(
                    "the request Origin is absent or outside the admitted set"
                )
            self.require_api_key()
        except server.ToolError as error:
            self.send_json(
                HTTP_STATUS_FOR_TERM.get(error.status, 400),
                {"error": str(error)},
                origin,
            )
            return
        self.send_json(200, {"session_secret": self.settings.session_secret}, origin)

    def handle_health(self):
        """Answer the launcher's own liveness probe, ahead of the router.

        `qwen-webui-session.sh` reads this with `curl` before the router
        starts, so the check here is the loopback Host guard alone: neither
        an Origin nor the per-launch session header is available to a shell
        probe that never loads a page. Every field in the response is a
        process or configuration identity; the signing key contributes its
        digest and never its bytes.
        """
        try:
            self.require_loopback_host()
        except server.ToolError as error:
            self.send_json(
                HTTP_STATUS_FOR_TERM.get(error.status, 400),
                {"error": str(error)},
            )
            return
        state_status = os.stat(self.settings.state_directory)
        self.send_json(
            200,
            {
                "protocol": "qwen-web-broker/1",
                "profile": self.settings.profile,
                # The image profile reports what this broker signs generation
                # grants for, so a launch reads the armed lane from the same
                # route it reads the language profile from. An empty value
                # states that no image lane is armed.
                "image_profile": self.settings.image_profile,
                "provider": self.settings.provider,
                "pid": os.getpid(),
                "start_time": self.settings.start_time,
                "signing_key_sha256": self.settings.signing_key_sha256,
                "state_dir": f"{state_status.st_dev}:{state_status.st_ino}",
                "origins": list(self.settings.origins),
            },
        )

    def do_POST(self):  # noqa: N802 -- BaseHTTPRequestHandler names the verb
        """Sign the grant for the exact arguments a human has just approved.

        Each admitted outcome writes one audit row under the nine-term
        vocabulary. The trail separates invalid session headers, malformed
        fields, exhausted buckets, and issued grants while every grant stays in
        the response alone. The `authorize-minute` bucket is charged before the
        loopback-host and session-header checks run, so a caller that holds
        neither cannot reach `ledger.record` faster than the bucket admits;
        without that ordering an unauthenticated loopback process floods the
        session check alone. Exhausted refusals coalesce to one row per bucket
        window, so post-limit connections cannot grow the audit trail.
        """
        started_at = time.time()
        origin = self.allowed_origin()
        path = self.path.split("?", 1)[0]
        if path not in (GRANT_PATH, IMAGE_GRANT_PATH):
            self.send_json(404, {"error": "no such endpoint"}, origin)
            return
        # The two endpoints share every gate ahead of the body, so an image
        # grant charges the same meter and presents the same session authority
        # a search grant does. The context they sign under is what differs:
        # `search-authorization` names a query and `qwen-image-generate-v1`
        # names a generation, and `sign_claim` covers the context string, so
        # neither token verifies as the other.
        image = path == IMAGE_GRANT_PATH
        row_for = image_audit_row if image else audit_row
        ledger = None
        fields = None
        try:
            ledger = server.Ledger(self.settings.state_directory)
            ledger.consume("authorize-minute", 60, self.settings.per_minute, started_at)
            self.require_loopback_host()
            # The session secret reaches a page through /session, which the
            # Origin allowlist gates, so a grant request from another origin
            # carries a secret that left the admitted page. The same allowlist
            # gates the signing route, so the secret alone buys nothing from a
            # page the launch did not name.
            if not origin:
                raise server.AuthorizationDenied(
                    "the request Origin is absent or outside the admitted set"
                )
            self.require_session_secret()
            payload = self.read_body()
            if image:
                fields = image_grant.parse_image_request(payload)
                token = issue_image_for_request(self.settings, fields)
            else:
                fields = parse_request_arguments(payload)
                token = issue_for_request(self.settings, fields)
            ledger.record(row_for(self.settings, fields, "success", started_at))
        except server.ToolError as error:
            if ledger is not None:
                record_audit(
                    ledger,
                    row_for(self.settings, fields, error.status, started_at),
                    60 if error.status == "rate_limited" else None,
                    started_at,
                )
            payload = {"error": str(error)}
            if isinstance(error, StaleSessionSecret):
                payload["code"] = STALE_SESSION_SECRET_CODE
            self.send_json(
                HTTP_STATUS_FOR_TERM.get(error.status, 400),
                payload,
                origin,
            )
            return
        finally:
            if ledger is not None:
                ledger.close()
        self.send_json(200, {"authorization": token}, origin)


class BrokerServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    """Serve independent requests concurrently over per-handler ledgers."""

    allow_reuse_address = False
    daemon_threads = False
    block_on_close = True

    def __init__(self, address, settings):
        self.address_family = socket.AF_INET6 if ":" in address[0] else socket.AF_INET
        self.broker_settings = settings
        super().__init__(address, BrokerHandler)


def positive_seconds(value):
    """Return a finite positive timeout from an argparse value."""
    try:
        parsed = float(value)
    except ValueError:
        raise argparse.ArgumentTypeError("timeout must be a number") from None
    if not 0 < parsed <= REQUEST_READ_TIMEOUT_MAX_SECONDS:
        raise argparse.ArgumentTypeError(
            "timeout must lie between 0 and "
            f"{REQUEST_READ_TIMEOUT_MAX_SECONDS:g} seconds"
        )
    return parsed


def build_parser():
    parser = argparse.ArgumentParser(
        prog="authorize-broker.py",
        description="issue one grant per human approval over loopback; "
        "POST /grant requires profile_id in the request body, matching "
        "--profile below, beside the search_exa fields it approves, and "
        "POST /grant-image requires language_profile matching --profile and "
        "image_profile matching --image-profile beside the generation fields "
        "it approves",
    )
    parser.add_argument("--host", type=loopback_host, default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument(
        "--token-key-file", default=os.environ.get("QWEN_WEB_TOKEN_KEY_FILE", "")
    )
    parser.add_argument(
        "--api-key-file", default=os.environ.get("QWEN_WEBUI_API_KEY_FILE", "")
    )
    parser.add_argument("--state-dir", default=os.environ.get("QWEN_WEB_STATE_DIR", ""))
    parser.add_argument("--provider", default=os.environ.get("QWEN_WEB_PROVIDER", "exa"))
    parser.add_argument(
        "--profile", default=os.environ.get("QWEN_WEB_PROFILE", "default"),
        help="the profile this broker serves; POST /grant requires the "
        "request body's profile_id to equal this value",
    )
    parser.add_argument(
        "--image-profile", default=os.environ.get("QWEN_IMAGE_PROFILE", ""),
        help="the image profile this broker signs generation grants for; "
        "POST /grant-image requires the request body's image_profile to equal "
        "this value, and an empty value refuses every generation grant",
    )
    parser.add_argument(
        "--lifetime", type=int, default=server.TOKEN_LIFETIME_DEFAULT_SECONDS
    )
    parser.add_argument("--per-minute", type=int, default=AUTHORIZE_PER_MINUTE_DEFAULT)
    parser.add_argument(
        "--request-read-timeout",
        type=positive_seconds,
        default=REQUEST_READ_TIMEOUT_DEFAULT_SECONDS,
    )
    parser.add_argument("--origin", action="append", default=None)
    return parser


def run(argv):
    """Serve until the caller ends the process, then remove the secret file."""
    entry_time = time.time()
    arguments = build_parser().parse_args(argv)
    if arguments.origin is None:
        configured = os.environ.get("QWEN_WEB_BROKER_ORIGIN", "")
        arguments.origin = [entry for entry in configured.split(",") if entry]
    if not arguments.state_dir:
        sys.stderr.write(
            "the broker meters and audits through the ledger, so "
            "QWEN_WEB_STATE_DIR or --state-dir names the directory it lives in\n"
        )
        return 2
    if not arguments.origin:
        sys.stderr.write(
            "the session endpoint admits an explicit Origin alone, so "
            "QWEN_WEB_BROKER_ORIGIN or --origin names the page that reads it\n"
        )
        return 2
    signing_key_sha256 = validate_signing_key(arguments.token_key_file)
    if signing_key_sha256 is None:
        return 2
    try:
        api_key = server.read_secret_file(arguments.api_key_file, "Web UI API")
    except server.ToolError as error:
        sys.stderr.write(f"the broker cannot read the Web UI API key: {error}\n")
        return 2
    settings = BrokerSettings(arguments)
    settings.api_key = api_key
    settings.signing_key_sha256 = signing_key_sha256
    settings.start_time = process_start_time(entry_time)
    try:
        ledger = server.Ledger(arguments.state_dir)
    except (OSError, server.ToolError) as error:
        sys.stderr.write(f"the broker cannot open the ledger: {error}\n")
        return 2
    ledger.close()
    settings.session_secret, secret_path = write_session_secret(arguments.state_dir)
    service = BrokerServer((arguments.host, arguments.port), settings)
    # The port reaches the caller on stdout because an ephemeral bind is the
    # default: a launcher reads the line rather than guessing the number.
    sys.stdout.write(f"listening {arguments.host} {service.server_address[1]}\n")
    sys.stdout.flush()
    # A terminating signal raises inside the accept loop rather than ending the
    # process where it stands, so the cleanup below runs and the secret file
    # goes with the launch that wrote it. The default SIGTERM disposition would
    # leave that file behind for the next launch to find.
    for terminating_signal in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(terminating_signal, raise_interrupt)
    try:
        service.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        service.server_close()
        if os.path.lexists(secret_path):
            os.unlink(secret_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(run(sys.argv[1:]))
