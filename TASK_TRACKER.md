# Raven2 Vulkan Qwen Setup Tracker

This file is the execution ledger for the appliance on the SSH host alias
`qwen-laptop`. It retains what was attempted, in what order, and against which
evidence. The settled operating configuration lives in `README.md`, repository
doctrine lives in `CLAUDE.md`, and `evidence/` holds the measurements; where a
completed row below disagrees with those, they are current and the row is
history.

Rows close when their stated evidence is retained or linked. Package, kernel,
firmware, GTT, and model-load mutations remain gated by a reviewed simulation
and rollback path.

## Fixed operating constraints

- SSH and terminal operations only. Remote GUI control stays out of scope.
- The desktop remains the highest-priority workload.
- Model tensors execute through RADV Vulkan, in full offload. Every tested
  hybrid placement lost to it, so a CPU tensor split is a measured regression
  rather than a tuning option.
- `QWEN_INFERENCE_CPU` selects the inference core and defaults to CPU 0 at nice
  19 and idle I/O; safety guards run on the other core.
- The server defaults to `127.0.0.1` and one slot. `QWEN_BIND_HOST` widens the
  listener, and the listener carries no key: `--tools all` is what makes a bind
  dangerous, and the read-only tool set is `read_file,file_glob_search,grep_search`.
- The operational server context runs at 24,576 tokens. A 32K floor is stated
  and unmet, so that figure is the active point rather than a ceiling.
- `paced-60` terminates above 75% aggregate GPU busy. The serialized and async
  LOW profiles use a 20 ms MEDIUM graphics-family service deadline and treat
  100% busy as an observation.
- Desktop responsiveness comes from RADV LOW global priority, the pinned core,
  and nice 19, which let the desktop's own queue preempt inference. The
  graphics-family probe measures whether that preemption holds.
  `QWEN_LATENCY_MODE=terminate` stops the server on the first late frame and
  arms after model load; `observe` records the same breaches and lets a run
  finish, because a measurement run spanning tens of minutes of saturated
  prefill would otherwise be ended by a single outlier and yield no timing.
- A fence returning anything other than `VK_SUCCESS` ends the run in both modes.
  Observe mode tolerates a deadline overrun, not a device fault.
- `model-memory-preflight.sh` reports host and Vulkan headroom and admits every
  launch. A load that exceeds the machine fails at once and names its reason.
- Qwen3.8-4B Distill Q4_K_M is the text default, on measured appliance behavior.
  Qwen3.8-27B is a quality reference whose predicted 1.17 decode tok/s places it
  outside interactive use.
- HIP through TheRock is an open comparison, not a rejected one. It requires
  `HSA_ENABLE_SDMA=0`, without which model load hangs.
- Sudo credentials are entered only by the user. `/etc/sudoers.d/90-qwen-agent`
  sets `timestamp_type=global` with a 60 minute timeout, so one `sudo -v` covers
  the SSH sessions that administer the machine. Passwords never cross SSH
  command lines, logs, or project files.

## Confirmed host facts

- Host access: `qwen-laptop` accepts the configured SSH key.
- Distribution: Linux Mint 22.2 `zara`, Ubuntu Noble package base.
- Running kernel: Ubuntu HWE `7.0.0-28-generic`.
- Installed alternate HWE kernel: `7.0.0-29-generic`.
- Candidate HWE kernel: `7.0.0-30.30~24.04.1`.
- GPU: AMD Raven2 `1002:15d8`, two active compute units.
- Vulkan device: `AMD Radeon Graphics (RADV RAVEN2)`.
- Mesa source: `ernstp/mesarc` Noble PPA is already enabled.
- Mesa runtime and candidate:
  `26.2.1+git2608201115.88947685514~n~mesarc0`.
- Secure Boot: disabled; platform reports Setup Mode.
- Sudo timestamp: active only on `qwen-admin:admin.0`; timestamp scope is the
  pane TTY.
- Durable remote session: tmux session `qwen-admin`.

## Access, identity, and security

- [x] Resolve the laptop hostname through mDNS and prove key-based SSH access.
- [x] Create and validate the `eirikr` account without using SMB as an
  authentication bypass.
- [x] Preserve `nick` and `eirikr` as separate accounts.
- [x] Add `eirikr` to `render` and `video` through the privileged doctor.
- [x] Add `nick` to `render` and `video` through the privileged doctor.
- [x] Verify `/dev/dri/renderD128` is `0660 root:render`.
- [x] Verify `/dev/dri/card1` is `0660 root:video`.
- [x] Verify offscreen Vulkan for `eirikr` selects RADV Raven2.
- [x] Verify offscreen Vulkan for `nick` selects RADV Raven2.
- [x] Verify neither account's permission test selects llvmpipe.
- [x] Establish the `qwen-admin` tmux session for secure sudo refreshes.
- [x] Refresh the sudo timestamp with `sudo -v` inside `qwen-admin`. Evidence:
  `sudo -n true` and the privileged post-runtime kernel capture succeed inside
  `qwen-admin:admin.0` without exposing the credential.
- [ ] Design bidirectional SSH for `eirikr` with separate purpose-bound keys.
  Evidence: host aliases, key permissions, and both directions pass BatchMode.
- [ ] Configure sudo authentication through the SSH terminal or a reviewed
  askpass mechanism. Evidence: sudo requires authentication and never becomes
  passwordless.
