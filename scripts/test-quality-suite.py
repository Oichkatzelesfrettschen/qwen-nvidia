#!/usr/bin/env python3
"""Check every grader against replies whose verdict is known.

A grader that silently accepts everything reports a perfect candidate, so each
kind is exercised with one reply it must accept and one it must refuse. The
suite file is checked for well-formed rows in the same run, because a row with
the wrong field count fails at measurement time rather than here.
"""

import contextlib
import hashlib
import io
import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import importlib.util

spec = importlib.util.spec_from_file_location(
    "quality_suite",
    os.path.join(os.path.dirname(os.path.abspath(__file__)),
                 "run-quality-suite.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

CASES = [
    ("numeric", "3168", "The product is 3168.", True),
    ("numeric", "3168", "The product is 3167.", False),
    ("numeric", "3168", "I cannot say.", False),
    ("numeric", "-11", "7 - 3*6 = 7 - 18 = -11", True),
    ("numeric", "2540", "That is 2,540 millimetres.", True),
    ("contains_all", "2|45", "The trip takes 2 hours and 45 minutes.", True),
    ("contains_all", "2|45", "The trip takes 2 hours.", False),
    ("contains_any", "off-by-one|<=", "It is an off-by-one error.", True),
    ("contains_any", "off-by-one|<=", "The loop is fine.", False),
    ("json_keys", "name|age", '{"name": "Ada", "age": 36}', True),
    ("json_keys", "name|age", '{"name": "Ada"}', False),
    ("json_keys", "name|age", 'Sure! {"name": "Ada", "age": 36}', False),
    ("json_keys", "name|age", '```json\n{"name": "Ada", "age": 36}\n```', False),
    ("json_keys", "name|age", '{"name": NaN, "age": 36}', False),
    ("json_keys", "name|age", '{"name": Infinity, "age": 36}', False),
    ("json_keys", "name|age", '{"name": -Infinity, "age": 36}', False),
    ("json_keys", "items", '[1, 2, 3]', False),
    ("regex", r"^\s*(yes|no)\s*[.!]?\s*$", "yes", True),
    ("regex", r"^\s*(yes|no)\s*[.!]?\s*$", "Yes, 12 is divisible by 4.", False),
    ("regex", r"^\s*\d{4}-\d{2}-\d{2}\s*$", "2024-02-29", True),
    ("regex", r"^\s*\d{4}-\d{2}-\d{2}\s*$", "29 February 2024", False),
    ("nonempty", "", "Any answer at all.", True),
    ("nonempty", "", "   \n  ", False),
]
CASES.append(("json_keys", "name", "[" * 2000 + "0" + "]" * 2000, False))

failures = 0
for kind, expectation, reply, expected in CASES:
    row = {"grader": kind, "expectation": expectation}
    passed, reason = module.grade(row, reply)
    if passed != expected:
        print(f"grader={kind} expectation={expectation!r} reply={reply!r} "
              f"expected={expected} got={passed} reason={reason}",
              file=sys.stderr)
        failures += 1

# Truncation refuses the presence grader and leaves every content grader alone.
# The roster arm that exposed this credited term-02 for a reply cut at the
# token budget, which is the termination failure the row exists to catch, while
# ctx-03 was truncated in the same arm and failed on its numeric terms.
TRUNCATION_CASES = [
    ("nonempty", "", "A reply that ran out of budget", True, False),
    ("nonempty", "", "A reply that finished", False, True),
    ("numeric", "42", "the answer is 42", True, True),
    ("contains_all", "canberra", "The capital is Canberra and", True, True),
]
for kind, expectation, reply, truncated, expected in TRUNCATION_CASES:
    row = {"grader": kind, "expectation": expectation}
    passed, reason = module.grade(row, reply, truncated)
    if passed != expected:
        print(f"grader={kind} truncated={truncated} reply={reply!r} "
              f"expected={expected} got={passed} reason={reason}",
              file=sys.stderr)
        failures += 1

suite_path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                          "quality-suite.tsv")
rows = module.load_suite(suite_path)
identifiers = [row["id"] for row in rows]
if len(set(identifiers)) != len(identifiers):
    print("suite holds duplicate identifiers", file=sys.stderr)
    failures += 1
known = {"numeric", "contains_all", "contains_any", "json_keys", "regex",
         "nonempty", "tool_call", "no_tool_call"}
for row in rows:
    if row["grader"] not in known:
        print(f"{row['id']}: unknown grader {row['grader']}", file=sys.stderr)
        failures += 1
    if row["grader"] not in ("nonempty",) and not row["expectation"]:
        print(f"{row['id']}: grader {row['grader']} carries no expectation",
              file=sys.stderr)
        failures += 1
    if not row["prompt"].strip():
        print(f"{row['id']}: empty prompt", file=sys.stderr)
        failures += 1

# Every attachment a row names must resolve here. An image absent from the
# fixture directory or a tool set absent from the declaration reaches the
# appliance as a wrong answer partway through an arm that already spent device
# time, which is the failure this check moves forward to a test run.
remote_directory = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(remote_directory, "quality-tools.json")) as handle:
    declared_tool_sets = json.load(handle)
