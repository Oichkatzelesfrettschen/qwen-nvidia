#!/usr/bin/env python3
"""Serve two web-research tools to llama-server over stdio MCP.

llama-server spawns this process to enumerate tools, kills it, and spawns it
again for every invocation, so no in-memory state survives between calls. A
search result is therefore carried forward as an HMAC-signed opaque token that
names the canonical URL it was issued for, and fetch_exa accepts that token
alone. A model-authored URL reaches no network path.

The server name in the launch configuration is `web`, which llama-server
composes with the tool names into `web_search_exa` and `web_fetch_exa`. The
pinned llama-ui renders those two identifiers natively.

Two secrets stay outside the process image: the Exa API key and the token
signing key each live in a file that only its owner may read, and only the
paths cross into this child. The contents are read at call time and reach no
argument vector, environment value, log line, or error message.
"""

import base64
import collections
import contextlib
import datetime
import hashlib
import hmac
import html.parser
import ipaddress
import json
import math
import os
import re
import signal
import sqlite3
import stat
import sys
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request

SERVER_NAME = "web"
SERVER_VERSION = "1.0.0"
PROTOCOL_VERSION = "2025-06-18"
SUPPORTED_PROTOCOL_VERSIONS = ("2025-06-18", "2025-03-26", "2024-11-05")

QUERY_CHARACTER_CAP = 512
RESULT_COUNT_CAP = 10
DOMAIN_LIST_CAP = 10
DOMAIN_CHARACTER_CAP = 253
WINDOW_CHARACTER_CAP = 24000
WINDOW_CHARACTER_DEFAULT = 12000
HIGHLIGHT_COUNT_CAP = 3
TITLE_CHARACTER_CAP = 300
AUTHOR_CHARACTER_CAP = 200
HIGHLIGHT_CHARACTER_CAP = 1200
SEARCH_OUTPUT_CHARACTER_CAP = 16000
RESULT_ID_CHARACTER_CAP = 4096
# The accepted grant is sized to the largest one `authorize` can emit: a
# 512-character query beside twenty domains of 253 characters signs into
# roughly 7 KiB of base64url, so a shorter constant would print grants the
# serving path refuses before it verifies their signature.
AUTHORIZATION_CHARACTER_CAP = 12288
URL_CHARACTER_CAP = 2048
DOCUMENT_CHARACTER_CAP = 131072
REQUEST_TIMEOUT_SECONDS = 20.0
# The HTTP cap defends this process against a provider response of any size;
# the document cap bounds how much page text one fetched result may hold; the
# window cap bounds one reply. Three separate limits, three separate failures.
HTTP_RESPONSE_BYTE_CAP = 4 * 1024 * 1024
MAX_AGE_HOURS_CAP = 24 * 365
TOKEN_LIFETIME_DEFAULT_SECONDS = 900
TOKEN_LIFETIME_MINIMUM_SECONDS = 60
TOKEN_LIFETIME_MAXIMUM_SECONDS = 3600
SECRET_BYTE_CAP = 4096
REQUEST_LINE_CHARACTER_CAP = 1024 * 1024
JSON_DEPTH_CAP = 32
OVERSIZED_LINE = object()
RESULT_CLAIM_CONTEXT = "result-id"
AUTHORIZATION_CLAIM_CONTEXT = "search-authorization"

SEPARATOR_PATTERN = re.compile(r"^-{3,}$")
GRANT_ID_PATTERN = re.compile(r"^[A-Za-z0-9_-]{8,64}$")
FAILURE_TAG_PATTERN = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
NUMERIC_LABEL_PATTERN = re.compile(r"^(0[xX][0-9a-fA-F]+|[0-9]+)$")
HOSTNAME_PATTERN = re.compile(
    r"^(?=.{1,253}$)[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?"
    r"(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$"
)

EXA_SEARCH_ENDPOINT = "https://api.exa.ai/search"
EXA_CONTENTS_ENDPOINT = "https://api.exa.ai/contents"

# Every place a provider name is admitted reads this tuple: the stdio server's
# own argument check, the `authorize` subcommand, `issue_grant`, and the
# approval broker that calls it. `enforce_search_authorization` compares the
# grant's provider against `provider.name`, so a name admitted in one place and
# refused in another signs grants the serving path never verifies.
PROVIDER_NAMES = ("exa", "fake", "searxng")

# Which engines answer a search belongs to the SearXNG instance's own
# `settings.yml`, which groups them into qwen-named categories. The web profile
# names a category and this provider sends it, so changing the engine
# population is an edit to the instance rather than to a request field a model
# or an environment could reach.
SEARXNG_CATEGORY_PATTERN = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
SEARXNG_LANGUAGE_PATTERN = re.compile(r"^(all|[A-Za-z]{2,8}(-[A-Za-z0-9]{2,8})*)$")
ENGINE_LIST_CHARACTER_CAP = 256
SEARXNG_SAFESEARCH_VALUES = ("0", "1", "2")
# `decode_content_text` reads text, so the retrieval admits the document types
# whose bodies are text and names a PDF or an archive by its declared type
# rather than by the decode failure it would raise.
SEARXNG_DOCUMENT_CONTENT_TYPES = (
    "text/html",
    "application/xhtml+xml",
    "text/plain",
)
SEARXNG_DOCUMENT_CHARSETS = ("utf-8", "utf8", "ascii", "us-ascii")
SEARXNG_SKIPPED_ELEMENTS = frozenset(
    ("script", "style", "noscript", "template", "svg", "head")
)
SEARXNG_BLOCK_ELEMENTS = frozenset(
    (
        "address", "article", "aside", "blockquote", "br", "dd", "div", "dl",
        "dt", "figcaption", "figure", "footer", "h1", "h2", "h3", "h4", "h5",
        "h6", "header", "hr", "li", "main", "nav", "ol", "p", "pre", "section",
        "table", "td", "th", "tr", "ul",
    )
)

UNTRUSTED_HEADER = "BEGIN UNTRUSTED WEB CONTENT"
UNTRUSTED_FOOTER = "END UNTRUSTED WEB CONTENT"
NONCE_BYTES = 12

SEARCH_PER_MINUTE_DEFAULT = 10
FETCH_PER_MINUTE_DEFAULT = 20
PROVIDER_DAILY_BUDGET_DEFAULT = 500
PAGE_DAILY_BUDGET_DEFAULT = 2000
LEDGER_FILE_NAME = "web-mcp-state.sqlite3"
STATE_DIRECTORY_MODE = 0o700
LEDGER_BUSY_TIMEOUT_SECONDS = 10.0
LEDGER_BUSY_TIMEOUT_MS = 10000
AUDIT_RETENTION_SECONDS = 14 * 86400
GRANT_MAX_USES = 1
SEARCH_FETCH_ALLOWANCE_DEFAULT = 8
GRANT_ID_BYTES = 12


ExtractedContent = collections.namedtuple(
    "ExtractedContent",
    "text provider_may_have_more provider_status content_id",
)


class ToolError(Exception):
    """An expected execution failure: policy, input, or provider grounds.

    The message reaches the model inside an `isError` result, which is what
    lets the model correct its own call. A malformed request and an unexpected
    exception take JSON-RPC error codes instead, so the client distinguishes a
    tool that refused from a tool that broke.

    `status` names the audit vocabulary entry the failure is recorded under.
    The message varies with the argument that produced it and the audit trail
    is queried across calls, so the row carries the fixed term and the model
    receives the prose.
    """

    status = "invalid_argument"


class InvalidArgument(ToolError):
    """An argument, a configuration value, or a key file refuses the call."""


class AuthorizationDenied(ToolError):
    """A grant or a result identifier fails verification against the key."""

    status = "authorization_denied"


class RateLimited(ToolError):
    """A per-minute call bucket is exhausted."""

    status = "rate_limited"


class BudgetExhausted(ToolError):
    """A daily page or provider-cost budget is exhausted."""

    status = "budget_exhausted"


class ProviderHttpError(ToolError):
    """The provider answered with a transport or HTTP status failure."""

    status = "provider_http_error"


class ProviderContentError(ToolError):
    """The provider answered, and the body fails a structure or encoding rule."""

    status = "provider_content_error"


class ExpiredResult(ToolError):
    """A signed claim verifies and its term has run out."""

    status = "expired_result"


class GrantReplayed(AuthorizationDenied):
    """A grant whose single use the ledger already recorded."""


class ProviderDeadlineExpired(TimeoutError):
    """The provider call exceeded its complete wall-clock deadline."""


@contextlib.contextmanager
def provider_deadline(seconds):
    """Bound DNS, connect, headers, and body reads by one POSIX timer."""
    previous_handler = signal.getsignal(signal.SIGALRM)
    started = time.monotonic()

    def expire(_signal_number, _frame):
        raise ProviderDeadlineExpired

    signal.signal(signal.SIGALRM, expire)
    previous_delay, previous_interval = signal.setitimer(signal.ITIMER_REAL, seconds)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous_handler)
        if previous_delay > 0:
            elapsed = time.monotonic() - started
            signal.setitimer(
                signal.ITIMER_REAL,
                max(0.000001, previous_delay - elapsed),
                previous_interval,
            )


def strict_json_loads(text):
    """Decode standards-compliant JSON and reject non-finite numbers."""

    def reject_constant(value):
        raise ValueError(f"non-finite JSON constant: {value}")

    def parse_finite_float(value):
        parsed = float(value)
        if not math.isfinite(parsed):
            raise ValueError(f"non-finite JSON number: {value}")
        return parsed

    return json.loads(
        text,
        parse_constant=reject_constant,
        parse_float=parse_finite_float,
    )


# The provenance an audit row retains beside the original twelve columns. A
# metasearch answer comes from several engines and may run a second category,
# so the trail states which search it was, which category was asked, which
# engines answered and which failed, whether the fallback ran, and how many
# results survived validation. None of it is query text.
AUDIT_PROVENANCE_COLUMNS = (
    ("search_id", "TEXT"),
    ("category", "TEXT"),
    ("engines_attempted", "TEXT"),
    ("engines_answered", "TEXT"),
    ("engines_failed", "TEXT"),
    ("fallback_used", "INTEGER"),
    ("usable_results", "INTEGER"),
)

# The trail is one table across the tools this ledger serves, so the vocabulary
# names every failure any of them records. `service_refused` and
# `service_unavailable` belong to the image lane, whose executor is a local
# Unix-socket service rather than an HTTP provider: a service that answers and
# declines the job is a refusal, and a socket that takes no job at all is a
# launch state, which `provider_http_error` would report as one remote fault.
AUDIT_STATUSES = (
    "success",
    "authorization_denied",
    "invalid_argument",
    "rate_limited",
    "budget_exhausted",
    "provider_http_error",
    "provider_content_error",
    "expired_result",
    "service_refused",
    "service_unavailable",
    "internal_error",
)


def sanitized_traceback(error):
    """Return a frame list of an unexpected exception with every value dropped.

    The exception message and the source lines can carry provider response text
    or an argument the caller supplied, so the diagnostic keeps the exception
    type and the file, line, and function of each frame and discards the rest.
    """
    frames = traceback.extract_tb(error.__traceback__)
    trail = " <- ".join(
        f"{os.path.basename(frame.filename)}:{frame.lineno} in {frame.name}"
        for frame in frames
    )
    return f"web-mcp internal error: {type(error).__name__} at {trail}"


def jsonrpc_error(identifier, code, message):
    return {
        "jsonrpc": "2.0",
        "id": identifier,
        "error": {"code": code, "message": message},
    }


def tool_result(identifier, text, is_error):
    return {
        "jsonrpc": "2.0",
        "id": identifier,
        "result": {
            "content": [{"type": "text", "text": text}],
            "isError": is_error,
        },
    }


def read_secret_file(path, purpose):
    """Return the contents of a key file that only its owner reads.

    The descriptor opens with O_NOFOLLOW, O_CLOEXEC, and O_NONBLOCK, so a
    symlink planted at the configured path fails the open rather than
    redirecting the read, no child of this process inherits the descriptor,
    and a FIFO returns at once for the regular-file check rather than waiting
    for a writer. The regular-file and mode
    checks run against fstat of that same descriptor, which leaves no window
    between the check and the read for a replacement. Every check runs per call
    because llama-server respawns the child for each invocation.
    """
    if not path:
        raise ToolError(
            f"the {purpose} key file is unconfigured, so the call reaches no "
            "network path"
        )
    try:
        # O_NONBLOCK returns the descriptor of a FIFO with no writer rather
        # than waiting for one, so the fstat below rejects a special file
        # planted at the configured path instead of hanging the call. A
        # regular file reads whole under the flag.
        descriptor = os.open(
            path,
            os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
        )
    except OSError:
        raise ToolError(f"the {purpose} key file is unreadable: {path}") from None
    try:
        file_status = os.fstat(descriptor)
        if not stat.S_ISREG(file_status.st_mode):
            raise ToolError(f"the {purpose} key file is not a regular file: {path}")
        mode = stat.S_IMODE(file_status.st_mode)
        if mode & 0o077:
            raise ToolError(
                f"the {purpose} key file {path} is mode {mode:04o}; "
                "0600 is required before a call runs"
            )
        try:
            raw = os.read(descriptor, SECRET_BYTE_CAP)
        except OSError:
            raise ToolError(
                f"the {purpose} key file is unreadable: {path}"
            ) from None
    finally:
        os.close(descriptor)
    try:
        secret = raw.decode("utf-8").strip()
    except UnicodeDecodeError:
        raise ToolError(f"the {purpose} key file is not UTF-8 text: {path}") from None
    if not secret:
        raise ToolError(f"the {purpose} key file is empty: {path}")
    return secret


def resolve_token_lifetime(settings):
    """Return the configured token lifetime in seconds.

    The lifetime bounds replay of a leaked result identifier, so the admitted
    range runs from 60 seconds, below which a reasoning turn outlives its own
    search, to 3600, beyond which a transcript outlives the appliance session.
    A value outside the range refuses the call rather than being clamped, since
    a clamp hides an operator's mistake behind a working search.
    """
    raw = settings.get("token_lifetime") or ""
    if not raw:
        return TOKEN_LIFETIME_DEFAULT_SECONDS
    try:
        lifetime = int(raw)
    except ValueError:
        raise ToolError(
            "QWEN_WEB_TOKEN_LIFETIME_SECONDS is not an integer"
        ) from None
    if not (
        TOKEN_LIFETIME_MINIMUM_SECONDS <= lifetime <= TOKEN_LIFETIME_MAXIMUM_SECONDS
    ):
        raise ToolError(
            "QWEN_WEB_TOKEN_LIFETIME_SECONDS lies outside "
            f"[{TOKEN_LIFETIME_MINIMUM_SECONDS}, "
            f"{TOKEN_LIFETIME_MAXIMUM_SECONDS}]: {lifetime}"
        )
    return lifetime


def base64url_encode(payload):
    return base64.urlsafe_b64encode(payload).rstrip(b"=").decode("ascii")