- [ ] Invalidate the final sudo timestamp. Evidence: `sudo -n true` fails.

## Host and driver evidence

- [x] Capture CPU topology, memory modules, GPU PCI identity, and Vulkan device.
- [x] Capture default RADV heap size, budget, maximum allocation, and buffer.
- [x] Measure the default GTT budget as approximately 5.15 GiB.
- [x] Measure the device-local budget as approximately 10.30 GiB.
- [x] Measure the combined Vulkan budget as approximately 15.46 GiB.
- [x] Measure the per-allocation and buffer ceiling just below 4 GiB.
- [x] Build a process-local RADV unified-heap comparator.
- [x] Prove the unified heap merges visibility without adding capacity.
- [x] Repair the capacity audit to distinguish init warnings from runtime
  hazards.
- [x] Validate the repaired audit with ShellCheck, syntax, negative, and
  synthetic-positive cases.
- [x] Hash and compare `raven2_rlc.bin` with upstream linux-firmware.
- [x] Prove the three RLC restore payloads are nonzero and in bounds.
- [x] Trace the PSP stale-response warning to preserved Ubuntu AMD source
  behavior.
- [x] Separate the display workqueue CPU-hog warning from PSP firmware loading.
- [x] Capture a fresh privileged kernel baseline after sudo refresh. Evidence:
  `evidence/kernel-baseline-7.0.0-28.log` and
  `evidence/kernel-post-runtime.log` retain boot identity and kernel output.
- [x] Confirm the fresh baseline contains no ring timeout, GPU reset, VM fault,
  OOM, or device loss. Evidence:
  `evidence/kernel-post-runtime-hazards.log` records `hazard_count=0` after the
  final Vulkan runtime tests.
- [ ] Quantify the display workqueue warning frequency and correlate it with
  visible desktop activity. Evidence: timestamped kernel and load samples.
- [ ] Audit Linux 7.0 Raven2, Picasso, Renoir, and comparable UMA changes from
  kernel source and Ubuntu packaging. Evidence: commit and package ledger.
- [ ] Audit Linux 7.1 Raven2, Picasso, Renoir, and comparable UMA changes from
  kernel source and Ubuntu packaging. Evidence: commit and package ledger.
- [ ] Audit recent field reports for Raven2 UMA allocation, GTT, Vulkan device
  loss, suspend, display, and long-compute behavior. Evidence: URL, date,
  hardware, stack, observation, and confidence ledger.
- [ ] Reconcile firmware, kernel amdgpu, Mesa RADV, Vulkan loader, and llama.cpp
  responsibilities. Evidence: each claimed limit has one owning layer and one
  falsifier.

## Mesa PPA and kernel admission

- [x] Inventory enabled APT repositories and package preferences.
- [x] Detect that `ernstp/mesarc` is already the active Mesa source.
- [x] Record the Mesa transition from installed 26.2.0 to installed and
  candidate 26.2.1.
- [x] Record installed HWE kernels 7.0.0-28 and 7.0.0-29.
- [x] Record candidate HWE kernel 7.0.0-30 and the running `-28` kernel.
- [x] Record Secure Boot disabled and Setup Mode enabled.
- [x] Inspect the mesarc PPA publication cadence, source package provenance,
  signing key, supported Noble dependencies, and downgrade instructions.
- [x] Compare mesarc with Kisak, Oibaf, and Ubuntu's supported Mesa packages.
  Evidence: freshness, patch policy, package scope, downgrade path, and Raven2
  relevance table.
- [x] Prove whether a second graphics PPA would conflict with mesarc.
  Evidence: package origins and version ordering for every replaced library.
- [x] Simulate the Mesa 26.2.1 upgrade with `apt-get -s`.
  Evidence: complete install, remove, upgrade, downgrade, and held-package set.
- [x] Check multiarch, VA-API, VDPAU, OpenGL, Vulkan, libdrm, and LLVM package
  coherence in the simulated transaction.
- [x] Review Mesa 26.2.0 to 26.2.1 RADV changes affecting Raven/Raven2, memory,
  queue priority, and device loss.
- [x] Define the Mesa upgrade admission rule: a relevant fix or measurable
  Vulkan benefit, coherent packages, a desktop smoke test, and proven rollback.
- [ ] Refresh the mesarc, Kisak, Oibaf, and Ubuntu candidate versions immediately
  before any graphics-stack mutation. Evidence: timestamped package-origin and
  Launchpad publication ledger.
- [ ] Capture every installed Mesa, libdrm, LLVM, Vulkan loader, VA-API, and
  OpenGL package version before any graphics-stack mutation. Evidence: sorted
  package manifest and APT policy output.
- [ ] Prove a graphics-track transition returns to one coherent Ubuntu Noble
  origin before another PPA is enabled. Evidence: simulated purge and downgrade
  transaction with no mixed ABI-coupled package origins.
- [x] Remove the obsolete dangling `mesa-vdpau-drivers` package after sudo
  refresh. Evidence: the transaction removed one package, installed four build
  prerequisites, preserved VA-API, and left no broken `libvdpau_radeonsi` link.
- [x] Record installed and residual kernel package states accurately with
  `dpkg-query` status fields.
- [x] Review Ubuntu HWE `-29` and `-30` changelogs and source deltas affecting
  amdgpu, DRM, scheduler, memory management, suspend, and display.
