#!/usr/bin/env python3
"""Hold read-paged-kv-layout.py to synthetic server logs.

A subject log with one fully backed buffer and six aligned attention layers
reads layout_holds with exact accounting; a control log with the default kind
and no paged lines reads layout_holds; a buffer whose mapped bytes fall under
its reservation, a tensor misaligned to the unit, a recurrent tensor inside
the paged buffer, and a subject log carrying the default kind are each refused
with the fault named.
"""

import os
import subprocess
import sys
import tempfile

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "read-paged-kv-layout.py")
UNIT = 2097152
K_ROW, V_ROW, DEPTH = 544, 288, 65536
K_BYTES, V_BYTES = K_ROW * DEPTH, V_ROW * DEPTH
LAYERS = (3, 7, 11, 15, 19, 23)


def tensor_line(name, ggml_type, row, nbytes, offset, unit=UNIT, padded=None, start="yes", extent="yes"):
    padded = padded if padded is not None else -(-nbytes // unit) * unit
    return ("ggml_backend_cuda_buffer_init_tensor: paged_kv_tensor name=%s type=%s ne0=512 ne1=%d ne2=1"
            " row_bytes=%d nbytes=%d alloc_bytes=%d padded_bytes=%d offset=%d unit_bytes=%d"
            " start_aligned=%s extent_aligned=%s\n"
            % (name, ggml_type, DEPTH, row, nbytes, nbytes, padded, offset, unit, start, extent))


def subject_log(mapped=None, tensors=None):
    total = len(LAYERS) * (K_BYTES + V_BYTES)
    mapped = total if mapped is None else mapped
    lines = ["load: some other line\n",
             "ggml_backend_cuda_paged_kv_alloc_buffer: paged_kv_buffer device=0 requested_bytes=%d"
             " virtual_reserved_bytes=%d physical_mapped_bytes=%d unit_bytes=%d granularity_minimum=%d"
             " granularity_recommended=%d access=device_rw\n" % (total, total, mapped, UNIT, UNIT, UNIT)]
    if tensors is None:
        tensors = []
        offset = 0
        for layer in LAYERS:
            tensors.append(tensor_line("cache_k_l%d" % layer, "q8_0", K_ROW, K_BYTES, offset))
            offset += K_BYTES
            tensors.append(tensor_line("cache_v_l%d" % layer, "q4_0", V_ROW, V_BYTES, offset))
            offset += V_BYTES
    lines.extend(tensors)
    lines.append("llama_kv_cache:      CUDA0 KV buffer size =   312.00 MiB\n")
    lines.append("llama_kv_cache: kv_buffer_kind=paged_kv_vmm buffer=CUDA0\n")
    lines.append("llama_kv_cache: size =  312.00 MiB ( 65536 cells,   6 layers,  1/1 seqs), K (q8_0):  204.00 MiB, V (q4_0):  108.00 MiB\n")
    lines.append("llama_memory_recurrent:      CUDA0 RS buffer size =    32.50 MiB\n")
    return "".join(lines)


def control_log():
    return ("llama_kv_cache:      CUDA0 KV buffer size =   312.00 MiB\n"
            "llama_kv_cache: kv_buffer_kind=device_default buffer=CUDA0\n"
            "llama_kv_cache: size =  312.00 MiB ( 65536 cells,   6 layers,  1/1 seqs), K (q8_0):  204.00 MiB, V (q4_0):  108.00 MiB\n"
            "llama_memory_recurrent:      CUDA0 RS buffer size =    32.50 MiB\n")


def run(text, expect, extra=()):
    with tempfile.NamedTemporaryFile("w", suffix=".log", delete=False) as handle:
        handle.write(text)
        path = handle.name
    try:
        result = subprocess.run([sys.executable, SCRIPT, path, "--expect", expect, *extra],
                                capture_output=True, text=True, check=False)
    finally:
        os.unlink(path)
    rows = dict(line.split("\t", 1) for line in result.stdout.splitlines() if "\t" in line and not line.startswith("fault"))
    faults = [line.split("\t", 1)[1] for line in result.stdout.splitlines() if line.startswith("fault\t")]
    return result.returncode, rows, faults


failures = 0


def check(name, condition, detail=""):
    global failures
    print("%s: %s%s" % ("ok" if condition else "FAIL", name, (" -- " + detail) if detail and not condition else ""))
    if not condition:
        failures += 1


code, rows, faults = run(subject_log(), "paged_kv_vmm")
total = len(LAYERS) * (K_BYTES + V_BYTES)
check("subject holds", code == 0 and rows["verdict"] == "layout_holds", "; ".join(faults))
check("logical bytes sum the tensors", rows.get("kv_logical_bytes") == str(total))
check("mapped equals virtual", rows.get("kv_physical_mapped_bytes") == rows.get("kv_virtual_reserved_bytes") == str(total))
check("padding is zero at whole-unit tensors", rows.get("kv_alignment_padding_bytes") == "0")
check("memory saved is zero by construction", rows.get("memory_saved_bytes") == "0")
check("six attention layers", rows.get("attention_layer_count") == "6" and rows.get("attention_layers") == "3,7,11,15,19,23")
check("K row crosses the unit", "rows_cross_unit" in rows.get("tensor:cache_k_l3", ""))
check("unit is the minimum granularity", rows.get("unit_bytes") == str(UNIT) and rows.get("vmm_granularity_minimum") == str(UNIT))

code, rows, faults = run(control_log(), "device_default")
check("control holds", code == 0 and rows["verdict"] == "layout_holds", "; ".join(faults))
check("control reports no accounting", rows.get("kv_physical_mapped_bytes") == "n/a")

code, rows, faults = run(subject_log(), "device_default")
check("a paged subject fails a control expectation", code == 1 and any("kv_buffer_kind reads paged_kv_vmm" in f for f in faults))

code, rows, faults = run(subject_log(mapped=total - UNIT), "paged_kv_vmm")
check("under-mapped buffer refused", code == 1 and any("physical_mapped_bytes differs" in f for f in faults))

bad = [tensor_line("cache_k_l3", "q8_0", K_ROW, K_BYTES, 0),
       tensor_line("cache_v_l3", "q4_0", V_ROW, V_BYTES, K_BYTES + 128, start="no")]
code, rows, faults = run(subject_log(tensors=bad), "paged_kv_vmm")
check("misaligned start refused", code == 1 and any("misaligned" in f and "cache_v_l3" in f for f in faults))

bad = [tensor_line("cache_k_l3", "q8_0", K_ROW, K_BYTES, 0),
       tensor_line("cache_r_l0", "f32", 4096, UNIT, K_BYTES)]
code, rows, faults = run(subject_log(tensors=bad), "paged_kv_vmm")
check("recurrent tensor in the paged buffer refused", code == 1 and any("outside the attention KV set" in f for f in faults))

bad = [tensor_line("cache_k_l3", "q8_0", K_ROW, K_BYTES, 0),
       tensor_line("cache_v_l3", "q4_0", V_ROW, V_BYTES, K_BYTES - UNIT)]
code, rows, faults = run(subject_log(tensors=bad), "paged_kv_vmm")
check("overlapping extents refused", code == 1 and any("overlap" in f for f in faults))

code, rows, faults = run(subject_log().replace("RS buffer size", "XX buffer size"), "paged_kv_vmm")
check("absent recurrent store refused", code == 1 and any("RS buffer size" in f for f in faults))

code, rows, faults = run(subject_log(), "paged_kv_vmm", ("--expect-tensors", "12"))
check("census count of twelve agrees", code == 0, "; ".join(faults))
code, rows, faults = run(subject_log(), "paged_kv_vmm", ("--expect-tensors", "14"))
check("census count of fourteen refused", code == 1 and any("census predicts 14" in f for f in faults))

only_k = [tensor_line("cache_k_l3", "q8_0", K_ROW, K_BYTES, 0)]
code, rows, faults = run(subject_log(tensors=only_k), "paged_kv_vmm")
check("a lone tensor fails coverage", code == 1 and any("padded tensor extents sum" in f for f in faults)
      and any("without both K and V" in f for f in faults))

code, rows, faults = run(subject_log().replace("nbytes=35651584", "nbytes=1"), "paged_kv_vmm")
check("nbytes disagreeing with the geometry refused", code == 1 and any("disagrees with row_bytes" in f for f in faults))

code, rows, faults = run(subject_log().replace("row_bytes=544", "row_bytes=512"), "paged_kv_vmm")
check("row size disagreeing with the type refused", code == 1 and any("disagrees with type q8_0" in f for f in faults))

zero = subject_log().replace("unit_bytes=%d" % UNIT, "unit_bytes=0").replace("granularity_minimum=%d" % UNIT, "granularity_minimum=0")
code, rows, faults = run(zero, "paged_kv_vmm")
check("zero unit refused", code == 1 and any("reads zero" in f for f in faults))

code, rows, faults = run(subject_log().replace("paged_kv_tensor name=cache_v_l23 type=q4_0", "paged_kv_tensor name=cache_v_l23 type="), "paged_kv_vmm")
check("a malformed record line refused", code == 1 and any("match no record pattern" in f for f in faults))

code, rows, faults = run(subject_log().replace("312.00 MiB", "310.00 MiB"), "paged_kv_vmm")
check("KV size line disagreeing with the reservation refused", code == 1 and any("KV buffer size line" in f for f in faults))

names = ",".join("cache_%s_l%d" % (operand, layer) for layer in LAYERS for operand in ("k", "v"))
code, rows, faults = run(subject_log(), "paged_kv_vmm", ("--expect-names", names))
check("census names agree", code == 0, "; ".join(faults))
code, rows, faults = run(subject_log(), "paged_kv_vmm", ("--expect-names", names.replace("cache_v_l23", "cache_v_l24")))
check("census names differing refused", code == 1 and any("differ from the census" in f for f in faults))

code, rows, faults = run(subject_log().replace("KV buffer size", "XX buffer size"), "paged_kv_vmm")
check("absent KV size line refused", code == 1 and any("exactly one KV buffer size line" in f for f in faults))
code, rows, faults = run(control_log().replace("KV buffer size", "XX buffer size"), "device_default")
check("absent KV size line refused on a control", code == 1)

code, rows, faults = run(subject_log().replace("kv_buffer_kind=paged_kv_vmm buffer=CUDA0", "kv_buffer_kind=paged_kv_vmm buffer=CPU"), "paged_kv_vmm")
check("kind line naming another buffer refused", code == 1 and any("names" in f and "CPU" in f for f in faults))

zero_dims = subject_log().replace("ne0=512", "ne0=0").replace("row_bytes=544", "row_bytes=0").replace("row_bytes=288", "row_bytes=0")
code, rows, faults = run(zero_dims, "paged_kv_vmm")
check("zero dimensions refused", code == 1 and any("zero dimension" in f for f in faults))

code, rows, faults = run(subject_log().replace("alloc_bytes=35651584", "alloc_bytes=35652128"), "paged_kv_vmm")
check("alloc bytes outside the padding rule refused", code == 1 and any("padding rule" in f for f in faults))

layout = ",".join("cache_k_l%d=q8_0:512,cache_v_l%d=q4_0:512" % (layer, layer) for layer in LAYERS)
code, rows, faults = run(subject_log(), "paged_kv_vmm", ("--expect-layout", layout, "--expect-cells", "65536"))
check("census layout and cells agree", code == 0, "; ".join(faults))
code, rows, faults = run(subject_log(), "paged_kv_vmm", ("--expect-layout", layout.replace("cache_k_l3=q8_0:512", "cache_k_l3=q8_0:1024")))
check("census layout differing refused", code == 1 and any("census predicts q8_0:1024" in f for f in faults))
code, rows, faults = run(subject_log(), "paged_kv_vmm", ("--expect-cells", "32768"))
check("cell count differing from the caller refused", code == 1 and any("32768 were expected" in f for f in faults))

reshaped = subject_log().replace("ne1=65536 ne2=1", "ne1=32768 ne2=2")
code, rows, faults = run(reshaped, "paged_kv_vmm")
check("tensors reshaped against the size line refused", code == 1 and any("where the cache holds 65536 cells over 1 streams" in f for f in faults))

code, rows, faults = run(subject_log().replace("llama_kv_cache: size =", "llama_kv_cache: xize ="), "paged_kv_vmm")
check("absent cells line refused", code == 1 and any("naming cells and streams" in f for f in faults))

grown = subject_log().replace("virtual_reserved_bytes=%d physical_mapped_bytes=%d" % (total, total),
                              "virtual_reserved_bytes=%d physical_mapped_bytes=%d" % (total + UNIT, total + UNIT)).replace("312.00 MiB\n", "314.00 MiB\n", 1)
code, rows, faults = run(grown, "paged_kv_vmm")
check("reservation above the rounded request refused", code == 1 and any("rounded up to the unit" in f for f in faults))

code, rows, faults = run(subject_log().replace("extent_aligned=yes\n", "extent_aligned=yesBROKEN\n", 1), "paged_kv_vmm")
check("a record with trailing garbage refused", code == 1 and any("match no record pattern" in f for f in faults))

print("failures=%d" % failures)
sys.exit(1 if failures else 0)
