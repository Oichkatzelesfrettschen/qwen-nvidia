# Media decode placement and preprocessing equivalence

The served vision path takes an image in four host stages ahead of the
encoder. `tools/mtmd/mtmd-helper.cpp` decodes the client's bytes with
stb_image on the host into interleaved RGB8; `tools/mtmd/mtmd-image.cpp`
resizes that with a Pillow-exact fixed-point kernel on the host, bicubic for
the Qwen3.5 projector and bilinear for LFM2, then normalizes to F32; and
`clip.cpp` uploads the planar tensor as the encoder's `inp_raw`. A
device-resident media input replaces the first two stages with a decode
whose pixels land on the device and a resize that runs there, and this
record is what that design is held to: where each codec's decode can run on
this device, what the decoded pixels are against the served decode, what
the library moves to reach a device target, and what a CV-CUDA resize
changes against the projector's own preprocessing.

`scripts/run-media-decode-placement.sh` runs `scripts/media-decode-probe/
media-placement.cpp` under the GPU owner lock. The probe decodes every
fixture through nvImageCodec 0.9.0 under five backend policies, each a
decoder created with that allowed-backend list, with the debug messenger
retained so the extension that processed each image is named by the
library rather than inferred; compares each decode byte for byte against
stb_image; builds the projector's own preprocessor from libmtmd over the
mmproj file with `clip_init` on the host, so the reference entries are the
exact F32 tensors the encoder would read; and holds four CV-CUDA 0.17.0
resizes of the device plane to those entries after the same normalization.
A second pass runs each policy alone under Nsight Systems with the
preprocessing off, and `scripts/read-nsys-embd-transfers.py` lists every
memory copy against the encoded and decoded byte counts.

## Preregistration

Stated ahead of the run, with the reading each outcome takes.

- **PNG placement.** nvImageCodec 0.9.0 ships no GPU PNG decoder; the
  OpenCV extension is the one PNG codec in the extension directory. The
  `gpu`, `hw`, and `hybrid` policies are expected to refuse every PNG and
  the `cpu` policy to decode it, so a PNG reaching a device target is a
  CPU decode plus one upload of the decoded plane, and the Nsight capture
  of the `cpu` policy is expected to show one host-to-device copy of
  exactly `decoded_bytes` per PNG. A GPU policy decoding a PNG refutes
  this and changes the design from a declared CPU media adapter to a
  device decode.
- **JPEG placement.** `nvjpeg_cuda_decoder` is expected to take baseline
  and progressive JPEG under the `any` and `gpu` policies, writing the
  device plane directly, so the capture shows no host-to-device copy of
  `decoded_bytes` under `gpu`. The hardware engine policy (`hw`) is
  expected to refuse on AD104, whose NVJPG unit nvJPEG's hardware backend
  does not drive at this release; a success there is the finding.
- **Decoded pixels.** A PNG decode is lossless, so every successful policy
  is expected to reproduce the stb_image bytes exactly, and a differing
  byte refutes the decoder rather than the format. A JPEG decode may
  differ between conforming decoders in the IDCT and upsampling rounding;
  the record states the differing-byte fraction and the maximum absolute
  difference per decoder, and a maximum above 4 on an 8-bit channel reads
  as a chroma-upsampling difference rather than rounding and is named as
  such.
- **Preprocessing contract.** CV-CUDA's `Resize` interpolates without the
  antialiasing Pillow applies on downscale and its cubic kernel takes
  a = -0.75 where Pillow takes a = -0.5, and `HQResize` antialiases with
  its own filter tables, so no arm is expected to reproduce the reference
  F32 entries element for element. The expected outcome is a separate
  preprocessing contract, stated per projector with the closest arm and
  its maximum byte-domain difference, and an arm reading `identical` on
  every fixture of a projector is the outcome that would let the resize
  move to the device under the existing contract.
- **Model independence of decode.** The decode rows are a property of the
  bitstream and the library; `summarize-media-decode-placement.py`
  refuses a run whose decode digests differ between the two projector
  directories.

Runtime transcoding is refused by construction: every JPEG fixture is
encoded once by `make-fixtures.py` from the lossless drawing, and the
probe hands each decoder the bytes the fixture holds.

## Run 03