- [x] Check DKMS modules against each installed kernel. Evidence: `dkms status`
  plus module build state for the candidate kernel.
- [ ] Verify GRUB retains known-good `7.0.0-28` and `6.14.0-29` boot entries.
- [x] Capture initramfs hashes and available boot-space before kernel changes.
- [x] Define the kernel admission rule: relevant fix, no known Raven2 regression,
  complete initramfs, retained fallback, and one-reboot validation plan.
- [ ] Refresh the Ubuntu HWE changelog, Mint Update Manager kernel status, and
  installed fallback inventory immediately before a kernel mutation.
- [ ] Prove the selected kernel remains an Ubuntu Noble HWE package with a
  complete image, modules, headers, initramfs, and GRUB entry before reboot.
- [ ] Complete post-upgrade admission validation for Mesa 26.2.1. Evidence:
  desktop, media, suspend, heap, offscreen Vulkan, and hazard checks.
- [ ] Upgrade a future Mesa version only if its admission rule passes.
- [ ] Boot a newer HWE kernel only if its admission rule passes and the user
  authorizes the required reboot.
- [ ] Re-run desktop graphics, offscreen Vulkan, heap, suspend, and hazard checks
  after any admitted Mesa or kernel change.
- [ ] Prove rollback to the retained package and kernel baseline.

## Compiler and alternative GPU backend admission

- [x] Capture the user-initiated Mesa 26.2.1 and OpenCL package transaction.
  Evidence: `evidence/compiler-opencl-admission.md`.
- [x] Verify the post-transaction Vulkan device remains RADV Raven2. Evidence:
  `vulkaninfo --summary` reports RADV and Mesa 26.2.1.
- [x] Inventory the installed OpenCL loader, headers, ICD package, and `clinfo`.
- [x] Prove mesarc's 26.2.1 `mesa-opencl-icd` contains documentation only and
  installs no ICD manifest or runtime library.
- [x] Prove the installed OpenCL state exposes zero platforms. Evidence:
  `/etc/OpenCL/vendors` has no manifest and `clinfo -l` is empty.
- [x] Prove the pinned llama.cpp OpenCL backend rejects AMD devices. Evidence:
  `ggml_opencl_is_device_supported()` accepts only Adreno and Intel families.
- [x] Reject PoCL as a model backend because it executes on the CPU.
- [x] Reject ROCm and AMDGPU-PRO as assumed Raven2 fallbacks without explicit
  device support, package-coherence, and runtime evidence.
- [ ] Audit upstream llama.cpp AMD OpenCL support, issues, and retained patches
  before building another ICD.
- [ ] Design Raven2 family detection, kernel compile flags, operation coverage,
  memory reporting, and strict fallback handling for the OpenCL backend.
- [ ] Audit an exact-source Mesa 26.2.1 Rusticl build in an isolated prefix only
  after the llama.cpp AMD device gate has an evidence-backed implementation.
  Evidence: source commit, Meson options, LLVM version, ICD path, and rollback.
- [ ] Admit an OpenCL comparator only after both `eirikr` and `nick` select
  Raven2 through the isolated ICD without a CPU platform.
- [ ] Build llama.cpp OpenCL in a separate build directory without changing the
  production Vulkan build.
- [ ] Verify Qwen3.8 operations, quant formats, KV types, Flash Attention, and
  strict no-CPU-fallback behavior on the OpenCL backend.
- [ ] Compare OpenCL and Vulkan memory ceilings, prefill, decode, stability, and
  desktop responsiveness before naming OpenCL an operator-selectable backend.
- [x] Keep Vulkan as the only automatic backend; OpenCL requires both a working
  Raven2 ICD and implemented llama.cpp AMD support before a manual profile can
  exist.
- [x] Inventory Noble compiler candidates: GCC 14 and Clang/LLVM 20 are
  distribution packages and install side by side.
- [x] Audit apt.llvm.org Noble packages for LLVM 21 and 22, including signing,
  versioned libraries, dependencies, and publication cadence.
- [x] Audit the Ubuntu Toolchain Test PPA GCC 16 snapshot and prove it publishes
  replacement global `libgcc-s1` and `libstdc++6` packages.
- [x] Reject the GCC 16 test PPA for the desktop baseline because it changes the
  global runtime without a llama.cpp requirement.
- [x] Preserve GCC 13 as `/usr/bin/cc` and `/usr/bin/c++`; invoke every compiler
  comparator by its versioned executable and an isolated build directory.
  Evidence: `evidence/llama-vulkan-build-provenance.log` records GCC/G++ 13.3.
- [ ] Install Clang/LLVM 20 from Noble only if a measured compiler comparator is
  needed after the GCC 13 production build passes.
- [ ] Admit apt.llvm.org LLVM 22 only for an isolated compiler experiment with a
  dedicated keyring, `signed-by`, narrow APT pins, transaction simulation, and
  removal proof.
- [ ] Build GCC 16 in an isolated prefix or container only if a compiler-specific
  hypothesis justifies its CPU cost; never replace the system libgcc or
  libstdc++ baseline.
- [ ] Record compile time, binary hash, size, warnings, tests, and llama
  throughput before preferring a newer compiler.

## Memory and capacity model

