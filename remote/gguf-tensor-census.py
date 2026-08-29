#!/usr/bin/env python3
"""Report what a GGUF actually contains, tensor by tensor.

A quantization label names a recipe rather than a layout. Q4_K_M assigns
several K-quant types across a model's tensors unless llama-quantize ran with
--pure, so two files carrying that label execute different kernel mixtures and
stream different byte counts. Comparing decode rates across checkpoints
requires the mixture, not the label, and file size stands in poorly for
per-token traffic because the token embedding tensor is read as a row lookup
while the file carries the whole tensor.

The reader is written against the GGUF format directly so that it runs on the
appliance with the distribution's Python alone. remote/test-gguf-tensor-census.py
cross-checks it against the pinned gguf-py.
"""

import argparse
import hashlib
import json
import re
import struct
import sys
from collections import defaultdict

GGUF_MAGIC = b"GGUF"

# Block length in elements and encoded block size in bytes for each ggml type,
# taken from GGML_QUANT_SIZES in the pinned gguf-py. A type absent here is
# reported by number so an unknown encoding stays visible instead of being
# silently sized wrong.
GGML_TYPES = {
    0: (1, 4, "F32"), 1: (1, 2, "F16"), 2: (32, 18, "Q4_0"),
    3: (32, 20, "Q4_1"), 6: (32, 22, "Q5_0"), 7: (32, 24, "Q5_1"),
    8: (32, 34, "Q8_0"), 9: (32, 40, "Q8_1"), 10: (256, 84, "Q2_K"),
    11: (256, 110, "Q3_K"), 12: (256, 144, "Q4_K"), 13: (256, 176, "Q5_K"),
    14: (256, 210, "Q6_K"), 15: (256, 292, "Q8_K"), 16: (256, 66, "IQ2_XXS"),
    17: (256, 74, "IQ2_XS"), 18: (256, 98, "IQ3_XXS"), 19: (256, 50, "IQ1_S"),
    20: (32, 18, "IQ4_NL"), 21: (256, 110, "IQ3_S"), 22: (256, 82, "IQ2_S"),
    23: (256, 136, "IQ4_XS"), 24: (1, 1, "I8"), 25: (1, 2, "I16"),
    26: (1, 4, "I32"), 27: (1, 8, "I64"), 28: (1, 8, "F64"),
    29: (256, 56, "IQ1_M"), 30: (1, 2, "BF16"), 34: (256, 54, "TQ1_0"),
    35: (256, 66, "TQ2_0"), 39: (32, 17, "MXFP4"), 40: (64, 36, "NVFP4"),
    41: (128, 18, "Q1_0"), 42: (64, 18, "Q2_0"),
}

# GGUF metadata value type tags, in the order the format defines them.
(UINT8, INT8, UINT16, INT16, UINT32, INT32, FLOAT32, BOOL, STRING, ARRAY,
 UINT64, INT64, FLOAT64) = range(13)

SCALAR_FORMATS = {
    UINT8: "<B", INT8: "<b", UINT16: "<H", INT16: "<h", UINT32: "<I",
    INT32: "<i", FLOAT32: "<f", BOOL: "<?", UINT64: "<Q", INT64: "<q",
    FLOAT64: "<d",
}

# Operation families, matched against the tensor name in order. The first
# pattern that matches wins, so the specific embedding and output names precede
# the suffix patterns that would also match them.
OPERATION_FAMILIES = (
    (re.compile(r"^token_embd"), "embedding"),
    (re.compile(r"^output\.weight$"), "output"),
    (re.compile(r"^(output|token_embd)_norm"), "norm"),
    (re.compile(r"\.ffn_(gate|up|down)_(exps|shexp)"), "moe_ffn"),
    (re.compile(r"\.ffn_gate_inp"), "moe_router"),
    (re.compile(r"\.ffn_(gate|up|down)"), "ffn"),
    (re.compile(r"\.attn_(q|k|v|output|qkv|gate)\b"), "attention"),
    (re.compile(r"\.(ssm|linear_attn)_"), "gated_deltanet"),
    (re.compile(r"\.(ssm|linear_attn)\."), "gated_deltanet"),
    (re.compile(r"_norm"), "norm"),
    (re.compile(r"\.bias$"), "bias"),
)

