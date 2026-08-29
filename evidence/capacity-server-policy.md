# Capacity Server Policy Evidence

## Claim and falsifiers

The capacity launcher supplies one immutable server policy before model load.
The claim fails if a caller can add or override a server argument, the process
escapes CPU 0, its CPU or I/O priority exceeds the desktop-safe values, the
server listens beyond localhost, more than one slot or thread is configured,
automatic fitting changes the requested context, a tensor can fall back to the
CPU, a context above 24,576 tokens starts, or speculative decoding becomes
active.

| Subclaim | Authority | Falsifier | Validation | Artifact |
|---|---|---|---|---|
| One slot and one thread are explicit | llama.cpp option parser and fixed argument sequence | A generated invocation omits or changes any of the three values | `remote/test-qwen-capacity-policy.sh` | Captured fake-server arguments |
| The desktop retains scheduling priority | `/proc/self/status`, `ps`, `ionice`, and the closed Vulkan profile | Affinity differs from CPU 0, nice differs from 19, I/O class differs from idle, LOW is absent, or inherited Mesa priority escapes | `remote/test-qwen-capacity-policy.sh` | Captured fake-server environment |
| The API remains local | llama.cpp `--host` option and fixed argument sequence | Host differs from `127.0.0.1` | `remote/test-qwen-capacity-policy.sh` | Captured fake-server arguments |
| Static UI admission is explicit | Validated directory plus fixed `--path` and `--ui` arguments | A missing `index.html` reaches llama.cpp or a headless launch enables UI | `remote/test-qwen-capacity-policy.sh` | Positive and negative static-path controls |
| Interactive routes require a secret | Generated mode-0600 key plus fixed `--api-key-file` argument | An empty key file reaches llama.cpp | `remote/test-qwen-capacity-policy.sh` | Positive and negative key-file controls |
| Operational context is bounded | `qwen-capacity-policy.sh` maximum context check | A value above 24,576 reaches llama.cpp | 24,576 positive and 24,577 negative boundary tests | Captured exit status and diagnostic |
| Cache overrides carry their own admission depth | Registry cache and attention tuple plus `QWEN_CACHE_OVERRIDE_CONTEXT_CEILING` | An overridden tuple reuses the registry tuple's ceiling, accepts a non-positive ceiling, or exceeds the registry ceiling | Override-ceiling positive and negative boundary tests | Captured fake-server arguments and diagnostics |
| Capacity caches remain bounded | llama.cpp option parser and fixed argument sequence | Checkpoints or RAM cache differ from zero, or context shift is enabled | `remote/test-qwen-capacity-policy.sh` | Captured fake-server arguments |
| RADV is the sole model backend | strict llama.cpp patch plus RADV environment wrapper | CPU tensor placement, CPU graph execution, another ICD, or llvmpipe proceeds | Post-build strict fallback tests | `evidence/strict-vulkan-placement.md` |
| Speculative decoding stays inactive | Closed argument surface with no draft options | Any `--spec-*` option reaches the server | `remote/test-qwen-capacity-policy.sh` | Captured fake-server arguments |

## Mechanism

`run-qwen-capacity-server.sh` runs the live host and Vulkan memory preflight,
then transfers control to `qwen-capacity-policy.sh`. The policy script accepts
no free-form server arguments and rejects every `LLAMA_ARG_*` environment
override. It supplies RADV device `Vulkan0`, complete layer offload, disabled
automatic fitting, one slot, one CPU thread, Q8/Q4 KV cache, zero recurrent
checkpoints, zero prompt RAM cache, and disabled context shift. The existing
RADV wrapper then applies CPU 0 affinity, nice level 19, idle I/O scheduling,
LOW Vulkan queue priority, the RADV ICD, and strict CPU-fallback rejection.
The default `low-serialized` profile fixes one in-flight submission, a 32-node
submission boundary, and no deliberate sleep. `paced-60` retains the 60% native
Vulkan duty-cycle control, while `low-async` is a separately guarded experiment.
The policy uses a 128-token
logical batch and 32-token microbatch so prompt ingestion yields to the
compositor at short graph boundaries.
The policy rejects context values above 24,576 before the RADV wrapper starts
llama.cpp. Each registry ceiling belongs to the cache-type and Flash Attention
tuple stored in the same row. Changing any tuple member requires a positive
`QWEN_CACHE_OVERRIDE_CONTEXT_CEILING` measured for that experiment, and the
policy rejects an override ceiling above the registry ceiling. The benchmark
client independently rejects prompt depths above 24,000 tokens so fixed decode
output retains context headroom.

The default capacity path keeps `--no-ui`. An interactive path must supply a
directory containing `index.html`; the closed policy then adds `--path`,
`--ui`, `--cors-origins localhost`, and a non-empty API-key file. The server
still binds `127.0.0.1`, and `remote/connect-qwen-webui.sh` forwards loopback to
loopback through SSH.

The first policy test falsified the original scheduler implementation because
`nice -n 19` adds 19 to an inherited nice value instead of selecting an
absolute value. An agent process at nice -4 therefore produced a child at nice
15. The RADV, memory-preflight, and build entry points now run
`renice -n 19 -p $$` before `exec`, and the policy test requires an observed
nice value of 19.

The binary gate verifies that the generated llama.cpp parser accepts every
option, `Vulkan0` names Raven2, forced CPU tensor and graph placement abort,
and the all-tensor Vulkan override completes a two-token request. The shell test
establishes construction and scheduling policy; the binary test establishes
runtime placement.

## Validation result

On 2026-08-24, local and remote warning-clean ShellCheck plus `sh -n` accepted
all launcher and test scripts. `test-qwen-capacity-policy.sh` returned
`qwen_capacity_policy=accepted`, and `test-radv-low-priority-env.sh` returned
`radv_environment=accepted`.

The 24K boundary regression accepts 24,576 and rejects 24,577. A direct 32K
launch attempt returns status 2 with `context size exceeds operational maximum`
before any llama.cpp process starts.

A remote end-to-end dry launch used an empty model fixture, a 4096-token
context, a 1 MiB synthetic Vulkan working set, and fake server port 18080. The
live preflight selected `AMD Radeon Graphics (RADV RAVEN2)`, reported
16,611,995,648 available Vulkan bytes, preserved a 4 GiB desktop reserve, and
accepted both memory gates. The fake server then observed CPU 0, nice 19, idle
I/O, LOW Vulkan priority, strict CPU-fallback rejection, and the exact 46 fixed
argument tokens, including `--no-ui`, allocation-summary verbosity 4, and
`--override-tensor '.*=Vulkan0'`. No model was opened and no network listener
was created.

The static-path regression separately observes `--path`, `--ui`, localhost
CORS, and `--api-key-file`. It rejects a missing `index.html` and an empty key
file, and it rejects a static path without an API key before the fake server
starts. The test performs no model load or network listen.

The cache-policy regression rejects tuple overrides without a dedicated
ceiling, rejects override ceilings above the registry ceiling, forwards the
overridden cache arguments at an admitted depth, and rejects a context one token
above that override ceiling. These are construction-policy tests; they do not
claim a new cache tuple has completed a hardware depth ladder.
