#!/usr/bin/env python3
"""Bound the decode-token saving a projection fan-out merge can reach.

Every mat-mul in a Qwen3.5 decode graph that takes the MMVQ path quantizes its
own second operand: `ggml/src/ggml-cuda/mmvq.cu:1332` calls
`quantize_row_q8_1_cuda` into a fresh pool allocation on every
`ggml_cuda_mul_mat_vec_q` call, with no cache keyed on the activation. That
function ends on `GGML_UNUSED(type_src0)` (`quantize.cu:571`), so the MMVQ q8_1
encoding is independent of the weight type and several mat-muls reading one
activation produce byte-identical buffers.

`src/models/qwen35.cpp` fans one activation out to several weights twice per
layer. A linear-attention layer sends `cur` to `wqkv` and `wqkv_gate`
(`build_qkvz`, lines 237 and 241) and to `ssm_beta` and `ssm_alpha` (lines 362
and 369), a four-way fan-out. A full-attention layer sends `cur` to `wq`, `wk`,
and `wv` (lines 270, 282, 285), a three-way fan-out. The feed-forward gate and
up projections are a third fan-out that `ggml_cuda_can_fuse` already collapses
through `mul_mat_glu_ops` (`ggml-cuda.cu:3043`), so it contributes nothing left
to save.

`mul_mat_vec_q` is templated on one `ggml_type` (`mmvq.cu:544`), so a merged
launch reaches only the largest same-type subset of a fan-out group. A group of
N mat-muls whose largest same-type subset is M currently issues N mat-mul and N
quantize launches; merged, it issues N - M + 1 mat-mul launches and one
quantize, so the merge removes N + M - 2 kernel launches.

The saving those removed launches carry is the per-launch fixed cost t0, and
this reader takes it as a parameter rather than assuming one. It prints the
launch count per model and the t0 at which the removal reaches a stated
promotion floor, so a measured t0 decides the lever rather than an estimate.
"""

import argparse
import collections
import os
import re
import sys

FAN_OUT_GROUPS = {
    "linear-attention": ("attn_qkv", "attn_gate", "ssm_beta", "ssm_alpha"),
    "full-attention": ("attn_q", "attn_k", "attn_v"),
}


def usage_error(message):
    sys.stderr.write("derive-projection-fan-out-bound.py: %s\n" % message)
    sys.stderr.write(
        "usage: derive-projection-fan-out-bound.py "
        "--model ID=PATH=DECODE_TOK_S [--model ...] [--floor-percent P]\n")
    raise SystemExit(2)


def read_layers(reader):
    layers = collections.defaultdict(dict)
    for tensor in reader.tensors:
        matched = re.match(r"blk\.(\d+)\.(.+)\.weight$", tensor.name)
        if matched is None:
            continue
        layers[int(matched.group(1))][matched.group(2)] = (
            int(tensor.tensor_type), int(tensor.n_bytes))
    return layers


def group_saving(layer, names):
    present = [(name, layer[name]) for name in names if name in layer]
    if len(present) < 2:
        return None
    types = collections.Counter(quant for _, (quant, _) in present)
    largest_same_type = max(types.values())
    return {
        "width": len(present),
        "largest_same_type_subset": largest_same_type,
        "saved_mat_mul_launches": largest_same_type - 1,
        "saved_quantize_launches": len(present) - 1,
        "saved_launches": len(present) + largest_same_type - 2,
        "bytes": sum(size for _, (_, size) in present),
    }


def main():
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--model", action="append", default=[],
                        help="ID=GGUF_PATH=DECODE_TOK_S")
    parser.add_argument("--floor-percent", type=float, default=5.1)
    parser.add_argument("--t0-mat-mul-microseconds", type=float, default=None,
                        help="measured fixed cost of one mul_mat_vec_q launch")
    parser.add_argument("--t0-quantize-microseconds", type=float, default=None,
                        help="measured fixed cost of one quantize_q8_1 launch")
    arguments = parser.parse_args()

    if not arguments.model:
        usage_error("name at least one --model")

    gguf_py_path = os.environ.get("GGUF_PY_PATH")
    if gguf_py_path:
        sys.path.insert(0, gguf_py_path)
    try:
        import gguf
    except ImportError:
        usage_error("gguf-py is unavailable; set GGUF_PY_PATH")

    print("\t".join((
        "model_id", "block_count", "linear_attention_layers",
        "full_attention_layers", "saved_mat_mul_launches",
        "saved_quantize_launches", "saved_launches_per_token",
        "decode_token_microseconds", "floor_percent",
        "uniform_t0_microseconds_reaching_floor")))
    detail = []
    totals = {}

    for specification in arguments.model:
        parts = specification.split("=")
        if len(parts) != 3:
            usage_error("--model takes ID=GGUF_PATH=DECODE_TOK_S")
        model_id, path, rate_text = parts
        try:
            decode_tok_s = float(rate_text)
        except ValueError:
            usage_error("DECODE_TOK_S is not a number: %s" % rate_text)
        if decode_tok_s <= 0:
            usage_error("DECODE_TOK_S is not positive: %s" % rate_text)

        layers = read_layers(gguf.GGUFReader(path))
        counts = collections.Counter()
        saved = saved_mat_mul = saved_quantize = 0
        for index in sorted(layers):
            for kind, names in FAN_OUT_GROUPS.items():
                result = group_saving(layers[index], names)
                if result is None:
                    continue
                counts[kind] += 1
                saved += result["saved_launches"]
                saved_mat_mul += result["saved_mat_mul_launches"]
                saved_quantize += result["saved_quantize_launches"]
                detail.append((model_id, index, kind, result))

        token_microseconds = 1e6 / decode_tok_s
        floor_microseconds = token_microseconds * arguments.floor_percent / 100.0
        t0_reaching_floor = floor_microseconds / saved if saved else float("inf")
        totals[model_id] = (saved_mat_mul, saved_quantize, token_microseconds)
        print("\t".join((
            model_id, str(len(layers)), str(counts["linear-attention"]),
            str(counts["full-attention"]), str(saved_mat_mul),
            str(saved_quantize), str(saved),
            "%.1f" % token_microseconds, "%.1f" % arguments.floor_percent,
            "%.2f" % t0_reaching_floor)))

    print()
    print("\t".join((
        "model_id", "layer", "group", "width", "largest_same_type_subset",
        "saved_launches", "group_weight_bytes")))
    seen = set()
    for model_id, index, kind, result in detail:
        signature = (model_id, kind, result["width"],
                     result["largest_same_type_subset"], result["bytes"])
        if signature in seen:
            continue
        seen.add(signature)
        print("\t".join((
            model_id, str(index), kind, str(result["width"]),
            str(result["largest_same_type_subset"]),
            str(result["saved_launches"]), str(result["bytes"]))))

    if (arguments.t0_mat_mul_microseconds is not None
            and arguments.t0_quantize_microseconds is not None):
        print()
        print("\t".join((
            "model_id", "mat_mul_saving_microseconds",
            "quantize_saving_microseconds", "total_saving_microseconds",
            "saving_percent", "clears_floor")))
        for model_id, (mat_mul, quantize, token) in totals.items():
            mat_mul_saving = mat_mul * arguments.t0_mat_mul_microseconds
            quantize_saving = quantize * arguments.t0_quantize_microseconds
            total = mat_mul_saving + quantize_saving
            percent = 100.0 * total / token
            print("\t".join((
                model_id, "%.1f" % mat_mul_saving, "%.1f" % quantize_saving,
                "%.1f" % total, "%.2f" % percent,
                "yes" if percent >= arguments.floor_percent else "no")))


if __name__ == "__main__":
    main()