- [x] Convert published model byte sizes to binary GiB.
- [x] Calculate Q8 K plus Q4 V KV growth at 32K, 64K, and 128K.
- [x] Include approximately 0.15 GiB of live recurrent state in lower bounds.
- [x] Establish 27B C128 lower bounds for Q2_K_XL through Q4_K_M.
- [x] Prove Q4_K_M cannot remain fully Vulkan-resident at long context within
  the measured 15.46 GiB Vulkan budget.
- [x] Identify Q2_K_XL as the only plausible 27B 128K capacity arm under the
  measured heap budget.
- [x] Identify current desktop memory pressure as unsafe for a 27B 128K run.
- [ ] Measure graph, scratch, staging, loading-peak, prompt-cache, and OS
  overhead with the exact llama.cpp build.
- [ ] Measure peak and steady RSS and GTT separately.
- [ ] Detect whether model loading creates a transient second resident copy.
- [ ] Recalculate every quant and context row with measured overhead and a 4 GiB
  desktop reserve.
- [x] Define a live preflight gate for MemAvailable, swap use, Vulkan budget,
  and desktop VRAM use. Evidence: `remote/model-memory-preflight.sh` and
  `evidence/model-memory-preflight.md`.
- [x] Define one 4K host and Vulkan admission gate for each requested
  Qwen3.8-27B quant. Evidence: `evidence/qwen38-27b-4k-admission.md`.
- [x] Define provisional Qwen3.5-4B Vulkan allocation gates for 4K, 32K, 64K,
  and 128K. Evidence: `evidence/qwen35-4b-allocation-ladder.md`.
- [x] Define the operator abort command and numeric resource thresholds before
  prompt ingestion. Evidence: `remote/monitor-qwen-runtime.sh`,
  `remote/watch-qwen-kernel-hazards.sh`, and
  `evidence/runtime-guard-policy.md`.

## Checkpoints and session topology

- [x] Verify recurrent-state bytes per checkpoint from the exact Qwen3.8 model
  metadata and llama.cpp revision. Evidence:
  `evidence/qwen38-checkpoint-memory.md`.
- [x] Verify `--ctx-checkpoints`, `--cache-ram`, `--checkpoint-min-step`, and
  `--no-context-shift` behavior from source. Evidence:
  `evidence/checkpoint-cache-context-semantics.md`.
- [x] Verify the generated `llama-server --help` defaults and option names after
  the pinned build exists. Evidence:
  `evidence/llama-vulkan-runtime-validation.log` records checkpoint default 32,
  minimum step 8192, RAM cache 8192 MiB, disabled context shift, and enabled UI
  runtime default; the fixed launcher explicitly supplies `--no-ui`.
- [x] Record that `--checkpoint-every-n-tokens` is not a registered option in
  the selected revision.
- [x] Prove the generated parser rejects `--checkpoint-every-n-tokens`.
  Evidence: the parser exits 1 with `invalid argument` in
  `evidence/llama-vulkan-runtime-validation.log`.
- [x] Define one-shot capacity mode with one slot, zero checkpoints, zero RAM
  cache, and no context shift. Evidence: `remote/qwen-capacity-policy.sh` and
  `evidence/capacity-server-policy.md`.
- [ ] Define bounded multi-turn mode with four checkpoints and an 8192-token
  minimum step.
- [ ] Admit eight checkpoints only after the four-checkpoint memory and reuse
  evidence passes.
- [ ] Sweep checkpoint minimum steps of 8192, 4096, and 2048 tokens.
- [ ] Measure actual prefix reuse and recomputed tail tokens for every checkpoint
  mode.
- [ ] Define persistent append-only session invariants: one sequence, delta-only
  appends, fixed system prompt, and prefix-mutation rejection.
- [ ] Design restart recovery without claiming that slot metadata restores
  recurrent checkpoint state.

## Model and quantization audit

- [x] Keep `unsloth/Qwen3.8-27B-GGUF` as the primary benchmark lineage.
- [x] Record Q2_K_XL and IQ3_XXS exact published byte sizes.
- [x] Record the known IQ3 artifact SHA-256.
- [x] Audit smaller Qwen candidates for reasoning, coding, tool use, context,
  multilingual ability, license, GGUF support, and Vulkan fit.
- [x] Audit non-Qwen candidates against the same rubric.
- [x] Verify every candidate from its model card, config, tokenizer, license,
  GGUF repository, and exact artifact listing.
- [x] Separate trained context from demonstrated usable context.
- [x] Separate benchmark claims from reproducible evaluations.
- [x] Estimate Vulkan-resident C32, C64, and C128 envelopes for every candidate.
- [x] Reject candidates that require CPU tensor fallback under the operating
  policy.
- [x] Rank a daily model frontier separately from the 27B quality benchmark.
- [x] Define a depth-curve corpus covering 32K, 64K, 96K, and 128K.
- [x] Include code, research prose, JSON tool transcripts, multi-document
  retrieval, multilingual text, and long-separated dependencies.
- [ ] Define Q2_K_XL versus Q4_K_M as the 27B low/high quality control.
- [ ] Design protected-attention IQ3 and IQ4 conversion experiments.
- [ ] Verify whether the converter can retain recurrent gates at F32,
  full-attention Q/K/V/O at Q8, embeddings and output at Q5/Q6, and bulk
  projections at IQ3/IQ4.
- [ ] Build a long-context importance matrix rather than relying on a 512-token
  calibration corpus.
