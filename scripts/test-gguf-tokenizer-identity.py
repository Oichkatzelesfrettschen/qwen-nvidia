#!/usr/bin/env python3
"""Prove tokenizer identity changes when any decoder array changes."""

import importlib.util
import os
import sys

SCRIPT_DIRECTORY = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "gguf_tensor_census", os.path.join(SCRIPT_DIRECTORY, "gguf-tensor-census.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

BASE_METADATA = {
    "tokenizer.ggml.model": "gpt2",
    "tokenizer.ggml.pre": "qwen35",
    "tokenizer.ggml.tokens": ["alpha", "beta"],
    "tokenizer.ggml.scores": [0.0, -1.25],
    "tokenizer.ggml.token_type": [1, 2],
    "tokenizer.ggml.merges": ["a lpha", "b eta"],
}

base_identity = module.tokenizer_identity(BASE_METADATA)
required_keys = {
    "vocabulary_size", "tokens_sha256", "scores_count", "scores_sha256",
    "token_types_count", "token_types_sha256", "merges_count", "merges_sha256",
}
failures = 0
missing = required_keys - set(base_identity)
if missing:
    print(f"tokenizer identity omits fields: {sorted(missing)}", file=sys.stderr)
    failures += 1

mutations = (
    ("tokens_sha256", "tokenizer.ggml.tokens", ["alpha", "gamma"]),
    ("scores_sha256", "tokenizer.ggml.scores", [0.0, -1.5]),
    ("token_types_sha256", "tokenizer.ggml.token_type", [1, 3]),
    ("merges_sha256", "tokenizer.ggml.merges", ["a lpha", "g amma"]),
)
for identity_key, metadata_key, replacement in mutations:
    mutated_metadata = dict(BASE_METADATA)
    mutated_metadata[metadata_key] = replacement
    mutated_identity = module.tokenizer_identity(mutated_metadata)
    if mutated_identity[identity_key] == base_identity[identity_key]:
        print(f"{identity_key} ignores changed {metadata_key}", file=sys.stderr)
        failures += 1
    if mutated_identity["vocabulary_size"] != base_identity["vocabulary_size"]:
        print("same-length tokenizer mutation changed vocabulary size",
              file=sys.stderr)
        failures += 1

if module.tokenizer_identity(dict(BASE_METADATA)) != base_identity:
    print("tokenizer identity is not deterministic", file=sys.stderr)
    failures += 1

nonfinite_scores = [float("-inf"), float("inf"), float("nan")]
nonfinite_digest = module.metadata_value_sha256(nonfinite_scores)
if module.metadata_value_sha256(nonfinite_scores) != nonfinite_digest:
    print("non-finite tokenizer scores are not deterministic", file=sys.stderr)
    failures += 1
if module.metadata_value_sha256([float("-inf"), float("inf"), 0.0]) \
        == nonfinite_digest:
    print("non-finite tokenizer score mutation did not change identity",
          file=sys.stderr)
    failures += 1

if failures:
    print(f"gguf_tokenizer_identity=rejected failures={failures}", file=sys.stderr)
    sys.exit(1)
print("gguf_tokenizer_identity=accepted arrays=4")