LAYER_PATTERN = re.compile(r"^blk\.(\d+)\.")

# Qwen3.5 checkpoints append multi-token-prediction blocks after the transformer
# stack and declare how many through <arch>.nextn_predict_layers. Those blocks
# hold a full layer's attention and feed-forward tensors alongside the nextn
# projections, so a name-based rule counts them as ordinary layers.
# llama_hparams::n_layer_effective returns n_layer_all - n_layer_nextn, so decode
# never runs them: they occupy memory and leave per-token traffic untouched.
NEXTN_KEY_SUFFIX = ".nextn_predict_layers"
BLOCK_COUNT_KEY_SUFFIX = ".block_count"

# A looped transformer declares <arch>.num_loops and runs its physical layers
# once per loop, sharing the weights across iterations: src/models/nanbeige.cpp
# sets hparams.n_layer_all = n_layer_phys * n_loops and gives each slot its own
# KV index. Parameter count falls and per-token weight traffic does not, because
# a working set of gigabytes cannot stay in a 4 MB L3 between iterations. The
# loop count therefore multiplies the layer bytes and leaves the embedding and
# output projections read once.
NUM_LOOPS_KEY_SUFFIX = ".num_loops"

# Metadata keys that record how the file was produced. Absence is itself a
# result: a file without them cannot be reproduced from the repository.
PROVENANCE_KEYS = (
    "general.source.url", "general.source.huggingface.repository",
    "general.source.repo_url", "general.base_model.0.repo_url",
    "general.quantization_version", "general.file_type",
    "quantize.imatrix.file", "quantize.imatrix.dataset",
    "quantize.imatrix.entries_count", "quantize.imatrix.chunks_count",
    "general.version", "general.basename", "general.finetune",
    "general.size_label", "general.license",
)


class GgufReadError(Exception):
    pass


class GgufReader:
    """Sequential reader over the GGUF header, metadata, and tensor index."""

    def __init__(self, data):
        self.data = data
        self.offset = 0

    def take(self, count):
        end = self.offset + count
        if end > len(self.data):
            raise GgufReadError(
                f"read of {count} bytes at {self.offset} runs past the file end"
            )
        chunk = self.data[self.offset:end]
        self.offset = end
        return chunk

    def scalar(self, value_type):
        fmt = SCALAR_FORMATS[value_type]
        return struct.unpack(fmt, self.take(struct.calcsize(fmt)))[0]

    def string(self):
        length = self.scalar(UINT64)
        return self.take(length).decode("utf-8", errors="replace")

    def value(self, value_type):
        if value_type == STRING:
            return self.string()
        if value_type == ARRAY:
            element_type = self.scalar(UINT32)
            count = self.scalar(UINT64)
            return [self.value(element_type) for _ in range(count)]
        if value_type in SCALAR_FORMATS:
            return self.scalar(value_type)
        raise GgufReadError(f"metadata value type {value_type} is undefined")


def classify_operation(tensor_name):
    for pattern, family in OPERATION_FAMILIES:
        if pattern.search(tensor_name):
            return family
    return "other"


def type_name(type_number):
    entry = GGML_TYPES.get(type_number)
    return entry[2] if entry else f"TYPE_{type_number}"


def tensor_bytes(type_number, element_count):
    entry = GGML_TYPES.get(type_number)
    if entry is None:
        raise GgufReadError(
            f"ggml type {type_number} has no known block size, so its byte "
            f"count is unresolvable"
        )
    block_elements, block_bytes, _ = entry
    if element_count % block_elements:
        raise GgufReadError(
            f"element count {element_count} is not a multiple of block length "
            f"{block_elements}"
        )
    return element_count // block_elements * block_bytes


def read_gguf(path, hash_file=True):
    with open(path, "rb") as handle:
        head = handle.read(4 * 1024 * 1024)
        if head[:4] != GGUF_MAGIC:
            raise GgufReadError(f"{path} does not begin with the GGUF magic")
        # The index length is unknown before it is parsed, so grow the buffer
        # until the parse completes rather than mapping the whole checkpoint.
        while True:
            reader = GgufReader(head)
            try:
                result = parse_header(reader)
                break
            except GgufReadError:
                if len(head) >= 512 * 1024 * 1024:
                    raise
                handle.seek(len(head))
                more = handle.read(len(head))
                if not more:
                    raise
                head = head + more
        file_bytes = handle.seek(0, 2)

    result["path"] = path
    result["file_bytes"] = file_bytes
    result["index_bytes"] = reader.offset
    result["sha256"] = sha256_of(path) if hash_file else None
    return result