def base64url_decode(text):
    padding = "=" * (-len(text) % 4)
    return base64.urlsafe_b64decode(text + padding)


def require_public_host(parts):
    """Refuse a result whose host names this machine or a private network.

    A search result reaches the provider's crawler and the wrapper's own error
    text, and a loopback or RFC 1918 literal in that position asks the tool
    surface to describe the network the appliance sits on. The check reads the
    literal address and the reserved `localhost` name; classifying an ordinary
    hostname would take a resolution here that differs from the provider's own,
    so a name resolves nowhere in this process.
    """
    host = (parts.hostname or "").lower()
    if host == "localhost" or host.endswith(".localhost"):
        raise ProviderContentError(
            "the result URL names a private host, which is refused"
        )
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        # A host whose every label is a decimal or hexadecimal integer and
        # which fails canonical parsing is a legacy numeric spelling:
        # `2130706433`, `0x7f000001`, and `0177.0.0.1` all reach 127.0.0.1
        # through common resolvers while `ip_address` rejects them, so the
        # private-address branch below would never see them. The spelling is
        # refused rather than converted, which keeps one address form in the
        # signed reference and leaves a canonical public literal admitted.
        labels = host.split(".")
        if host and all(NUMERIC_LABEL_PATTERN.match(label) for label in labels):
            raise ProviderContentError(
                "the result URL names a noncanonical numeric host, which is "
                "refused"
            )
        return
    if (
        address.is_private
        or address.is_loopback
        or address.is_link_local
        or address.is_reserved
        or address.is_multicast
        or address.is_unspecified
    ):
        raise ProviderContentError(
            "the result URL names a private address, which is refused"
        )


def require_loopback_endpoint(url, allow_remote, name):
    """Return a provider endpoint reduced to scheme and authority.

    A SearXNG instance runs on this machine or reaches one over an
    SSH-forwarded loopback port, so the endpoint is read the way
    `require_public_host` reads a result host and with the opposite polarity:
    the check classifies the literal address and the reserved `localhost` name
    and resolves no hostname, since a resolution here would differ from the one
    the request performs. `QWEN_WEB_SEARXNG_ALLOW_REMOTE=1` admits any host for
    an operator who accepts that the model-authored query leaves the machine.
    """
    parts = urllib.parse.urlsplit(url.strip())
    if parts.scheme.lower() not in ("http", "https"):
        raise InvalidArgument(f"{name} carries an unsupported scheme: {url}")
    if not parts.netloc or "@" in parts.netloc:
        raise InvalidArgument(f"{name} names no plain host: {url}")
    if parts.query or parts.fragment:
        raise InvalidArgument(f"{name} carries a query or fragment: {url}")
    if allow_remote:
        return f"{parts.scheme.lower()}://{parts.netloc.lower()}{parts.path.rstrip('/')}"
    host = (parts.hostname or "").lower()
    loopback = host == "localhost" or host.endswith(".localhost")
    if not loopback:
        try:
            loopback = ipaddress.ip_address(host).is_loopback
        except ValueError:
            loopback = False
    if not loopback:
        raise InvalidArgument(
            f"{name} names a host other than loopback, which "
            "QWEN_WEB_SEARXNG_ALLOW_REMOTE=1 admits: " + url
        )
    return f"{parts.scheme.lower()}://{parts.netloc.lower()}{parts.path.rstrip('/')}"


def canonical_url(url):
    """Return the comparison form of a URL: scheme and host lowercased.

    Token issue and token redemption both run through this function, so a
    fetch matches its search on the same string the signature covers.
    """
    if len(url) > URL_CHARACTER_CAP:
        raise ProviderContentError(
            f"the result URL exceeds the {URL_CHARACTER_CAP} character cap"
        )
    parts = urllib.parse.urlsplit(url)
    if parts.scheme.lower() not in ("http", "https"):
        raise ProviderContentError(f"the result URL carries an unsupported scheme: {url}")
    if not parts.netloc:
        raise ProviderContentError(f"the result URL names no host: {url}")
    if "@" in parts.netloc:
        raise ProviderContentError("the result URL carries userinfo, which is refused")
    if any(character in url for character in ("\n", "\r", "\t", " ")):
        raise ProviderContentError("the result URL carries whitespace, which is refused")
    require_public_host(parts)
    return urllib.parse.urlunsplit(
        (
            parts.scheme.lower(),
            parts.netloc.lower(),
            parts.path,
            parts.query,
            "",
        )
    )


def sign_claim(signing_key, context, claim):
    """Return `payload.signature` for a claim bound to one context string.

    The HMAC covers the context and the base64url payload string rather than
    the decoded object, so an encoder that admits two spellings of one object
    still signs one byte string, and a search authorization never verifies as a
    result identifier.
    """
    payload = base64url_encode(
        json.dumps(claim, sort_keys=True, separators=(",", ":")).encode("utf-8")
    )
    signature = base64url_encode(
        hmac.new(
            signing_key.encode("utf-8"),
            f"{context}:{payload}".encode("ascii"),
            hashlib.sha256,
        ).digest()
    )
    return f"{payload}.{signature}"


