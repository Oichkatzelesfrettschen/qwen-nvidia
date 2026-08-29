# Qwen3.5-4B interrupted 32K prefill

The guarded request targeted 32,000 prompt tokens and 64 decode tokens in a
32,768-token server context. An active desktop user reported degraded system
performance, so the request stopped after the server completed 20,992 prompt
tokens. The stop is an operational failure for concurrent desktop use, not a
completed 32K benchmark.

| Measurement | Observation |
| --- | ---: |
| Completed prompt tokens | 20,992 |
| Cumulative prompt time | 1,661.52 s |
| Cumulative prefill rate | 12.63 tok/s |
| First 512-token microbatch rate | 26.04 tok/s |
| Last completed 512-token marginal rate | 8.39 tok/s |
| Decode rate | not run |
| Telemetry samples | 337 |
| Minimum MemAvailable | 11,631,404 KiB |
| Maximum swap-in per sample | 0 bytes |
| Maximum temperature | 87,750 millicelsius |
| Maximum server RSS | 213,672 KiB |
| Maximum server peak RSS | 242,668 KiB |
| Maximum GTT used | 2,809,393,152 bytes |
| Maximum VRAM used | 1,835,311,104 bytes |
| Matching live kernel hazards | 0 |

`qwen35-4b-c32k-server.log` retains allocation, exact prompt progress, and
termination records. `qwen35-4b-c32k-telemetry.log` retains the five-second
resource samples. `qwen35-4b-c32k-kernel-hazards.log` contains only its watcher
header and hazard pattern, so no matching event entered the live stream.

The runtime policy caps server context at 24,576 tokens and benchmark prompts
at 24,000 tokens. Contexts above 24K remain capacity evidence only and cannot
start through the operational launcher. A one-second runtime guard also stops
the server on a GPU busy sample above 75%; future tok/s results require a
microbatch pacer that remains within that ceiling.
