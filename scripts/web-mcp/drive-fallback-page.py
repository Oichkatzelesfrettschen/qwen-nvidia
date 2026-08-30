#!/usr/bin/env python3
"""Drive the served fallback page through one web-search turn in headless Chromium.

The page is the executor the broker path is built around, so an admission
that reads its source proves the request shape and nothing about the path
the browser runs. This driver opens the page at the router origin in a
headless Chromium, turns the per-turn Web toggle on, sends one prompt, waits
for the approval dialog the page opens over the model's proposal, records the
fields the dialog shows, clicks the one approval, and waits for the turn to
end. It talks to Chromium over the DevTools protocol with the standard
library alone, because the appliance carries Chromium and Python and no
browser-automation package.

The report on stdout is one JSON object: the page origin, the model the page
selected, the dialog fields, the rendered review verdict where `--review`
drove one, the transcript the page holds after the turn, and the request log
the page's own fetch calls produced, captured by wrapping window.fetch before
the prompt is sent. Every request in that log is what the
browser sent; the shell harness compares them against the routes it drove.
The report is written on every exit path, including a raised TimeoutError:
`error` names the exception type and message where one interrupted the turn
and stays null on a completed one, `dialog` stays null when the approval
dialog never opened, and `history` carries whatever the page had already
appended -- a full assistant reply with no proposed tool call included --
because the process exits non-zero on a caught exception rather than
propagating a traceback that leaves the report file empty.
"""

import argparse
import base64
import json
import os
import re
import secrets
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request


