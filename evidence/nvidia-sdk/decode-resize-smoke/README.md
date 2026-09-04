# nvImageCodec to CV-CUDA, device-resident between the two

`scripts/run-nvidia-sdk-smoke.sh` ran once on the RTX 4070 Ti under the GPU
owner lock, with the operator's telemetry llama-server stopped for the window
and the desktop compositor and a browser GPU process recorded as the client
set (`ownership.txt`). `summary.tsv` carries the compiler, the fixture digest,
and the exit; `smoke.txt` carries the binary's own claim line;
`device-environment.tsv` binds the run to driver 610.57.04 and CUDA 13.3.

What the binary proves, read from `scripts/nvidia-sdk-smoke/decode-resize.cpp`:

- The input is one JPEG, drawn by `make-fixture.py` from a declaration in its
  own source, 640x480, digest in `summary.tsv`.
- nvImageCodec decodes it on device 0: `execution.device_id` names the
  device, the target image is `NVIMGCODEC_IMAGE_BUFFER_KIND_STRIDED_DEVICE`
  over a `cudaMallocAsync` allocation, and `target_info.cuda_stream` is the
  stream the program created, so the decode runs on the caller's stream.
- CV-CUDA wraps that same allocation as an NHWC U8 tensor
  (`nvcvTensorWrapDataConstruct` over the decoded pointer) and
  `cvcudaResizeSubmit` runs on the same stream into a 224x224 RGB8 tensor;
  no copy sits between decode and resize.
- The transfers are the encoded bytes in and the resized pixels out, one
  each: `host_to_device_transfers=1 device_to_host_transfers=1`.
- Both buffers are device-resident, read back from the pointer attributes:
  `decoded_on_device=yes output_on_device=yes`.
- The output is 224x224 with content digest `output_fnv1a=b065a1a396a2e27a`,
  which a rerun on the same stack compares against.

The two loader lines ahead of the claim report that nvJPEG2000 and nvTIFF are
absent; both stay out of `scripts/nvidia-sdk-artifacts.tsv` until a consumer
needs them, and the JPEG path is unaffected.

The smoke resizes and does not normalize: a normalize operator belongs to a
consumer that states its mean and scale, and none exists in this tree yet.