attachment_kinds = {}
for row in rows:
    kind, names = module.parse_attachment(row.get("attachment"))
    attachment_kinds[kind] = attachment_kinds.get(kind, 0) + 1
    for name in names:
        if kind == "image":
            try:
                module.resolve_fixture(
                    os.path.join(remote_directory, "quality-images"), name)
            except SystemExit:
                print(f"{row['id']}: names an absent fixture {name}", file=sys.stderr)
                failures += 1
        elif name not in declared_tool_sets:
            print(f"{row['id']}: names an undeclared tool set {name}",
                  file=sys.stderr)
            failures += 1

# A tool grader without a tool set is a row that can only report a refusal, and
# an image grader without an image grades the prompt.
for row in rows:
    kind, _ = module.parse_attachment(row.get("attachment"))
    if row["grader"] in ("tool_call", "no_tool_call") and kind != "tools":
        print(f"{row['id']}: tool grader with attachment kind {kind}",
              file=sys.stderr)
        failures += 1
    if row["category"] in ("vision", "photo") and kind != "image":
        print(f"{row['id']}: {row['category']} row with attachment kind {kind}",
              file=sys.stderr)
        failures += 1

# The tool graders separate the stages a single pass rate merges, and each stage
# is exercised with a call whose verdict is known.
WEATHER_ROW = {"grader": "tool_call", "expectation": "get_weather:city=Oslo"}


def fixture_calls(name, arguments):
    return module.read_tool_calls(
        {"tool_calls": [{"function": {"name": name, "arguments": arguments}}]})


NUMBER_ROW = {"grader": "tool_call", "expectation": "multiply:left=47|right=89"}

TOOL_CASES = [
    (WEATHER_ROW, fixture_calls("get_weather", '{"city": "Oslo"}'), True),
    # A schema declaring {"type": "number"} lets a model emit 47, 47.0, or "47"
    # for one value, and a string comparison scores two of the three wrong.
    (NUMBER_ROW, fixture_calls("multiply", '{"left": 47, "right": 89}'), True),
    (NUMBER_ROW, fixture_calls("multiply", '{"left": 47.0, "right": 89.0}'), True),
    (NUMBER_ROW, fixture_calls("multiply", '{"left": "47", "right": "89"}'), True),
    (NUMBER_ROW, fixture_calls("multiply", '{"left": 48, "right": 89}'), False),
    (WEATHER_ROW, fixture_calls("get_weather", '{"city": "oslo"}'), True),
    (WEATHER_ROW, fixture_calls("get_weather", '{"city": "Bergen"}'), False),
    (WEATHER_ROW, fixture_calls("get_local_time", '{"city": "Oslo"}'), False),
    (WEATHER_ROW, fixture_calls("get_weather", "not json at all"), False),
    (WEATHER_ROW, [], False),
    ({"grader": "no_tool_call", "expectation": "paris"}, [], None),
]
for row, calls, expected in TOOL_CASES:
    if expected is None:
        continue
    passed, reason = module.grade(row, "", tool_calls=calls)
    if passed != expected:
        print(f"tool grader: calls={calls} expected={expected} got={passed} "
              f"reason={reason}", file=sys.stderr)
        failures += 1