class DevToolsSocket:
    """A minimal WebSocket client for one DevTools page session."""

    def __init__(self, url):
        match = re.match(r"ws://([^:/]+):(\d+)(/.*)", url)
        if match is None:
            raise ValueError("unexpected DevTools URL: " + url)
        host, port, path = match.group(1), int(match.group(2)), match.group(3)
        self.sock = socket.create_connection((host, port), timeout=30)
        key = base64.b64encode(secrets.token_bytes(16)).decode("ascii")
        request = (
            "GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\n"
            "Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        ).format(path=path, host=host, port=port, key=key)
        self.sock.sendall(request.encode("ascii"))
        response = b""
        while b"\r\n\r\n" not in response:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("DevTools handshake closed early")
            response += chunk
        if not response.startswith(b"HTTP/1.1 101"):
            raise ConnectionError("DevTools handshake refused: " + response[:120].decode("latin-1"))
        self.buffer = response.split(b"\r\n\r\n", 1)[1]
        self.next_id = 0

    def _read_exactly(self, count):
        while len(self.buffer) < count:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("DevTools socket closed")
            self.buffer += chunk
        data, self.buffer = self.buffer[:count], self.buffer[count:]
        return data

    def send_text(self, text):
        payload = text.encode("utf-8")
        header = bytearray([0x81])
        length = len(payload)
        if length < 126:
            header.append(0x80 | length)
        elif length < 65536:
            header.append(0x80 | 126)
            header += struct.pack(">H", length)
        else:
            header.append(0x80 | 127)
            header += struct.pack(">Q", length)
        mask = secrets.token_bytes(4)
        header += mask
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        self.sock.sendall(bytes(header) + masked)

    def receive_text(self):
        message = b""
        while True:
            first, second = self._read_exactly(2)
            opcode = first & 0x0F
            length = second & 0x7F
            if length == 126:
                length = struct.unpack(">H", self._read_exactly(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self._read_exactly(8))[0]
            if second & 0x80:
                mask = self._read_exactly(4)
                data = bytes(byte ^ mask[index % 4] for index, byte in enumerate(self._read_exactly(length)))
            else:
                data = self._read_exactly(length)
            if opcode == 0x8:
                raise ConnectionError("DevTools closed the socket")
            if opcode == 0x9:
                continue
            message += data
            if first & 0x80:
                return message.decode("utf-8")

    def call(self, method, **params):
        self.next_id += 1
        call_id = self.next_id
        self.send_text(json.dumps({"id": call_id, "method": method, "params": params}))
        while True:
            reply = json.loads(self.receive_text())
            if reply.get("id") == call_id:
                if "error" in reply:
                    raise RuntimeError(method + ": " + json.dumps(reply["error"]))
                return reply.get("result", {})

    def evaluate(self, expression):
        result = self.call(
            "Runtime.evaluate",
            expression=expression,
            awaitPromise=True,
            returnByValue=True,
        )
        if "exceptionDetails" in result:
            raise RuntimeError("page threw: " + json.dumps(result["exceptionDetails"])[:400])
        return result.get("result", {}).get("value")


def wait_for(socket_, expression, seconds, what):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = socket_.evaluate(expression)
        if value:
            return value
        time.sleep(0.5)
    raise TimeoutError("waited {}s for {}".format(seconds, what))


def capture_transcript(page):
    """The page's own state, read whether the turn finished or the driver

    gave up on it. `history` carries every message the page itself appended
    -- the user turn, the assistant's reply, any `tool_calls` it proposed, and
    the retained tool result -- so a dialog that never opened still leaves the
    model's full reply readable here rather than lost with the raised
    exception. A page that has not reached `typeof requestModel !== 'undefined'`
    answers with an empty snapshot instead of raising a second exception on
    top of the one already caught.
    """
    try:
        raw = page.evaluate(
            "JSON.stringify({ origin: window.location.origin,"
            " model: (typeof requestModel !== 'undefined' ? requestModel : null),"
            " history: (typeof history !== 'undefined' ? history : []),"
            " requests: window.__qwenRequests || [],"
            " imageStates: Array.from(document.querySelectorAll('.image-state')).map(el => el.textContent),"
            " imageCards: Array.from(document.querySelectorAll('figure.image-artifact')).map(card => ({"
            "   caption: (card.querySelector('figcaption') || {}).textContent || '',"
            "   src: ((card.querySelector('img') || {}).src || '').slice(0, 40) })),"
            " log: (document.querySelector('#log') ? document.querySelector('#log').innerText.slice(0, 6000) : '') })"
        )
        return json.loads(raw)
    except Exception:
        return {}


# `body` is truncated because one request carries a data URI of a whole PNG,
# and a harness reading a cut string cannot parse it. `bodyKeys` carries the
# top-level key names of a JSON body whole, so a check on which keys a request
# sent -- that a review carried no `tools`, for instance -- reads the names
# rather than a fragment, and the values stay out of the report the way the
# grant does.
FETCH_RECORDER = """
(() => {
  window.__qwenRequests = [];
  const original = window.fetch;
  window.fetch = function (input, init) {
    const url = typeof input === 'string' ? input : input.url;
    let body = init && init.body;
    if (typeof body !== 'string') body = null;
    let bodyKeys = null;
    let bodyModel = null;
    if (body !== null) {
      try {
        const parsed = JSON.parse(body);
        if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
          bodyKeys = Object.keys(parsed);
          if (typeof parsed.model === 'string') bodyModel = parsed.model;
        }
      } catch (error) {
        /* a body that is not one JSON object contributes no key list */
      }
    }
    window.__qwenRequests.push({
      url: new URL(url, window.location.href).href,
      method: (init && init.method) || 'GET',
      body: body === null ? null : body.slice(0, 4000),
      bodyKeys,
      bodyModel,
    });
    return original.apply(this, arguments);
  };
  return true;
})()
"""


def run_review(page, seconds):
    """Click one artifact card's Review button and read the checklist it renders.

    The button is hidden until `resolveVisionModel` finds a roster row whose
    `GET /props?model=` reports a vision modality, so waiting for it to become
    visible is the page's own statement that a reviewer serves. `runImageReview`
    holds the same `busy` flag a chat turn holds and releases it in its own
    `finally`, so the wait ends on either a rendered checklist or the note the
    page writes when the review did not complete.
    """
    wait_for(
        page,
        "(() => { const button = document.querySelector('.image-review-button');"
        " return Boolean(button && !button.hidden); })()",
        seconds,
        "the Review button to appear",
    )
    page.evaluate(
        "(() => { document.querySelector('.image-review-button').click();"
        " return true; })()"
    )
    wait_for(
        page,
        "busy === false && Boolean(document.querySelector('.image-review')"
        " || document.querySelector('.image-review-note'))",
        seconds,
        "the review to settle",
    )
    raw = page.evaluate(
        "JSON.stringify((() => {"
        " const block = document.querySelector('.image-review');"
        " const note = document.querySelector('.image-review-note');"
        " return {"
        "   heading: block ? (block.querySelector('.meta') || {}).textContent || '' : '',"
        "   constraints: block ? Array.from(block.querySelectorAll('li')).map(item => ({"
        "     verdict: item.className, text: item.textContent })) : [],"
        "   note: note ? note.textContent : null,"
        "   noteIsFailure: Boolean(note && note.classList.contains('bad')) };"
        "})())"
    )
    return json.loads(raw)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--origin", required=True, help="router origin the page is served from")
    parser.add_argument("--prompt", required=True, help="the user turn to send")
    parser.add_argument("--broker", default="",
                        help="approval broker origin; passed to the page as its ?broker= query parameter")
    parser.add_argument("--artifacts", default="",
                        help="image artifact listener origin; typed into the page's own "
                             "artifact-origin field, the way an operator reads the port off the session status line")
    # The two lanes carry the same turn shape over their own controls: a
    # per-turn toggle, a dialog the proposal opens, and one approval. Naming
    # the lane rather than each selector keeps a driver invocation readable
    # and keeps the page's element names in one place.
    parser.add_argument("--lane", choices=("web", "image"), default="web",
                        help="which per-turn lane's toggle and approval dialog to drive")
    parser.add_argument("--model", default="",
                        help="select this roster id in the page's own picker before sending "
                             "the prompt, refusing the step by name where the picker carries "
                             "no option for it; a paired preset's default selection otherwise "
                             "follows the page's own rule and can land on a review-only row")
    # The Review button appears on an artifact card where some roster row
    # reports a vision modality, so a review arm runs only against a preset
    # holding a review section. The verdict it renders is text a model wrote
    # after reading an image, which the page puts on the card through
    # textContent; the report carries the same text and no prompt_delta, the
    # way the request log carries the grant's fields and not the grant.
    parser.add_argument("--review", action="store_true",
                        help="click the artifact card's Review button and report the rendered checklist")
    parser.add_argument("--review-timeout", type=int, default=420)
    parser.add_argument("--api-key-file", default="",
                        help="file whose first line is the bearer key the page sets before connecting")
    parser.add_argument("--chromium", default="chromium")
    parser.add_argument("--load-timeout", type=int, default=180)
    parser.add_argument("--dialog-timeout", type=int, default=600)
    parser.add_argument("--turn-timeout", type=int, default=900)
    arguments = parser.parse_args()

    profile_directory = tempfile.mkdtemp(prefix="qwen-page-drive.")
    command = [
        arguments.chromium,
        "--headless=new",
        "--no-sandbox",
        "--disable-gpu",
        "--no-first-run",
        "--remote-debugging-port=0",
        "--user-data-dir=" + profile_directory,
        "about:blank",
    ]
    # Chromium keeps writing to stderr for the life of the process, so it
    # goes to a file the driver polls rather than a pipe that would fill.
    browser_log = open(os.path.join(profile_directory, "chromium.log"), "w+b")
    browser = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=browser_log)
    try:
        # `page`, `selected_model`, and `dialog` stay readable after any raise
        # inside this block, so a caught exception still leaves the report
        # able to name what the page had already done -- the model it
        # selected and, through capture_transcript() below, its full reply.
        page = None
        selected_model = None
        dialog = None
        review = None
        error = None
        try:
            devtools = None
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline and browser.poll() is None:
                browser_log.seek(0)
                match = re.search(r"DevTools listening on (ws://\S+)", browser_log.read().decode("utf-8", "replace"))
                if match:
                    devtools = match.group(1)
                    break
                time.sleep(0.2)
            if devtools is None:
                raise RuntimeError("Chromium printed no DevTools address")
            http_origin = re.match(r"ws://([^/]+)/", devtools).group(1)
            # The page resolves the broker from ?broker= ahead of its meta tag,
            # so a launch on another broker port reaches the page the way an
            # operator's own visit would.
            # DevTools takes the target URL as the raw remainder of its own query
            # string, so one parameter travels there and a second would be read as
            # the debugger's. The broker goes in the URL, the way an operator's
            # bookmark carries it, and the artifact listener is typed into its own
            # field below, the way an operator reads the port off the session
            # status line.
            page_url = arguments.origin + "/"
            if arguments.broker:
                page_url += "?broker=" + urllib.parse.quote(arguments.broker, safe="")
            request = urllib.request.Request(
                "http://{}/json/new?{}".format(http_origin, page_url), method="PUT"
            )
            with urllib.request.urlopen(request, timeout=30) as response:
                target = json.load(response)
            page = DevToolsSocket(target["webSocketDebuggerUrl"])
            page.call("Page.enable")
            page.call("Runtime.enable")

            wait_for(page, "document.readyState === 'complete' && typeof requestModel !== 'undefined'",
                     arguments.load_timeout, "the page to load")
            if arguments.api_key_file:
                # The key enters the page through its own field and set-key
                # click, which is the path a user takes; it stays in the
                # throwaway profile's sessionStorage and in no report field.
                with open(arguments.api_key_file, encoding="utf-8") as handle:
                    api_key = handle.readline().strip()
                page.evaluate(
                    "(() => { document.querySelector('#api-key').value = "
                    + json.dumps(api_key)
                    + "; document.querySelector('#set-key').click(); return true; })()"
                )
            if arguments.artifacts:
                page.evaluate(
                    "(() => { document.querySelector('#artifact-origin').value = "
                    + json.dumps(arguments.artifacts)
                    + "; return true; })()"
                )
            selected_model = wait_for(page, "requestModel", arguments.load_timeout, "the page to select a model")
            if arguments.model and arguments.model != selected_model:
                # The page's own default -- storage, then the first roster id
                # that answers `GET /tools` with 200 -- is not the identity a
                # harness needs: it is proving that identity, so this driver
                # picks the model explicitly rather than trusting the page's
                # rule to land on it. A picker with no option for the id is a
                # roster mismatch the harness should fail loudly on rather
                # than silently sending the turn to whichever row the page
                # picked, so the check runs before the picker's value is
                # touched.
                has_option = page.evaluate(
                    "Array.from(document.querySelectorAll('#model-picker option'))"
                    ".some(option => option.value === " + json.dumps(arguments.model) + ")"
                )
                if not has_option:
                    raise RuntimeError(
                        "the page's model picker carries no option for --model "
                        + arguments.model
                    )
                page.evaluate(
                    "(() => { const picker = document.querySelector('#model-picker');"
                    " picker.value = " + json.dumps(arguments.model) + ";"
                    " picker.dispatchEvent(new Event('change')); return true; })()"
                )
                wait_for(
                    page, "requestModel === " + json.dumps(arguments.model),
                    arguments.load_timeout, "the page to select --model " + arguments.model,
                )
                selected_model = arguments.model
            page.evaluate(FETCH_RECORDER)
            if arguments.lane == "image":
                toggle, dialog_id = "#image-tools", "#image-approval"
                approve, args_list = "#image-approve-once", "#image-approval-args"
                note_id = "#image-approval-note"
            else:
                toggle, dialog_id = "#web-tools", "#web-approval"
                approve, args_list = "#approve-once", "#approval-args"
                note_id = "#approval-note"
            page.evaluate(
                "(() => { document.querySelector('" + toggle + "').checked = true; return true; })()"
            )
            page.evaluate(
                "(() => { const box = document.querySelector('#input'); box.value = "
                + json.dumps(arguments.prompt)
                + "; document.querySelector('#send').click(); return true; })()"
            )
            wait_for(page, "document.querySelector('" + dialog_id + "').open", arguments.dialog_timeout,
                     "the approval dialog")
            dialog = page.evaluate(
                "(() => { const args = {}; document.querySelectorAll('" + args_list + " dt').forEach(dt => {"
                " args[dt.textContent.trim()] = (dt.nextElementSibling || {}).textContent; });"
                " return { heading: document.querySelector('" + dialog_id + " h2').textContent,"
                " note: document.querySelector('" + note_id + "').textContent, args }; })()"
            )
            page.evaluate(
                "(() => { document.querySelector('" + approve + "').click(); return true; })()"
            )
            wait_for(page, "busy === false", arguments.turn_timeout, "the turn to end")
            if arguments.lane == "image":
                # executeImageGeneration() awaits the artifact before it answers
                # the call, so a turn that ended carries either a card holding a
                # blob URL or an `Image failed` state line. The wait reads that
                # settled state and a timeout leaves the page as it stands for
                # the report to carry.
                try:
                    wait_for(
                        page,
                        "(() => { const state = document.querySelector('.image-state');"
                        " if (state && /^Image failed/.test(state.textContent)) return true;"
                        " const card = document.querySelector('figure.image-artifact');"
                        " if (!card) return false;"
                        " const img = card.querySelector('img');"
                        " return Boolean(img && img.src); })()",
                        120,
                        "the artifact fetch to resolve",
                    )
                except TimeoutError:
                    pass
                if arguments.review:
                    review = run_review(page, arguments.review_timeout)
        except Exception as exc:
            # A raise here -- most often wait_for()'s TimeoutError on a dialog
            # that never opened -- previously left main() propagate straight
            # to sys.exit(main()), so the traceback went to stderr and stdout,
            # and the report file the shell harness reads, stayed empty. The
            # page's own transcript survives the exception; only the fields
            # this driver was mid-collecting are lost.
            error = {"type": type(exc).__name__, "message": str(exc)}

        report = capture_transcript(page) if page is not None else {}
        report.setdefault("origin", "")
        report.setdefault("model", None)
        report.setdefault("history", [])
        report.setdefault("requests", [])
        report["selected_model_at_load"] = selected_model
        report["dialog"] = dialog
        report["review"] = review
        report["error"] = error
        json.dump(report, sys.stdout, indent=1)
        sys.stdout.write("\n")
        return 1 if error else 0
    finally:
        browser_log.close()
        browser.terminate()
        try:
            browser.wait(timeout=10)
        except subprocess.TimeoutExpired:
            browser.kill()
        # Chromium keeps writing into its cache while it unwinds, so a
        # bottom-up walk races it: a directory emptied by the walk regains an
        # index file before the rmdir reaches it and the removal raises
        # ENOTEMPTY out of the `finally`, replacing a completed run's exit
        # status with a traceback. The profile is a throwaway temporary tree,
        # so its removal is best effort and the report is what the run carries.
        shutil.rmtree(profile_directory, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
