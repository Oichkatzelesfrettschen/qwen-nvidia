#!/usr/bin/env python3
"""Grade a live server against scripts/quality-suite.tsv.

The five-prompt screen no longer separates candidates, so admission needs a
suite wide enough to show what a lower-bit quantization trades away and a
grader that reads it the same way every time. Every row carries the program
that grades it, so a run reports correctness, completion, and reasoning span
without a reader in the loop.

Long-context rows are padded to a requested depth with generated filler placed
before the question, which measures retrieval past a prefix rather than
retrieval from a short prompt.

A row's `attachment` column names what the request carries besides the prompt.
`image:NAME` sends the fixture that scripts/generate-quality-images.py draws,
whose content this repository declares, so a vision row is graded against a
known answer rather than against a reader's impression. `tools:SET` offers the
named set from scripts/quality-tools.json in the request body. Nothing is
executed on either path: the appliance runs without --tools, so the server holds
no tool server, and what a tool row grades is the `tool_calls` object the model
emitted.
"""

import argparse
import base64
import http.client
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

FILLER_SENTENCE = (
    "The survey team recorded routine observations at the site and filed them "
    "with the district office in the usual sequence. "
)


SUITE_FIELDS = ("id", "category", "grader", "expectation", "prompt", "attachment")


def load_suite(path):
    rows = []
    with open(path) as handle:
        for line in handle:
            if line.startswith("#") or not line.strip():
                continue
            fields = line.rstrip("\n").split("\t")
            if len(fields) != len(SUITE_FIELDS):
                raise SystemExit(f"suite row holds {len(fields)} fields: {fields[0]}")
            rows.append(dict(zip(SUITE_FIELDS, fields)))
    return rows


def parse_attachment(value):
    """Return (kind, names). `-` is a row that carries the prompt alone.

    One column rather than two because a row carries images or tools and never
    both: an image row measures what the projector put in the embedding space
    and a tool row measures selection from a declared set, and mixing them would
    leave a failure unattributable between the two.
    """
    value = (value or "-").strip()
    if value in ("", "-"):
        return "none", ()
    kind, separator, names = value.partition(":")
    if not separator or kind not in ("image", "tools"):
        raise SystemExit(f"attachment must be `-`, `image:...`, or `tools:...`: {value}")
    parts = tuple(part for part in names.split("|") if part)
    if not parts:
        raise SystemExit(f"attachment names nothing: {value}")
    if kind == "tools" and len(parts) != 1:
        raise SystemExit(f"a tool row names one set: {value}")
    return kind, parts


def last_number(text):
    matches = re.findall(r"-?\d+(?:\.\d+)?", text.replace(",", ""))
    return float(matches[-1]) if matches else None


def reject_nonfinite_json_constant(constant):
    """Reject Python's non-standard NaN and infinity JSON extensions."""
    raise ValueError(f"non-finite JSON constant: {constant}")


def parse_tool_expectation(expectation):
    """`name:key=value|key=value` for one call, `;` between calls.

    The expectation names what the model should have asked for. It is parsed
    rather than compared as text because a model emits its arguments as a JSON
    string whose key order and spacing it chooses.
    """
    wanted = []
    for clause in expectation.split(";"):
        clause = clause.strip()
        if not clause:
            continue
        name, separator, argument_text = clause.partition(":")
        arguments = {}
        if separator:
            for pair in argument_text.split("|"):
                if not pair.strip():
                    continue
                key, equals, value = pair.partition("=")
                if not equals:
                    raise SystemExit(f"tool argument holds no `=`: {pair}")
                arguments[key.strip()] = value.strip()
        wanted.append((name.strip(), arguments))
    return wanted