# An emitted call fails a no_tool_call row whatever the prose says, because the
# row asks whether the model reached for a tool it did not need.
passed, _ = module.grade({"grader": "no_tool_call", "expectation": "paris"},
                         "The capital is Paris.",
                         tool_calls=fixture_calls("get_weather", '{"city": "Paris"}'))
if passed:
    print("no_tool_call accepted a reply that called a tool", file=sys.stderr)
    failures += 1

# The photographic fixture is pinned rather than drawn, so its bytes are checked
# against the digest its fetch script names. A fixture replaced upstream, or a
# thumbnail regenerated by a different encoder, changes what every `photo` row
# was graded against.
photo_path = os.path.join(remote_directory, "quality-images", "zebra.jpg")
fetch_script = os.path.join(remote_directory, "download-quality-photo.sh")
with open(fetch_script) as handle:
    fetch_text = handle.read()
pinned_digest = next(
    (line.split("=", 1)[1].strip() for line in fetch_text.splitlines()
     if line.startswith("photo_sha256=")), None)
try:
    with open(photo_path, "rb") as handle:
        actual_digest = hashlib.sha256(handle.read()).hexdigest()
except OSError as error:
    print(f"photographic fixture is unreadable: {error}", file=sys.stderr)
    failures += 1
else:
    if pinned_digest != actual_digest:
        print(f"photographic fixture does not match its fetch script: "
              f"pinned {pinned_digest}, found {actual_digest}", file=sys.stderr)
        failures += 1

# One logical fixture name identifies one byte sequence. Choosing the first
# extension would let a stale PNG shadow a newly pinned JPEG without changing
# the suite row that names it.
with tempfile.TemporaryDirectory() as temporary_directory:
    for extension in (".png", ".jpg"):
        with open(os.path.join(temporary_directory, "duplicate" + extension), "wb"):
            pass
    try:
        module.resolve_fixture(temporary_directory, "duplicate")
    except SystemExit as error:
        if "fixture is ambiguous" not in str(error):
            print(f"ambiguous fixture reported the wrong failure: {error}",
                  file=sys.stderr)
            failures += 1
    else:
        print("fixture resolver selected one of two byte sequences", file=sys.stderr)
        failures += 1

# A tool row answered by its call alone is not an empty answer. Counting it as
# one made a tool arm report an 0.800 empty-answer rate beside nine of ten rows
# graded correct, and correct_on_completed was computed over the two rows that
# happened to carry prose.
with tempfile.TemporaryDirectory() as temporary_directory:
    suite = os.path.join(temporary_directory, "suite.tsv")
    output = os.path.join(temporary_directory, "result.json")
    with open(suite, "w") as handle:
        handle.write("call\ttool\ttool_call\tget_weather:city=Oslo\t"
                     "Weather in Oslo?\ttools:weather\n")
    tool_document = {
        "model": "qwen-apu",
        "choices": [{
            "message": {
                "content": "",
                "tool_calls": [{"function": {"name": "get_weather",
                                             "arguments": '{"city": "Oslo"}'}}],
            },
            "finish_reason": "tool_calls",
        }],
        "timings": {"predicted_n": 12, "prompt_n": 200},
        "_wall_seconds": 1.0,
    }
    original_request = module.request
    module.request = lambda *args, **kwargs: tool_document
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            module.main(("run-quality-suite.py", "http://fixture", output,
                         "--suite", suite))
    finally:
        module.request = original_request
    with open(output) as handle:
        tool_result = json.load(handle)
    tool_summary = tool_result["summary"]
    if tool_summary["empty_answer_rate"] != 0.0:
        print(f"a tool call counted as an empty answer: {tool_summary}",
              file=sys.stderr)
        failures += 1
    if tool_summary["correct_on_completed"] != 1.0:
        print(f"a graded tool call fell outside completed: {tool_summary}",
              file=sys.stderr)
        failures += 1
    if (tool_summary["tool_stages"] or {}).get("arguments_match") != 1:
        print(f"tool stages did not record the match: {tool_summary}",
              file=sys.stderr)
        failures += 1

