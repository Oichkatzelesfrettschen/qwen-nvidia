#!/usr/bin/env python3
"""Cross-check remote/gguf-tensor-census.py against the pinned gguf-py.

The census reads the GGUF format directly so that it runs on the appliance with
the distribution's Python alone. That independence is what needs checking: this
builds a fixture carrying several quantization types across several operation
families, reads it with both parsers, and requires every tensor's type, shape,
and byte count to agree. It then repeats the comparison against whatever real
GGUF files are named on the command line.

gguf-py is located through GGUF_PY_PATH or the usual llama.cpp source trees.
Exits 2 when it cannot be found, since a check that silently skips is a check
that never fails.
"""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT_DIRECTORY = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIRECTORY))

def load_census_module():
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "gguf_tensor_census", SCRIPT_DIRECTORY / "gguf-tensor-census.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def locate_gguf_py():
    candidates = []
    if os.environ.get("GGUF_PY_PATH"):
        candidates.append(Path(os.environ["GGUF_PY_PATH"]))
    home = Path.home()
    candidates += [
        home / "src/llama.cpp-qwen-apu/gguf-py",
        home / "worktrees/llama-qwen-vulkan-pacer/gguf-py",
        home / "src/llama.cpp/gguf-py",
    ]
    for candidate in candidates:
        if (candidate / "gguf" / "constants.py").is_file():
            return candidate
    return None


def build_fixture(gguf, path):
    """Write a GGUF carrying mixed types across embedding, attention, Gated
    DeltaNet, feed-forward, norm, and output tensors, with the output tensor
    present so the untied branch is exercised."""
    import numpy as np

    writer = gguf.GGUFWriter(path, "qwen3next")
    writer.add_uint32("qwen3next.block_count", 2)
    writer.add_uint32("qwen3next.embedding_length", 256)
    writer.add_uint32("qwen3next.feed_forward_length", 512)
    writer.add_string("general.name", "census fixture")

    def quantized(name, rows, columns, quant_type):
        # gguf-py takes raw_shape as the encoded byte shape and derives the
        # logical shape from the type's block size, so a row is its block count
        # times the block's encoded length.
        block_elements, block_bytes = gguf.GGML_QUANT_SIZES[quant_type]
        assert columns % block_elements == 0, (name, columns, block_elements)
        row_bytes = columns // block_elements * block_bytes
        payload = np.frombuffer(
            bytes((index * 37 + 11) % 256 for index in range(rows * row_bytes)),
            dtype=np.uint8).reshape(rows, row_bytes)
        writer.add_tensor(name, payload, raw_shape=(rows, row_bytes),
                          raw_dtype=quant_type)

    quant = gguf.GGMLQuantizationType
    quantized("token_embd.weight", 512, 256, quant.Q6_K)
    quantized("output.weight", 512, 256, quant.Q6_K)
    writer.add_tensor("output_norm.weight", np.ones(256, dtype=np.float32))
    for layer in range(2):
        quantized(f"blk.{layer}.attn_q.weight", 256, 256, quant.Q4_K)
        quantized(f"blk.{layer}.attn_k.weight", 256, 256, quant.Q4_K)
        quantized(f"blk.{layer}.attn_v.weight", 256, 256, quant.Q6_K)
        quantized(f"blk.{layer}.attn_output.weight", 256, 256, quant.Q4_K)
        quantized(f"blk.{layer}.ssm_in.weight", 256, 512, quant.Q4_K)
        quantized(f"blk.{layer}.ssm_out.weight", 512, 256, quant.Q5_K)
        writer.add_tensor(f"blk.{layer}.ssm_conv1d.weight",
                          np.ones((4, 256), dtype=np.float32))
        quantized(f"blk.{layer}.ffn_gate.weight", 512, 256, quant.Q4_K)
        quantized(f"blk.{layer}.ffn_up.weight", 512, 256, quant.Q4_K)
        quantized(f"blk.{layer}.ffn_down.weight", 256, 512, quant.Q6_K)
        writer.add_tensor(f"blk.{layer}.attn_norm.weight",
                          np.ones(256, dtype=np.float16))
        writer.add_tensor(f"blk.{layer}.ffn_norm.weight",
                          np.ones(256, dtype=np.float32))

    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    writer.write_tensors_to_file()
    writer.close()