def parse_header(reader):
    reader.take(4)
    version = reader.scalar(UINT32)
    tensor_count = reader.scalar(UINT64)
    metadata_count = reader.scalar(UINT64)

    metadata = {}
    for _ in range(metadata_count):
        key = reader.string()
        metadata[key] = reader.value(reader.scalar(UINT32))

    tensors = []
    for _ in range(tensor_count):
        name = reader.string()
        dimension_count = reader.scalar(UINT32)
        dimensions = [reader.scalar(UINT64) for _ in range(dimension_count)]
        tensor_type = reader.scalar(UINT32)
        data_offset = reader.scalar(UINT64)
        element_count = 1
        for dimension in dimensions:
            element_count *= dimension
        layer_match = LAYER_PATTERN.match(name)
        tensors.append({
            "name": name,
            "dimensions": dimensions,
            "type": tensor_type,
            "type_name": type_name(tensor_type),
            "elements": element_count,
            "bytes": tensor_bytes(tensor_type, element_count),
            "offset": data_offset,
            "layer": int(layer_match.group(1)) if layer_match else None,
            "family": classify_operation(name),
        })

    architecture = metadata.get("general.architecture", "")
    num_loops = int(metadata.get(architecture + NUM_LOOPS_KEY_SUFFIX, 1) or 1)
    nextn_layers = int(metadata.get(architecture + NEXTN_KEY_SUFFIX, 0) or 0)
    block_count = int(metadata.get(architecture + BLOCK_COUNT_KEY_SUFFIX, 0) or 0)
    if nextn_layers > 0 and block_count > 0:
        first_nextn_layer = block_count - nextn_layers
        for tensor in tensors:
            if tensor["layer"] is not None and tensor["layer"] >= first_nextn_layer:
                tensor["family"] = "mtp"

    return {"version": version, "metadata": metadata, "tensors": tensors,
            "nextn_layers": nextn_layers, "block_count": block_count,
            "num_loops": num_loops}


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def summarize(census):
    tensors = census["tensors"]
    metadata = census["metadata"]
    architecture = metadata.get("general.architecture", "unknown")

    by_type = defaultdict(int)
    by_family = defaultdict(int)
    by_layer = defaultdict(int)
    by_family_type = defaultdict(int)
    for tensor in tensors:
        by_type[tensor["type_name"]] += tensor["bytes"]
        by_family[tensor["family"]] += tensor["bytes"]
        by_layer[tensor["layer"]] += tensor["bytes"]
        by_family_type[(tensor["family"], tensor["type_name"])] += tensor["bytes"]

    names = {tensor["name"] for tensor in tensors}
    has_embedding = any(name.startswith("token_embd") for name in names)
    has_output = "output.weight" in names
    embedding_bytes = by_family.get("embedding", 0)
    output_bytes = by_family.get("output", 0)

    # Decode reads the embedding table as a single row and streams every other
    # weight, so per-token traffic is the file minus the embedding tensor. A
    # tied checkpoint carries one tensor that serves both the lookup and the
    # output projection, in which case the projection reads it in full and only
    # the lookup share is excluded; the exclusion is the same tensor either way
    # because the output matvec is already counted through it.
    num_loops = census.get("num_loops", 1)
    # Layer tensors are re-read once per loop; the logit projection and the
    # embedding lookup sit outside the loop and are read once.
    looped_bytes = sum(
        tensor["bytes"] for tensor in tensors
        if tensor["layer"] is not None and tensor["family"] not in ("embedding", "mtp")
    )
    unlooped_bytes = sum(
        tensor["bytes"] for tensor in tensors
        if tensor["layer"] is None and tensor["family"] not in ("embedding", "mtp")
    )
    streamed_bytes = looped_bytes * num_loops + unlooped_bytes
    if not has_output:
        # Tied: the output projection streams the embedding tensor, so add it
        # back once.
        streamed_bytes += embedding_bytes

    return {
        "architecture": architecture,
        "tensor_count": len(tensors),
        "by_type": dict(by_type),
        "by_family": dict(by_family),
        "by_layer": dict(by_layer),
        "by_family_type": {f"{f}/{t}": b for (f, t), b in by_family_type.items()},
        "embeddings_tied": (not has_output) if has_embedding else None,
        "embedding_bytes": embedding_bytes,
        "output_bytes": output_bytes,
        "streamed_bytes": streamed_bytes,
        "layer_count": len([k for k in by_layer if k is not None]),
        "nextn_layers": census.get("nextn_layers", 0),
        "mtp_bytes": by_family.get("mtp", 0),
        "num_loops": num_loops,
        "looped_bytes": looped_bytes,
    }