# The fact lands inside the filler and the question lands last, which is what
# makes a long-context row a retrieval test rather than a longer prompt. A fact
# left adjacent to its question is answerable from the final sentence alone.
padded = module.pad_prompt("FACT ||| QUESTION", 4000)
if len(padded) < 4000:
    print(f"padding produced {len(padded)} characters", file=sys.stderr)
    failures += 1
if not padded.endswith("QUESTION"):
    print("padding left the question away from the end", file=sys.stderr)
    failures += 1
if "FACT QUESTION" in padded or padded.index("FACT") > padded.index("QUESTION"):
    print("padding left the fact adjacent to the question", file=sys.stderr)
    failures += 1
gap = padded.index("QUESTION") - (padded.index("FACT") + len("FACT"))
if gap < 1000:
    print(f"padding left only {gap} characters between fact and question",
          file=sys.stderr)
    failures += 1
if module.pad_prompt("FACT ||| QUESTION", 0) != "FACT QUESTION":
    print("unpadded long-context prompt kept its separator", file=sys.stderr)
    failures += 1

# Every long_context row must carry the separator, or its fact stays welded to
# its question and the category silently stops testing retrieval.
for row in rows:
    if row["category"] == "long_context" and module.NEEDLE_SEPARATOR not in row["prompt"]:
        print(f"{row['id']}: long_context row holds no fact separator",
              file=sys.stderr)
        failures += 1


def synthetic_document(content, finish_reason="stop", served_model="qwen-apu"):
    document = {
        "choices": [{
            "message": {"content": content, "reasoning_content": ""},
            "finish_reason": finish_reason,
        }],
        "timings": {
            "predicted_n": 1,
            "prompt_n": 1,
            "predicted_per_second": 1.0,
        },
        "_wall_seconds": 1.0,
    }
    if served_model is not None:
        document["model"] = served_model
    return document


# An image-withheld control changes image presence alone. Sending the prompt as
# a bare string would also change the chat-template input from multipart to
# scalar content and confound the control with representation sensitivity.
with tempfile.TemporaryDirectory() as temporary_directory:
    suite = os.path.join(temporary_directory, "suite.tsv")
    output = os.path.join(temporary_directory, "result.json")
    with open(suite, "w") as handle:
        handle.write(
            "vision-control\tvision\tnonempty\t\tDescribe the image.\t"
            "image:shapes\n")
    captured_request = {}

    def capture_withheld_request(*_arguments, **keyword_arguments):
        captured_request.update(keyword_arguments)
        return synthetic_document("A control reply.")

    original_request = module.request
    module.request = capture_withheld_request
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            status = module.main((
                "run-quality-suite.py", "http://fixture", output,
                "--suite", suite, "--omit-images",
                "--images", os.path.join(remote_directory, "quality-images"),
            ))
    finally:
        module.request = original_request
    withheld_content = module.build_request_content(
        "Describe the image.", captured_request.get("image_parts", ()),
        preserve_multipart=captured_request.get("preserve_multipart", False))
    if status != 0:
        print("image-withheld control returned failure", file=sys.stderr)
        failures += 1
    if captured_request.get("image_parts") != []:
        print("image-withheld control still sent image parts", file=sys.stderr)
        failures += 1
    if withheld_content != [{"type": "text", "text": "Describe the image."}]:
        print(f"image-withheld control changed request shape: {withheld_content!r}",
              file=sys.stderr)
        failures += 1