`run-03/` is the retained run on the RTX 4070 Ti under driver 610.57.04 and
CUDA 13.3 (`device-environment.tsv`), with the operator's telemetry server
stopped for the window and the compositor, a browser, and Discord recorded
as the client set (`ownership.txt`). The probe compiled with GCC 15.3
against the promoted closure's libmtmd (`summary.tsv` carries its digest
and every fixture's SHA-256); the fixtures are the four tracked images under
`scripts/quality-images/`, `scripts/handoff-images/bars-large.png`, and the
six encodings `make-fixtures.py` writes, regenerated by the runner rather
than retained. Both projector directories carry identical decode rows, and
`verdict.txt` reads `completed` with zero refusals. Runs 01 and 02 were the
same campaign with two probe defects, a decoder-creation refusal treated as
a fatal error and the Qwen3.5 pad geometry left out of the comparison, and
are discarded; the numbers below are run 03's alone.

### Decode placement

| fixture | codec | `any` decoder | `gpu` | `hw` | `hybrid` | `cpu` decoder | placement |
| --- | --- | --- | --- | --- | --- | --- | --- |
| bars.png, bars-rgba.png, bars-palette.png, shapes.png, page.png, bars-large.png | png | opencv_png_decoder | refused | refused | codec_unsupported | opencv_png_decoder | CPU decode plus one upload |
| bars-baseline-420.jpg, bars-baseline-444.jpg, bars-progressive.jpg, bars-gray.jpg, zebra.jpg | jpeg | nvjpeg_cuda_decoder | refused | refused | nvjpeg_cuda_decoder | libjpeg_turbo_decoder | device decode, hybrid backend |

The `gpu` and `hw` policies refuse at `nvimgcodecDecoderCreate` with
`arch_mismatch` for every fixture: on this device and release no loaded
extension offers a GPU_ONLY or HW_GPU_ONLY decoder, so nvJPEG's path here
is the HYBRID_CPU_GPU kind, entropy decoding on the host and the inverse
transform and color conversion on the device. The preregistered PNG
expectation holds: the OpenCV extension is the one PNG decoder, and the
`hybrid` policy reports the codec unsupported. The preregistered `hw`
refusal holds, and the preregistered `gpu` success for JPEG is refuted:
nvJPEG on this stack is reachable through the hybrid kind alone.

### Decoded pixels against stb_image

Every PNG decode is byte-identical to the stb_image decode under both
policies that decode it, across the RGB, RGBA, and palette encodings, so a
PNG's device plane carries the served path's bytes exactly.

| JPEG fixture | nvjpeg_cuda_decoder differing bytes | max abs | libjpeg_turbo differing bytes | max abs |
| --- | ---: | ---: | ---: | ---: |
| bars-baseline-420.jpg | 7785 of 280800 | 3 | 6971 | 3 |
| bars-baseline-444.jpg | 1479 of 280800 | 3 | 850 | 2 |
| bars-progressive.jpg | 7785 of 280800 | 3 | 6971 | 3 |
| bars-gray.jpg | 1290 of 280800 | 1 | 831 | 1 |
| zebra.jpg | 128447 of 1843200 | 3 | 96612 | 3 |

A JPEG decode differs between conforming decoders inside the rounding of
the inverse transform and the chroma upsampling; every maximum sits at or
under 3, inside the preregistered rounding class, and the 4:2:0 fixtures
differ more than the 4:4:4 one because upsampling is where the three
decoders part. The progressive fixture decodes to the same bytes as the
baseline 4:2:0 one under every decoder, so the scan order changes nothing
in the output.

### Transfers, read from the capture

`nsys/<policy>/transfers.tsv` lists every copy of the decode-only pass
under each policy; `gpu` and `hw` opened no device work and hold no copy
table.

| policy | host-to-device | device-to-host |
| --- | --- | --- |
| `cpu` | one copy of exactly `decoded_bytes` per fixture, 11 copies, 6969600 bytes | the probe's 11 readbacks |
| `hybrid` | one copy per JPEG at 190592, 300800, 300800, 570752, and 1843712 bytes, none equal to `encoded_bytes` or `decoded_bytes` | the probe's 5 readbacks |
| `any` | the 6 PNG uploads of `decoded_bytes` plus the 5 JPEG copies above | the probe's 11 readbacks |

