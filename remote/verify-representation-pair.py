#!/usr/bin/env python3
"""Refuse representation arms whose checkpoint structure does not match.

The check reads GGUF headers only. It binds an arm to matching architecture
dimensions, tokenizer identity, and tensor names and shapes while allowing the
tensor types and byte counts that a representation comparison must vary. The
check does not assert equality of the numeric tensor values.
"""

import importlib.util
import pathlib
import sys


SCRIPT_DIRECTORY = pathlib.Path(__file__).resolve().parent


def load_census_module():
    census_path = SCRIPT_DIRECTORY / "gguf-tensor-census.py"
    spec = importlib.util.spec_from_file_location("gguf_tensor_census", census_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"census parser is unreadable: {census_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CENSUS = load_census_module()


def tensor_layout(census):
    """Return a quantization-independent tensor layout keyed by tensor name."""
    layout = {}
    for tensor in census["tensors"]:
        name = tensor["name"]
        if name in layout:
            raise ValueError(f"duplicate tensor name: {name}")
        layout[name] = {
            "dimensions": tensor["dimensions"],
            "family": tensor["family"],
            "layer": tensor["layer"],
        }
    return layout


def pair_mismatches(control, subject):
    """Describe every structural identity mismatch between two parsed GGUFs."""
    mismatches = []
    control_metadata = control["metadata"]
    subject_metadata = subject["metadata"]
    control_architecture = control_metadata.get("general.architecture", "")
    subject_architecture = subject_metadata.get("general.architecture", "")
    if control_architecture != subject_architecture:
        mismatches.append(
            f"architecture {control_architecture!r} != {subject_architecture!r}")
    control_dimensions = CENSUS.architecture_dimensions(
        control_metadata, control_architecture)
    subject_dimensions = CENSUS.architecture_dimensions(
        subject_metadata, subject_architecture)
    if control_dimensions != subject_dimensions:
        mismatches.append("architecture dimensions differ")
    if CENSUS.tokenizer_identity(control_metadata) != CENSUS.tokenizer_identity(
            subject_metadata):
        mismatches.append("tokenizer identity differs")
    if tensor_layout(control) != tensor_layout(subject):
        mismatches.append("tensor names, shapes, families, or layers differ")
    return mismatches


def changed_tensor_types(control, subject):
    """Count corresponding tensors whose GGML representation differs."""
    control_types = {tensor["name"]: tensor["type_name"]
                     for tensor in control["tensors"]}
    subject_types = {tensor["name"]: tensor["type_name"]
                     for tensor in subject["tensors"]}
    return sum(control_types.get(name) != subject_type
               for name, subject_type in subject_types.items())


def main(argv):
    if len(argv) != 2:
        print(f"usage: {sys.argv[0]} CONTROL_MODEL SUBJECT_MODEL", file=sys.stderr)
        return 2
    try:
        control = CENSUS.read_gguf(argv[0], hash_file=False)
        subject = CENSUS.read_gguf(argv[1], hash_file=False)
        mismatches = pair_mismatches(control, subject)
    except (OSError, ValueError, CENSUS.GgufReadError) as error:
        print(f"representation pair header check failed: {error}", file=sys.stderr)
        return 1
    if mismatches:
        for mismatch in mismatches:
            print(f"representation pair mismatch: {mismatch}", file=sys.stderr)
        return 1
    type_changes = changed_tensor_types(control, subject)
    if type_changes == 0:
        print("representation pair changes no tensor types", file=sys.stderr)
        return 1
    print("representation_pair=compatible "
          "identity=architecture+dimensions+tokenizer+tensor-layout "
          f"changed_tensor_types={type_changes}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