- [ ] Measure retrieval, reasoning, tool accuracy, and perplexity across the
  full context-depth curve.

## llama.cpp build and scheduling

- [x] Clone llama.cpp at
  `f280b26983ad0fdb705a0d9ebf0503e76f2899b0`.
- [x] Verify the remote checkout is clean.
- [x] Identify missing build packages `glslc` and `spirv-headers`.
- [x] Verify `libvulkan-dev` is installed.
- [x] Install `glslc`, `libshaderc1`, `spirv-headers`, and `shellcheck` after
  sudo and package-source gates pass. Evidence: simulation reports four new
  Noble packages, zero upgrades, and zero removals.
- [x] Inspect Vulkan instance, physical-device, queue-family, device-create, and
  submit paths in the pinned llama.cpp revision. Evidence:
  `evidence/vulkan-low-priority-admission.md`.
- [x] Determine whether RADV exposes global-priority query and low-priority queue
  creation for Raven2. Evidence: the headless queue-creation probe returns
  `VK_SUCCESS` for compute-only family 1.
- [x] Design an opt-in low global queue priority that leaves default behavior
  unchanged and reports the selected priority. Evidence:
  `evidence/vulkan-low-priority-admission.md`.
- [x] Implement capability detection and explicit handling for permission or
  unsupported-priority errors. Evidence:
  `patches/llama-vulkan-low-priority.patch` and `git diff --check`.
- [x] Add focused tests and documentation for low-priority selection. Evidence:
  `remote/test-vulkan-low-priority.sh` and
  `evidence/vulkan-low-priority-admission.md`.
- [x] Trace Vulkan LOW through RADV, libdrm, the amdgpu context ioctl, and the
  DRM scheduler. Evidence: `evidence/vulkan-priority-first-policy.md` names
  each source function and primary-source revision.
- [x] Prove `AMDGPU_CTX_PRIORITY_VERY_LOW` and LOW collapse to the same Linux
  7.0 scheduler and hardware class. Evidence: both map to
  `DRM_SCHED_PRIORITY_LOW`, normal GFX pipe priority, and ring priority zero.
- [x] Detect Mesa's post-Vulkan `AMD_PRIORITY` override and clear it at the
  process boundary. Evidence: the installed RADV binary contains the option,
  the Mesa 26.2.1 source consumes it in `ac_drm_cs_ctx_create2()`, and the
  wrapper test observes it unset.
- [x] Clear inherited Vulkan memory-priority, graphics-queue, RADV performance,
  device-selection, layer-injection, and backend-tuning variables. Evidence:
  the closed wrapper replaces its complete performance policy and tests
  `GGML_VK_ENABLE_MEMORY_PRIORITY`, `GGML_VK_ALLOW_GRAPHICS_QUEUE`, and
  `RADV_PERFTEST=nogttspill` as negative inherited controls.
- [x] Require the exact `GGML_VK_LOW_PRIORITY=1` opt-in and reject malformed
  values before device creation. Evidence: patch replay and negative server
  test.
- [x] Configure Vulkan as the only accelerator while retaining the CPU control
  backend required by llama.cpp. Evidence: `remote/build-llama-vulkan.sh` and
  `evidence/build-backend-policy.md`.
- [x] Build with one Ninja job under one-core affinity, `nice 19`, and idle I/O.
- [x] Treat compiler and linker warnings as errors. Evidence: 451 generated
  compile commands contain `-Werror`.
- [x] Record compiler, CMake, Ninja, Vulkan header, loader, Mesa, and commit
  versions. Evidence: `evidence/llama-vulkan-build-provenance.log`.
- [x] Verify `llama-cli --list-devices` and `llama-server --list-devices` name
  RADV Raven2 exactly. Evidence:
  `evidence/llama-vulkan-runtime-validation.log`.

## Runtime guardrails

- [x] Implement a process-local RADV-only launcher environment. Evidence:
  `remote/radv-low-priority-env.sh`.
- [x] Reject llvmpipe and every non-RADV Vulkan device before model load.
  Evidence: `remote/test-radv-low-priority-env.sh` selects the single RADV ICD
  and requires the exact Raven2 device name.
- [x] Reject an insufficient live host-memory or Vulkan-budget reserve.
  Evidence: `remote/model-memory-preflight.sh`,
  `remote/vulkan-memory-budget-probe.c`, and
  `evidence/model-memory-preflight.md`.
- [x] Enforce `--parallel 1`, `--threads 1`, and `--threads-batch 1`.
  Evidence: `remote/qwen-capacity-policy.sh` and
  `evidence/capacity-server-policy.md`.
- [x] Enforce one-core affinity, absolute nice 19, and idle I/O scheduling.
  Evidence: the remote policy test observes CPU 0, nice 19, and idle I/O.
- [x] Remove inherited environment sentinels as scheduling-policy bypasses.
  Evidence: the environment test injects both former names and proves they are
  unset; the runtime-guard test independently proves CPU 1 and nice 0.
- [x] Replace duration-sensitive negative guard fixtures with explicitly
  terminated persistent processes. Evidence: the retained failed run records
  the expired target, and the full remote gate passes with status 0.
- [x] Add an opt-in native Vulkan submission pacer at each completed intra-graph
  fence.
  Evidence: `patches/llama-vulkan-duty-cycle.patch` and
  `evidence/vulkan-duty-cycle-policy.md`.