Under the `cpu` policy the library decodes on the host and uploads the
plane it was asked to place on the device, so the CPU media adapter's cost
is one upload of the decoded size and nothing else. Under `hybrid` the
upload is the host-decoded coefficient data, about two bytes per sample
with the size following the chroma subsampling and MCU alignment, and the
decoded plane is written on the device; the 4:2:0 baseline and progressive
fixtures upload the same 300800 bytes, the 4:4:4 one 570752, the grayscale
one 190592, and the 960x640 photograph 1843712.

### Preprocessing contract

The reference is the projector's own preprocessor over the stb_image
pixels: `dyn_size` for the Qwen3.5 projector, bicubic under `PAD_CEIL` with
a black canvas and a centered offset, and the LFM2 single-tile path,
bilinear under `PAD_NONE`. The probe reproduces the pad geometry from the
same arithmetic and resamples with CV-CUDA to the resample size the
reference used, so the rows compare the resample alone; bars-large.png and
zebra.jpg tile on LFM2 and zebra.jpg is served at its own size on Qwen3.5,
so those rows are not measured.

| projector | fixture | closest arm | elements differing | max abs, 8-bit levels |
| --- | --- | --- | ---: | ---: |
| qwen35-2b (bicubic, pad ceil) | bars-large.png | hqresize_cubic_aa | 0.12% | 11 |
| | shapes.png | hqresize_cubic_aa | 0.46% | 9 |
| | bars.png, bars-rgba.png, bars-palette.png | hqresize_cubic_aa | 0.86% | 22 |
| | bars-gray.jpg | hqresize_cubic_aa | 2.1% | 18 |
| | bars-baseline-444.jpg | hqresize_cubic_aa | 2.2% | 19 |
| | bars-baseline-420.jpg, bars-progressive.jpg | hqresize_cubic_aa | 2.6% | 18 |
| | page.png | hqresize_cubic_aa | 4.7% | 22 |
| lfm25-vl-450m (bilinear, no pad) | page.png | hqresize_linear_aa | 0.03% | 1 |
| | shapes.png | resize_linear | 0.07% | 1 |
| | bars.png, bars-rgba.png, bars-palette.png | hqresize_linear_aa | 0.64% | 1 |
| | bars-gray.jpg | hqresize_linear_aa | 1.8% | 1 |
| | bars-baseline-444.jpg | hqresize_linear_aa | 1.9% | 1 |
| | bars-baseline-420.jpg, bars-progressive.jpg | hqresize_linear_aa | 2.3% | 1 |

No arm reads `identical`, which is the preregistered outcome: a device
resize is a separate preprocessing contract on both projectors. The two
contracts differ in kind. LFM2's bilinear reference is met by `HQResize`
with antialiasing to within one 8-bit level on every measured fixture, and
by plain `Resize` where the target is an upscale (shapes.png, 320x200 to
352x224), which is a rounding difference between two antialiased bilinear
kernels. The Qwen3.5 bicubic reference is met by the antialiased cubic arm
to within 9 to 22 levels on under 5% of elements, the gap between Pillow's
a = -0.5 kernel and CV-CUDA's, concentrated at the drawings' hard edges;
`Resize` without antialiasing differs on 2% to 20% of elements on both
projectors and is the wrong candidate for a downscale.

### What this record settles and what it leaves open

- A PNG input is a declared CPU media adapter plus one upload, chosen over
  refusal: the decode is byte-identical to the served path, the upload is
  one copy of the decoded plane, and no lossy transcode is involved.
- A JPEG input decodes on the device through nvJPEG's hybrid backend, with
  one coefficient upload per image and pixels inside the rounding class of
  the served decoder; a design that requires bit-identity with stb_image
  on JPEG has to decode on the host, and one that accepts a conforming
  decoder's rounding takes the device path.
- The resize is a separate contract on both projectors and is designed
  against the closest arm per projector; whether a one-level bilinear
  difference or a 22-level bicubic edge difference moves a served reply is
  a graded question a later arm answers on the served path, and is not
  claimed here.
- Tiled layouts (LFM2 above its tile threshold) and the LFM2 overview
  under padding stay unmeasured; the probe names them `tiled_layout`.
