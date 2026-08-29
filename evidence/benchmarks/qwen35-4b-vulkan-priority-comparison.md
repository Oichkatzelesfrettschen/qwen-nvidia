# Qwen3.5-4B Vulkan Priority Comparison

## Scope

The comparable completed arms use the same Qwen3.5-4B Q4_K_M artifact, 4,096
token context, 46-token prompt, 128-token decode request, strict `Vulkan0`
tensor placement, CPU 0 at nice 19, and independent guards on CPU 1. The
MEDIUM-priority graphics-family probe submits every 16 ms and rejects a fence
that exceeds 20 ms. Every run retains server, telemetry, graphics-service, and
kernel-hazard evidence under its matching directory.

The idle probe supplies the service baseline. The first `paced-60` attempt is
retained because its 20.913 ms startup breach exposed probe contention before
CPU isolation. The CPU-isolated paced retry passed graphics service but stopped
at the separate 75% aggregate-busy ceiling. The 32-node async arm falsified
that queue depth with a 20.017 ms fence. The 16-node async arm is the bounded
async result.

## Results

| Profile | Result | Prompt tok/s | Decode tok/s | MEDIUM mean | MEDIUM P99 | MEDIUM max | GPU mean/max | Max temp |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Idle, 16 ms probe | pass, 400 samples | n/a | n/a | 0.510 ms | 1.886 ms | 7.343 ms | n/a | n/a |
| `paced-60`, initial | reject, service deadline | n/a | n/a | 1.078 ms | 20.913 ms | 20.913 ms | 4% / 4% | 67.500 C |
| `paced-60`, CPU-isolated | reject, 78% busy | n/a | n/a | 0.456 ms | 2.208 ms | 9.660 ms | 53.22% / 78% | 74.375 C |
| `low-serialized`, 32 nodes | pass | 11.437 | 1.316 | 0.288 ms | 2.000 ms | 4.986 ms | 67.42% / 94% | 76.750 C |
| `low-async`, 32 nodes | reject, service deadline | n/a | n/a | 0.344 ms | 2.617 ms | 20.017 ms | 88.54% / 99% | 74.125 C |
| `low-async`, 16 nodes | pass | 14.103 | 2.713 | 0.283 ms | 2.581 ms | 11.185 ms | 93.13% / 99% | 84.375 C |

No retained kernel watcher matched a ring timeout, GPU reset, VM fault, device
loss, OOM, or oom-kill record. The passing async arm raises prompt throughput
23.31% and decode throughput 106.12% over serialization. Expressed as the cost
of serialization, the one-in-flight profile loses 18.90% prompt throughput and
51.48% decode throughput relative to the admitted async arm.

## Decision

`low-serialized` remains the default because one 50-second async request does
not prove interactive desktop latency. `low-async` with 16-node submissions is
an admitted experimental profile for the external desktop-input oracle and a
longer thermal soak. The 32-node async profile is rejected. Aggregate GPU busy
remains telemetry for both LOW profiles because the independent MEDIUM queue
received bounded service while aggregate busy reached 99%.

The earlier 3.79 prompt tok/s and 0.677 decode tok/s paced result used a
different 16-token request and remains a transport control rather than a row in
the equal-request comparison.
