# The one-variable build ladder: three levers measured, none moved

`scripts/build-llama-cuda.sh` folds every lever into a configuration digest,
so each arm below is one named closure differing from the candidate
844181cfaedc by one variable. The measurement schema per closure: the
cuda_payload line (architecture, cubin count, PTX count), library size, three
cold starts with the page cache dropped through `sudo -n`, three warm starts,
and where a rate claim is at stake a mirrored pp512/tg128 pair per runtime
class in repository order (2B, 0.8B, 4B) through the served flags. A closure
whose deltas sit inside the registered floors is recorded and refused
promotion.

## Fatbin compression (arch held at 89)

| mode | libggml-cuda.so | cold start median | warm start |
| --- | ---: | ---: | ---: |
| size | 80 MB | 13.5 s | 1.5 s |
| speed | 246 MB | 12.9 s | 1.4 s |
| none | 499 MB | 12.8 s | 1.4 s |

Cold start is model-read dominated; decompression is about 0.6 s of it, and
the run caught ambient outliers of 21 and 63 s from concurrent disk work,
each larger than the whole effect. `size` stays: 0.6 s of cold start does not
buy 166 to 419 MB of disk and page cache.

## GGML_LTO (host-only, verified)

The configured LTO tree carries `-flto=auto` on host objects and zero
`-dlto`, `lto_89`, or `code=lto` markers in build.ninja, so the flag reaches
no device code at this pin and the kernel inventory cannot move. Mirrored
pp512/tg128 pairs on closure 9b1e40a071f2 against the candidate: 2B
14309/222.8 against 14306/224.1, 0.8B 22218/299.3 against 22573/297.4, 4B
6403/110.7 against 6352/109.9. Every delta sits inside the 0.7 to 1.6%
floors with no direction shared across classes. LTO stays OFF.

## CUDA module loading

CUDA_MODULE_LOADING=LAZY loads the 0.8B to one token in 1.34 s at 1.21 GB
maximum RSS; EAGER takes 1.79 s at 1.87 GB, paying 434 MB of kernel preload
visible even on a bare context. The unset default measures identical to LAZY,
so production keeps the default and sets nothing. A loader-thread-count arm
was not exercised in this ladder; the CUDA 13.3 programming guide documents
CUDA_BINARY_LOADER_THREAD_COUNT (0 maps to the default single thread), so
the earlier reading that no such variable exists is corrected to
not-previously-exercised. loader-thread-count.tsv carries the arm: three
one-token 0.8B loads each at unset, 1, 2, and 4 on the promoted binary
read 1.28 to 1.30 s wall at 1238.1 to 1238.7 MB maximum RSS with no
ordering by setting, because the default LAZY module loading leaves the
loader threads nearly nothing to parallelize at this model size. The
variable stays unset.

## Dependency trimming

trim-ladder-summary.tsv holds seven one-variable arms over the schema-2
89-real CUDA-only baseline 1613a1c3ef06 at thresholds 10/12: the embedded
Web UI, LLAMAFILE, CPU repacking, OpenMP, OpenSSL, and peer copy, each
toggled alone. Every arm passes the strict CUDA0 one-token placement check.
The trims buy 4 KB (peer copy) to 3.13 MB (embedded UI) of the 80.6 MB bin
tree, and one-repetition pp512/tg64 reads on the 2B sit inside this host's
ambient span: tg64 spans 230.9 to 236.4 across all seven arms with no arm
outside 2.4% of baseline, and the largest prefill deviation is openmp-off
at -6.2% on a single repetition. Nothing clears the drift floor against a
named capability loss -- the pinned browser UI, HTTPS, the CPU SGEMM and
repack paths llama-quantize and CPU research consume, and host threading --
so every lever keeps its default.

## Standing verdicts

The promoted tuple direction after this ladder: 89-real, CUDA only, NCCL
off, graphs on, all served flash-attention quant pairs, VMM on, compression
size, native host, LTO off, module loading at the driver default, MMVQ
thresholds awaiting the candidate patch admission. Promotion into serving
remains behind the placement, teardown, and mixed-roster admission contract.
