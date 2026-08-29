# The Setting That Doubled Decode, and the Gate That Rejected 9B

## The literal environment state responsible for 2.02x decode

`remote/radv-low-priority-env.sh` unsets every `GGML_VK_*` variable before its
profile case, so a profile is defined by what it exports afterwards. The
`low-async` case exports exactly one variable:

```sh
low-async)
    export GGML_VK_MAX_NODES_PER_SUBMIT=16
    ;;
```

`GGML_VK_SERIALIZE_SUBMISSIONS` is therefore **absent from the environment**,
not set to `0`. ggml reads it with a presence test in some paths, so the absent
state and the `=0` state are not interchangeable and the manifest records the
absent state. `low-serialized` exports it as `1`, and that single difference
carried the measured 1.348 to 2.718 decode tok/s change on a chat request. Node
count did not: 32 to 512 moved the same request 1.348 to 1.396.

## The host-memory gate double-counts the model

`remote/model-memory-preflight.sh` computes

```sh
required_host_bytes=$((required_vulkan_bytes + model_bytes + desktop_reserve_bytes))
```

On an APU the Vulkan heap is carved from system RAM, so `required_vulkan_bytes`
already covers the resident copy of the weights. Adding `model_bytes` charges
the weights a second time. The file itself reaches the Vulkan buffers through a
mapping whose pages are reclaimable page cache, which `MemAvailable` already
counts as available.

For Qwen3.8-9B-Q4_K_M against a 7,168 MiB Vulkan request the gate computed
7.516 + 5.780 + 4.295 = 17.591 GB required against 15.373 GB available and
rejected the load. Without the second charge the requirement is 11.811 GB,
which the same machine satisfied.

The second charge is spurious, measured on the running 4B server rather than
argued. `/proc/PID/smaps_rollup` for the live process holding 2.74 GB of
weights reports:

```
Rss:              229044 kB
Private_Dirty:    156092 kB
Private_Clean:     26032 kB
Swap:                  0 kB
```

229 MB resident and no swap. The weights are not in the process's address
space as host pages; they reach the Vulkan heap through a mapping whose file
pages are reclaimable and, at 26 MB of `Private_Clean`, largely already
reclaimed. Host demand beyond the Vulkan allocation is roughly 0.23 GB, not
the 2.74 GB the gate charges.

The gate is nonetheless left as written. Relaxing admission control on one
model's measurement would trade the desktop's protection for a checkpoint that
has not been shown to run well here, and the 9B figure is the confirmation
that would license the change: load it with the gate relaxed on an idle
machine and record whether peak resident host memory tracks the 4B result or
climbs toward `vulkan + model`. The 4B path is unaffected either way, since its
requirement clears the gate with the second charge included.

## The laptop was not idle during the rejection

The rejecting run also recorded 8.6 GiB of swap in use with zram0 at 7.8 of
8 GiB. A concurrent desktop session held a QEMU guest at 3.0 GiB resident and
roughly twenty Firefox content processes. Under that load the rejection is the
guard honoring its contract rather than a miscalculation, and the relaxed-gate
measurement belongs on an otherwise idle machine.

## Bandwidth model for larger checkpoints

The distill decodes 2.721 tok/s against 2.783 GB of weights, an effective
7.57 GB/s of weight traffic per second of decode. Treating decode as
bandwidth-bound predicts:

| Checkpoint | Weight bytes | Predicted decode tok/s |
| --- | ---: | ---: |
| Qwen3.8-9B-Q4_K_M | 5.780 GB | 1.31 |
| Qwen3.8-27B-UD-Q2_K_XL | 9.829 GB | 0.77 |
| Qwen3.8-27B-UD-IQ3_XXS | 10.935 GB | 0.69 |

These are extrapolations from one measured point through the origin. The 9B
load is the falsifier: a measured decode within roughly 15% of 1.31 tok/s
confirms the linear model and licenses the 27B row, while a substantially lower
figure means dequantization on two compute units, not memory traffic, sets the
rate -- in which case the IQ3 quantizations are slower than the table implies,
since they cost more arithmetic per byte.

`Qwen3.8-27B-UD-IQ3_S.gguf.part`, a truncated 12.04 GB download, was removed.
It was reachable only as a resumable partial of a benchmark artifact whose
complete siblings remain pinned in `evidence/model-candidate-audit.md`, and a
truncated GGUF loads as a crash rather than as a model.