def verify_claim(signing_key, context, token, now, label):
    """Return the claim of a token whose signature verifies and whose term runs."""
    if not isinstance(token, str) or token.count(".") != 1:
        raise AuthorizationDenied(f"the {label} is malformed")
    payload, signature = token.split(".")
    expected = base64url_encode(
        hmac.new(
            signing_key.encode("utf-8"),
            f"{context}:{payload}".encode("ascii"),
            hashlib.sha256,
        ).digest()
    )
    if not hmac.compare_digest(signature, expected):
        raise AuthorizationDenied(f"the {label} signature fails verification")
    try:
        claim = json.loads(base64url_decode(payload).decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        raise AuthorizationDenied(f"the {label} payload is malformed") from None
    if not isinstance(claim, dict):
        raise AuthorizationDenied(f"the {label} payload is malformed")
    expiry = claim.get("expiry")
    if not isinstance(expiry, (int, float)) or now >= expiry:
        raise ExpiredResult(f"the {label} has expired")
    return claim


def freshness_policy(constraints):
    """Return the three fields that decide which copy of a page a call reads.

    A fetch spends provider budget under the same publication window and cached
    age the search was approved for, so the policy travels inside the signed
    result reference rather than being re-derived from arguments the model
    writes on the second call.
    """
    return {
        "max_age_hours": constraints.get("max_age_hours"),
        "published_after": constraints.get("published_after") or "",
        "published_before": constraints.get("published_before") or "",
    }


def issue_result_id(
    signing_key,
    url,
    provider_result_id,
    provider_name,
    search_id,
    freshness,
    issued_at,
    lifetime_seconds,
):
    """Sign a result reference into an opaque token.

    The reference names both keys a provider answers on: `canonical_url` is
    what a URL-keyed contents response matches, and `provider_result_id` is the
    opaque identifier Exa returns beside it, which survives a redirect or a
    trailing-slash difference that would break URL equality. `search_id` binds
    the reference to the search that issued it, and `freshness` carries the
    approved publication window and cached age into the fetch.
    """
    def signed(identifier):
        return sign_claim(
            signing_key,
            RESULT_CLAIM_CONTEXT,
            {
                "canonical_url": url,
                "provider_result_id": identifier,
                "provider": provider_name,
                "issued_at": issued_at,
                "expiry": issued_at + lifetime_seconds,
                "search_id": search_id,
                "freshness": freshness,
            },
        )

    token = signed(provider_result_id)
    if len(token) > RESULT_ID_CHARACTER_CAP:
        # `fetch_exa` caps the `result_id` argument, so a token past that cap
        # renders a result no fetch can redeem. The opaque identifier is what
        # a long claim carries, and the canonical URL still resolves the
        # contents entry, so the identifier is dropped rather than the result.
        token = signed("")
    if len(token) > RESULT_ID_CHARACTER_CAP:
        raise ProviderContentError(
            f"the result reference exceeds the {RESULT_ID_CHARACTER_CAP} "
            "character cap that redeems it"
        )
    return token


def redeem_result_id(signing_key, result_id, now):
    """Return the claim of a result identifier this server issued.

    A tampered payload fails `compare_digest` and an expired claim fails the
    term check, so the only URL a fetch reaches is one a prior search returned
    inside the lifetime.
    """
    claim = verify_claim(
        signing_key, RESULT_CLAIM_CONTEXT, result_id, now, "result_id"
    )
    if "canonical_url" not in claim:
        raise AuthorizationDenied("the result_id payload is malformed")
    claim["canonical_url"] = canonical_url(str(claim["canonical_url"]))
    provider_result_id = claim.get("provider_result_id")
    claim["provider_result_id"] = (
        provider_result_id
        if isinstance(provider_result_id, str)
        and len(provider_result_id) <= RESULT_ID_CHARACTER_CAP
        else ""
    )
    freshness = claim.get("freshness")
    claim["freshness"] = freshness_policy(
        freshness if isinstance(freshness, dict) else {}
    )
    search_id = claim.get("search_id")
    claim["search_id"] = search_id if isinstance(search_id, str) else ""
    return claim


def authorization_claim(
    query,
    include_domains,
    exclude_domains,
    published_after,
    published_before,
    max_age_hours,
    max_results,
    expiry,
):
    """Return the canonical form of a search grant.

    `max_age_hours` is covered because 0 forces a live crawl, which is the one
    search parameter that spends provider budget on the model's word. Both the
    issuing subcommand and the serving path build the grant through this
    function, so the comparison runs over one spelling of every field:
    the query stripped, the domain lists normalized and sorted, and the dates
    in the calendar form `require_iso_date` produces.
    """
    return {
        "query": query.strip(),
        "include_domains": sorted(include_domains),
        "exclude_domains": sorted(exclude_domains),
        "published_after": published_after,
        "published_before": published_before,
        "max_age_hours": max_age_hours,
        "max_results": max_results,
        "expiry": expiry,
    }


def enforce_search_authorization(
    settings, signing_key, query, max_results, constraints, provider_name, ledger
):
    """Return the grant a search runs under, or None for an unauthorized one.

    A search query is model-authored, and a note the model reads can rewrite it
    the way `tool-08` rewrote a tool argument in every measured arm, so the
    signed grant rather than the model decides which query reaches the
    provider. `QWEN_WEB_SEARCH_AUTH=optional` admits an unauthorized search for
    an operator who accepts that exposure; the default refuses it.

    A grant names one provider, one profile, and one use, so a token issued for
    the metered production profile buys nothing against another profile or
    another provider. The single use is spent in the ledger, which is what
    makes the count survive the respawn, so a presented grant requires a state
    directory rather than falling back to an unenforced count.
    """
    mode = settings.get("search_auth") or "required"
    if mode not in ("required", "optional"):
        raise ToolError(
            f"QWEN_WEB_SEARCH_AUTH names an unknown mode: {mode}"
        )
    token = settings.get("_authorization")
    if not token:
        if mode == "required":
            raise AuthorizationDenied(
                "search_exa requires an authorization token issued by "
                "`server.py authorize`; the operator grants the query rather "
                "than the model"
            )
        return None
    if ledger is None:
        raise AuthorizationDenied(
            "a search authorization spends a single use that lives in the "
            "ledger, so QWEN_WEB_STATE_DIR names the directory that holds it"
        )
    granted = verify_claim(
        signing_key,
        AUTHORIZATION_CLAIM_CONTEXT,
        token,
        time.time(),
        "authorization",
    )
    requested = authorization_claim(
        query,
        constraints["include_domains"],
        constraints["exclude_domains"],
        constraints["published_after"],
        constraints["published_before"],
        constraints["max_age_hours"],
        max_results,
        granted.get("expiry"),
    )
    for field in (
        "query",
        "include_domains",
        "exclude_domains",
        "published_after",
        "published_before",
        "max_age_hours",
    ):
        if granted.get(field) != requested[field]:
            raise AuthorizationDenied(
                f"the search arguments leave the authorization: {field} differs"
            )
    granted_results = granted.get("max_results")
    if not isinstance(granted_results, int) or max_results > granted_results:
        raise AuthorizationDenied(
            "the search arguments leave the authorization: max_results exceeds "
            "the granted count"
        )
    if granted.get("provider") != provider_name:
        raise AuthorizationDenied(
            "the authorization names another provider than the configured one"
        )
    if granted.get("profile_id") != (settings.get("profile") or "default"):
        raise AuthorizationDenied(
            "the authorization names another profile than the serving one"
        )
    if granted.get("max_uses") != GRANT_MAX_USES:
        raise AuthorizationDenied(
            f"the authorization admits a use count other than {GRANT_MAX_USES}"
        )
    grant_id = granted.get("grant_id")
    if not isinstance(grant_id, str) or not GRANT_ID_PATTERN.match(grant_id):
        raise AuthorizationDenied("the authorization carries no usable grant_id")
    return granted


class Provider:
    """The two operations a web-research backend supplies, and what it honors.

    `search` returns a list of result records with `url` and optional `title`,
    `published`, `author`, `engine`, and `highlights`. `contents` returns the
    extracted text of one already-issued URL.

    The five capability flags state which authorized search arguments the
    backend carries into its request. An argument a human approved and the
    provider cannot express is refused by `refuse_unhonored_arguments` naming
    both the argument and the provider, because dropping it silently serves a
    result set outside the window the approval covered. A flag reads true where
    the argument is honored, whether the provider's own request field carries
    it or this wrapper enforces it over the response: `include_domains` and
    `exclude_domains` reach `filter_by_domains` and `max_results` reaches the
    slice in `call_search` for every provider, so both stay true where the
    backend has no matching request field.

    `supports_paging` states whether the backend returns further pages of
    results. No tool argument requests one -- `fetch_exa`'s `start_index` pages
    the stored document snapshot inside this wrapper -- so the flag records the
    surface a later argument would consult rather than gating one today.

    `provenance` returns what the completed search retained about where its
    results came from. `call_search` copies it into the audit row, so a trail
    states which engines were asked and which answered without holding the
    query. A backend that reports none leaves the fields empty.
    """

    name = "provider"

    supports_exact_date_bounds = True
    supports_freshness_max_age = True
    supports_domain_filter = True
    supports_paging = False
    supports_num_results = True

    def provenance(self):
        return {
            "category": "",
            "engines_attempted": "",
            "engines_answered": "",
            "engines_failed": "",
            "fallback_used": 0,
            "usable_results": 0,
        }

    def preflight(self):
        """Validate the credential this provider posts with.

        A grant admits one search and the ledger spends its use before the
        request, so a credential the provider rejects at request time would
        cost the operator a token for a call that reached no network. The
        check runs ahead of that spend and reads the same file the request
        does.
        """
        return None

    def search(self, query, max_results, constraints):
        raise NotImplementedError

    def contents(self, url, max_characters, provider_result_id="", freshness=None):
        raise NotImplementedError


def select_by_reference(entries, url, provider_result_id=""):
    """Return the entry the signed reference names, by either key.

    A provider response is attacker-influenced through the page it describes,
    so the entry is selected by what the claim carries rather than by position
    in the array. Exa keys a contents entry by its opaque result identifier or
    by the URL, and a redirect moves the second while leaving the first, so a
    match on either key resolves the entry and a match on neither returns
    nothing.
    """
    if not isinstance(entries, list):
        return None
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        for key in ("url", "id"):
            candidate = entry.get(key)
            if not isinstance(candidate, str):
                continue
            if provider_result_id and candidate == provider_result_id:
                return entry
            try:
                if canonical_url(candidate) == url:
                    return entry
            except ToolError:
                continue
    return None


def host_within_domain(host, domain):
    """Return whether a host is the domain itself or a subdomain of it."""
    return host == domain or host.endswith("." + domain)


def admitted_by_domains(url, include_domains, exclude_domains):
    """Return whether one URL's host survives the granted domain lists.

    The comparison reads the hostname rather than the netloc, which leaves the
    exclusion in force where the URL carries a port.
    """
    host = (urllib.parse.urlsplit(url).hostname or "").lower()
    if include_domains and not any(
        host_within_domain(host, domain) for domain in include_domains
    ):
        return False
    return not any(host_within_domain(host, domain) for domain in exclude_domains)


def unresponsive_engine_names(reported):
    """Return the engine names a SearXNG answer reports as failing.

    The field is a list whose entries are `[engine, reason]` pairs in the
    instance's JSON format, and an entry may be a bare name. The value comes
    from the instance rather than from a page, and it reaches an audit column,
    so a name is clipped to the engine-list cap and an entry of another shape
    contributes nothing.
    """
    names = []
    if not isinstance(reported, list):
        return names
    for entry in reported:
        if isinstance(entry, list) and entry:
            entry = entry[0]
        if isinstance(entry, str) and entry.strip():
            name = entry.strip()[:ENGINE_LIST_CHARACTER_CAP]
            if name not in names:
                names.append(name)
    return names


def filter_by_domains(results, include_domains, exclude_domains):
    """Return the records the granted domain lists admit.

    The lists reach the provider as request fields, and a provider defect or a
    compromised response can still answer with an off-domain record that the
    renderer would sign into a fetchable Result ID, so the wrapper enforces
    the operator's scope over what came back. The comparison reads the URL's
    hostname rather than its netloc, which leaves the exclusion in force where
    the record carries a port.
    """
    if not include_domains and not exclude_domains:
        return results
    return [
        record
        for record in results
        if isinstance(record, dict)
        and admitted_by_domains(
            str(record.get("url", "")), include_domains, exclude_domains
        )
    ]


def refuse_unhonored_arguments(provider, constraints, max_results):
    """Refuse a search argument the active provider cannot carry.

    The dialog a human approves names the query, the publication interval, both
    domain lists, the result count, and whether `max_age_hours` of 0 forces a
    live crawl, and the grant is signed over those exact fields. A provider
    that drops one of them answers a different question than the one approved,
    so the call ends here naming the argument and the provider rather than
    returning results the operator never authorized. The refusal runs before
    the ledger spends the grant, which leaves the single use available to the
    caller who corrects the arguments.
    """
    if not provider.supports_exact_date_bounds and (
        constraints["published_after"] or constraints["published_before"]
    ):
        raise InvalidArgument(
            "published_after and published_before name an exact publication "
            f"interval, which provider {provider.name} does not express"
        )
    if constraints["max_age_hours"] is not None and (
        not provider.supports_freshness_max_age
    ):
        raise InvalidArgument(
            "max_age_hours bounds the age of the copy served, which provider "
            f"{provider.name} does not express"
        )
    if not provider.supports_domain_filter and (
        constraints["include_domains"] or constraints["exclude_domains"]
    ):
        raise InvalidArgument(
            "include_domains and exclude_domains bound the sources, which "
            f"provider {provider.name} does not express"
        )
    if not provider.supports_num_results and max_results:
        raise InvalidArgument(
            "max_results bounds the result count, which provider "
            f"{provider.name} does not express"
        )


def failure_tag(status):
    """Return the provider's failure tag reduced to a safe short token.

    The tag reaches the model inside an error message, so a value that is not a
    short identifier is replaced rather than forwarded.
    """
    error = status.get("error")
    tag = error.get("tag") if isinstance(error, dict) else None
    if isinstance(tag, str) and FAILURE_TAG_PATTERN.match(tag.strip()):
        return tag.strip()
    return "unspecified"


class RefuseRedirect(urllib.request.HTTPRedirectHandler):
    """End a provider redirect at the response that requested it.

    `HTTPRedirectHandler.redirect_request` copies the request headers onto the
    redirected request, so following a cross-host 301, 302, or 303 hands
    `x-api-key` to a host of the redirector's choosing. Returning None leaves
    urllib raising the 3xx as an `HTTPError`, which `_post` reports with its
    status, so the key reaches the pinned Exa endpoint alone.
    """

    def redirect_request(self, request, fp, code, message, headers, newurl):
        return None


# One opener serves every provider request. `build_opener` replaces the default
# redirect handler with the subclass instance, which is what removes the
# following behavior from the whole process rather than from one call site.
PROVIDER_OPENER = urllib.request.build_opener(RefuseRedirect())


class ExaProvider(Provider):
    """Exa's /search and /contents JSON APIs over urllib.

    The API key reaches the `x-api-key` header alone and is read per call from
    its file. The response body is read to one byte past the cap so an
    oversized body is refused during the read rather than after it.
    """

    name = "exa"

    # The Search API reads `startPublishedDate`, `endPublishedDate`,
    # `includeDomains`, `excludeDomains`, and `numResults` at the request top
    # level and `maxAgeHours` inside `contents`, at any hour count including
    # the 0 that forces a live crawl. It returns one ranked set per request.
    supports_exact_date_bounds = True
    supports_freshness_max_age = True
    supports_domain_filter = True
    supports_paging = False
    supports_num_results = True
    freshness_max_age_hours = None

    def __init__(self, key_file_path):
        self.key_file_path = key_file_path
        self.response_bytes = 0
        # The endpoints are instance attributes seeded from the module
        # constants, which lets a test point one instance at a local fixture
        # server. The configuration reads no endpoint, because a redirected
        # endpoint would carry the `x-api-key` header to a host of the
        # redirector's choosing.
        self.search_endpoint = EXA_SEARCH_ENDPOINT
        self.contents_endpoint = EXA_CONTENTS_ENDPOINT

    def preflight(self):
        read_secret_file(self.key_file_path, "Exa API")

    def _post(self, endpoint, body):
        api_key = read_secret_file(self.key_file_path, "Exa API")
        request = urllib.request.Request(
            endpoint,
            data=json.dumps(body).encode("utf-8"),
            headers={
                "content-type": "application/json",
                "accept": "application/json",
                "x-api-key": api_key,
            },
            method="POST",
        )
        try:
            with provider_deadline(REQUEST_TIMEOUT_SECONDS):
                with PROVIDER_OPENER.open(
                    request, timeout=REQUEST_TIMEOUT_SECONDS
                ) as response:
                    raw = response.read(HTTP_RESPONSE_BYTE_CAP + 1)
            self.response_bytes += len(raw)
        except ProviderDeadlineExpired:
            raise ProviderHttpError(
                f"the provider request exceeded {REQUEST_TIMEOUT_SECONDS:g} seconds"
            ) from None
        except urllib.error.HTTPError as error:
            status_code = error.code
            error.close()
            raise ProviderHttpError(
                f"the provider rejected the request with status {status_code}"
            ) from None
        except Exception:
            raise ProviderHttpError("the provider request failed") from None
        if len(raw) > HTTP_RESPONSE_BYTE_CAP:
            raise ProviderContentError(
                f"the provider response exceeds the {HTTP_RESPONSE_BYTE_CAP} byte cap"
            )
        try:
            document = strict_json_loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise ProviderContentError("the provider response is not valid UTF-8 JSON") from None
        if not isinstance(document, dict):
            raise ProviderContentError("the provider response is not a JSON object")
        return document

    def search(self, query, max_results, constraints):
        """Ask /search for ranked results with highlights inside one request.

        Exa's Search API reads `maxAgeHours` inside the `contents` object,
        beside the highlight request that decides what text is returned, and
        reads the publication window and the domain filters at the request top
        level. A cached-age bound written at the top level of a /search body is
        a key the endpoint ignores, which serves a cached page under a policy
        the operator granted for a live crawl.
        """
        contents = {
            "highlights": {
                "query": query,
                "maxCharacters": HIGHLIGHT_CHARACTER_CAP,
            }
        }
        if constraints["max_age_hours"] is not None:
            contents["maxAgeHours"] = constraints["max_age_hours"]
        body = {
            "query": query,
            "numResults": max_results,
            "contents": contents,
        }
        if constraints["published_after"]:
            body["startPublishedDate"] = constraints["published_after"]
        if constraints["published_before"]:
            body["endPublishedDate"] = constraints["published_before"]
        if constraints["include_domains"]:
            body["includeDomains"] = constraints["include_domains"]
        if constraints["exclude_domains"]:
            body["excludeDomains"] = constraints["exclude_domains"]
        document = self._post(self.search_endpoint, body)
        results = document.get("results")
        # An answer whose `results` is absent or holds an entry that is not an
        # object is malformed provider content rather than an empty search: a
        # string in that position rendered as `No results.` and a null reached
        # `record.get` in the renderer.
        if not isinstance(results, list):
            raise ProviderContentError(
                "the provider response carries no result list"
            )
        if any(not isinstance(record, dict) for record in results):
            raise ProviderContentError(
                "the provider response carries a result that is not an object"
            )
        return results

    def contents(self, url, max_characters, provider_result_id="", freshness=None):
        """Return the content record Exa reports as retrieved for this result.

        Exa answers a contents request with a `statuses` array beside
        `results`, and a failed URL still occupies a position in the response,
        so taking `results[0]` returns another URL's page whenever the
        requested one failed or the provider reordered the array. The status
        for this reference must read success and a result must name it before
        any text is returned, matched on the opaque result identifier or the
        canonical URL, since Exa keys an entry by either.
        """
        body = {"urls": [url], "text": {"maxCharacters": max_characters}}
        # The Contents API reads `maxAgeHours` at the request top level, where
        # the Search API reads it inside `contents`, so the same policy takes
        # two positions and the fetch spends the age the search was granted.
        policy = freshness_policy(freshness or {})
        if policy["max_age_hours"] is not None:
            body["maxAgeHours"] = policy["max_age_hours"]
        document = self._post(self.contents_endpoint, body)
        status = select_by_reference(
            document.get("statuses"), url, provider_result_id
        )
        if status is None:
            raise ProviderContentError("the provider reported no status for the result")
        if str(status.get("status", "")).lower() != "success":
            raise ProviderContentError(
                "the provider could not retrieve the result: "
                + failure_tag(status)
            )
        record = select_by_reference(
            document.get("results"), url, provider_result_id
        )
        if record is None:
            raise ProviderContentError("the provider returned no content for the result")
        return record


class HtmlTextExtractor(html.parser.HTMLParser):
    """Reduce one HTML document to the text a reader sees.

    A SearXNG result names a page rather than carrying it, so the fetch reads
    the source itself and this parser is what turns the response into the text
    `decode_content_text` accepts. Script, style, and template contents are
    dropped because they are program text rather than prose, and a block
    element ends the line so the extracted document keeps the paragraph
    structure a model reads it by.
    """

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.suppressed = 0

    def handle_starttag(self, tag, attributes):
        if tag in SEARXNG_SKIPPED_ELEMENTS:
            self.suppressed += 1
        elif tag in SEARXNG_BLOCK_ELEMENTS:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in SEARXNG_SKIPPED_ELEMENTS:
            self.suppressed = max(0, self.suppressed - 1)
        elif tag in SEARXNG_BLOCK_ELEMENTS:
            self.parts.append("\n")

    def handle_data(self, data):
        if self.suppressed == 0:
            self.parts.append(data)

    def text(self):
        joined = "".join(self.parts)
        lines = [" ".join(line.split()) for line in joined.splitlines()]
        return "\n".join(line for line in lines if line)


def html_to_text(document):
    """Return the readable text of an HTML document, or the document itself.

    A malformed document reaches this parser as page bytes an attacker chose,
    so a parser failure returns the raw text rather than breaking the call: the
    frame around the window already states that the content is untrusted, and a
    refusal here would let a broken page deny the fetch its Result ID bought.
    """
    extractor = HtmlTextExtractor()
    try:
        extractor.feed(document)
        extractor.close()
    except Exception:
        return document
    return extractor.text()


class SearXNGProvider(Provider):
    """A SearXNG instance's JSON search API, and a direct read of one result.

    `GET {base}/search?q=...&format=json` returns ranked metadata with no page
    text, so `contents` retrieves the source itself over one GET of the exact
    canonical URL a prior search signed into a Result ID. That retrieval runs
    through `PROVIDER_OPENER`, which ends a redirect at the response that
    requested it, so the fetch reaches the host the search returned and no
    other; a page that answers only behind a redirect therefore fails.

    The instance is unauthenticated, so no secret reaches this provider and
    `preflight` validates nothing. The endpoint, the categories, and the
    minimum are validated in `__init__`, ahead of every ledger transaction, so
    a misconfigured profile spends no grant.

    Which engines answer belongs to the instance's `settings.yml`, which groups
    them under qwen-named categories. The web profile names a primary category
    and an optional fallback, and this provider sends the category: the engine
    population changes by editing the instance rather than by any request field
    a model or an environment reaches.
    """

    name = "searxng"

    # The JSON API reads `categories`, `language`, `safesearch`, and `pageno`,
    # and carries no publication interval. A mixed category answers from
    # engines whose recency support differs -- Bing's web engine expresses no
    # time range at all -- so a category cannot promise one and both temporal
    # arguments are refused rather than approximated. Domain scope and result
    # count are honored in this provider: it drops an off-domain or private
    # record before counting, which is also what decides whether the fallback
    # category runs.
    supports_exact_date_bounds = False
    supports_freshness_max_age = False
    supports_domain_filter = True
    supports_paging = False
    supports_num_results = True

    def __init__(
        self,
        base_url,
        primary_category,
        fallback_category="",
        minimum_results=1,
        language="",
        safesearch="",
        allow_remote=False,
    ):
        self.response_bytes = 0
        self.timeout_seconds = REQUEST_TIMEOUT_SECONDS
        self.fallback_used = 0
        self.usable_results = 0
        self.engines_answered = []
        self.engines_failed = []
        if not base_url:
            raise InvalidArgument(
                "the searxng provider requires QWEN_WEB_SEARXNG_URL to name "
                "the instance"
            )
        self.base_url = require_loopback_endpoint(
            base_url, allow_remote, "QWEN_WEB_SEARXNG_URL"
        )
        self.search_endpoint = self.base_url + "/search"
        self.primary_category = (primary_category or "").strip()
        if not SEARXNG_CATEGORY_PATTERN.match(self.primary_category):
            raise InvalidArgument(
                "QWEN_WEB_SEARXNG_PRIMARY_CATEGORY names no category the "
                f"instance can carry: {primary_category}"
            )
        self.fallback_category = (fallback_category or "").strip()
        if self.fallback_category in ("-", ""):
            self.fallback_category = ""
        elif not SEARXNG_CATEGORY_PATTERN.match(self.fallback_category):
            raise InvalidArgument(
                "QWEN_WEB_SEARXNG_FALLBACK_CATEGORY names no category the "
                f"instance can carry: {fallback_category}"
            )
        try:
            self.minimum_results = int(minimum_results)
        except (TypeError, ValueError):
            raise InvalidArgument(
                "QWEN_WEB_SEARXNG_MINIMUM_RESULTS names no integer: "
                f"{minimum_results}"
            ) from None
        if not 1 <= self.minimum_results <= RESULT_COUNT_CAP:
            raise InvalidArgument(
                "QWEN_WEB_SEARXNG_MINIMUM_RESULTS lies between 1 and "
                f"{RESULT_COUNT_CAP}, and the configuration names "
                f"{self.minimum_results}"
            )
        self.language = language
        if self.language and not SEARXNG_LANGUAGE_PATTERN.match(self.language):
            raise InvalidArgument(
                f"QWEN_WEB_SEARXNG_LANGUAGE names no language tag: {self.language}"
            )
        self.safesearch = safesearch
        if self.safesearch and self.safesearch not in SEARXNG_SAFESEARCH_VALUES:
            raise InvalidArgument(
                "QWEN_WEB_SEARXNG_SAFESEARCH reads one of "
                + ", ".join(SEARXNG_SAFESEARCH_VALUES)
                + f", and the configuration names {self.safesearch}"
            )

    def _open(self, url, accept):
        """Return the body and headers of one bounded GET.

        The body is read to one byte past the cap so an oversized response is
        refused during the read, and the same POSIX timer that bounds an Exa
        request bounds DNS, connect, headers, and body here.
        """
        request = urllib.request.Request(
            url, headers={"accept": accept}, method="GET"
        )
        try:
            with provider_deadline(self.timeout_seconds):
                with PROVIDER_OPENER.open(
                    request, timeout=self.timeout_seconds
                ) as response:
                    raw = response.read(HTTP_RESPONSE_BYTE_CAP + 1)
                    headers = response.headers
            self.response_bytes += len(raw)
        except ProviderDeadlineExpired:
            raise ProviderHttpError(
                f"the provider request exceeded {self.timeout_seconds:g} seconds"
            ) from None
        except urllib.error.HTTPError as error:
            status_code = error.code
            error.close()
            raise ProviderHttpError(
                f"the provider rejected the request with status {status_code}"
            ) from None
        except Exception:
            raise ProviderHttpError("the provider request failed") from None
        if len(raw) > HTTP_RESPONSE_BYTE_CAP:
            raise ProviderContentError(
                f"the provider response exceeds the {HTTP_RESPONSE_BYTE_CAP} byte cap"
            )
        return raw, headers

    def search(self, query, max_results, constraints):
        """Query the primary category, and the fallback once where it is short.

        A record is usable when its URL canonicalizes, names a public host,
        survives the granted domain lists, and is not a URL an earlier record
        already carried, so the count that decides the fallback is the count of
        results the reply can actually carry: `render_search_results` renders
        one block per canonical URL, so a repeat that counted here would both
        inflate the audit's `usable_results` and suppress a fallback the reply
        needed. Exactly one fallback query runs: an instance suspends a failing
        engine on its own, so a retry loop here would spend the approval on the
        same outage the instance is already routing around.
        """
        issued = set()
        usable = self._query_category(
            query, self.primary_category, constraints, issued
        )
        if len(usable) < self.minimum_results and self.fallback_category:
            self.fallback_used = 1
            usable = usable + self._query_category(
                query, self.fallback_category, constraints, issued
            )
        self.usable_results = len(usable)
        return usable[:max_results]

    def _query_category(self, query, category, constraints, issued):
        """Return the usable records of one category query.

        A result whose URL names this machine, a private network, or a domain
        outside the grant is dropped here rather than raising, because a
        metasearch answer mixes engines and one bad entry among ten is an entry
        to discard rather than a reason to refuse the approved search. `issued`
        accumulates the canonical URLs already returned across both category
        queries, so one URL is counted and rendered once.
        """
        parameters = [("q", query), ("format", "json"), ("categories", category)]
        if self.language:
            parameters.append(("language", self.language))
        if self.safesearch:
            parameters.append(("safesearch", self.safesearch))
        raw, _ = self._open(
            self.search_endpoint + "?" + urllib.parse.urlencode(parameters),
            "application/json",
        )
        try:
            document = strict_json_loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise ProviderContentError(
                "the provider response is not valid UTF-8 JSON"
            ) from None
        if not isinstance(document, dict):
            raise ProviderContentError("the provider response is not a JSON object")
        results = document.get("results")
        if not isinstance(results, list):
            raise ProviderContentError("the provider response carries no result list")
        if any(not isinstance(record, dict) for record in results):
            raise ProviderContentError(
                "the provider response carries a result that is not an object"
            )
        for name in unresponsive_engine_names(document.get("unresponsive_engines")):
            if name not in self.engines_failed:
                self.engines_failed.append(name)
        usable = []
        for position, record in enumerate(results, start=1):
            mapped = self.map_result(record, category, position)
            try:
                mapped["url"] = canonical_url(mapped["url"])
            except ToolError:
                continue
            if not admitted_by_domains(
                mapped["url"],
                constraints["include_domains"],
                constraints["exclude_domains"],
            ):
                continue
            if mapped["url"] in issued:
                continue
            issued.add(mapped["url"])
            for name in mapped["engines"]:
                if name not in self.engines_answered:
                    self.engines_answered.append(name)
            usable.append(mapped)
        return usable

    def provenance(self):
        attempted = list(self.engines_answered) + [
            name for name in self.engines_failed if name not in self.engines_answered
        ]
        return {
            "category": self.primary_category,
            "engines_attempted": ",".join(sorted(attempted)),
            "engines_answered": ",".join(sorted(self.engines_answered)),
            "engines_failed": ",".join(sorted(self.engines_failed)),
            "fallback_used": self.fallback_used,
            "usable_results": self.usable_results,
        }

    @staticmethod
    def map_result(record, category, rank):
        """Return one SearXNG entry in the shape the renderer reads.

        `content` is the instance's own snippet, which takes the highlight
        position an Exa result fills. `engines`, `category`, `rank`, and
        `score` state where the entry came from and how the instance placed it,
        which is what the reply's `Sources:` line and the audit row read. The
        record carries no opaque identifier, so `provider_result_id` returns
        the empty string and the canonical URL alone resolves the fetch.
        """
        engines = []
        for key in ("engines", "engine"):
            value = record.get(key)
            if isinstance(value, str):
                value = [value]
            if isinstance(value, list):
                for entry in value:
                    if (
                        isinstance(entry, str)
                        and entry.strip()
                        and entry.strip() not in engines
                    ):
                        engines.append(entry.strip())
        snippet = record.get("content")
        published = record.get("publishedDate")
        score = record.get("score")
        return {
            "url": str(record.get("url", "")),
            "title": record.get("title") or "",
            "publishedDate": published if isinstance(published, str) else "",
            "author": "",
            "engines": engines,
            "category": category,
            "rank": rank,
            "score": score if isinstance(score, (int, float)) else None,
            "highlights": [snippet] if isinstance(snippet, str) and snippet else [],
        }

    def contents(self, url, max_characters, provider_result_id="", freshness=None):
        """Return the text of the source page a signed Result ID names.

        A SearXNG instance holds no page text, so the document comes from the
        host the search returned. `redeem_result_id` has verified the signature
        and re-run `canonical_url`, which applies `require_public_host`, so the
        URL reaching this GET is one a prior search issued over a public host.
        The declared content type decides admission, which names a PDF or an
        archive as the wrong document type rather than letting it reach the
        UTF-8 decode as a byte error.
        """
        raw, headers = self._open(
            url, "text/html, application/xhtml+xml;q=0.9, text/plain;q=0.8"
        )
        content_type = (headers.get_content_type() or "").lower()
        if content_type not in SEARXNG_DOCUMENT_CONTENT_TYPES:
            raise ProviderContentError(
                f"the source answered with content type {content_type or 'none'}, "
                "and the fetch reads HTML and plain text"
            )
        charset = (headers.get_content_charset() or "utf-8").lower()
        if charset not in SEARXNG_DOCUMENT_CHARSETS:
            raise ProviderContentError(
                f"the source declares the {charset} character set, and the "
                "fetch reads UTF-8"
            )
        try:
            document = raw.decode("utf-8")
        except UnicodeDecodeError:
            raise ProviderContentError(
                "the provider content is not valid UTF-8"
            ) from None
        if content_type != "text/plain":
            document = html_to_text(document)
        # `extract_content` reads `complete` to separate a document that ends
        # at the requested length from one the retrieval cut, and the read
        # above covers the whole response, so completion is the length
        # comparison this method can make.
        return {
            "text": document[:max_characters],
            "complete": len(document) <= max_characters,
        }


class FakeProvider(Provider):
    """Fixture-backed provider that runs the tools with the network absent.

    The fixture document maps a query string to a result list and a canonical
    URL to a content record. A content record supplies `text` for ordinary
    fixtures or `text_base64` for a hostile one, which lets a fixture carry
    bytes that are invalid UTF-8 while the fixture file itself stays a legal
    UTF-8 JSON document.
    """

    name = "fake"

    # A fixture answers whatever the document holds, and `call_search` applies
    # the domain lists and the result slice over that answer the same way it
    # applies them to an HTTP provider, so every argument a grant carries is
    # honored and a fixture run reaches the same refusals a live run reaches.
    supports_exact_date_bounds = True
    supports_freshness_max_age = True
    supports_domain_filter = True
    supports_paging = False
    supports_num_results = True
    freshness_max_age_hours = None

    def __init__(self, fixture_path):
        self.response_bytes = 0
        if not fixture_path:
            raise ToolError(
                "the fake provider requires QWEN_WEB_FAKE_FIXTURES to name a "
                "fixture document"
            )
        try:
            with open(fixture_path, "rb") as handle:
                self.document = json.loads(handle.read().decode("utf-8"))
        except (OSError, ValueError, UnicodeDecodeError):
            raise ToolError(
                f"the fixture document is unreadable: {fixture_path}"
            ) from None

    def search(self, query, max_results, constraints):
        """Return the fixture's result list for one query.

        The domain lists are enforced in `call_search` over whatever a
        provider answers, so this fixture returns its records unfiltered and
        both providers meet one enforcement point. `response_bytes` counts the
        served record the way the HTTP provider counts its response, which
        keeps the audit row comparable across the two.
        """
        key = self.fixture_key(query)
        delay = self.document.get("delays", {}).get(key, 0) if key else 0
        if delay:
            # A fixture names the seconds a query holds the call, so a run
            # observes where the deadlines sit: the provider's own timeout,
            # the per-call timeout_ms llama-server reads from the MCP
            # configuration, and the router's proxy read timeout are three
            # different clocks, and only a call that outlasts one of them
            # shows which fires first.
            time.sleep(float(delay))
        results = self.document.get("search", {}).get(key, [])[:max_results] if key else []
        self.response_bytes += len(json.dumps(results).encode("utf-8"))
        return results

    def fixture_key(self, query):
        """Return the fixture search key the query satisfies, or None.

        A model composes the query it proposes, and the same prompt has
        produced `raven2 vulkan decode`, `raven2 vulkan decode rate`, and
        `Raven2 Vulkan decode rate` on one checkpoint at temperature 0, so an
        exact-string lookup measures the model's phrasing rather than the
        path. A key matches when every one of its words appears in the query,
        case-insensitively, and the key with the most words wins, so a delay
        key such as `raven2 vulkan decode stalled` is chosen over its prefix
        only when the query names the stall.
        """
        query_words = set(query.lower().split())
        candidates = set(self.document.get("search", {})) | set(self.document.get("delays", {}))
        matching = [
            key for key in candidates
            if key.lower().split() and set(key.lower().split()) <= query_words
        ]
        if not matching:
            return None
        return max(matching, key=lambda key: (len(key.split()), key))

    def contents(self, url, max_characters, provider_result_id="", freshness=None):
        record = self.document.get("contents", {}).get(url)
        if record is None:
            raise ProviderContentError("the provider returned no content for the result")
        self.response_bytes += len(json.dumps(record).encode("utf-8"))
        return record


class Ledger:
    """A rate ledger and audit trail that outlive the process.

    llama-server kills the child after every call, so a counter in memory
    resets between two invocations and bounds nothing. SQLite in the state
    directory carries the counters across spawns, and BEGIN IMMEDIATE takes the
    database write lock for the whole read-modify-write of a bucket, so two
    children spawned for concurrent calls serialize rather than reading one
    count and both writing it back.
    """

    def __init__(self, directory, now=None):
        """Open the state database inside a directory this user alone reaches.

        The directory holds the audit trail, the grant and search state, and
        the content snapshots, so its ownership and mode are checked rather
        than assumed: a symlink, another uid, or any group or world bit refuses
        the call. The umask is set to 0o077 first, which is what gives the
        database and the journal SQLite creates their private modes.
        """
        os.umask(0o077)
        os.makedirs(directory, mode=STATE_DIRECTORY_MODE, exist_ok=True)
        directory_status = os.lstat(directory)
        if stat.S_ISLNK(directory_status.st_mode):
            raise InvalidArgument(
                f"the state directory is a symlink, which is refused: {directory}"
            )
        if not stat.S_ISDIR(directory_status.st_mode):
            raise InvalidArgument(
                f"the state path is not a directory: {directory}"
            )
        if directory_status.st_uid != os.getuid():
            raise InvalidArgument(
                f"the state directory belongs to another user: {directory}"
            )
        directory_mode = stat.S_IMODE(directory_status.st_mode)
        if directory_mode & 0o077:
            raise InvalidArgument(
                f"the state directory {directory} is mode {directory_mode:04o}; "
                f"{STATE_DIRECTORY_MODE:04o} is required before a call runs"
            )
        database_path = os.path.join(directory, LEDGER_FILE_NAME)
        if os.path.lexists(database_path):
            database_status = os.lstat(database_path)
            if not stat.S_ISREG(database_status.st_mode):
                raise InvalidArgument(
                    f"the state database is not a regular file: {database_path}"
                )
            if database_status.st_uid != os.getuid():
                raise InvalidArgument(
                    f"the state database belongs to another user: {database_path}"
                )
            os.chmod(database_path, 0o600)
        self.connection = sqlite3.connect(
            database_path,
            timeout=LEDGER_BUSY_TIMEOUT_SECONDS,
            isolation_level=None,
        )
        os.chmod(database_path, 0o600)
        # The rollback journal is a file inside this directory that SQLite
        # removes at commit, where a WAL leaves page images in a sidecar until
        # a checkpoint runs; snapshots hold page text, so the journal mode that
        # bounds a body's lifetime by its row is the one this ledger takes.
        # `secure_delete` overwrites a freed page rather than releasing it with
        # its content intact.
        self.connection.execute(f"PRAGMA busy_timeout = {LEDGER_BUSY_TIMEOUT_MS}")
        self.connection.execute("PRAGMA journal_mode = DELETE")
        self.connection.execute("PRAGMA secure_delete = ON")
        self.connection.execute(
            "CREATE TABLE IF NOT EXISTS buckets ("
            "name TEXT PRIMARY KEY, window_start INTEGER, used INTEGER)"
        )
        self.connection.execute(
            "CREATE TABLE IF NOT EXISTS audit ("
            "recorded_at TEXT, profile TEXT, operation TEXT, query_sha256 TEXT,"
            " domains TEXT, result_count INTEGER, fetched_host TEXT,"
            " provider_bytes INTEGER, returned_characters INTEGER,"
            " latency_ms INTEGER, status TEXT, recorded_epoch INTEGER)"
        )
        # A database written by an earlier revision holds the twelve original
        # columns, and `CREATE TABLE IF NOT EXISTS` leaves it as it stands, so
        # each provenance column is added where the table lacks it. `record`
        # names its columns rather than counting them, which keeps one INSERT
        # correct across a migrated and a fresh table alike.
        present = {
            column[1]
            for column in self.connection.execute("PRAGMA table_info(audit)")
        }
        for column, declaration in AUDIT_PROVENANCE_COLUMNS:
            if column not in present:
                self.connection.execute(
                    f"ALTER TABLE audit ADD COLUMN {column} {declaration}"
                )
        self.connection.execute(
            "CREATE TABLE IF NOT EXISTS grants ("
            "grant_id TEXT PRIMARY KEY, profile TEXT, provider TEXT,"
            " consumed_at INTEGER, expiry INTEGER)"
        )
        self.connection.execute(
            "CREATE TABLE IF NOT EXISTS searches ("
            "search_id TEXT PRIMARY KEY, profile TEXT, provider TEXT,"
            " fetches_used INTEGER, fetches_allowed INTEGER, expiry INTEGER)"
        )
        self.connection.execute(
            "CREATE TABLE IF NOT EXISTS search_results ("
            "search_id TEXT, canonical_url TEXT, provider_result_id TEXT,"
            " PRIMARY KEY(search_id, canonical_url))"
        )
        self.connection.execute(
            "CREATE TABLE IF NOT EXISTS content ("
            "content_id TEXT PRIMARY KEY, search_id TEXT, canonical_url TEXT,"
            " text TEXT, content_sha256 TEXT, may_have_more INTEGER,"
            " provider_status TEXT, retrieved_at INTEGER, expiry INTEGER)"
        )
        self.prune(time.time() if now is None else now)

    def prune(self, now):
        """Drop audit and grant rows past their retention on every open.

        The trail answers what ran over a bounded recent period and a spent
        grant is evidence only until its own expiry passes, so retention runs
        where the database is already open rather than through a separate
        maintenance path that a respawned child would never execute.
        """
        self.connection.execute(
            "DELETE FROM audit WHERE recorded_epoch IS NOT NULL"
            " AND recorded_epoch < ?",
            (int(now) - AUDIT_RETENTION_SECONDS,),
        )
        self.connection.execute(
            "DELETE FROM grants WHERE expiry < ?", (int(now),)
        )
        self.connection.execute(
            "DELETE FROM searches WHERE expiry < ?", (int(now),)
        )
        self.connection.execute(
            "DELETE FROM search_results WHERE search_id NOT IN"
            " (SELECT search_id FROM searches)"
        )
        self.connection.execute(
            "DELETE FROM content WHERE expiry < ?", (int(now),)
        )
        self.connection.commit()

    def snapshot(self, content_id, now):
        """Return the stored document of one (search, URL) pair, or None.

        The window a fetch returns comes from this row on every call after the
        first, so what the model reads on page two is the text page one was
        cut from: a source that changes between two pages changes nothing the
        reply carries, and the digest on each page describes the same
        document.
        """
        row = self.connection.execute(
            "SELECT text, may_have_more, provider_status, retrieved_at, expiry"
            " FROM content WHERE content_id = ?",
            (content_id,),
        ).fetchone()
        if row is None or now >= row[4]:
            return None
        return {
            "text": row[0],
            "may_have_more": bool(row[1]),
            "provider_status": row[2],
            "retrieved_at": row[3],
        }

    def store_snapshot(self, extraction, search_id, url, retrieved_at, expiry):
        """Store one retrieved document under its content identity.

        The row is written after extraction succeeds, so a body refused for its
        size or its encoding leaves nothing behind and the next attempt charges
        the provider again rather than serving a half-written snapshot. The
        expiry equals the result identifier's own, so the snapshot and the
        reference that reaches it end together and `prune` removes the text.
        """
        self.connection.execute(
            "INSERT OR REPLACE INTO content(content_id, search_id, canonical_url,"
            " text, content_sha256, may_have_more, provider_status, retrieved_at,"
            " expiry) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                extraction.content_id,
                search_id,
                url,
                extraction.text,
                hashlib.sha256(extraction.text.encode("utf-8")).hexdigest(),
                1 if extraction.provider_may_have_more else 0,
                extraction.provider_status,
                int(retrieved_at),
                int(expiry),
            ),
        )
        self.connection.commit()

    def open_search(self, search_id, profile, provider, allowed, expiry, issued):
        """Record the results one search issued and the fetches they buy.

        The result identifiers a search hands out are what a later fetch may
        redeem, so the ledger holds the pair (search, canonical URL) beside the
        fetch allowance. The row expires with the result identifiers it covers,
        and `prune` drops it and its results together.
        """
        self.connection.execute("BEGIN IMMEDIATE")
        try:
            self.connection.execute(
                "INSERT OR REPLACE INTO searches(search_id, profile, provider,"
                " fetches_used, fetches_allowed, expiry) VALUES(?, ?, ?, 0, ?, ?)",
                (search_id, profile, provider, int(allowed), int(expiry)),
            )
            self.connection.executemany(
                "INSERT OR REPLACE INTO search_results(search_id, canonical_url,"
                " provider_result_id) VALUES(?, ?, ?)",
                [
                    (search_id, url, provider_result)
                    for url, provider_result in issued
                ],
            )
            self.connection.execute("COMMIT")
        except BaseException:
            self.connection.execute("ROLLBACK")
            raise

    def reserve_fetch(self, search_id, url, content_id, now, profile):
        """Return the stored document, or reserve one against the search.

        The snapshot lookup and the allowance reservation run inside one
        BEGIN IMMEDIATE, so two children spawned for one result cannot both
        observe the row absent and both issue a billable provider request: the
        second takes the write lock after the first commits its snapshot and
        reads it. A global bucket bounds the account and says nothing about
        one search, so a page a search returned buys the bounded number of
        documents the row carries, and a result the ledger never issued
        reaches no provider.
        """
        self.connection.execute("BEGIN IMMEDIATE")
        try:
            # The search row rather than the claim carries the profile, so the
            # admission runs ahead of the snapshot: a second configuration
            # sharing the signing key and this directory would otherwise read
            # a stored document the first profile paid for.
            row = self.connection.execute(
                "SELECT fetches_used, fetches_allowed, expiry, profile FROM"
                " searches WHERE search_id = ?",
                (search_id,),
            ).fetchone()
            if row is None:
                raise AuthorizationDenied(
                    "the search that issued this result is unknown to the ledger"
                )
            used, allowed, expiry, issuing_profile = row
            if issuing_profile != profile:
                raise AuthorizationDenied(
                    "the search that issued this result ran under another "
                    "profile"
                )
            if now >= expiry:
                raise ExpiredResult(
                    "the search that issued this result has expired"
                )
            issued = self.connection.execute(
                "SELECT 1 FROM search_results WHERE search_id = ?"
                " AND canonical_url = ?",
                (search_id, url),
            ).fetchone()
            if issued is None:
                raise AuthorizationDenied(
                    "the search that issued this result returned another URL"
                )
            stored = self.snapshot(content_id, now)
            if stored is not None:
                self.connection.execute("COMMIT")
                return stored
            if used >= allowed:
                raise BudgetExhausted(
                    f"the per-search fetch budget of {allowed} is exhausted; "
                    "a further document needs a new search"
                )
            self.connection.execute(
                "UPDATE searches SET fetches_used = ? WHERE search_id = ?",
                (used + 1, search_id),
            )
            self.connection.execute("COMMIT")
        except BaseException:
            self.connection.execute("ROLLBACK")
            raise
        return None

    def release_fetch(self, search_id):
        """Return one reserved document to the search that reserved it.

        A reservation buys a provider request, so a refusal that reaches no
        provider gives the document back rather than spending it: repeated
        rate-limited attempts would otherwise exhaust an allowance no
        retrieval consumed.
        """
        self.connection.execute("BEGIN IMMEDIATE")
        try:
            self.connection.execute(
                "UPDATE searches SET fetches_used = MAX(fetches_used - 1, 0)"
                " WHERE search_id = ?",
                (search_id,),
            )
            self.connection.execute("COMMIT")
        except BaseException:
            self.connection.execute("ROLLBACK")
            raise

    def consume_grant(self, grant_id, profile, provider, expiry, now):
        """Spend the single use of one grant, or refuse a replay.

        The primary key is the grant identifier, so the insert is the
        enforcement: BEGIN IMMEDIATE holds the write lock across the read and
        the write, and a second search presenting the same token meets a
        constraint violation rather than a count two children both read as
        zero. `prune` drops the row once the grant's own expiry passes, which
        keeps the table bounded by the lifetime rather than by the traffic.
        """
        self.connection.execute("BEGIN IMMEDIATE")
        try:
            self.connection.execute(
                "INSERT INTO grants(grant_id, profile, provider, consumed_at,"
                " expiry) VALUES(?, ?, ?, ?, ?)",
                (grant_id, profile, provider, int(now), int(expiry)),
            )
            self.connection.execute("COMMIT")
        except sqlite3.IntegrityError:
            self.connection.execute("ROLLBACK")
            raise GrantReplayed(
                "the authorization is spent; a grant admits one search and "
                "the operator issues another"
            ) from None
        except BaseException:
            self.connection.execute("ROLLBACK")
            raise

    def _consume_bucket(
        self, name, window_seconds, limit, now, exhausted=RateLimited, units=1
    ):
        """Consume one bucket inside the caller's active transaction."""
        window_start = int(now) - int(now) % window_seconds
        row = self.connection.execute(
            "SELECT window_start, used FROM buckets WHERE name = ?", (name,)
        ).fetchone()
        used = row[1] if row and row[0] == window_start else 0
        if used + units > limit:
            raise exhausted(
                f"the {name} rate limit of {limit} per "
                f"{window_seconds} seconds is exhausted"
            )
        self.connection.execute(
            "INSERT INTO buckets(name, window_start, used) VALUES(?, ?, ?) "
            "ON CONFLICT(name) DO UPDATE SET window_start = excluded.window_start,"
            " used = excluded.used",
            (name, window_start, used + units),
        )

    def consume_search(self, grant, profile, provider, now, limits, pages):
        """Atomically spend one grant and every search budget bucket."""
        self.connection.execute("BEGIN IMMEDIATE")
        try:
            if grant is not None:
                self.connection.execute(
                    "INSERT INTO grants(grant_id, profile, provider, consumed_at,"
                    " expiry) VALUES(?, ?, ?, ?, ?)",
                    (
                        grant["grant_id"],
                        profile,
                        provider,
                        int(now),
                        int(grant["expiry"]),
                    ),
                )
            self._consume_bucket(
                "search-minute", 60, limits["search_per_minute"], now
            )
            self._consume_bucket(
                "pages-day",
                86400,
                limits["page_budget"],
                now,
                BudgetExhausted,
                units=pages,
            )
            self._consume_bucket(
                "provider-day",
                86400,
                limits["provider_budget"],
                now,
                BudgetExhausted,
            )
            self.connection.execute("COMMIT")
        except sqlite3.IntegrityError:
            self.connection.execute("ROLLBACK")
            raise GrantReplayed(
                "the authorization is spent; a grant admits one search and "
                "the operator issues another"
            ) from None
        except BaseException:
            self.connection.execute("ROLLBACK")
            raise

    def consume(
        self, name, window_seconds, limit, now, exhausted=RateLimited, units=1
    ):
        """Take `units` of a bucket, or refuse with the caller's failure class.

        `exhausted` states which audit term the refusal carries: a per-minute
        call bucket records `rate_limited` and a daily page or provider-cost
        budget records `budget_exhausted`, so the trail separates a call that
        arrived too fast from one that spent an exhausted allowance. `units`
        charges a search for the pages it asks for, which is what separates the
        page budget from the count of calls.
        """
        self.connection.execute("BEGIN IMMEDIATE")
        try:
            self._consume_bucket(
                name, window_seconds, limit, now, exhausted, units
            )
            self.connection.execute("COMMIT")
        except BaseException:
            self.connection.execute("ROLLBACK")
            raise

    def record(self, row):
        """Append one audit row.

        The row carries the SHA-256 of the query rather than the query, the
        host rather than the URL, and byte and character counts rather than any
        text, so the trail states what ran without retaining a secret, a token,
        or a page body. `status` is written from `AUDIT_STATUSES` alone, so a
        term the trail admits is one of nine and a caller that offers another
        writes `internal_error`.
        """
        status = row["status"] if row["status"] in AUDIT_STATUSES else "internal_error"
        columns = [
            "recorded_at",
            "profile",
            "operation",
            "query_sha256",
            "domains",
            "result_count",
            "fetched_host",
            "provider_bytes",
            "returned_characters",
            "latency_ms",
            "status",
            "recorded_epoch",
        ] + [column for column, _ in AUDIT_PROVENANCE_COLUMNS]
        values = [
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
            status,
            int(row["recorded_epoch"]),
        ] + [
            # A caller that fills none of the provenance -- the approval broker
            # writes its own rows through this method -- leaves each column at
            # the empty value its declared type takes, so an aggregate over
            # `fallback_used` or `usable_results` reads integers throughout.
            row.get(column, "" if declaration == "TEXT" else 0)
            for column, declaration in AUDIT_PROVENANCE_COLUMNS
        ]
        self.connection.execute(
            "INSERT INTO audit ("
            + ", ".join(columns)
            + ") VALUES("
            + ", ".join("?" for _ in columns)
            + ")",
            values,
        )
        self.connection.commit()

    def close(self):
        self.connection.close()


