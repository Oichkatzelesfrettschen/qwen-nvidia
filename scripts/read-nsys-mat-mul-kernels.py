#!/usr/bin/env python3
"""Report the quantized mat-mul kernels a Nsight Systems capture recorded.

The kernel symbol carries the claim. ggml/src/ggml-cuda/mmvq.cu:544 declares
`template <ggml_type type, int ncols_dst, bool has_fusion, bool small_k,
bool halve_iters> __global__ void mul_mat_vec_q`, so an MMVQ launch demangles to
`mul_mat_vec_q<(ggml_type)12, (int)7, ...>` and names the quantization type and
the column count of the mat-mul second operand in the symbol itself. MMQ
demangles to `mul_mat_q<(ggml_type)T, (int)mmq_x, (bool)need_check>`, whose
second parameter is the tile width rather than ne11, so an MMQ launch is read
for its type alone.

MMQ partitions its work stream-k and reduces the partial tiles in a second
kernel. `ggml/src/ggml-cuda/mmq.cuh:1233-1235` declares
`template <ggml_type type, int J, bool fallback> __global__ void
mul_mat_q_stream_k_fixup`, the same template parameter list `mul_mat_q` carries
at `mmq.cuh:946-948`, and `mmq.cuh:1463` launches it inside the same call that
launched `mul_mat_q` whenever `fixup_needed` at `mmq.cuh:1440` holds. The
symbol therefore demangles to `mul_mat_q_stream_k_fixup<(ggml_type)8, (int)16,
(bool)0>`, whose leading argument names the quantization type and whose second
is the tile width `J` rather than ne11. FIXUP is its own family because the
launch is a reduction of MMQ's partial tiles rather than a mat-mul path a
dispatch chooses, and it reads its type from the symbol and reports no ncols
for the same reason an MMQ row does.

The reader queries the SQLite export rather than `nsys stats --report
cuda_gpu_kern_sum`. That report returns a header and no rows against the
capture this repository takes with Nsight Systems 2026.1.3, while
`CUPTI_ACTIVITY_KIND_KERNEL` joined to `StringIds` carries every launch, so the
activity table is the authority and the report is not.

Each output row is one distinct kernel symbol with its launch count and summed
device time, which separates a prefill launch at ncols_dst equal to the arm's B
from the decode launches at 1 that the same process also issues.
"""

import argparse
import re
import sqlite3
import sys

GGML_TYPE_NAMES = {
    0: "F32", 1: "F16", 2: "Q4_0", 3: "Q4_1", 6: "Q5_0", 7: "Q5_1",
    8: "Q8_0", 9: "Q8_1", 10: "Q2_K", 11: "Q3_K", 12: "Q4_K", 13: "Q5_K",
    14: "Q6_K", 15: "Q8_K", 30: "BF16",
}

MMVQ = re.compile(r"\bmul_mat_vec_q<\(ggml_type\)(\d+),\s*\(int\)(\d+)")
MMQ = re.compile(r"\bmul_mat_q<\(ggml_type\)(\d+)")
FIXUP = re.compile(r"\bmul_mat_q_stream_k_fixup<\(ggml_type\)(\d+)")
CUBLAS = re.compile(r"gemm|xmma|cutlass|_tn_|_nn_|_nt_", re.IGNORECASE)

KERNEL_QUERY = """
select s.value, count(*), sum(k.end - k.start)
from CUPTI_ACTIVITY_KIND_KERNEL k
join StringIds s on s.id = k.demangledName
group by s.value
"""


def classify(name):
    """Return (family, type_number, ncols_dst) for a mat-mul kernel, or None.

    ncols_dst is the MMVQ template argument alone. MMQ and FIXUP both carry the
    tile width in that position, so both report None and the column keeps one
    meaning across the retained rows.
    """
    match = MMVQ.search(name)
    if match:
        return "MMVQ", int(match.group(1)), int(match.group(2))
    # FIXUP is tested ahead of MMQ so the ordering states the separation
    # rather than resting on `mul_mat_q` being followed by `_stream` here.
    match = FIXUP.search(name)
    if match:
        return "FIXUP", int(match.group(1)), None
    match = MMQ.search(name)
    if match:
        return "MMQ", int(match.group(1)), None
    if "mul_mat_f<" in name or "mul_mat_vec_f<" in name:
        return "MMF", None, None
    if CUBLAS.search(name):
        return "CUBLAS", None, None
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sqlite_export", help="the .sqlite nsys wrote")
    parser.add_argument("--arm-id", default="-")
    parser.add_argument("--quant-family", default="-")
    parser.add_argument("--ne11", default="-")
    arguments = parser.parse_args()

    connection = sqlite3.connect(arguments.sqlite_export)
    try:
        rows = list(connection.execute(KERNEL_QUERY))
    except sqlite3.OperationalError as error:
        print(f"the capture carries no kernel activity table: {error}",
              file=sys.stderr)
        return 1
    finally:
        connection.close()

    if not rows:
        print("the capture recorded no kernel launches", file=sys.stderr)
        return 1

    emitted = 0
    for name, launches, total_ns in sorted(rows, key=lambda r: -r[1]):
        classified = classify(name)
        if classified is None:
            continue
        family, type_number, ncols = classified
        type_name = "-" if type_number is None else GGML_TYPE_NAMES.get(
            type_number, f"type{type_number}")
        print("\t".join((
            arguments.arm_id,
            arguments.quant_family,
            str(arguments.ne11),
            name.replace("\t", " "),
            family,
            type_name,
            "-" if ncols is None else str(ncols),
            str(launches),
            str(total_ns or 0),
            "observed",
        )))
        emitted += 1

    if emitted == 0:
        print("the capture recorded no quantized mat-mul kernel", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