# The retained reply is the object that the grader reads. Truncating only the
# JSON evidence makes a later re-grade unable to reproduce the recorded verdict.
with tempfile.TemporaryDirectory() as temporary_directory:
    suite = os.path.join(temporary_directory, "suite.tsv")
    output = os.path.join(temporary_directory, "result.json")
    with open(suite, "w") as handle:
        handle.write(
            "wrong\tscreen\tnumeric\t1\tFirst prompt\t-\n"
            "truncated\tscreen\tnumeric\t1\tSecond prompt\t-\n"
            "long-reply\tscreen\tnonempty\t\tThird prompt\t-\n")
    documents = iter((
        synthetic_document("2"),
        synthetic_document("1", finish_reason="length"),
        synthetic_document("x" * 700),
    ))
    original_request = module.request
    module.request = lambda *args, **kwargs: next(documents)
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            status = module.main(("run-quality-suite.py", "http://fixture", output,
                                  "--suite", suite))
    finally:
        module.request = original_request
    with open(output) as handle:
        result = json.load(handle)
    if status != 0:
        print("synthetic quality run returned failure", file=sys.stderr)
        failures += 1
    if result["records"][2]["content"] != "x" * 700:
        print("quality evidence truncated the reply used for grading",
              file=sys.stderr)
        failures += 1
    if result["summary"]["completion_rate"] != 2 / 3:
        print("truncated reply counted as completed", file=sys.stderr)
        failures += 1
    if result["summary"]["correct_on_completed"] != 0.5:
        print("truncated reply entered completed-row accuracy", file=sys.stderr)
        failures += 1

# Attribution is a per-row invariant. Reducing only the non-empty model ids to a
# set lets one unattributed response disappear beside a correctly attributed one.
with tempfile.TemporaryDirectory() as temporary_directory:
    suite = os.path.join(temporary_directory, "suite.tsv")
    output = os.path.join(temporary_directory, "result.json")
    with open(suite, "w") as handle:
        handle.write(
            "missing-model\tscreen\tnonempty\t\tFirst prompt\t-\n"
            "matched-model\tscreen\tnonempty\t\tSecond prompt\t-\n")
    documents = iter((
        synthetic_document("answer", served_model=None),
        synthetic_document("answer"),
    ))
    original_request = module.request
    module.request = lambda *args, **kwargs: next(documents)
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            status = module.main(("run-quality-suite.py", "http://fixture", output,
                                  "--suite", suite))
    finally:
        module.request = original_request
    with open(output) as handle:
        result = json.load(handle)
    if status != 1:
        print("quality suite accepted an unattributed row", file=sys.stderr)
        failures += 1
    if result["summary"]["attribution_failures"] != 1:
        print("quality summary lost the unattributed row", file=sys.stderr)
        failures += 1
    if result["records"][0]["passed"] or not result["records"][0]["attribution_error"]:
        print("unattributed row did not retain its attribution failure",
              file=sys.stderr)
        failures += 1
    if result["summary"]["served_models"] != ["qwen-apu"]:
        print("served-model roster changed while checking row attribution",
              file=sys.stderr)
        failures += 1

# A reset is one row's transport result, not an exception that prevents the
# remaining suite and its summary JSON from being retained.
with tempfile.TemporaryDirectory() as temporary_directory:
    suite = os.path.join(temporary_directory, "suite.tsv")
    output = os.path.join(temporary_directory, "result.json")
    with open(suite, "w") as handle:
        handle.write("reset\tscreen\tnonempty\t\tPrompt\t-\n")
    original_request = module.request
    module.request = lambda *args, **kwargs: (_ for _ in ()).throw(
        ConnectionResetError("fixture reset"))
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            status = module.main(("run-quality-suite.py", "http://fixture", output,
                                  "--suite", suite))
    finally:
        module.request = original_request
    with open(output) as handle:
        result = json.load(handle)
    if status != 1 or "fixture reset" not in result["records"][0]["error"]:
        print("connection reset did not become a retained transport failure",
              file=sys.stderr)
        failures += 1