def architecture_dimensions(metadata, architecture):
    prefix = f"{architecture}."
    return {
        key[len(prefix):]: value
        for key, value in metadata.items()
        if key.startswith(prefix) and not isinstance(value, list)
    }


def metadata_value_sha256(value):
    """Hash arrays through a typed, ordered stream, including non-finite floats."""
    digest = hashlib.sha256()

    def append_value(type_tag, payload=b""):
        digest.update(type_tag)
        digest.update(str(len(payload)).encode("ascii"))
        digest.update(b":")
        digest.update(payload)

    def visit(item):
        if item is None:
            append_value(b"N")
        elif isinstance(item, bool):
            append_value(b"B", b"1" if item else b"0")
        elif isinstance(item, int):
            append_value(b"I", str(item).encode("ascii"))
        elif isinstance(item, float):
            append_value(b"F", item.hex().encode("ascii"))
        elif isinstance(item, str):
            append_value(b"S", item.encode("utf-8"))
        elif isinstance(item, (list, tuple)):
            append_value(b"L", str(len(item)).encode("ascii"))
            for member in item:
                visit(member)
        else:
            raise TypeError(
                f"unsupported tokenizer metadata value: {type(item).__name__}")

    visit(value)
    return digest.hexdigest()


def tokenizer_identity(metadata):
    """Name the decoder half of a checkpoint that the tensor census cannot see.

    A requantization rewrites tensors and copies metadata, so two files that
    agree tensor for tensor still answer differently when one carries a
    different chat template, a different pre-tokenizer, or different special
    token ids. The template is hashed rather than printed because it runs to
    kilobytes of Jinja and only its identity is being compared.
    """
    identity = {}
    template = metadata.get("tokenizer.chat_template")
    if isinstance(template, str):
        identity["chat_template_sha256"] = hashlib.sha256(
            template.encode("utf-8")).hexdigest()
        identity["chat_template_bytes"] = len(template.encode("utf-8"))
    for key in ("tokenizer.ggml.model", "tokenizer.ggml.pre",
                "tokenizer.ggml.bos_token_id", "tokenizer.ggml.eos_token_id",
                "tokenizer.ggml.eot_token_id", "tokenizer.ggml.padding_token_id",
                "tokenizer.ggml.add_bos_token", "tokenizer.ggml.add_eos_token"):
        if key in metadata:
            identity[key[len("tokenizer.ggml."):]] = metadata[key]
    tokens = metadata.get("tokenizer.ggml.tokens")
    if isinstance(tokens, list):
        identity["vocabulary_size"] = len(tokens)
        identity["tokens_sha256"] = metadata_value_sha256(tokens)
    for metadata_key, identity_name in (
        ("tokenizer.ggml.scores", "scores"),
        ("tokenizer.ggml.token_type", "token_types"),
        ("tokenizer.ggml.merges", "merges"),
    ):
        values = metadata.get(metadata_key)
        if isinstance(values, list):
            identity[f"{identity_name}_count"] = len(values)
            identity[f"{identity_name}_sha256"] = metadata_value_sha256(values)
    return identity