def integer_setting(settings, key, default):
    raw = settings.get(key) or ""
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        raise ToolError(f"{key} is not an integer") from None
    if value < 1:
        raise ToolError(f"{key} must be positive")
    return value


def resolve_max_results_cap(settings):
    """Return the per-call result-count ceiling, bounded by RESULT_COUNT_CAP.

    `QWEN_WEB_MAX_RESULTS` narrows `search_exa`'s `max_results` for a profile
    that spends a smaller per-call page budget; the value can lower the
    ceiling `call_search` enforces but never raise it past the provider
    rendering cap `RESULT_COUNT_CAP` names.
    """
    raw = settings.get("max_results_cap") or ""
    if not raw:
        return RESULT_COUNT_CAP
    try:
        value = int(raw)
    except ValueError:
        raise ToolError("QWEN_WEB_MAX_RESULTS is not an integer") from None
    if not (1 <= value <= RESULT_COUNT_CAP):
        raise ToolError(
            f"QWEN_WEB_MAX_RESULTS lies outside [1, {RESULT_COUNT_CAP}]: {value}"
        )
    return value


def resolve_max_chars_per_fetch_cap(settings):
    """Return the per-call fetch-window ceiling, bounded by WINDOW_CHARACTER_CAP.

    `QWEN_WEB_MAX_CHARS_PER_FETCH` narrows `fetch_exa`'s `max_chars` the same
    way `resolve_max_results_cap` narrows `max_results`, and the bound never
    exceeds `WINDOW_CHARACTER_CAP`, which is what one reply admits.
    """
    raw = settings.get("max_chars_per_fetch_cap") or ""
    if not raw:
        return WINDOW_CHARACTER_CAP
    try:
        value = int(raw)
    except ValueError:
        raise ToolError(
            "QWEN_WEB_MAX_CHARS_PER_FETCH is not an integer"
        ) from None
    if not (1 <= value <= WINDOW_CHARACTER_CAP):
        raise ToolError(
            "QWEN_WEB_MAX_CHARS_PER_FETCH lies outside "
            f"[1, {WINDOW_CHARACTER_CAP}]: {value}"
        )
    return value


