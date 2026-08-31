# AGENTS.md

Guidance for repository agents (including Jules) working in this repository.

Read `CLAUDE.md` before changing executable policy or current-state defaults. `CLAUDE.md` holds the full repository doctrine.

## Authority Hierarchy & Hardware Boundary
- The physical Ryzen 5 5600X3D + RTX 4070 Ti appliance is the sole authority for CUDA, Vulkan, memory, performance, thermal, stability, kernel-path, and model-quality claims.
- The Jules VM is a clone-local development environment, not a measurement host.
- Never manufacture, infer, simulate, or convert a cloud build, missing device, different GPU, mocked result, static inspection, or unit test into an appliance measurement.
- Never add or modify retained evidence to imply a hardware experiment occurred.
- Committed registries (`scripts/models.tsv`), validation ledgers (`scripts/validated-tuples.tsv`), quarantine records (`scripts/quarantine.tsv`), promotion manifests (`evidence/ada/promotion-*/`), and executable policy are authority over descriptive prose.
- Treat current-host evidence (`evidence/ada/`, `evidence/depth-validation-cuda/`) as current measurement and `evidence/legacy/raven2/` as prior-host comparison only. Preserve historical evidence records as historical history; do not rewrite past records to match later operational conclusions.

## Operational & Execution Rules
- **Atomic Script Replacement**: Live scripts under `scripts/` are executed directly by running appliance processes. Always write updates to a temporary file and atomically move/rename over the target (`mv` / `os.replace`). Never perform truncating in-place edits.
- **CUDA0 Serving Authority**: CUDA0 is the primary serving backend with explicit tensor placement (`-ot .*=CUDA0`). Vulkan0 is the fallback backend supported by the same dual-backend binary.
- **Fail-Closed Semantics**: Treat registry, validation-ledger, quarantine, and promotion validation semantics as fail-closed. Treat warnings, unexpected schema changes, and malformed authority input as hard failures.
- **Prohibition on Cloud Promotions**: Never promote a build, change a measured default, lift a quarantine, increase a validated depth, or grant execution capability based on unmeasured cloud VM results.
- **Commit & Hygiene Discipline**: Keep local absolute paths, credentials, secrets, private hostnames, and machine-specific unsanitized state out of commits.

## Verification & Test Discipline
- **Cloud-Safe Tests**: Run clone-local shell, Python, parser, fixture, lint, and static consistency checks freely.
- **Appliance-Only Validations**: CUDA execution, NVML/NVIDIA telemetry, Nsight/CUPTI profiling, Vulkan device execution, actual model loading, filled-depth probing, router residency transitions, throughput benchmarks, and promotion admissions are appliance-only unless explicitly running inside a mock/fixture test.