- [x] Fix the model duty cycle at 60% beneath the 75% aggregate abort boundary.
  Evidence: the policy test observes `GGML_VK_DUTY_CYCLE_PERCENT=60` after the
  wrapper replaces inherited environment state.
- [x] Bound interactive prompt bursts to 32-token Vulkan microbatches. Evidence:
  the closed argument surface fixes batch 128 and microbatch 32.
- [x] Verify pacing arithmetic and invalid-input rejection with compiler
  warnings treated as errors. Evidence: `remote/test-vulkan-pacing-math.sh`.
- [x] Define `paced-60`, `low-serialized`, and `low-async` as closed profiles.
  Evidence: inherited pacing, serialization, node-limit, and Mesa-priority
  values cannot escape `remote/radv-low-priority-env.sh`.
- [x] Add a validated 32-node runtime submission bound to llama.cpp. Evidence:
  `llama-vulkan-runtime-submit-limit.patch`, its warning-clean parser test, and
  the byte-exact four-patch replay.
- [x] Build a headless MEDIUM-priority graphics-family service probe. Evidence:
  `vulkan-graphics-service-probe.c` compiles with all warnings as errors,
  creates no surface, and completes five positive queue submissions.
- [x] Prove the graphics-service deadline terminates its watched process.
  Evidence: a 1 microsecond synthetic deadline produces `probe_breach`, sends
  SIGTERM, and returns status 3.
- [x] Require the graphics-service watcher for every Web server profile and
  terminate the server if it disappears. Evidence: session wiring and the
  synthetic watcher-loss runtime test.
- [x] Measure idle MEDIUM graphics-family fence latency before a model load.
  Evidence: 400 retained 16 ms samples measure 0.510 ms mean, 0.987 ms P95,
  1.886 ms P99, and 7.343 ms maximum on RADV Raven2.
- [x] Enforce localhost-only binding and one inference slot. Evidence: the
  closed argument surface fixes `--host 127.0.0.1` and `--parallel 1`.
- [x] Reject server contexts above 24,576 tokens and benchmark prompts above
  24,000 tokens. Evidence: both boundary tests pass and a 32K launch is
  rejected before model load.
- [x] Disable embedded Web UI assets at build time and in the default capacity
  runtime. Evidence: both UI build switches are off, no embedded HTML payload
  remains, and a launch without a validated static path supplies `--no-ui`.
- [x] Admit an APU-specific static UI only through the closed runtime surface.
  Evidence: `remote/test-qwen-capacity-policy.sh` requires `--path`, `--ui`,
  localhost CORS, and a non-empty API-key file together.
- [x] Bind both ends of client access to loopback and require SSH transport.
  Evidence: `remote/connect-qwen-webui.sh` fixes both forwarding addresses to
  `127.0.0.1` and rejects privileged or malformed ports.
- [x] Keep the browser and all graphical work on the client machine. Evidence:
  `WEBUI.md` defines a same-process static server and no remote GUI command.
- [x] Enforce zero checkpoints and zero RAM cache for capacity runs. Evidence:
  the closed argument surface fixes both values to zero.
- [x] Enforce no context shift and no MTP for initial runs. Evidence: the closed
  argument surface supplies `--no-context-shift` and contains no draft option.
- [x] Detect CPU tensor assignment and stop instead of continuing with fallback.
  Evidence: `patches/llama-no-cpu-fallback.patch` and
  `evidence/strict-vulkan-placement.md`.
- [x] Force every model tensor to `Vulkan0`; complete layer offload alone leaves
  the embedding graph eligible for CPU execution. Evidence: the policy fixes
  `--override-tensor '.*=Vulkan0'`.
- [x] Verify the strict tensor and graph gates with positive Vulkan and forced
  CPU-fallback tests after the build exists. Evidence:
  `remote/test-strict-vulkan-placement.sh` and
  `evidence/llama-vulkan-runtime-validation.log`.
- [x] Sample RSS, GTT, heap budget, clocks, temperature, swap, and desktop load.
  Evidence: `evidence/benchmarks/qwen35-4b-c32k-telemetry.log` retains 337
  five-second samples through the interrupted 32K prefill.
- [x] Scan kernel logs for device loss, ring timeout, reset, VM fault, and OOM.
  Evidence: the post-runtime hazard count is zero.
- [x] Stop on any hardware hazard or desktop-responsiveness threshold breach.
  Evidence: the 32K request stopped when an active desktop user reported
  degraded performance.
- [x] Terminate the server on the first GPU busy sample above 75%. Evidence:
  the one-second monitor and synthetic 76% negative test return the documented
  `gpu_busy_percent_breached` reason.
- [x] Rebuild the pinned remote binaries with all four qwen-apu patches.
  Evidence: the fatal-compiler-warning build completed at pinned llama.cpp
  commit `f280b26983ad0fdb705a0d9ebf0503e76f2899b0`.
- [x] Verify the real model path reports LOW queue priority and 60% duty.
  Evidence: the server log records the Raven2 device, all model layers on
  `Vulkan0`, and `duty cycle = 60%`.
- [x] Measure aggregate GPU busy, prompt tok/s, and decode tok/s through one
  guarded 4K Web UI request. Evidence:
  `evidence/benchmarks/qwen35-4b-webui-serialized/summary.md` records 3.79 prompt
  tok/s, 0.677 decode tok/s, 49.65% mean GPU busy, and 72% maximum GPU busy.
