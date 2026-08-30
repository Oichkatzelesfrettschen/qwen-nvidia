#!/usr/bin/env python3
"""Check the quantization-independent representation-pair boundary."""

import importlib.util
import pathlib
import sys


SCRIPT_DIRECTORY = pathlib.Path(__file__).resolve().parent


def load_module():
    path = SCRIPT_DIRECTORY / "verify-representation-pair.py"
    spec = importlib.util.spec_from_file_location("verify_representation_pair", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"validator is unreadable: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


VALIDATOR = load_module()


def fixture(tensor_type="Q4_K", architecture="qwen35", token="a",
            dimensions=None):
    tensor_dimensions = dimensions or [8, 4]
    return {
        "metadata": {
            "general.architecture": architecture,
            f"{architecture}.block_count": 1,
            "tokenizer.ggml.tokens": [token],
        },
        "tensors": [{
            "name": "blk.0.attn_q.weight",
            "dimensions": tensor_dimensions,
            "type_name": tensor_type,
            "family": "attention",
            "layer": 0,
        }],
    }


def main():
    control = fixture()
    subject = fixture(tensor_type="F16")
    if VALIDATOR.pair_mismatches(control, subject):
        print("matching structure was rejected", file=sys.stderr)
        return 1
    if VALIDATOR.changed_tensor_types(control, subject) != 1:
        print("the changed tensor type was not counted", file=sys.stderr)
        return 1

    mutations = (
        fixture(tensor_type="F16", architecture="qwen3"),
        fixture(tensor_type="F16", token="b"),
        fixture(tensor_type="F16", dimensions=[16, 4]),
    )
    for mutated in mutations:
        if not VALIDATOR.pair_mismatches(control, mutated):
            print(f"mismatched pair was admitted: {mutated!r}", file=sys.stderr)
            return 1
    print("representation_pair_validator=accepted")
    return 0


if __name__ == "__main__":
    sys.exit(main())