# Selecting a retrieval row without a real depth is an invocation error. The
# suite never silently degrades that category into short recall.
with tempfile.TemporaryDirectory() as temporary_directory:
    suite = os.path.join(temporary_directory, "suite.tsv")
    output = os.path.join(temporary_directory, "result.json")
    with open(suite, "w") as handle:
        handle.write(
            "long\tlong_context\tcontains_all\tneedle\t"
            "needle ||| What is the needle?\t-\n")
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            module.main(("run-quality-suite.py", "http://fixture", output,
                         "--suite", suite))
    except SystemExit as error:
        if error.code != 2:
            print(f"missing long-context depth exited {error.code}, expected 2",
                  file=sys.stderr)
            failures += 1
    else:
        print("quality suite accepted long-context rows without a real depth",
              file=sys.stderr)
        failures += 1

# A grader that accepts a reply carrying no answer is a no-op, and a no-op
# grader reports a perfect candidate. Every row except the termination category,
# which grades presence rather than content, must refuse this.
REFUSAL = "I am not able to answer that question right now."
for row in rows:
    if row["grader"] == "nonempty":
        continue
    passed, reason = module.grade(row, REFUSAL)
    if passed:
        print(f"{row['id']}: grader {row['grader']} accepted a reply with no "
              f"answer ({reason})", file=sys.stderr)
        failures += 1

# A row that asks which of two alternatives holds is graded by a substring in
# the wrong answer's own denial: "not bare; in full leaf" carries the word the
# correct answer needs. Each contrast row therefore names the reply it must
# reject beside the ones it must accept, because a grader that only ever sees
# correct answers proves nothing about the ones it would award.
CONTRAST_CASES = (
    ("photo-06", "left", True),
    ("photo-06", "not left; right", False),
    ("photo-06", "Right.", False),
    ("photo-07", "Bare.", True),
    ("photo-07", "leafless", True),
    ("photo-07", "not bare; in full leaf", False),
    ("photo-07", "They are in full leaf.", False),
    ("photo-08", "Dry.", True),
    ("photo-08", "dry and golden brown", True),
    ("photo-08", "not dry; green", False),
    ("photo-08", "The grass is green and lush.", False),
    ("photo-09", "Side.", True),
    ("photo-09", "in profile", True),
    ("photo-09", "not side-on; head-on", False),
    ("photo-09", "Head-on.", False),
    ("photo-09", "photographed from the front", False),
)

rows_by_id = {row["id"]: row for row in rows}
for row_id, reply, expected in CONTRAST_CASES:
    row = rows_by_id.get(row_id)
    if row is None:
        print(f"{row_id}: contrast case names an absent row", file=sys.stderr)
        failures += 1
        continue
    passed, reason = module.grade(row, reply)
    if passed != expected:
        verdict = "accepted" if passed else "rejected"
        print(f"{row_id}: grader {verdict} {reply!r} ({reason})", file=sys.stderr)
        failures += 1

# `$` under re.MULTILINE matches at every line end, so an unanchored pattern
# accepts a compliant line inside a reply that violated the instruction.
for row in rows:
    if row["grader"] == "regex" and not row["expectation"].startswith("\\A"):
        print(f"{row['id']}: regex expectation is not anchored at \\A",
              file=sys.stderr)
        failures += 1

if failures:
    print(f"quality_suite_grader=rejected failures={failures}", file=sys.stderr)
    sys.exit(1)
print(f"quality_suite_grader=accepted cases={len(CASES) + len(TRUNCATION_CASES) + len(TOOL_CASES) + len(CONTRAST_CASES)} rows={len(rows)}")