- [ ] ACTIVE: Measure desktop input latency through an external headless
  latency oracle for `low-serialized` and 16-node `low-async`.
  Manual impressions do not satisfy this row.
- [x] Build the isolated pinned `llama.cpp-qwen-apu` source and binary
  with exact LOW opt-in, duty control, strict Vulkan placement, and the runtime
  submission limit. Evidence: the retained build log, patch hashes, fatal
  compiler-warning flags, binary hashes, and warning-clean focused tests.
- [x] Retain command, environment, model hash, build identity, telemetry, kernel
  delta, exit status, and stop reason for every run. Evidence:
  `evidence/benchmarks/qwen35-4b-c32k-partial-summary.md` links the retained
  surfaces and records the user stop.

## Download and benchmark ladder

- [x] Verify disk capacity, partial-download handling, pinned source
  revision, byte size, and expected SHA-256 before downloading
  `Qwen3.5-4B-Q4_K_M.gguf`. Evidence:
  `evidence/qwen35-4b-download-admission.md`.
- [x] Admit Qwen3.5-4B as the provisional daily candidate after its host,
  desktop-reserve, strict-placement, queue-service, temperature, and kernel
  gates pass. External desktop-input latency remains an independent promotion
  gate for the async profile.
- [x] Download and verify Qwen3.8-27B `UD-Q2_K_XL` at the pinned source
  revision. Evidence: 9,828,981,664 bytes and SHA-256
  `fd4730dd8aad070517978752b63d530aeb1740d2283cab9fa24f1e404032ddb0`.
- [ ] Run Qwen3.8-27B `UD-Q2_K_XL` at 4K through the guarded Web server. Record
  load time, prompt tok/s, decode tok/s, GPU samples, memory, temperature,
  hazards, and output-quality result. The refreshed live preflight rejects
  15,474,085,888 available host bytes against a 24,861,367,200-byte loading
  requirement while accepting the Vulkan budget; the model remains unopened.
- [x] Download and verify Qwen3.8-27B `UD-IQ3_XXS` at the pinned source
  revision. Evidence: 10,934,860,704 bytes and SHA-256
  `c0b7c3038681ed2e3040456c1dd45f9858b6c2290bed172c70388a94874f3eee`.
- [ ] Run Qwen3.8-27B `UD-IQ3_XXS` at 4K through the guarded Web server. Record
  load time, prompt tok/s, decode tok/s, GPU samples, memory, temperature,
  hazards, and output-quality result. The refreshed live preflight rejects
  15,480,442,880 available host bytes against a 27,040,988,064-byte loading
  requirement while accepting the Vulkan budget; the model remains unopened.
- [ ] Download and verify Qwen3.8-27B `UD-IQ3_S` at the pinned source revision.
  Evidence: exact byte count, SHA-256, and Apache-2.0 license.
- [ ] Run Qwen3.8-27B `UD-IQ3_S` at 4K through the guarded Web server. Record
  load time, prompt tok/s, decode tok/s, GPU samples, memory, temperature,
  hazards, and output-quality result.
- [ ] Download and verify Qwen3.8-27B `UD-IQ4_XS` at the pinned source revision.
  Evidence: exact byte count, SHA-256, and Apache-2.0 license.
- [ ] Run Qwen3.8-27B `UD-IQ4_XS` at 4K through the guarded Web server. Record
  load time, prompt tok/s, decode tok/s, GPU samples, memory, temperature,
  hazards, and output-quality result.
- [ ] Advance a passing Qwen3.8-27B candidate from 4K to 24K only after the
  measured 4K working set preserves the 4 GiB desktop reserve.
- [x] Identify the exact Qwen3.8-9B Distill Q4_K_M repository, revision,
  filename, byte count, hash, and license. Evidence:
  `evidence/qwen38-9b-distill-admission.md`.
- [x] Download and verify Qwen3.8-9B Distill Q4_K_M through the resumable
  pinned downloader. Evidence: 5,780,090,176 bytes and SHA-256
  `df13d66021cef676f82be74053220fd75af6bf2a6a7fb77f5222ab9e50744a7a`.
- [ ] Run Qwen3.8-9B Distill at 4K under `low-serialized`. Record load time,
  prompt tok/s, decode tok/s, graphics-service latency, GPU busy, memory,
  temperature, kernel hazards, and output-quality result. The live 6,144 MiB
  preflight rejects 15,140,962,304 available host bytes against a
  16,517,508,416-byte loading requirement while accepting the Vulkan budget;
  the model remains unopened.
- [ ] Advance Qwen3.8-9B Distill to 24K only after the measured 4K working set
  preserves the 4 GiB desktop reserve and the 20 ms graphics deadline.
- [x] Download through tmux with one-core verification and idle I/O priority.
  Evidence: `evidence/runtime-logs/qwen-qwen35-4b-download.log`.
- [x] SHA-256 verify the complete artifact before llama.cpp opens it. Evidence:
  the download log records the exact published byte count, SHA-256, and pinned
  source revision before the `.part` rename.
- [x] Run a 4K minimal allocation smoke test without generation. Evidence:
  `evidence/qwen35-4b-c4k-allocation.log` and
  `evidence/qwen35-4b-c4k-kernel-hazards.log`.