def resolve_max_fetches(settings):
    """Return the per-search document allowance after startup validation."""
    raw = settings.get("max_fetches") or ""
    if not raw:
        return SEARCH_FETCH_ALLOWANCE_DEFAULT
    try:
        value = int(raw)
    except ValueError:
        raise ToolError(
            "QWEN_WEB_MAX_FETCHES_PER_SEARCH is not an integer"
        ) from None
    if not (1 <= value <= RESULT_COUNT_CAP):
        raise ToolError(
            "QWEN_WEB_MAX_FETCHES_PER_SEARCH lies outside "
            f"[1, {RESULT_COUNT_CAP}]: {value}"
        )
    return value


def resolve_environment_caps(settings):
    """Replace raw cap strings in `settings` with validated integers.

    Both caps gate every later call, so a malformed value fails once here
    rather than on the first `search_exa` or `fetch_exa` invocation the
    respawned child receives.
    """
    settings["max_results_cap"] = resolve_max_results_cap(settings)
    settings["max_chars_per_fetch_cap"] = resolve_max_chars_per_fetch_cap(settings)
    settings["max_fetches"] = resolve_max_fetches(settings)


def open_ledger(settings):
    """Return the ledger for this call.

    A state directory is what makes a limit persist across the respawn, so a
    provider that spends money and reaches the network refuses to run without
    one: an unset or unusable QWEN_WEB_STATE_DIR fails the call rather than
    serving it unmetered and unaudited. The fake provider reaches no network and
    spends nothing, so it runs unmetered and a fixture-driven test needs no
    directory.
    """
    directory = settings.get("state_dir") or ""
    if not directory:
        if settings.get("provider") == "fake":
            return None
        raise ToolError(
            "QWEN_WEB_STATE_DIR names no directory, so the rate ledger cannot "
            "persist across the respawn and the call is refused rather than "
            "served unmetered"
        )
    try:
        return Ledger(directory)
    except (OSError, sqlite3.Error):
        raise ToolError(
            "QWEN_WEB_STATE_DIR names a directory the ledger cannot open: "
            f"{directory}"
        ) from None