def read_tool_calls(message):
    """Normalise the emitted calls to (name, arguments dict).

    A call whose arguments do not parse as JSON keeps its name and an empty
    dict, so the grader can separate `chose the right tool and malformed its
    arguments` from `chose the wrong tool`.
    """
    calls = []
    for call in message.get("tool_calls") or ():
        function = call.get("function") or {}
        raw = function.get("arguments")
        if isinstance(raw, dict):
            arguments, parsed = raw, True
        else:
            try:
                arguments = json.loads(raw or "{}")
                parsed = isinstance(arguments, dict)
                if not parsed:
                    arguments = {}
            except (ValueError, TypeError):
                arguments, parsed = {}, False
        calls.append({"name": function.get("name") or "",
                      "arguments": arguments, "arguments_parsed": parsed})
    return calls


def argument_matches(actual, expected):
    """Compare one emitted argument against its expectation.

    Numerically where both sides are numbers, because a schema declaring
    `{"type": "number"}` lets a model emit 47, 47.0, or "47" for the same value
    and a string comparison would score two of those three wrong.
    """
    if actual is None:
        return False
    try:
        return float(actual) == float(expected)
    except (TypeError, ValueError):
        return str(actual).strip().lower() == expected.strip().lower()


def describe_tool_calls(row, calls):
    """Report the stages of a tool call apart, because one pass rate merges
    `chose no tool`, `chose the wrong tool`, and `chose the right tool with the
    wrong city` into a single number that names none of them."""
    if row["grader"] not in ("tool_call", "no_tool_call"):
        return None
    emitted = [call["name"] for call in calls]
    detail = {
        "emitted": emitted,
        "called_a_tool": bool(calls),
        "arguments_parsed": all(call["arguments_parsed"] for call in calls),
    }
    if row["grader"] == "no_tool_call":
        detail["names_match"] = not calls
        detail["arguments_match"] = not calls
        return detail
    wanted = parse_tool_expectation(row["expectation"])
    detail["names_match"] = sorted(emitted) == sorted(name for name, _ in wanted)
    arguments_match = detail["names_match"]
    for name, expected_arguments in wanted:
        call = next((entry for entry in calls if entry["name"] == name), None)
        if call is None:
            arguments_match = False
            continue
        for key, value in expected_arguments.items():
            if not argument_matches(call["arguments"].get(key), value):
                arguments_match = False
    detail["arguments_match"] = arguments_match
    return detail


def grade(row, reply, truncated=False, tool_calls=()):
    """Return (passed, reason). A grader reports why it refused, because a
    category-level pass rate without reasons hides a formatting failure inside
    a correctness figure.

    Truncation refuses the `nonempty` grader alone. That grader asserts the
    model reached an answer and stopped, and a reply cut at the token budget was
    stopped rather than stopping, which is the termination failure the row
    exists to catch. Every other grader asserts a property of content, and
    content that is present is present wherever the reply ended: ctx-03 was
    truncated and failed on its own numeric terms in the same arm. The
    completion claim stays separate in `truncated` and `correct_on_completed`.
    """
    kind, expectation = row["grader"], row["expectation"]
    body = reply.strip()
    # A tool row is answered by the emitted call rather than by prose, and a
    # model that calls a tool correctly and says nothing has answered it.
    if kind == "tool_call":
        detail = describe_tool_calls(row, tool_calls)
        if not detail["called_a_tool"]:
            return False, "no tool call emitted"
        if not detail["arguments_parsed"]:
            return False, "tool arguments are not a JSON object"
        if not detail["names_match"]:
            return False, ("called " + "|".join(detail["emitted"] or ["nothing"])
                           + f", want {expectation}")
        if not detail["arguments_match"]:
            return False, f"arguments disagree with {expectation}"
        return True, "tool and arguments match"
    if kind == "no_tool_call":
        if tool_calls:
            return False, ("called " + "|".join(
                call["name"] for call in tool_calls) + " where none is needed")
        if not body:
            return False, "empty reply"
        wanted = [part.lower() for part in expectation.split("|")]
        present = [part for part in wanted if part in body.lower()]
        return bool(present), ("answered without a tool call, matched "
                               + present[0] if present
                               else f"none of {'|'.join(wanted)}")
    if not body:
        return False, "empty reply"
    if kind == "nonempty":
        if truncated:
            return False, "reply cut at the token budget"
        return True, "answered"
    if kind == "numeric":
        found = last_number(body)
        if found is None:
            return False, "no number in reply"
        want = float(expectation)
        tolerance = max(abs(want) * 1e-6, 1e-9)
        return abs(found - want) <= tolerance, f"found {found}, want {want}"
    if kind in ("contains_all", "contains_any"):
        wanted = [part.lower() for part in expectation.split("|")]
        present = [part for part in wanted if part in body.lower()]
        if kind == "contains_all":
            missing = [part for part in wanted if part not in present]
            return not missing, ("all present" if not missing
                                 else f"missing {'|'.join(missing)}")
        return bool(present), ("matched " + present[0] if present
                               else f"none of {'|'.join(wanted)}")
    if kind == "json_keys":
        try:
            document = json.loads(
                body, parse_constant=reject_nonfinite_json_constant)
        except (ValueError, RecursionError) as error:
            return False, f"not JSON: {error}"
        if not isinstance(document, dict):
            return False, "JSON is not an object"
        missing = [key for key in expectation.split("|") if key not in document]
        return not missing, ("keys present" if not missing
                             else f"missing keys {'|'.join(missing)}")
    if kind == "regex":
        return (bool(re.search(expectation, body, re.I | re.M)),
                "pattern matched" if re.search(expectation, body, re.I | re.M)
                else "pattern did not match")
    return False, f"unknown grader {kind}"


