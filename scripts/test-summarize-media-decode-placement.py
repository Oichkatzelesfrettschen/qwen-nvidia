#!/usr/bin/env python3
"""Hold summarize-media-decode-placement.py to a synthetic run directory.

The run directory holds two projector directories whose decode rows agree, a
transfer table for the policies that decoded something, and no table for a
policy every decoder refused. The summary is expected to classify a PNG as a
CPU decode plus one upload, a JPEG as a device decode under the hybrid
policy, read the copy counts per policy, take the closest resize arm per
projector, and mark a tiled fixture as not measured. A decode row that
differs between the two projector directories and a decoded policy with no
transfer table are each expected to refuse.
"""

import csv
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SUMMARIZER = os.path.join(HERE, "summarize-media-decode-placement.py")

POLICIES = ("any", "gpu", "hw", "hybrid", "cpu")


def decode_line(image, policy, status, codec, decoder, width, height, nbytes, digest, identical, max_abs):
    return ("decode\timage=%s\tpolicy=%s\tstatus=%s\tcodec=%s\tdecoder=%s\textensions=-\twidth=%d\theight=%d\t"
            "decoded_bytes=%d\toutput_memory=device\tdigest=%s\tvs_stb_compared=%d\tvs_stb_differing=%d\t"
            "vs_stb_max_abs=%d\tvs_stb_identical=%s\n") % (
        image, policy, status, codec, decoder, width, height, nbytes, digest, nbytes if status == "success" else 0,
        0 if identical else 5, max_abs, "yes" if identical else ("no" if status == "success" else "n/a"))


def placement_text(png_digest="aaaa", jpeg_any_digest="bbbb"):
    lines = ["probe\tdevice=fixture\n"]
    # a PNG: cpu decoder alone, identical to stb
    lines.append("reference_decode\timage=a.png\tencoded_bytes=100\tdecoder=stb_image\tbackend_kind=cpu_only\t"
                 "output_memory=host\twidth=4\theight=2\tsource_channels=3\tdecoded_bytes=24\tdigest=1111\n")
    for policy in POLICIES:
        if policy in ("any", "cpu"):
            lines.append(decode_line("a.png", policy, "success", "png", "opencv_png_decoder", 4, 2, 24, png_digest, True, 0))
        else:
            lines.append(decode_line("a.png", policy, "decoder_create:arch_mismatch", "png", "-", 4, 2, 24, "-", False, 0))
    lines.append("preproc\timage=a.png\tentries=1\tgrid_x=0\tgrid_y=0\thas_overview=no\n")
    lines.append("preproc_entry\timage=a.png\tentry=0\twidth=4\theight=2\telements=24\tdigest=2222\n")
    for op, fraction, max_u8 in (("resize_linear", "0.5", 9), ("hqresize_linear_aa", "0.01", 1)):
        lines.append("preproc_compare\timage=a.png\tentry=0\top=%s\tsource=device_decode\ttarget=4x2\tresample=4x2\t"
                     "pad=none\toffset=0,0\tresult=differs\tcompared=24\tdiffering=2\tdiffering_fraction=%s\t"
                     "max_abs_f32=0.1\tmax_abs_u8=%d\tdigest=3333\n" % (op, fraction, max_u8))
    # a JPEG: hybrid device decoder, differs from stb by rounding; tiled on this projector
    lines.append("reference_decode\timage=b.jpg\tencoded_bytes=200\tdecoder=stb_image\tbackend_kind=cpu_only\t"
                 "output_memory=host\twidth=8\theight=2\tsource_channels=3\tdecoded_bytes=48\tdigest=4444\n")
    for policy in POLICIES:
        if policy in ("any", "hybrid"):
            lines.append(decode_line("b.jpg", policy, "success", "jpeg", "nvjpeg_cuda_decoder", 8, 2, 48, jpeg_any_digest, False, 3))
        elif policy == "cpu":
            lines.append(decode_line("b.jpg", policy, "success", "jpeg", "libjpeg_turbo_decoder", 8, 2, 48, "cccc", False, 2))
        else:
            lines.append(decode_line("b.jpg", policy, "decoder_create:arch_mismatch", "jpeg", "-", 8, 2, 48, "-", False, 0))
    lines.append("preproc\timage=b.jpg\tentries=4\tgrid_x=2\tgrid_y=2\thas_overview=no\n")
    lines.append("preproc_compare\timage=b.jpg\tentry=0\top=-\tresult=not_run\treason=tiled_layout\n")
    lines.append("transfers\tprogram_host_to_device=0\tprogram_device_to_host=3\tlibrary_transfers=read_from_nsys_capture\n")
    lines.append("media_placement=completed\n")
    return "".join(lines)


def transfers_text(rows):
    header = "start_ns\tend_ns\tkind\tbytes\tsrc_kind\tdst_kind\tstream\tapi\tkernel_before\tkernel_after\tembedding_sized\trow_multiple\n"
    body = "".join("%d\t%d\t%s\t%d\tPinned\tDevice\t7\tcudaMemcpyAsync\t-\t-\tyes\tno\n" % (index, index + 1, kind, nbytes)
                   for index, (kind, nbytes) in enumerate(rows))
    return header + body