def spend_call_budget(ledger, settings, operation, now, pages=1):
    """Charge the call and page counters one invocation spends.

    A call, a page, and a provider request are three costs and the ledger
    keeps three buckets. These two charge every invocation: the per-minute
    bucket bounds how fast calls arrive and the daily page bucket bounds how
    many results and windows reach the model, so a window served from a stored
    snapshot spends them the same way a retrieval does. A search that asks for
    ten results charges ten pages against one call.
    """
    per_minute = (
        integer_setting(settings, "search_per_minute", SEARCH_PER_MINUTE_DEFAULT)
        if operation == "search"
        else integer_setting(
            settings, "fetch_per_minute", FETCH_PER_MINUTE_DEFAULT
        )
    )
    ledger.consume(f"{operation}-minute", 60, per_minute, now)
    ledger.consume(
        "pages-day",
        86400,
        integer_setting(settings, "page_budget", PAGE_DAILY_BUDGET_DEFAULT),
        now,
        BudgetExhausted,
        units=pages,
    )


def spend_provider_budget(ledger, settings, now):
    """Charge one provider request against the daily account budget.

    The bucket counts what the account is billed for, so a window served from
    a stored snapshot leaves it untouched while the call and page buckets it
    reaches charge every invocation.
    """
    ledger.consume(
        "provider-day",
        86400,
        integer_setting(
            settings, "daily_budget", PROVIDER_DAILY_BUDGET_DEFAULT
        ),
        now,
        BudgetExhausted,
    )


def search_budget_limits(settings):
    """Resolve every search bucket limit before a transaction begins."""
    return {
        "search_per_minute": integer_setting(
            settings, "search_per_minute", SEARCH_PER_MINUTE_DEFAULT
        ),
        "page_budget": integer_setting(
            settings, "page_budget", PAGE_DAILY_BUDGET_DEFAULT
        ),
        "provider_budget": integer_setting(
            settings, "daily_budget", PROVIDER_DAILY_BUDGET_DEFAULT
        ),
    }


def select_provider(settings):
    if settings["provider"] == "fake":
        return FakeProvider(settings["fixtures"])
    if settings["provider"] == "searxng":
        return SearXNGProvider(
            settings["searxng_url"],
            settings["searxng_primary_category"].strip(),
            settings["searxng_fallback_category"].strip(),
            settings["searxng_minimum_results"].strip() or 1,
            settings["searxng_language"].strip(),
            settings["searxng_safesearch"].strip(),
            allow_remote=settings["searxng_allow_remote"].strip() == "1",
        )
    return ExaProvider(settings["exa_key_file"])


def require_string(arguments, key, cap, required=True, default=""):
    value = arguments.get(key, default)
    if value is None:
        value = default
    if not isinstance(value, str):
        raise ToolError(f"{key} must be a string")
    value = value.strip()
    if required and not value:
        raise ToolError(f"{key} is required")
    if len(value) > cap:
        raise ToolError(f"{key} exceeds the {cap} character cap")
    return value


def require_integer(arguments, key, default, minimum, maximum):
    value = arguments.get(key, default)
    if value is None:
        value = default
    if isinstance(value, bool) or not isinstance(value, int):
        raise ToolError(f"{key} must be an integer")
    if value < minimum or value > maximum:
        raise ToolError(f"{key} must lie between {minimum} and {maximum}")
    return value


def require_iso_date(arguments, key):
    """Return an ISO 8601 calendar date, or the empty string when absent.

    `datetime.date.fromisoformat` accepts the extended forms Python admits, so
    the value is reformatted to YYYY-MM-DD; the reformatted string is what the
    provider body and the authorization claim both carry, which keeps one
    spelling of a date on both sides of the comparison.
    """
    value = arguments.get(key)
    if value in (None, ""):
        return ""
    if not isinstance(value, str):
        raise ToolError(f"{key} must be an ISO 8601 date string")
    try:
        parsed = datetime.date.fromisoformat(value.strip())
    except ValueError:
        raise ToolError(f"{key} is not an ISO 8601 date") from None
    return parsed.isoformat()


def require_optional_integer(arguments, key, minimum, maximum):
    if arguments.get(key) is None:
        return None
    return require_integer(arguments, key, minimum, minimum, maximum)


def require_domain_list(arguments, key):
    value = arguments.get(key) or []
    if not isinstance(value, list):
        raise ToolError(f"{key} must be a list of domain names")
    if len(value) > DOMAIN_LIST_CAP:
        raise ToolError(f"{key} exceeds the {DOMAIN_LIST_CAP} entry cap")
    domains = []
    for entry in value:
        if not isinstance(entry, str) or not entry.strip():
            raise ToolError(f"{key} entries must be non-empty domain names")
        entry = entry.strip().lower().rstrip(".")
        if len(entry) > DOMAIN_CHARACTER_CAP:
            raise ToolError(
                f"{key} entries exceed the {DOMAIN_CHARACTER_CAP} character cap"
            )
        if not HOSTNAME_PATTERN.match(entry):
            raise ToolError(f"{key} carries an entry that is not a hostname")
        domains.append(entry)
    return domains


def decode_content_text(record):
    """Return the UTF-8 text of a content record, bounded at the document cap.

    A `text_base64` field decodes through a strict UTF-8 decode, so a body that
    is not valid UTF-8 is refused here rather than reaching the model as
    replacement characters. A record above the HTTP byte cap is refused as a
    provider defect, and a document above the character cap is truncated, which
    the reply reports on its `Possibly Truncated:` line.
    """
    if "text_base64" in record:
        try:
            raw = base64.b64decode(record["text_base64"], validate=True)
        except (ValueError, TypeError):
            raise ProviderContentError("the provider content is not valid base64") from None
        if len(raw) > HTTP_RESPONSE_BYTE_CAP:
            raise ProviderContentError(
                f"the provider content exceeds the {HTTP_RESPONSE_BYTE_CAP} byte cap"
            )
        try:
            return raw.decode("utf-8")[:DOCUMENT_CHARACTER_CAP]
        except UnicodeDecodeError:
            raise ProviderContentError("the provider content is not valid UTF-8") from None
    text = record.get("text", "")
    if not isinstance(text, str):
        raise ProviderContentError("the provider content is not text")
    if len(text.encode("utf-8")) > HTTP_RESPONSE_BYTE_CAP:
        raise ProviderContentError(
            f"the provider content exceeds the {HTTP_RESPONSE_BYTE_CAP} byte cap"
        )
    return text[:DOCUMENT_CHARACTER_CAP]


def content_identity(search_id, url):
    """Return the key one document takes under the search that issued it."""
    return hashlib.sha256(f"{search_id}\n{url}".encode("utf-8")).hexdigest()


def extract_content(record, requested_characters, content_id):
    """Return the extraction as a record rather than as a bare string.

    A body whose length equals the requested maximum is the case a character
    count cannot resolve: the document may end exactly there or the provider
    may have cut it. Exa marks a complete extraction where it supplies the
    signal, so a record carrying `textComplete` or `complete` true reports
    completion and every other exact-cap length reports that more may remain.
    The reply's `Possibly Truncated:` line reads this field rather than
    recomputing the comparison, and the snapshot stores it, so page two of a
    cached document reports what the retrieval observed.
    """
    text = decode_content_text(record)
    complete = any(
        record.get(key) is True for key in ("textComplete", "complete")
    )
    return ExtractedContent(
        text=text,
        provider_may_have_more=len(text) >= requested_characters and not complete,
        provider_status=str(record.get("status", "success"))[:64],
        content_id=content_id,
    )


def provider_result_id(record):
    """Return the provider's own identifier for a result, or the empty string.

    Exa returns an opaque `id` beside the URL and answers a contents request on
    either key, so the identifier is signed into the reference and a redirect
    or a trailing-slash difference still resolves the entry. A record without
    one leaves the field empty and the URL carries the match alone.
    """
    candidate = record.get("id")
    if isinstance(candidate, str) and 0 < len(candidate) <= RESULT_ID_CHARACTER_CAP:
        return candidate
    return ""


def render_search_results(
    results,
    provider_name,
    signing_key,
    search_id,
    freshness,
    issued_at,
    lifetime_seconds,
):
    """Render one block per result in the layout the pinned llama-ui parses.

    The renderer treats everything after `Highlights:` up to the `---`
    separator as highlight text, so the result identifier and the trust label
    precede that key and the highlight lines are the last content in a block.
    `Trust: untrusted-web-result` states in the rendered surface what the
    wrapper enforces: the title, author, and highlight text below it are
    attacker-chosen. A `Results Omitted:` count follows the final separator
    where the output cap dropped results, so a short list is distinguishable
    from a short answer; the line sits outside every block, which keeps it
    clear of the highlight region.
    """
    blocks = []
    issued = []
    block_characters = 0
    # The marker sits outside every block and the join writes five characters
    # between two blocks and four after the last, so admission counts the
    # exact length the reply will carry and reserves the widest marker the
    # result count can produce. Provider-chosen field lengths would otherwise
    # leave the blocks just under the cap and the marker past it.
    admitted_characters = SEARCH_OUTPUT_CHARACTER_CAP - len(
        f"\nResults Omitted: {len(results)}"
    )
    issued_urls = set()
    for record in results:
        url = canonical_url(str(record.get("url", "")))
        # The snapshot and the `search_results` row key a document by the
        # search and the canonical URL, so two records that canonicalize alike
        # would map to one stored document and the second token would return
        # the first's text without reaching the provider. The first record
        # wins and the duplicate renders nothing.
        if url in issued_urls:
            continue
        issued_urls.add(url)
        highlights = record.get("highlights") or []
        if not isinstance(highlights, list):
            highlights = []
        published = record.get("publishedDate") or record.get("published") or ""
        lines = [
            f"Title: {clip(record.get('title') or url, TITLE_CHARACTER_CAP)}",
            f"URL: {url}",
            f"Published: {clip(published, 64)}",
            f"Author: {clip(record.get('author') or '', AUTHOR_CHARACTER_CAP)}",
            "Result ID: "
            + issue_result_id(
                signing_key,
                url,
                provider_result_id(record),
                provider_name,
                search_id,
                freshness,
                issued_at,
                lifetime_seconds,
            ),
            "Trust: untrusted-web-result",
        ]
        # A metasearch answer names which engines returned the record, which is
        # what tells a reader whether one index or several found it. The line
        # sits ahead of `Highlights:`, so the highlight region the pinned
        # llama-ui parses keeps its own boundary.
        engines = record.get("engines") or []
        if isinstance(engines, list) and engines:
            sources = clip(
                ", ".join(str(engine) for engine in engines),
                ENGINE_LIST_CHARACTER_CAP,
            )
            if sources:
                lines.append(f"Sources: {sources}")
        lines.append("Highlights:")
        for highlight in highlights[:HIGHLIGHT_COUNT_CAP]:
            lines.append(f"- {clip(highlight, HIGHLIGHT_CHARACTER_CAP)}")
        block = "\n".join(lines)
        projected = block_characters + len(block) + 5 * (len(blocks) + 1) - 1
        if projected > admitted_characters:
            break
        blocks.append(block)
        block_characters += len(block)
        issued.append((url, provider_result_id(record)))
    if not blocks:
        return "No results.", issued
    rendered = "\n---\n".join(blocks) + "\n---"
    omitted = len(results) - len(blocks)
    if omitted:
        rendered += f"\nResults Omitted: {omitted}"
    return rendered, issued


