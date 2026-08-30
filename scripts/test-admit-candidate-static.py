#!/usr/bin/env python3
"""Check the static-admission reader against a hand-built GGUF header.

The reader answers two questions the ledger records: which artifact a
fingerprint was read from, and whether the header parsed at all. Both have a
failure mode that returns a plausible answer. A selection rule that ignored its
preference order would fingerprint a projector or a Q2_K rung and report a
fingerprint either way; a truncated window would report an absent chat template
and look like a finding. These checks build a header whose every field is known
and then withhold bytes from it.
"""

import importlib.util
import pathlib
import struct
import sys
from unittest import mock

SCRIPT_DIRECTORY = pathlib.Path(__file__).resolve().parent


def load_module(name, filename):
    spec = importlib.util.spec_from_file_location(name, SCRIPT_DIRECTORY / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ADMIT = load_module("admit_candidate_static", "admit-candidate-static.py")
CENSUS = ADMIT.CENSUS

STRING = 8
UINT32 = 4


def encode_string(text):
    payload = text.encode("utf-8")
    return struct.pack("<Q", len(payload)) + payload


def build_header(chat_template, architecture="qwen35", block_count=24):
    """Build a tensorless GGUF whose metadata block is fully known."""
    entries = [
        ("general.architecture", STRING, encode_string(architecture)),
        (f"{architecture}.block_count", UINT32, struct.pack("<I", block_count)),
        (f"{architecture}.embedding_length", UINT32, struct.pack("<I", 2048)),
        ("tokenizer.chat_template", STRING, encode_string(chat_template)),
    ]
    body = b""
    for key, value_type, payload in entries:
        body += encode_string(key) + struct.pack("<I", value_type) + payload
    return (CENSUS.GGUF_MAGIC + struct.pack("<I", 3) + struct.pack("<Q", 0)
            + struct.pack("<Q", len(entries)) + body)


def check_selection():
    """The preference order decides which file a fingerprint speaks for."""
    failures = 0
    tree = [
        {"path": "mmproj-F16.gguf", "bytes": 400},
        {"path": "model-Q2_K.gguf", "bytes": 100},
        {"path": "model-Q4_K_M.gguf", "bytes": 300},
        {"path": "model-Q8_0.gguf", "bytes": 800},
        {"path": "model-00002-of-00002.gguf", "bytes": 50},
    ]
    entry, rule = ADMIT.select_artifact(tree)
    if entry["path"] != "model-Q4_K_M.gguf" or rule != "preference:q4_k_m":
        print(f"selection chose {entry['path']} by {rule}")
        failures += 1

    # A repository publishing no preferred rung falls back to the smallest
    # checkpoint, and a projector is never that checkpoint.
    entry, rule = ADMIT.select_artifact([
        {"path": "mmproj-F16.gguf", "bytes": 10},
        {"path": "model-IQ3_S.gguf", "bytes": 500},
    ])
    if entry["path"] != "model-IQ3_S.gguf" or rule != "smallest":
        print(f"fallback chose {entry['path']} by {rule}")
        failures += 1

    # A tree holding a projector alone names no checkpoint to read.
    try:
        ADMIT.select_artifact([{"path": "mmproj-F16.gguf", "bytes": 10}])
        print("a projector-only tree returned a checkpoint")
        failures += 1
    except ADMIT.AdmissionError:
        pass

    # A named file overrides the rule, and an absent one fails rather than
    # falling back to a different artifact under the caller's name.
    entry, rule = ADMIT.select_artifact(tree, "model-Q2_K.gguf")
    if entry["path"] != "model-Q2_K.gguf" or rule != "requested":
        print(f"request chose {entry['path']} by {rule}")
        failures += 1
    try:
        ADMIT.select_artifact(tree, "model-Q6_K.gguf")
        print("an absent request returned a substitute")
        failures += 1
    except ADMIT.AdmissionError:
        pass
    return failures


def check_short_read_is_not_an_absent_key():
    """A withheld tail raises rather than reporting the template absent."""
    failures = 0
    header = build_header("{{ messages }}")
    record = ADMIT.fingerprint(CENSUS.parse_header(CENSUS.GgufReader(header)))
    if record["chat_template_sha256"] == "absent":
        print("the complete header reported its own template absent")
        failures += 1
    if record["architecture_fingerprint"] != "qwen35/block_count=24/embedding_length=2048":
        print(f"fingerprint reads {record['architecture_fingerprint']}")
        failures += 1

    # Every truncation that lands inside the metadata block must raise. A
    # truncation that returned a partial dictionary would report the trailing
    # keys as absent, which is the fabricated absence these checks exist for.
    raised = 0
    truncations = range(len(CENSUS.GGUF_MAGIC) + 20, len(header), 7)
    for cut in truncations:
        try:
            CENSUS.parse_header(CENSUS.GgufReader(header[:cut]))
        except CENSUS.GgufReadError:
            raised += 1
        except Exception as error:  # noqa: BLE001 - any other class is a defect
            print(f"truncation at {cut} raised {type(error).__name__}: {error}")
            failures += 1
    if raised != len(list(truncations)):
        print(f"{raised} of {len(list(truncations))} truncations raised")
        failures += 1

    # A file whose header is absent entirely is a different failure again.
    header_without_template = build_header("")
    record = ADMIT.fingerprint(
        CENSUS.parse_header(CENSUS.GgufReader(header_without_template)))
    if record["chat_template_bytes"] != 0:
        print("an empty template reported bytes")
        failures += 1
    return failures


def check_streamed_bytes_excludes_the_prediction_block():
    """Static admission uses the census's loop and tied-embedding accounting."""
    header = {"metadata": {"general.architecture": "test"}, "num_loops": 2,
              "nextn_layers": 1, "tensors": [
        {"name": "token_embd.weight", "family": "embedding", "layer": None,
         "type_name": "F16", "bytes": 40},
        {"name": "blk.0.ffn.weight", "family": "ffn", "layer": 0,
         "type_name": "F16", "bytes": 100},
        {"name": "blk.1.ffn.weight", "family": "mtp", "layer": 1,
         "type_name": "F16", "bytes": 30},
        {"name": "output_norm.weight", "family": "norm", "layer": None,
         "type_name": "F32", "bytes": 70},
    ]}
    loaded, skipped = ADMIT.streamed_bytes(header)
    if (loaded, skipped) != (310, 30):
        print(f"streamed bytes read {loaded} loaded and {skipped} skipped")
        return 1
    return 0


def check_tree_shape_validation():
    """Malformed tree shapes fail before they can become plausible artifacts."""
    failures = 0
    malformed_trees = (
        {},
        [None],
        [{"type": "file", "path": 7, "size": 10}],
        [{"type": "file", "path": "model.gguf", "size": "10"}],
        [{"type": "file", "path": "model.gguf", "lfs": []}],
        [{"type": "file", "path": "model.gguf", "lfs": {"size": 0}}],
    )
    for tree in malformed_trees:
        with mock.patch.object(ADMIT, "fetch_json", return_value=tree):
            try:
                ADMIT.list_artifacts("owner/model", "revision")
                print(f"malformed tree was admitted: {tree!r}")
                failures += 1
            except ADMIT.AdmissionError:
                pass

    valid_tree = [
        {"type": "directory", "path": "weights"},
        {"type": "file", "path": "weights/model.gguf", "size": 10,
         "lfs": {"size": 12}},
    ]
    with mock.patch.object(ADMIT, "fetch_json", return_value=valid_tree):
        if ADMIT.list_artifacts("owner/model", "revision") != [
                {"path": "weights/model.gguf", "bytes": 12}]:
            print("a valid tree did not preserve its LFS artifact bytes")
            failures += 1
    return failures


def check_range_bound():
    """A server that ignores the range must be refused rather than buffered."""
    failures = 0
    window = 16 << 20
    cases = (
        # status, size_download, Content-Range, admitted, what the case is
        ("206", window, f"bytes 0-{window - 1}/1312164224", True,
         "a served range"),
        ("206", 4096, "bytes 0-4095/4096", True, "a file shorter than the window"),
        ("200", 4096, None, True, "a whole object smaller than the window"),
        ("200", window + 1, None, False, "a whole object over the window"),
        ("206", window, None, False, "206 without a Content-Range"),
        ("206", window, "bytes */1312164224", False, "an unsatisfied range"),
        ("206", window, f"bytes 4096-{window + 4095}/1312164224", False,
         "a range that does not start at zero"),
        ("206", window, f"bytes 0-{window}/1312164224", False,
         "a range past the window"),
        ("206", window + 1, f"bytes 0-{window - 1}/1312164224", False,
         "more bytes than the window"),
        ("416", 0, None, False, "an unsatisfiable range"),
        ("", 0, None, False, "no status at all"),
    )
    for status, size, content_range, admitted, description in cases:
        reason = ADMIT.validate_range_response(status, size, content_range, window)
        if admitted and reason is not None:
            print(f"{description} was refused: {reason}")
            failures += 1
        if not admitted and reason is None:
            print(f"{description} was admitted")
            failures += 1
    return failures


def check_split_shard_set():
    """A split set is recognised by stem, and a plain file stands alone."""
    failures = 0
    entries = [
        {"path": "model-00001-of-00003.gguf", "bytes": 10},
        {"path": "model-00002-of-00003.gguf", "bytes": 20},
        {"path": "model-00003-of-00003.gguf", "bytes": 30},
        {"path": "other-00001-of-00002.gguf", "bytes": 5},
        {"path": "model-extra-00001-of-00002.gguf", "bytes": 100},
        {"path": "model-extra-00002-of-00002.gguf", "bytes": 200},
        {"path": "model-00001-of-00030.gguf", "bytes": 300},
        {"path": "plain-Q4_K_M.gguf", "bytes": 7},
    ]
    shards = ADMIT.shard_set(entries, "model-00001-of-00003.gguf")
    if [shard["path"] for shard in shards] != [
            "model-00001-of-00003.gguf", "model-00002-of-00003.gguf",
            "model-00003-of-00003.gguf"]:
        print(f"shard set resolved to {[s['path'] for s in shards]}")
        failures += 1
    if sum(shard["bytes"] for shard in shards) != 60:
        print("shard set bytes do not sum across the set")
        failures += 1
    alone = ADMIT.shard_set(entries, "plain-Q4_K_M.gguf")
    if [entry["path"] for entry in alone] != ["plain-Q4_K_M.gguf"]:
        print(f"a plain file resolved to {[e['path'] for e in alone]}")
        failures += 1
    try:
        ADMIT.shard_set([
            {"path": "model-00001-of-00003.gguf", "bytes": 10},
            {"path": "model-00003-of-00003.gguf", "bytes": 30},
        ], "model-00001-of-00003.gguf")
        print("an incomplete split set was admitted")
        failures += 1
    except ADMIT.AdmissionError:
        pass
    return failures


def main(argv):
    if argv:
        print(f"usage: {sys.argv[0]}", file=sys.stderr)
        return 2
    failures = 0
    for name, check in (
        ("artifact_selection", check_selection),
        ("short_read", check_short_read_is_not_an_absent_key),
        ("streamed_bytes", check_streamed_bytes_excludes_the_prediction_block),
        ("tree_shape", check_tree_shape_validation),
        ("range_bound", check_range_bound),
        ("split_shard_set", check_split_shard_set),
    ):
        count = check()
        print(f"{name}={'accepted' if count == 0 else 'rejected'}")
        failures += count
    if failures:
        print(f"admit_candidate_static=rejected failures={failures}", file=sys.stderr)
        return 1
    print("admit_candidate_static=accepted")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