def build_run(root, second_png_digest="aaaa", drop_hybrid_table=False):
    for model in ("model-a", "model-b"):
        os.makedirs(os.path.join(root, model))
        with open(os.path.join(root, model, "placement.tsv"), "w") as handle:
            handle.write(placement_text(png_digest="aaaa" if model == "model-a" else second_png_digest))
    tables = {
        "any": [("Host-to-Device", 24), ("Device-to-Host", 24), ("Host-to-Device", 300), ("Device-to-Host", 48)],
        "hybrid": [("Host-to-Device", 300), ("Device-to-Host", 48)],
        "cpu": [("Host-to-Device", 24), ("Device-to-Host", 24), ("Host-to-Device", 48), ("Device-to-Host", 48)],
    }
    if drop_hybrid_table:
        del tables["hybrid"]
    for policy, rows in tables.items():
        os.makedirs(os.path.join(root, "nsys", policy))
        with open(os.path.join(root, "nsys", policy, "transfers.tsv"), "w") as handle:
            handle.write(transfers_text(rows))


def run(root):
    completed = subprocess.run([sys.executable, SUMMARIZER, root], capture_output=True, text=True)
    return completed.returncode, completed.stdout


def expect(condition, message):
    if not condition:
        sys.exit("refused: " + message)
    print("accepted", message)


def main():
    workspace = tempfile.mkdtemp(prefix="media-placement-summary-")
    try:
        root = os.path.join(workspace, "run")
        build_run(root)
        code, out = run(root)
        expect(code == 0, "the consistent run summarizes: %s" % out.strip().splitlines()[-1])
        with open(os.path.join(root, "placement-summary.tsv")) as handle:
            rows = {row["image"]: row for row in csv.DictReader(handle, delimiter="\t")}
        png, jpeg = rows["a.png"], rows["b.jpg"]
        expect(png["placement"] == "cpu_decoder_upload" and png["device_decoder"] == "-", "the PNG is a CPU decode plus upload")
        expect(png["cpu_htod_decoded"] == "1" and png["gpu_htod_decoded"] == "0", "the PNG upload is read from the cpu table and the refused policy reads zero")
        expect(jpeg["hybrid_htod_other"] == "300" and png["hybrid_htod_other"] == "0", "the hybrid coefficient upload is attributed to the JPEG alone")
        expect(jpeg["any_htod_other"] == "300" and png["any_htod_decoded"] == "1", "copies partition by readback under the mixed policy")
        expect(jpeg["placement"] == "device_decoder" and jpeg["device_decoder"] == "hybrid:nvjpeg_cuda_decoder",
               "the JPEG is a device decode named by the hybrid policy")
        expect(jpeg["hybrid_htod_decoded"] == "0" and jpeg["cpu_htod_decoded"] == "1", "the hybrid decoder uploads no decoded plane and the cpu one does")

        root = os.path.join(workspace, "run-no-terminal")
        build_run(root)
        with open(os.path.join(root, "model-b", "placement.tsv")) as handle:
            text = handle.read().replace("media_placement=completed\n", "")
        with open(os.path.join(root, "model-b", "placement.tsv"), "w") as handle:
            handle.write(text)
        code, out = run(root)
        expect(code != 0 and "did not end on media_placement=completed" in out, "a directory without the completion line refuses")

        root = os.path.join(workspace, "run-missing-row")
        build_run(root)
        with open(os.path.join(root, "model-b", "placement.tsv")) as handle:
            text = "".join(line for line in handle if not (line.startswith("decode\timage=a.png\tpolicy=cpu")))
        with open(os.path.join(root, "model-b", "placement.tsv"), "w") as handle:
            handle.write(text)
        code, out = run(root)
        expect(code != 0 and "decode row set differs" in out, "a missing decode row in one directory refuses")

        root = os.path.join(workspace, "run-extra-copy")
        build_run(root)
        with open(os.path.join(root, "nsys", "cpu", "transfers.tsv"), "a") as handle:
            handle.write("99\t100\tHost-to-Device\t4096\tPinned\tDevice\t7\tcudaMemcpyAsync\t-\t-\tno\tno\n")
        code, out = run(root)
        expect(code != 0 and "after the last attributed readback" in out, "a copy after the last readback refuses")
        expect(png["model-a_best_op"] == "hqresize_linear_aa" and png["model-a_contract"] == "separate", "the closest arm is taken per projector")
        expect(jpeg["model-a_contract"] == "not_measured" and jpeg["model-a_best_op"] == "not_run:tiled_layout", "a tiled fixture is not measured")

        root = os.path.join(workspace, "run-differs")
        build_run(root, second_png_digest="ffff")
        code, out = run(root)
        expect(code != 0 and "decode row differs" in out, "a decode digest differing between projectors refuses")

        root = os.path.join(workspace, "run-no-table")
        build_run(root, drop_hybrid_table=True)
        code, out = run(root)
        expect(code != 0 and "no transfer table for policy hybrid" in out, "a decoded policy without a transfer table refuses")
    finally:
        shutil.rmtree(workspace)
    print("summarize_media_decode_placement=accepted")


if __name__ == "__main__":
    main()
