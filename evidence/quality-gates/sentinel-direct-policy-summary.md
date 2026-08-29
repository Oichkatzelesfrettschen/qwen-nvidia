# Direct CPU Policy Quality Gate

The launcher and guard scripts apply their scheduling policy directly, so an
inherited `QWEN_ONE_CORE_ACTIVE` or `QWEN_GUARD_CPU_ACTIVE` value cannot bypass
CPU affinity, nice priority, or I/O priority. The wrapper also removes both
legacy names before executing a target.

The first remote run rejected the test fixture because its 30-second synthetic
server expired before the watchdog-loss monitor started. The monitor returned
setup status 2 for a missing server, which is the correct production behavior.
`qwen-apu-quality-gates-sentinel-bypass-rejected.log` retains that falsifier.

Negative cases now use persistent synthetic processes whose termination is
owned by the monitor or test cleanup. The final remote suite starts with both
sentinels absent and proves:

- the model policy reports CPU 0, nice 19, and idle I/O;
- both guards report CPU 1 and nice 0;
- normal exit and every synthetic termination control pass;
- the real Qwen3.5-4B model initializes with LOW Vulkan queue priority;
- CPU tensor and graph placement are rejected;
- the four-patch source replay matches llama.cpp commit
  `f280b26983ad0fdb705a0d9ebf0503e76f2899b0`; and
- pacing, runtime submit-limit, and MEDIUM graphics-service probes pass.

`status/sentinel-direct-policy.status` contains `0`. The raw imported hashes
precede identifier sanitization in `PRE_SANITIZATION_SHA256SUMS`.