def clip(value, cap):
    """Return a provider string as one bounded line.

    Title, author, and highlight text come from the page, so both their length
    and their line structure are attacker-chosen. Collapsing every whitespace
    run to one space keeps a field inside the single line its key claims, and a
    value that is a run of dashes alone becomes a placeholder, so page text
    cannot write the `---` line that closes a result block.
    """
    text = " ".join(str(value).split())
    if SEPARATOR_PATTERN.match(text):
        text = "[separator]"
    return text[:cap]


def wrap_untrusted(url, retrieved_at, window, start_index, truncated):
    """Frame one window of page text with the state a next call needs.

    The frame carries a nonce drawn after retrieval and absent from the window,
    so page text cannot write the line that closes the frame: a body holding
    the literal footer meets a delimiter whose nonce it could not have
    predicted, and the enclosing turn still reads one frame.

    `Next Start Index` names the offset that continues the document and reads
    `end` where the window reached the last character the document holds, so
    paging is decided by the server's own count rather than by the model's
    arithmetic over a body it cannot measure.
    """
    nonce = base64url_encode(os.urandom(NONCE_BYTES))
    while nonce in window:
        nonce = base64url_encode(os.urandom(NONCE_BYTES))
    digest = hashlib.sha256(window.encode("utf-8")).hexdigest()
    next_index = start_index + len(window)
    return "\n".join(
        [
            f"{UNTRUSTED_HEADER} [{nonce}]",
            f"Source: {url}",
            f"Retrieved: {retrieved_at}",
            f"Content SHA-256: {digest}",
            f"Start Index: {start_index}",
            f"Returned Characters: {len(window)}",
            f"Next Start Index: {next_index if truncated else 'end'}",
            f"Possibly Truncated: {'yes' if truncated else 'no'}",
            window,
            f"{UNTRUSTED_FOOTER} [{nonce}]",
        ]
    )


def utc_timestamp(now):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))


def search_id_for():
    return base64url_encode(os.urandom(9))


def call_search(settings, arguments):
    query = require_string(arguments, "query", QUERY_CHARACTER_CAP)
    max_results_cap = settings.get("max_results_cap", RESULT_COUNT_CAP)
    max_results = require_integer(
        arguments, "max_results", min(5, max_results_cap), 1, max_results_cap
    )
    constraints = {
        "published_after": require_iso_date(arguments, "published_after"),
        "published_before": require_iso_date(arguments, "published_before"),
        "max_age_hours": require_optional_integer(
            arguments, "max_age_hours", 0, MAX_AGE_HOURS_CAP
        ),
        "include_domains": require_domain_list(arguments, "include_domains"),
        "exclude_domains": require_domain_list(arguments, "exclude_domains"),
    }
    if (
        constraints["published_after"]
        and constraints["published_before"]
        and constraints["published_after"] > constraints["published_before"]
    ):
        raise ToolError("published_after falls after published_before")
    settings = dict(settings)
    settings["_authorization"] = require_string(
        arguments,
        "authorization",
        AUTHORIZATION_CHARACTER_CAP,
        required=False,
        default="",
    )
    ledger = open_ledger(settings)
    started = time.monotonic()
    now = time.time()
    audit = {
        "recorded_at": utc_timestamp(now),
        "recorded_epoch": int(now),
        "profile": settings.get("profile") or "default",
        "operation": "search",
        "query_sha256": hashlib.sha256(query.encode("utf-8")).hexdigest(),
        "domains": ",".join(
            [f"+{domain}" for domain in constraints["include_domains"]]
            + [f"-{domain}" for domain in constraints["exclude_domains"]]
        ),
        "result_count": 0,
        "fetched_host": "",
        "provider_bytes": 0,
        "returned_characters": 0,
        "latency_ms": 0,
        "status": "internal_error",
        "search_id": "",
        "category": "",
        "engines_attempted": "",
        "engines_answered": "",
        "engines_failed": "",
        "fallback_used": 0,
        "usable_results": 0,
    }
    provider = None
    try:
        signing_key = read_secret_file(settings["token_key_file"], "token signing")
        provider = select_provider(settings)
        # Every local configuration the reply depends on resolves before the
        # ledger spends the grant: a lifetime outside its range and a key file
        # the mode check refuses both reach no provider, so the single use
        # stays available to the operator who corrects the configuration.
        lifetime_seconds = resolve_token_lifetime(settings)
        provider.preflight()
        # An argument the active provider cannot carry refuses here, ahead of
        # the ledger transaction, so a grant approved for a window this
        # provider does not express stays available to a corrected call.
        refuse_unhonored_arguments(provider, constraints, max_results)
        limits = search_budget_limits(settings)
        granted = enforce_search_authorization(
            settings,
            signing_key,
            query,
            max_results,
            constraints,
            provider.name,
            ledger,
        )
        if ledger is not None:
            # The grant and all three search costs form one state transition.
            # A replay fails before charging a bucket, while a bucket refusal
            # rolls the grant insertion back for a corrected retry.
            ledger.consume_search(
                granted,
                settings.get("profile") or "default",
                provider.name,
                now,
                limits,
                max_results,
            )
        # The domain lists reach the provider as request fields and bound
        # what it returns here, so an off-domain record is dropped before the
        # renderer signs it into a fetchable Result ID.
        results = filter_by_domains(
            provider.search(query, max_results, constraints),
            constraints["include_domains"],
            constraints["exclude_domains"],
        )[:max_results]
        search_id = search_id_for()
        audit["search_id"] = search_id
        rendered, issued = render_search_results(
            results,
            provider.name,
            signing_key,
            search_id,
            freshness_policy(constraints),
            int(now),
            lifetime_seconds,
        )
        if ledger is not None:
            ledger.open_search(
                search_id,
                settings.get("profile") or "default",
                provider.name,
                settings["max_fetches"],
                int(now) + lifetime_seconds,
                issued,
            )
        audit["result_count"] = len(
            [line for line in rendered.splitlines() if line.startswith("URL: ")]
        )
        audit["returned_characters"] = len(rendered)
        audit["status"] = "success"
        return rendered
    except ToolError as error:
        audit["status"] = error.status
        raise
    except Exception:
        audit["status"] = "internal_error"
        raise
    finally:
        # The budget counts a provider request where it is issued, so a
        # response read and then refused for its size, encoding, or structure
        # has already cost the account. The counter is copied here rather than
        # on the success path, which keeps the retained usage evidence equal
        # to what was spent.
        if provider is not None:
            audit["provider_bytes"] = provider.response_bytes
            # The provenance is copied on every exit path, so a search that
            # reached the instance and then failed a later rule still records
            # which engines answered and whether the fallback ran.
            audit.update(provider.provenance())
        audit["latency_ms"] = int((time.monotonic() - started) * 1000)
        if ledger is not None:
            ledger.record(audit)
            ledger.close()


def call_fetch(settings, arguments):
    result_id = require_string(arguments, "result_id", RESULT_ID_CHARACTER_CAP)
    start_index = require_integer(
        arguments, "start_index", 0, 0, DOCUMENT_CHARACTER_CAP
    )
    max_chars_cap = settings.get("max_chars_per_fetch_cap", WINDOW_CHARACTER_CAP)
    max_chars = require_integer(
        arguments,
        "max_chars",
        min(WINDOW_CHARACTER_DEFAULT, max_chars_cap),
        1,
        max_chars_cap,
    )
    window_end = start_index + max_chars
    if window_end > DOCUMENT_CHARACTER_CAP:
        raise ToolError(
            "start_index plus max_chars exceeds the "
            f"{DOCUMENT_CHARACTER_CAP} character document cap"
        )
    now = time.time()
    ledger = open_ledger(settings)
    started = time.monotonic()
    audit = {
        "recorded_at": utc_timestamp(now),
        "recorded_epoch": int(now),
        "profile": settings.get("profile") or "default",
        "operation": "fetch",
        "query_sha256": "",
        "domains": "",
        "result_count": 0,
        "fetched_host": "",
        "provider_bytes": 0,
        "returned_characters": 0,
        "latency_ms": 0,
        "status": "internal_error",
        "search_id": "",
        "category": "",
        "engines_attempted": "",
        "engines_answered": "",
        "engines_failed": "",
        "fallback_used": 0,
        "usable_results": 0,
    }
    provider = None
    try:
        signing_key = read_secret_file(settings["token_key_file"], "token signing")
        claim = redeem_result_id(signing_key, result_id, now)
        url = claim["canonical_url"]
        audit["fetched_host"] = urllib.parse.urlsplit(url).netloc
        provider = select_provider(settings)
        if claim.get("provider") != provider.name:
            raise AuthorizationDenied(
                "the result_id was issued by another provider than the "
                "configured one"
            )
        # Credential validation precedes call budgets and the per-search
        # reservation. A local key-file defect reaches no paid state transition.
        provider.preflight()
        content_id = content_identity(claim["search_id"], url)
        # The call and page buckets charge every invocation, so a window read
        # from the snapshot spends them; the snapshot spares the provider
        # request alone.
        if ledger is not None:
            spend_call_budget(ledger, settings, "fetch", now)
        stored = (
            ledger.reserve_fetch(
                claim["search_id"],
                url,
                content_id,
                now,
                settings.get("profile") or "default",
            )
            if ledger is not None
            else None
        )
        retrieved_at = now
        if stored is None:
            if ledger is not None:
                # The reservation buys a provider request, so a daily budget
                # that refuses one returns the document to the search.
                try:
                    spend_provider_budget(ledger, settings, now)
                except BaseException:
                    ledger.release_fetch(claim["search_id"])
                    raise
            # The retrieval asks for the whole document the cap admits rather
            # than this window, so the snapshot holds every character a later
            # window can name and the truncation flag describes the document.
            record = provider.contents(
                url,
                DOCUMENT_CHARACTER_CAP,
                claim["provider_result_id"],
                claim["freshness"],
            )
            extraction = extract_content(record, DOCUMENT_CHARACTER_CAP, content_id)
            if ledger is not None:
                ledger.store_snapshot(
                    extraction, claim["search_id"], url, now, claim["expiry"]
                )
        else:
            # A window past the first reads the stored document, so paging
            # costs one provider request per document and a source that
            # changes between two pages leaves both pages as retrieved.
            extraction = ExtractedContent(
                text=stored["text"],
                provider_may_have_more=stored["may_have_more"],
                provider_status=stored["provider_status"],
                content_id=content_id,
            )
            retrieved_at = stored["retrieved_at"]
        text = extraction.text
        window = text[start_index:window_end]
        truncated = len(text) > start_index + len(window) or (
            extraction.provider_may_have_more and start_index + len(window) >= len(text)
        )
        audit["result_count"] = 1
        audit["returned_characters"] = len(window)
        audit["status"] = "success"
        return wrap_untrusted(
            url, utc_timestamp(retrieved_at), window, start_index, truncated
        )
    except ToolError as error:
        audit["status"] = error.status
        raise
    except Exception:
        audit["status"] = "internal_error"
        raise
    finally:
        # The budget counts a provider request where it is issued, so a
        # response read and then refused for its size, encoding, or structure
        # has already cost the account. The counter is copied here rather than
        # on the success path, which keeps the retained usage evidence equal
        # to what was spent.
        if provider is not None:
            audit["provider_bytes"] = provider.response_bytes
        audit["latency_ms"] = int((time.monotonic() - started) * 1000)
        if ledger is not None:
            ledger.record(audit)
            ledger.close()


def tool_definitions(settings):
    """Return the two tool schemas, their numeric bounds drawn from settings.

    `tools/list` runs after `main` resolves `max_results_cap` and
    `max_chars_per_fetch_cap` from the environment, so the advertised maximum
    and default match what `call_search` and `call_fetch` enforce rather than
    the compiled-in ceiling a profile has narrowed.
    """
    max_results_cap = settings.get("max_results_cap", RESULT_COUNT_CAP)
    max_results_default = min(5, max_results_cap)
    max_chars_cap = settings.get("max_chars_per_fetch_cap", WINDOW_CHARACTER_CAP)
    return [
        {
            "name": "search_exa",
            "description": (
                "Search the web and return ranked results with titles, URLs, and "
                "highlights. Each result carries a Result ID that fetch_exa "
                "redeems for the page text."
            ),
            "inputSchema": {
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "Search query, at most 512 characters.",
                    },
                    "max_results": {
                        "type": "integer",
                        "maximum": max_results_cap,
                        "description": (
                            f"Result count, 1 to {max_results_cap}. Default "
                            f"{max_results_default}."
                        ),
                    },
                    "published_after": {
                        "type": "string",
                        "description": (
                            "ISO 8601 date; results published before it are "
                            "dropped."
                        ),
                    },
                    "published_before": {
                        "type": "string",
                        "description": (
                            "ISO 8601 date; results published after it are "
                            "dropped."
                        ),
                    },
                    "max_age_hours": {
                        "type": "integer",
                        "description": (
                            "Cached page age the provider may serve. 0 forces a "
                            "live crawl. Omitted leaves the provider default."
                        ),
                    },
                    "include_domains": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Admit these domains alone, at most 10.",
                    },
                    "exclude_domains": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Drop these domains, at most 10.",
                    },
                    "authorization": {
                        "type": "string",
                        "description": (
                            "Operator-issued grant covering these exact search "
                            "arguments. Supply the token the user provided."
                        ),
                    },
                },
                "required": ["query"],
            },
        },
        {
            "name": "fetch_exa",
            "description": (
                "Fetch the text of a page named by a Result ID from a prior "
                "search_exa call. The Result ID is the only accepted reference; "
                "a URL is refused."
            ),
            "inputSchema": {
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "result_id": {
                        "type": "string",
                        "description": "Result ID printed by search_exa.",
                    },
                    "start_index": {
                        "type": "integer",
                        "description": "Character offset into the page text.",
                    },
                    "max_chars": {
                        "type": "integer",
                        "maximum": max_chars_cap,
                        "description": (
                            f"Characters to return, at most {max_chars_cap}. "
                            "The reply names the next start index when more "
                            "text remains."
                        ),
                    },
                },
                "required": ["result_id"],
            },
        },
    ]


TOOL_HANDLERS = {"search_exa": call_search, "fetch_exa": call_fetch}


