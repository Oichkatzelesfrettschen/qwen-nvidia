# Explicit tensor placement doubles 9B prefill

`evidence/ada/baseline-sweep-01/` measured four checkpoints with `-ngl 99`
alone. This sweep measures the same four through `scripts/cuda-runtime-env.sh`
with `-ot .*=CUDA0`, which is the placement `qwen-capacity-policy.sh` gives the
server, and under the `LLAMA_NO_CPU_FALLBACK=1` the wrapper exports.

| checkpoint | prefill 01 | prefill 02 | decode 01 | decode 02 |
| --- | ---: | ---: | ---: | ---: |
| Qwen3.5-0.8B Q8_0 | 22460.53 | 22769.94 | 312.74 | 310.50 |
| Qwen3.8-2B distill Q4_K_M | 14077.38 | 14748.05 | 232.47 | 231.37 |
| Qwen3.8-4B distill Q4_K_M | 6506.27 | 6703.23 | 114.56 | 113.54 |
| Qwen3.8-9B distill Q4_K_M | 2183.61 | 4410.81 | 67.16 | 67.91 |

The 9B's prefill doubles, 102% up, while its decode moves 1.1%. The other three
move 1.4 to 4.8% on prefill and under 1% on decode, which is the scale of the
sweeps' own forward-to-reverse spans.

`-ngl 99` offloads every repeating layer and leaves the scheduler free to place
what remains; on the largest checkpoint here that left enough on the host to
halve a prefill step, and left decode alone because decode reads the offloaded
trunk. The guard makes the placement observable rather than silent: with
`LLAMA_NO_CPU_FALLBACK=1` set and no `-ot`, `llama-bench` refuses to load at
all, which is how the host placement was found. The appliance already served
under `--override-tensor '.*=CUDA0' --fit off`, so sweep 01 measured a placement
the serving path never uses.

A rate compared across the two sweeps therefore compares harnesses. Sweep 02 is
the reference for this host, and `scripts/models.tsv` carries its four paired
means.

## What stays open

Which tensors the scheduler left on the host at `-ngl 99` is unread here. The
run establishes the size of the effect and that it grows with the checkpoint,
not the identity of the buffer.