NEEDLE_SEPARATOR = " ||| "


def pad_prompt(prompt, depth_characters):
    """Bury the fact inside the filler and leave the question at the end.

    A long_context row states its fact before ` ||| ` and its question after.
    Filler goes on both sides of the fact, so the model reads the fact, then a
    long stretch of irrelevant text, then the question. Placing the filler
    before an intact fact-and-question pair measures answering after a long
    prefix, which every candidate passes and which is not retrieval.
    """
    fact, separator, question = prompt.partition(NEEDLE_SEPARATOR)
    if not separator:
        fact, question = "", prompt
    if depth_characters <= 0:
        return (fact + " " + question).strip()
    half = max(depth_characters // 2, len(FILLER_SENTENCE))
    repeats = half // len(FILLER_SENTENCE) + 1
    filler = FILLER_SENTENCE * repeats
    return (filler + fact.strip() + " " + filler + question.strip()).strip()


# The drawn fixtures are PNG and the photographic one is the JPEG its upstream
# publishes. Re-encoding that JPEG to PNG would put a decoder this repository
# chose between the camera and the projector, which is the thing the
# photographic row exists to leave out.
IMAGE_MEDIA_TYPES = {".png": "image/png", ".jpg": "image/jpeg"}


def resolve_fixture(directory, name):
    matches = []
    for extension, media_type in IMAGE_MEDIA_TYPES.items():
        path = os.path.join(directory, name + extension)
        if os.path.isfile(path):
            matches.append((path, media_type))
    if len(matches) == 1:
        return matches[0]
    fixture_stem = os.path.join(directory, name)
    if not matches:
        raise SystemExit(
            f"fixture is absent: {fixture_stem}"
            f"{{{','.join(IMAGE_MEDIA_TYPES)}}}")
    raise SystemExit(
        f"fixture is ambiguous: {fixture_stem} matches "
        + ", ".join(path for path, _media_type in matches))


def load_image_part(directory, name):
    """One fixture as a data URI content part.

    The image travels in the request rather than by path, because the server
    reads it in a child process whose working directory and file access this
    harness does not control, and a path that resolves here and not there fails
    as a wrong answer rather than as a missing file.
    """
    path, media_type = resolve_fixture(directory, name)
    with open(path, "rb") as handle:
        encoded = base64.b64encode(handle.read()).decode()
    return {"type": "image_url",
            "image_url": {"url": f"data:{media_type};base64," + encoded}}


def build_request_content(prompt, image_parts=(), preserve_multipart=False):
    content = prompt
    if image_parts or preserve_multipart:
        # The text part leads so the question is read before the pixels, which
        # is the order the text rows already establish. An image-withheld
        # control retains this multipart text shape so image presence is the
        # only changed request dimension.
        content = [{"type": "text", "text": prompt}, *image_parts]
    return content


def request(endpoint, api_key, model, prompt, max_tokens, thinking, timeout,
            image_parts=(), tools=None, preserve_multipart=False):
    content = build_request_content(
        prompt, image_parts, preserve_multipart=preserve_multipart)
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": content}],
        "max_tokens": max_tokens,
        "temperature": 0,
        "top_k": 1,
        "seed": 1,
        "chat_template_kwargs": {"enable_thinking": thinking},
    }
    if tools:
        payload["tools"] = tools
    body = json.dumps(payload).encode()
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    call = urllib.request.Request(
        f"{endpoint}/v1/chat/completions", data=body, headers=headers)
    started = time.monotonic()
    with urllib.request.urlopen(call, timeout=timeout) as response:
        document = json.load(response)
    document["_wall_seconds"] = time.monotonic() - started
    return document


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("endpoint")
    parser.add_argument("output_json")
    parser.add_argument("--suite", default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "quality-suite.tsv"))
    parser.add_argument("--categories", default="",
                        help="comma-separated subset; empty runs every row")
    parser.add_argument("--max-tokens", type=int, default=1024)
    # Router mode routes on this name and answers 400 for one it does not hold,
    # so the served id is the name a preset section carries. A single-model
    # server accepts any name and answers with its own alias, which is why the
    # served id is recorded per row rather than assumed from this argument.
    parser.add_argument("--model", default="qwen-apu",
                        help="model id sent in the request body")
    parser.add_argument("--thinking", default="on", choices=("on", "off"))
    parser.add_argument(
        "--long-context-characters", type=int,
        help="required positive filler depth when long_context rows are selected")
    parser.add_argument("--timeout", type=float, default=1800)
    parser.add_argument("--images", default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "quality-images"),
        help="directory holding the fixtures an image row names")
    parser.add_argument("--tools", default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "quality-tools.json"),
        help="tool sets a tool row offers")
    # The control arm for the vision category. A vision row that a model answers
    # with the image withheld was answered from the prompt, its world knowledge,
    # or the shape of the question, and the row measures none of those. Running
    # it withheld is what separates the three.
    parser.add_argument("--omit-images", action="store_true",
                        help="send image rows without their image")
    arguments = parser.parse_args(argv[1:])

    rows = load_suite(arguments.suite)
    if arguments.categories:
        wanted = set(arguments.categories.split(","))
        rows = [row for row in rows if row["category"] in wanted]
    if not rows:
        raise SystemExit("no suite rows selected")
    if any(row["category"] == "long_context" for row in rows):
        if (arguments.long_context_characters is None
                or arguments.long_context_characters <= 0):
            parser.error(
                "--long-context-characters must be positive when long_context "
                "rows are selected")

    # Every attachment resolves before the first request. A fixture absent from
    # the appliance would otherwise surface as a wrong answer partway through an
    # arm that has already spent device time.
    attachments = {}
    tool_sets = {}
    for row in rows:
        kind, names = parse_attachment(row.get("attachment"))
        attachments[row["id"]] = (kind, names)
        if kind == "tools":
            tool_sets[names[0]] = None
    if tool_sets:
        with open(arguments.tools) as handle:
            declared = json.load(handle)
        for name in tool_sets:
            if name not in declared:
                raise SystemExit(f"tool set is undeclared: {name}")
            tool_sets[name] = declared[name]
    image_parts = {}
    for kind, names in attachments.values():
        if kind != "image":
            continue
        for name in names:
            if name not in image_parts:
                image_parts[name] = load_image_part(arguments.images, name)

    api_key = os.environ.get("QWEN_API_KEY", "")
    thinking = arguments.thinking == "on"
    records = []
    for index, row in enumerate(rows):
        prompt = row["prompt"]
        if row["category"] == "long_context":
            prompt = pad_prompt(prompt, arguments.long_context_characters)
        kind, names = attachments[row["id"]]
        row_images = ([image_parts[name] for name in names]
                      if kind == "image" and not arguments.omit_images else [])
        row_tools = tool_sets[names[0]] if kind == "tools" else None
        try:
            document = request(arguments.endpoint, api_key, arguments.model,
                               prompt, arguments.max_tokens, thinking,
                               arguments.timeout, image_parts=row_images,
                               tools=row_tools,
                               preserve_multipart=kind == "image")
            error = None
        except (urllib.error.URLError, OSError, http.client.HTTPException,
                json.JSONDecodeError) as failure:
            document, error = {}, str(failure)

        choice = (document.get("choices") or [{}])[0]
        message = choice.get("message") or {}
        content = message.get("content") or ""
        reasoning = message.get("reasoning_content") or ""
        timings = document.get("timings") or {}
        # A reply cut off at the token budget is a completion failure rather
        # than a wrong answer, and the two are reported apart.
        truncated = choice.get("finish_reason") == "length"
        tool_calls = read_tool_calls(message)
        served_model = document.get("model")
        attribution_error = None
        if error is None:
            if not served_model:
                attribution_error = "response omitted the served model id"
            elif served_model != arguments.model:
                attribution_error = (
                    f"response model {served_model!r} differs from requested "
                    f"model {arguments.model!r}")
        if error:
            passed, reason = False, error
        elif attribution_error:
            passed, reason = False, attribution_error
        else:
            passed, reason = grade(row, content, truncated, tool_calls)

        records.append({
            "id": row["id"],
            "requested_model": arguments.model,
            "served_model": served_model,
            "category": row["category"],
            "grader": row["grader"],
            "expectation": row["expectation"],
            "attachment": row.get("attachment", "-"),
            "images_sent": len(row_images),
            "tool_calls": tool_calls,
            # The stages of a tool row are reported apart, because a single pass
            # rate merges choosing no tool, choosing the wrong one, and choosing
            # the right one with wrong arguments.
            "tool_detail": describe_tool_calls(row, tool_calls),
            "prompt_characters": len(prompt),
            "passed": bool(passed),
            "reason": reason,
            "truncated": truncated,
            # A tool row's answer is the call it emitted, so a valid call with
            # no prose beside it is an answer rather than an empty reply. Left
            # as a bare content test, a tool arm reported an 0.800 empty-answer
            # rate while nine of its ten rows were graded correct, and
            # correct_on_completed was then computed over the two rows that
            # happened to carry prose.
            "empty_answer": not content.strip() and not tool_calls,
            "error": error,
            "attribution_error": attribution_error,
            "content": content,
            # The API exposes text for the reasoning span and one generated-token
            # count for the whole response. Word count stays explicitly a word
            # count instead of posing as tokenizer output.
            "reasoning_words": len(reasoning.split()) if reasoning else 0,
            "generated_tokens": timings.get("predicted_n"),
            "prompt_tokens": timings.get("prompt_n"),
            "decode_tok_per_second": timings.get("predicted_per_second"),
            "wall_seconds": document.get("_wall_seconds"),
        })
        print(f"row={row['id']} category={row['category']} "
              f"served={served_model} "
              f"passed={bool(passed)} truncated={truncated} reason={reason}",
              flush=True)

    by_category = {}
    for record in records:
        bucket = by_category.setdefault(
            record["category"],
            {"attempted": 0, "passed": 0, "truncated": 0, "empty": 0})
        bucket["attempted"] += 1
        bucket["passed"] += int(record["passed"])
        bucket["truncated"] += int(record["truncated"])
        bucket["empty"] += int(record["empty_answer"])

    completed = [
        record for record in records
        if (not record["error"] and not record["attribution_error"]
            and not record["empty_answer"]
            and not record["truncated"])
    ]
    # The served id comes from the response rather than from the request, so a
    # router that answered from a different preset than the one named shows up
    # here as a second entry instead of being hidden by the loop variable.
    served_models = sorted({
        record["served_model"] for record in records
        if record["served_model"]})
    # Tool rows report their stages in the summary too. A category pass rate of
    # 6/10 says nothing about whether the misses chose no tool or the wrong one.
    tool_records = [record for record in records if record["tool_detail"]]
    tool_stages = {
        "rows": len(tool_records),
        "called_a_tool": sum(r["tool_detail"]["called_a_tool"] for r in tool_records),
        "arguments_parsed": sum(
            r["tool_detail"]["arguments_parsed"] for r in tool_records),
        "names_match": sum(r["tool_detail"]["names_match"] for r in tool_records),
        "arguments_match": sum(
            r["tool_detail"]["arguments_match"] for r in tool_records),
    } if tool_records else None
    summary = {
        "rows": len(records),
        "requested_model": arguments.model,
        "tool_stages": tool_stages,
        "images_omitted": bool(arguments.omit_images),
        "images_sent": sum(record["images_sent"] for record in records),
        "served_models": served_models,
        "attribution_failures": sum(
            bool(record["attribution_error"]) for record in records),
        "passed": sum(r["passed"] for r in records),
        "completion_rate": len(completed) / len(records),
        "empty_answer_rate": sum(r["empty_answer"] for r in records) / len(records),
        "truncated_rate": sum(r["truncated"] for r in records) / len(records),
        # Correctness on completed rows separates a wrong answer from an answer
        # the model never produced, which a single pass rate merges.
        "correct_on_completed": (
            sum(r["passed"] for r in completed) / len(completed)
            if completed else None),
        "reasoning_words_total": sum(r["reasoning_words"] for r in records),
        "generated_tokens_total": sum(r["generated_tokens"] or 0 for r in records),
        "wall_seconds_total": sum(r["wall_seconds"] or 0 for r in records),
        "by_category": by_category,
    }

    with open(arguments.output_json, "w") as handle:
        json.dump({"summary": summary, "records": records}, handle, indent=2)

    for name in sorted(by_category):
        bucket = by_category[name]
        print(f"category={name} passed={bucket['passed']}/{bucket['attempted']} "
              f"truncated={bucket['truncated']} empty={bucket['empty']}")
    if tool_stages:
        print(f"tool_stages rows={tool_stages['rows']} "
              f"called={tool_stages['called_a_tool']} "
              f"parsed={tool_stages['arguments_parsed']} "
              f"names={tool_stages['names_match']} "
              f"arguments={tool_stages['arguments_match']}")
    transport_errors = sum(bool(record["error"]) for record in records)
    attribution_failures = summary["attribution_failures"]
    print(f"served_models={','.join(served_models) if served_models else 'none'} "
          f"requested_model={arguments.model}")
    terminal_state = (
        "completed" if transport_errors == 0 and attribution_failures == 0
        else "failed")
    print(f"quality_suite={terminal_state} passed={summary['passed']}/{summary['rows']} "
          f"completion_rate={summary['completion_rate']:.3f} "
          f"empty_answer_rate={summary['empty_answer_rate']:.3f} "
          f"transport_errors={transport_errors} "
          f"attribution_failures={attribution_failures} "
          f"wall_seconds={summary['wall_seconds_total']:.1f}")
    return 0 if transport_errors == 0 and attribution_failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