- [x] Run a 32K allocation smoke without generation after the 4K resource and
  kernel gates pass. Evidence: `evidence/qwen35-4b-c32k-allocation.log` and
  `evidence/qwen35-4b-c32k-kernel-hazards.log`.
- [x] Run a 64K allocation smoke without generation after the 32K resource and
  kernel gates pass. Evidence: `evidence/qwen35-4b-c64k-allocation.log` and
  `evidence/qwen35-4b-c64k-kernel-hazards.log`.
- [x] Run a 128K allocation smoke without generation after the 64K resource and
  kernel gates pass. Evidence: `evidence/qwen35-4b-c128k-allocation.log` and
  `evidence/qwen35-4b-c128k-kernel-hazards.log`.
- [x] Define the automated abort command and numeric memory, swap-in,
  temperature, process-placement, and GPU-hazard thresholds before 32K prefill.
  Evidence: `remote/test-qwen-runtime-guards.sh` passes both positive and
  synthetic-negative controls.
- [x] Start the guarded 32K multi-domain prefill and stop at 20,992 tokens when
  an active desktop user reports degraded performance. Evidence:
  `evidence/benchmarks/qwen35-4b-c32k-partial-summary.md`.
- [x] Review retained partial 32K memory, hazard, fallback, speed, and desktop
  evidence. The partial cumulative rate is 12.63 tok/s, decode is not run, the
  maximum temperature is 87.75 C, and the live hazard count is zero.
- [x] Prohibit 64K, 96K, and 128K operational launches under the 24K cap.
  Capacity-only allocation evidence remains historical and does not authorize
  prompt ingestion.
- [x] Implement and prove llama.cpp intra-graph submission pacing that holds
  the measured 4K request below 75% without raising queue priority.
- [x] Quantify standalone serialization cost with equal 46-token prompt and
  128-token decode requests. The passing 16-node async arm gains 23.31% prompt
  throughput and 106.12% decode throughput; the 32-node arm is rejected at a
  20.017 ms MEDIUM fence. Evidence:
  `evidence/benchmarks/qwen35-4b-vulkan-priority-comparison.md`.
- [ ] Run the guarded 24K prefill and fixed-depth decode gate only after the
  selected profile passes the external desktop-input oracle and the desktop is
  free of user-visible impact.
- [ ] Review retained 24K memory, hazard, fallback, speed, and desktop evidence.
- [ ] Judge the daily laptop profile from the 24K operational result and the
  retained partial 32K falsifier.
- [ ] Add four recurrent checkpoints only after stable 128K one-shot operation.
- [ ] Test n-gram speculation only after long-context stability.
- [ ] Test MTP only for generation after n-gram, with draft processing excluded
  from prompt microbatches.
- [ ] Measure accepted drafts, extra context memory, device stability, and actual
  speedup before admitting speculation to a daily profile.

### Context speed ledger

| Context | Prompt tokens completed | Prefill tok/s | Decode tok/s | Status |
| ---: | ---: | ---: | ---: | --- |
| 24K | not run | not run | not run | Blocked on external desktop-input oracle |
| 32K | 20,992 of 32,000 | 12.63 cumulative | not run | User-stopped partial; prohibited by current policy |
| 64K | not run | not run | not run | Prohibited by 24K operational cap |
| 96K | not run | not run | not run | Prohibited by 24K operational cap |
| 128K | not run | not run | not run | Prohibited by 24K operational cap |

## Append-only service and client

- [ ] Specify an OpenAI-compatible facade around one owned llama sequence.
- [ ] Reject edits to prior messages, system prompt changes, and divergent
  prefixes within an active session.
- [ ] Append only new user, tool, and assistant tokens to the retained context.
- [ ] Define explicit new-session and checkpoint-mediated branch operations.
- [ ] Implement bounded request size, cancellation, timeout, and clean shutdown.
- [ ] Implement crash-safe metadata without overstating recurrent-state
  persistence.
- [ ] Add unit tests for prefix equality, mutation rejection, and delta append.
- [ ] Add integration tests for 100K-plus append-only multi-turn operation.
- [x] Audit llama.cpp's embedded UI, Open WebUI, LibreChat, LobeHub, and the
  existing qwen-lab diagnostic panel from their primary sources.
- [x] Select the same-process qwen-apu static panel for the first test. It runs
  the browser on the client, adds no laptop service, and uses exact server-side
  token counts.
- [x] Start the guarded 4K Web UI after the submission pacer passes the 75% GPU
  gate. Evidence: the authenticated real-model request completes with a 72%
  maximum aggregate GPU sample.
- [ ] Evaluate a Debian-installable CLI and TUI after the Web UI path proves the
  API, reasoning display, cancellation, and timing surfaces.
- [ ] Run Open WebUI on the client workstation only if persistent history, RAG,
  or multi-user controls justify its additional services.

## Closure

- [ ] Verify no unauthorized PPA, Mesa, kernel, firmware, GTT, GUI, or sudoers
  change occurred.
- [ ] Verify no unintended llama, build, download, or benchmark process remains.
- [ ] Retain hashes for scripts, configs, binaries, models, and evidence indexes.
- [ ] Document package, kernel, account, SSH, launcher, and service rollback.
- [ ] Publish measured daily and benchmark profiles with explicit limits.
- [ ] Verify the complete setup end to end under live desktop use.