def compare(census_module, gguf, path, label):
    """Require both parsers to agree on every tensor and on the file totals."""
    failures = []
    ours = census_module.read_gguf(str(path), hash_file=False)
    theirs = gguf.GGUFReader(str(path))

    our_tensors = {tensor["name"]: tensor for tensor in ours["tensors"]}
    their_tensors = {tensor.name: tensor for tensor in theirs.tensors}

    if set(our_tensors) != set(their_tensors):
        only_ours = sorted(set(our_tensors) - set(their_tensors))
        only_theirs = sorted(set(their_tensors) - set(our_tensors))
        failures.append(
            f"{label}: tensor name sets differ, ours only {only_ours}, "
            f"gguf-py only {only_theirs}")
        return failures

    for name, our_tensor in our_tensors.items():
        their_tensor = their_tensors[name]
        their_type = int(their_tensor.tensor_type)
        if our_tensor["type"] != their_type:
            failures.append(
                f"{label}: {name} type {our_tensor['type']} against "
                f"gguf-py {their_type}")
        # gguf-py reports shape in the file's own axis order, fastest first,
        # and pads it to four axes; the file records only the axes it declares.
        our_dimensions = [int(d) for d in our_tensor["dimensions"]]
        their_dimensions = [int(d) for d in their_tensor.shape][:len(our_dimensions)]
        if our_dimensions != their_dimensions:
            failures.append(
                f"{label}: {name} dimensions {our_dimensions} against "
                f"gguf-py {their_dimensions}")
        their_bytes = int(their_tensor.n_bytes)
        if our_tensor["bytes"] != their_bytes:
            failures.append(
                f"{label}: {name} bytes {our_tensor['bytes']} against "
                f"gguf-py {their_bytes}")

    # gguf-py exposes the header counts as pseudo-fields under a GGUF. prefix
    # alongside the real metadata keys, so those are excluded from the set the
    # census reports.
    their_keys = {key for key in theirs.fields if not key.startswith("GGUF.")}
    if their_keys != set(ours["metadata"]):
        only_ours = sorted(set(ours["metadata"]) - their_keys)
        only_theirs = sorted(their_keys - set(ours["metadata"]))
        failures.append(
            f"{label}: metadata keys differ, ours only {only_ours}, "
            f"gguf-py only {only_theirs}")

    if not failures:
        print(f"agree\t{label}\ttensors={len(our_tensors)}\t"
              f"metadata={len(ours['metadata'])}")
    return failures


def check_fixture_summary(census_module, path):
    """The fixture's byte totals are known by construction, so the summary is
    checkable against arithmetic rather than against the other parser."""
    failures = []
    census = census_module.read_gguf(str(path), hash_file=False)
    summary = census_module.summarize(census)

    expectations = {
        "tensor_count": 27,
        "layer_count": 2,
        "embeddings_tied": False,
    }
    for key, expected in expectations.items():
        if summary[key] != expected:
            failures.append(f"fixture: {key} is {summary[key]}, expected {expected}")

    families = summary["by_family"]
    for family in ("embedding", "output", "attention", "gated_deltanet", "ffn",
                   "norm"):
        if families.get(family, 0) <= 0:
            failures.append(f"fixture: family {family} carries no bytes")
    if "other" in families:
        failures.append(
            f"fixture: {families['other']} bytes fell into the other family, "
            f"so a tensor name is unclassified")

    total = sum(tensor["bytes"] for tensor in census["tensors"])
    if summary["streamed_bytes"] != total - summary["embedding_bytes"]:
        failures.append(
            "fixture: untied streamed bytes must exclude the embedding tensor "
            f"exactly, got {summary['streamed_bytes']} against "
            f"{total - summary['embedding_bytes']}")

    by_type_total = sum(summary["by_type"].values())
    if by_type_total != total:
        failures.append(
            f"fixture: type totals {by_type_total} against tensor total {total}")
    by_family_total = sum(families.values())
    if by_family_total != total:
        failures.append(
            f"fixture: family totals {by_family_total} against tensor total {total}")

    if not failures:
        print(f"summary\tfixture\ttensor_bytes={total}\t"
              f"streamed={summary['streamed_bytes']}")
    return failures