def settings_from_environment(argv):
    settings = {
        "provider": os.environ.get("QWEN_WEB_PROVIDER", "exa"),
        "exa_key_file": os.environ.get("QWEN_WEB_EXA_KEY_FILE", ""),
        "token_key_file": os.environ.get("QWEN_WEB_TOKEN_KEY_FILE", ""),
        "fixtures": os.environ.get("QWEN_WEB_FAKE_FIXTURES", ""),
        "searxng_url": os.environ.get("QWEN_WEB_SEARXNG_URL", ""),
        "searxng_primary_category": os.environ.get(
            "QWEN_WEB_SEARXNG_PRIMARY_CATEGORY", ""
        ),
        "searxng_fallback_category": os.environ.get(
            "QWEN_WEB_SEARXNG_FALLBACK_CATEGORY", ""
        ),
        "searxng_minimum_results": os.environ.get(
            "QWEN_WEB_SEARXNG_MINIMUM_RESULTS", ""
        ),
        "searxng_language": os.environ.get("QWEN_WEB_SEARXNG_LANGUAGE", ""),
        "searxng_safesearch": os.environ.get("QWEN_WEB_SEARXNG_SAFESEARCH", ""),
        "searxng_allow_remote": os.environ.get(
            "QWEN_WEB_SEARXNG_ALLOW_REMOTE", ""
        ),
        "token_lifetime": os.environ.get("QWEN_WEB_TOKEN_LIFETIME_SECONDS", ""),
        "search_auth": os.environ.get("QWEN_WEB_SEARCH_AUTH", "required"),
        "state_dir": os.environ.get("QWEN_WEB_STATE_DIR", ""),
        "profile": os.environ.get("QWEN_WEB_PROFILE", "default"),
        "search_per_minute": os.environ.get("QWEN_WEB_SEARCH_PER_MINUTE", ""),
        "fetch_per_minute": os.environ.get("QWEN_WEB_FETCH_PER_MINUTE", ""),
        "daily_budget": os.environ.get("QWEN_WEB_DAILY_BUDGET", ""),
        "page_budget": os.environ.get("QWEN_WEB_DAILY_PAGE_BUDGET", ""),
        "max_fetches": os.environ.get("QWEN_WEB_MAX_FETCHES_PER_SEARCH", ""),
        "max_results_cap": os.environ.get("QWEN_WEB_MAX_RESULTS", ""),
        "max_chars_per_fetch_cap": os.environ.get(
            "QWEN_WEB_MAX_CHARS_PER_FETCH", ""
        ),
    }
    option_keys = {
        "--provider": "provider",
        "--exa-key-file": "exa_key_file",
        "--token-key-file": "token_key_file",
        "--fixtures": "fixtures",
        "--searxng-url": "searxng_url",
    }
    index = 0
    while index < len(argv):
        key = option_keys.get(argv[index])
        if key is None or index + 1 >= len(argv):
            usage()
        settings[key] = argv[index + 1]
        index += 2
    if settings["provider"] not in PROVIDER_NAMES:
        usage()
    return settings


def usage():
    names = "|".join(PROVIDER_NAMES)
    sys.stderr.write(
        f"usage: server.py [--provider {names}] [--exa-key-file PATH]"
        " [--token-key-file PATH] [--fixtures PATH] [--searxng-url URL]\n"
        "       server.py authorize --token-key-file PATH --query TEXT"
        " [--include-domain D]... [--exclude-domain D]..."
        " [--published-after DATE] [--published-before DATE]"
        f" [--max-age-hours N] [--provider {names}] [--profile NAME]"
        " [--max-results N] [--lifetime SECONDS]\n"
    )
    raise SystemExit(2)


def issue_grant(
    token_key_file,
    query,
    include_domains,
    exclude_domains,
    published_after,
    published_before,
    max_age_hours,
    max_results,
    provider,
    profile,
    lifetime,
    now=None,
):
    """Return the signed grant for one exact set of search arguments.

    Both issuing paths -- the `authorize` subcommand an operator runs and the
    approval broker a user interface calls -- reach the signing key through
    this function, so one implementation validates the fields, builds the
    canonical claim, and signs it. A second implementation would admit a
    spelling the serving path rejects, and `enforce_search_authorization`
    compares the claim field by field against arguments rebuilt through the
    same helpers.

    Every failure is a `ToolError`, and the key contents reach `sign_claim`
    alone, so no message and no return value carries them.
    """
    if provider not in PROVIDER_NAMES:
        raise InvalidArgument(
            "provider names none of " + ", ".join(PROVIDER_NAMES) + f": {provider}"
        )
    arguments = {
        "query": query,
        "published_after": published_after,
        "published_before": published_before,
        "max_age_hours": max_age_hours,
        "include_domains": include_domains,
        "exclude_domains": exclude_domains,
        "max_results": max_results,
    }
    issued_at = int(time.time() if now is None else now)
    claim = authorization_claim(
        require_string(arguments, "query", QUERY_CHARACTER_CAP),
        require_domain_list(arguments, "include_domains"),
        require_domain_list(arguments, "exclude_domains"),
        require_iso_date(arguments, "published_after"),
        require_iso_date(arguments, "published_before"),
        require_optional_integer(arguments, "max_age_hours", 0, MAX_AGE_HOURS_CAP),
        require_integer(arguments, "max_results", 5, 1, RESULT_COUNT_CAP),
        issued_at + resolve_token_lifetime({"token_lifetime": str(lifetime)}),
    )
    # The identity fields bind the grant to one ledger row, one provider, and
    # one profile: `grant_id` is the primary key the single use is recorded
    # under, and the serving path refuses a grant whose provider or profile
    # differs from the one it runs as.
    claim.update(
        {
            "grant_id": base64url_encode(os.urandom(GRANT_ID_BYTES)),
            "provider": provider,
            "profile_id": profile,
            "issued_at": issued_at,
            "max_uses": GRANT_MAX_USES,
        }
    )
    signing_key = read_secret_file(token_key_file, "token signing")
    token = sign_claim(signing_key, AUTHORIZATION_CLAIM_CONTEXT, claim)
    if len(token) > AUTHORIZATION_CHARACTER_CAP:
        # A grant the serving path refuses before signature verification buys
        # nothing, so the cap is enforced where the grant is issued rather than
        # where it is presented, and both issuing paths meet it here. The
        # message states the cap alone, which keeps the oversized token out of
        # the operator's stderr and out of the broker's response and audit row.
        raise InvalidArgument(
            f"the grant exceeds the {AUTHORIZATION_CHARACTER_CAP} character "
            "cap the search argument admits"
        )
    return token


def run_authorize(argv):
    """Print a search grant for the exact arguments an operator names.

    The subcommand runs outside the MCP session, so the operator or the user
    interface issues the grant and the model receives a token it can spend on
    one query alone. The grant is signed with the same key file the server
    verifies against, and the key never leaves that file.
    """
    fields = {
        "token_key_file": os.environ.get("QWEN_WEB_TOKEN_KEY_FILE", ""),
        "provider": os.environ.get("QWEN_WEB_PROVIDER", "exa"),
        "profile": os.environ.get("QWEN_WEB_PROFILE", "default"),
        "query": None,
        "published_after": "",
        "published_before": "",
        "max_age_hours": None,
        "max_results": 5,
        "lifetime": TOKEN_LIFETIME_DEFAULT_SECONDS,
    }
    include_domains = []
    exclude_domains = []
    index = 0
    while index < len(argv):
        option = argv[index]
        if index + 1 >= len(argv):
            usage()
        value = argv[index + 1]
        if option == "--token-key-file":
            fields["token_key_file"] = value
        elif option == "--query":
            fields["query"] = value
        elif option == "--include-domain":
            include_domains.append(value)
        elif option == "--exclude-domain":
            exclude_domains.append(value)
        elif option == "--published-after":
            fields["published_after"] = value
        elif option == "--published-before":
            fields["published_before"] = value
        elif option == "--provider":
            fields["provider"] = value
        elif option == "--profile":
            fields["profile"] = value
        elif option in ("--max-results", "--lifetime", "--max-age-hours"):
            try:
                fields[option[2:].replace("-", "_")] = int(value)
            except ValueError:
                usage()
        else:
            usage()
        index += 2
    if fields["query"] is None:
        usage()
    if fields["provider"] not in PROVIDER_NAMES:
        usage()
    try:
        token = issue_grant(
            fields["token_key_file"],
            fields["query"],
            include_domains,
            exclude_domains,
            fields["published_after"],
            fields["published_before"],
            fields["max_age_hours"],
            fields["max_results"],
            fields["provider"],
            fields["profile"],
            fields["lifetime"],
        )
    except ToolError as error:
        sys.stderr.write(f"{error}\n")
        return 2
    sys.stdout.write(token + "\n")
    return 0


def handle_request(settings, message):
    """Return a JSON-RPC response object, or None for a notification.

    A protocol fault answers with a JSON-RPC error; a tool that refuses its
    arguments answers with a successful result carrying `isError`, which is
    what the MCP client surfaces to the model.
    """
    method = message["method"]
    identifier = message.get("id")
    if "id" not in message:
        return None
    params = message.get("params") or {}
    if method == "initialize":
        requested = params.get("protocolVersion")
        version = (
            requested if requested in SUPPORTED_PROTOCOL_VERSIONS else PROTOCOL_VERSION
        )
        return {
            "jsonrpc": "2.0",
            "id": identifier,
            "result": {
                "protocolVersion": version,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            },
        }
    if method == "ping":
        return {"jsonrpc": "2.0", "id": identifier, "result": {}}
    if method == "tools/list":
        return {
            "jsonrpc": "2.0",
            "id": identifier,
            "result": {"tools": tool_definitions(settings)},
        }
    if method == "tools/call":
        handler = TOOL_HANDLERS.get(params.get("name"))
        if handler is None:
            return jsonrpc_error(
                identifier, -32602, f"unknown tool: {params.get('name')}"
            )
        arguments = params.get("arguments")
        if arguments is None:
            arguments = {}
        if not isinstance(arguments, dict):
            return jsonrpc_error(
                identifier, -32602, "arguments must be a JSON object"
            )
        # The schema names every argument a tool reads, so a name outside it
        # is a request the tool would silently drop. Refusing it makes the
        # executor's boundary observable: llama-server forwards the `params`
        # object of POST /tools and keeps its own routing keys out of it, and
        # a parser that started forwarding one would surface here as a
        # refusal naming the key rather than as a search that ran anyway.
        admitted = {
            name
            for tool in tool_definitions(settings)
            if tool["name"] == params.get("name")
            for name in tool["inputSchema"]["properties"]
        }
        unknown = sorted(name for name in arguments if name not in admitted)
        if unknown:
            return tool_result(
                identifier,
                "the call carries an argument the tool does not read: "
                + ", ".join(unknown),
                True,
            )
        try:
            text = handler(settings, arguments)
        except ToolError as error:
            return tool_result(identifier, str(error), True)
        except Exception as error:
            sys.stderr.write(sanitized_traceback(error) + "\n")
            sys.stderr.flush()
            return jsonrpc_error(
                identifier, -32603, "internal error during tool execution"
            )
        return tool_result(identifier, text, False)
    return jsonrpc_error(identifier, -32601, f"unknown method: {method}")


def read_request_line(stream):
    """Return one request line, `OVERSIZED_LINE`, or None at end of input.

    A peer that writes bytes and no newline would otherwise grow one string
    until the process dies, so the reader takes the cap plus one character and
    drains the rest of an oversized line. Draining rather than closing keeps
    the next line parseable, and the caller answers the oversized one with an
    invalid-request error.
    """
    line = stream.readline(REQUEST_LINE_CHARACTER_CAP + 1)
    if not line:
        return None
    if len(line) > REQUEST_LINE_CHARACTER_CAP:
        while not line.endswith("\n"):
            line = stream.readline(REQUEST_LINE_CHARACTER_CAP)
            if not line:
                break
        return OVERSIZED_LINE
    return line


def within_depth(value, remaining):
    """Return whether a decoded document nests inside the admitted depth.

    The decoder builds the whole document before any handler runs, so the cap
    bounds what the handlers walk rather than what the parser allocates: a
    deeply nested `arguments` object reaches `require_domain_list` and its
    kin, and the bound keeps that walk finite.
    """
    if remaining <= 0:
        return False
    if isinstance(value, dict):
        return all(within_depth(entry, remaining - 1) for entry in value.values())
    if isinstance(value, list):
        return all(within_depth(entry, remaining - 1) for entry in value)
    return True


def validate_message(message):
    """Return a JSON-RPC error for a structurally invalid request, or None.

    The checks run before any handler reads a field, so `params: []` answers
    with -32602 rather than reaching `.get` on a list. An `id` of string,
    number, or null is a request; an absent `id` is a notification, which the
    caller answers with silence.
    """
    if not isinstance(message, dict):
        return jsonrpc_error(None, -32600, "the request must be a JSON object")
    if not within_depth(message, JSON_DEPTH_CAP):
        return jsonrpc_error(
            None, -32600, f"the request nests deeper than {JSON_DEPTH_CAP} levels"
        )
    identifier = message.get("id")
    if "id" in message and not isinstance(
        identifier, (str, int, float, type(None))
    ):
        return jsonrpc_error(None, -32600, "id must be a string, a number, or null")
    if isinstance(identifier, bool):
        return jsonrpc_error(None, -32600, "id must be a string, a number, or null")
    if isinstance(identifier, float) and not math.isfinite(identifier):
        return jsonrpc_error(None, -32600, "id must be a finite number")
    if not isinstance(message.get("method"), str):
        return jsonrpc_error(identifier, -32600, "method must be a string")
    params = message.get("params")
    if params is not None and not isinstance(params, dict):
        return jsonrpc_error(identifier, -32602, "params must be a JSON object")
    return None


def main(argv):
    if argv and argv[0] == "authorize":
        return run_authorize(argv[1:])
    settings = settings_from_environment(argv)
    try:
        resolve_environment_caps(settings)
    except ToolError as error:
        sys.stderr.write(f"{error}\n")
        return 2
    while True:
        line = read_request_line(sys.stdin)
        if line is None:
            break
        if line is OVERSIZED_LINE:
            response = jsonrpc_error(
                None,
                -32600,
                f"the request exceeds the {REQUEST_LINE_CHARACTER_CAP} "
                "character line cap",
            )
        else:
            line = line.strip()
            if not line:
                continue
            try:
                message = strict_json_loads(line)
            except (ValueError, RecursionError):
                response = jsonrpc_error(None, -32700, "parse error")
            else:
                response = validate_message(message)
                if isinstance(message, dict) and "id" not in message:
                    # JSON-RPC notifications never receive a response, including
                    # malformed notifications. Silence prevents an unsolicited
                    # id:null error from being mistaken for a request reply.
                    response = None
                elif response is None:
                    response = handle_request(settings, message)
        if response is not None:
            sys.stdout.write(json.dumps(response, allow_nan=False) + "\n")
            sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