def report(census, summary):
    metadata = census["metadata"]
    architecture = summary["architecture"]
    lines = []
    add = lines.append

    add(f"path\t{census['path']}")
    add(f"sha256\t{census['sha256'] or 'not computed'}")
    add(f"file_bytes\t{census['file_bytes']}")
    add(f"index_bytes\t{census['index_bytes']}")
    add(f"gguf_version\t{census['version']}")
    add(f"architecture\t{architecture}")
    add(f"tensor_count\t{summary['tensor_count']}")
    add(f"layer_count\t{summary['layer_count']}")
    tied = summary["embeddings_tied"]
    add(f"embeddings_tied\t{'absent' if tied is None else str(tied).lower()}")
    add(f"embedding_bytes\t{summary['embedding_bytes']}")
    add(f"output_bytes\t{summary['output_bytes']}")
    add(f"num_loops\t{summary['num_loops']}")
    add(f"looped_layer_bytes\t{summary['looped_bytes']}")
    add(f"nextn_layers\t{summary['nextn_layers']}")
    add(f"mtp_bytes\t{summary['mtp_bytes']}")
    add(f"streamed_bytes_per_token\t{summary['streamed_bytes']}")

    add("")
    add("# architecture dimensions")
    for key, value in sorted(architecture_dimensions(metadata, architecture).items()):
        add(f"{key}\t{value}")

    add("")
    add("# provenance")
    for key in PROVENANCE_KEYS:
        if key in metadata:
            add(f"{key}\t{metadata[key]}")
    missing = [key for key in PROVENANCE_KEYS if key not in metadata]
    if missing:
        add(f"absent\t{' '.join(missing)}")

    add("")
    add("# tokenizer identity")
    identity = tokenizer_identity(metadata)
    if identity:
        for key, value in identity.items():
            add(f"{key}\t{value}")
    else:
        add("absent\ttokenizer metadata")

    add("")
    add("# bytes by ggml type")
    for name, value in sorted(summary["by_type"].items(), key=lambda i: -i[1]):
        add(f"{name}\t{value}\t{100 * value / census['file_bytes']:.2f}%")

    add("")
    add("# bytes by operation family")
    for name, value in sorted(summary["by_family"].items(), key=lambda i: -i[1]):
        add(f"{name}\t{value}\t{100 * value / census['file_bytes']:.2f}%")

    add("")
    add("# bytes by operation family and ggml type")
    for name, value in sorted(summary["by_family_type"].items(), key=lambda i: -i[1]):
        add(f"{name}\t{value}")

    add("")
    add("# bytes by layer")
    for layer in sorted(summary["by_layer"], key=lambda k: (k is None, k)):
        label = "unlayered" if layer is None else str(layer)
        add(f"{label}\t{summary['by_layer'][layer]}")

    return "\n".join(lines)


def main(argv):
    parser = argparse.ArgumentParser(
        description="Census the tensors, types, and provenance of a GGUF file."
    )
    parser.add_argument("model_paths", nargs="+", metavar="MODEL")
    parser.add_argument("--skip-hash", action="store_true",
                        help="omit the file SHA-256, which reads the whole file")
    parser.add_argument("--json", action="store_true",
                        help="emit the census as JSON rather than a text report")
    parser.add_argument("--tensors", action="store_true",
                        help="append one row per tensor")
    arguments = parser.parse_args(argv[1:])

    documents = []
    for model_path in arguments.model_paths:
        census = read_gguf(model_path, hash_file=not arguments.skip_hash)
        summary = summarize(census)
        if arguments.json:
            documents.append({
                "path": census["path"],
                "sha256": census["sha256"],
                "file_bytes": census["file_bytes"],
                "gguf_version": census["version"],
                "summary": summary,
                "tokenizer_identity": tokenizer_identity(census["metadata"]),
                "tensors": census["tensors"] if arguments.tensors else None,
            })
            continue
        print(report(census, summary))
        if arguments.tensors:
            print("")
            print("# tensors")
            for tensor in census["tensors"]:
                dimensions = ",".join(str(d) for d in tensor["dimensions"])
                print(f"{tensor['name']}\t{tensor['type_name']}\t{dimensions}"
                      f"\t{tensor['bytes']}\t{tensor['family']}")
        if model_path != arguments.model_paths[-1]:
            print("")

    if arguments.json:
        json.dump(documents, sys.stdout, indent=2, default=str)
        print("")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