def check_tied_branch(census_module, gguf, directory):
    """A checkpoint without output.weight ties the embedding, and the output
    projection then streams that tensor, so it stays inside the per-token
    total."""
    import numpy as np
    path = directory / "tied.gguf"
    writer = gguf.GGUFWriter(str(path), "qwen3next")
    writer.add_uint32("qwen3next.block_count", 1)
    block_elements, block_bytes = gguf.GGML_QUANT_SIZES[gguf.GGMLQuantizationType.Q6_K]
    row_bytes = 256 // block_elements * block_bytes
    payload = np.frombuffer(bytes(512 * row_bytes), dtype=np.uint8).reshape(
        512, row_bytes)
    writer.add_tensor("token_embd.weight", payload, raw_shape=(512, row_bytes),
                      raw_dtype=gguf.GGMLQuantizationType.Q6_K)
    writer.add_tensor("blk.0.ffn_up.weight", np.ones((256, 128), dtype=np.float32))
    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    writer.write_tensors_to_file()
    writer.close()

    census = census_module.read_gguf(str(path), hash_file=False)
    summary = census_module.summarize(census)
    total = sum(tensor["bytes"] for tensor in census["tensors"])
    failures = []
    if not summary["embeddings_tied"]:
        failures.append("tied: a file without output.weight must report tied")
    if summary["streamed_bytes"] != total:
        failures.append(
            f"tied: streamed bytes {summary['streamed_bytes']} must equal the "
            f"tensor total {total}, since the output projection reads the "
            f"embedding tensor")
    if not failures:
        print(f"tied\tfixture\tstreamed={summary['streamed_bytes']}")
    return failures


def check_mtp_branch(census_module, gguf, directory):
    """A checkpoint declaring nextn_predict_layers carries multi-token-prediction
    blocks after the transformer stack. llama_hparams::n_layer_effective subtracts
    them, so decode never runs them and their bytes leave the per-token total even
    though they carry ordinary attention and feed-forward names."""
    import numpy as np
    path = directory / "mtp.gguf"
    writer = gguf.GGUFWriter(str(path), "qwen35")
    writer.add_uint32("qwen35.block_count", 2)
    writer.add_uint32("qwen35.nextn_predict_layers", 1)
    for layer in range(2):
        writer.add_tensor(f"blk.{layer}.ffn_up.weight",
                          np.ones((256, 128), dtype=np.float32))
        writer.add_tensor(f"blk.{layer}.attn_q.weight",
                          np.ones((128, 128), dtype=np.float32))
    writer.add_tensor("blk.1.nextn.eh_proj.weight",
                      np.ones((128, 64), dtype=np.float32))
    writer.add_tensor("token_embd.weight", np.ones((64, 32), dtype=np.float32))
    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    writer.write_tensors_to_file()
    writer.close()

    census = census_module.read_gguf(str(path), hash_file=False)
    summary = census_module.summarize(census)
    failures = []
    if summary["nextn_layers"] != 1:
        failures.append(f"mtp: nextn_layers is {summary['nextn_layers']}, expected 1")

    layer_one = [t for t in census["tensors"] if t["layer"] == 1]
    misfiled = [t["name"] for t in layer_one if t["family"] != "mtp"]
    if misfiled:
        failures.append(f"mtp: block 1 tensors outside the mtp family: {misfiled}")
    layer_zero = [t for t in census["tensors"] if t["layer"] == 0]
    if any(t["family"] == "mtp" for t in layer_zero):
        failures.append("mtp: block 0 must stay outside the mtp family")

    # The fixture carries no output.weight, so the embedding is tied and the
    # logit projection streams it; what the nextn block contributes is what must
    # be absent.
    expected_streamed = (sum(t["bytes"] for t in layer_zero)
                         + summary["embedding_bytes"])
    if summary["streamed_bytes"] != expected_streamed:
        failures.append(
            f"mtp: streamed bytes {summary['streamed_bytes']} must exclude the "
            f"nextn block, expected {expected_streamed}")
    if summary["mtp_bytes"] != sum(t["bytes"] for t in layer_one):
        failures.append("mtp: mtp_bytes must total the nextn block")
    if not failures:
        print(f"mtp\tfixture\tmtp_bytes={summary['mtp_bytes']}\t"
              f"streamed={summary['streamed_bytes']}")
    return failures


def check_loop_branch(census_module, gguf, directory):
    """A looped transformer shares its physical layers across num_loops
    iterations, so per-token traffic counts the layer bytes once per loop while
    the embedding lookup and the logit projection stay outside the loop."""
    import numpy as np
    path = directory / "loop.gguf"
    writer = gguf.GGUFWriter(str(path), "nanbeige")
    writer.add_uint32("nanbeige.block_count", 2)
    writer.add_uint32("nanbeige.num_loops", 3)
    for layer in range(2):
        writer.add_tensor(f"blk.{layer}.ffn_up.weight",
                          np.ones((256, 128), dtype=np.float32))
    writer.add_tensor("token_embd.weight", np.ones((64, 32), dtype=np.float32))
    writer.add_tensor("output.weight", np.ones((64, 32), dtype=np.float32))
    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    writer.write_tensors_to_file()
    writer.close()

    census = census_module.read_gguf(str(path), hash_file=False)
    summary = census_module.summarize(census)
    failures = []
    if summary["num_loops"] != 3:
        failures.append(f"loop: num_loops is {summary['num_loops']}, expected 3")

    layer_bytes = sum(t["bytes"] for t in census["tensors"] if t["layer"] is not None)
    expected = layer_bytes * 3 + summary["output_bytes"]
    if summary["streamed_bytes"] != expected:
        failures.append(
            f"loop: streamed bytes {summary['streamed_bytes']} must count the "
            f"layer bytes three times and the output projection once, expected "
            f"{expected}")
    if summary["looped_bytes"] != layer_bytes:
        failures.append(
            f"loop: looped_bytes {summary['looped_bytes']} must be the "
            f"single-pass layer total {layer_bytes}")
    if not failures:
        print(f"loop\tfixture\tnum_loops=3\tstreamed={summary['streamed_bytes']}")
    return failures


def main(argv):
    gguf_py_path = locate_gguf_py()
    if gguf_py_path is None:
        print("gguf-py was not found; set GGUF_PY_PATH to a llama.cpp "
              "gguf-py directory", file=sys.stderr)
        return 2
    sys.path.insert(0, str(gguf_py_path))
    try:
        import gguf
        import numpy  # noqa: F401
    except ImportError as error:
        print(f"gguf-py at {gguf_py_path} is unimportable: {error}",
              file=sys.stderr)
        return 2

    census_module = load_census_module()
    print(f"gguf_py\t{gguf_py_path}")

    failures = []
    directory = Path(tempfile.mkdtemp(prefix="gguf-census-"))
    try:
        fixture = directory / "fixture.gguf"
        build_fixture(gguf, str(fixture))
        failures += compare(census_module, gguf, fixture, "fixture")
        failures += check_fixture_summary(census_module, fixture)
        failures += check_tied_branch(census_module, gguf, directory)
        failures += check_mtp_branch(census_module, gguf, directory)
        failures += check_loop_branch(census_module, gguf, directory)
    finally:
        shutil.rmtree(directory, ignore_errors=True)

    for real_path in argv[1:]:
        failures += compare(census_module, gguf, Path(real_path),
                            Path(real_path).name)

    # The command-line entry point must succeed, not only the imported one.
    result = subprocess.run(
        [sys.executable, str(SCRIPT_DIRECTORY / "gguf-tensor-census.py"),
         "--skip-hash", "--json"] + list(argv[1:] or []),
        capture_output=True, text=True)
    if argv[1:] and result.returncode != 0:
        failures.append(f"command line exited {result.returncode}: "
                        f"{result.stderr.strip()}")

    if failures:
        for failure in failures:
            print(f"FAIL\t{failure}", file=sys.stderr)
        return 1
    print("census=agrees_with_gguf_py")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
