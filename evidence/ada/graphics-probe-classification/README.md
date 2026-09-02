# The graphics-latency probe is a compute client

`scripts/gpu-workloads.tsv` classifies `vulkan-graphics-service-probe.c` as an
authorized monitor whose submissions are project-generated traffic even on the
graphics queue, and `gpu_ownership_inspect` decides a run by reading
`nvidia-smi --query-compute-apps`. Whether that query reaches a Vulkan
submitter that opens no CUDA context was open, and it decides whether the
compute-client authority can identify the probe at all or whether the owner
lock is the only mechanism that reaches it.

`scripts/classify-graphics-latency-probe.sh` answers it by observation. The
harness takes the top-level owner lock, starts a `sleep` as the probe's
lifetime argument, runs the probe as an authorized monitor with both children
launched under `9>&-`, samples the three driver client surfaces once per second
for ten seconds while the probe submits, stops the watched process, and proves
the probe is absent from all three surfaces afterwards.

## The prediction was wrong, and the deviation is the finding

`prediction.txt` was written before the device was touched. On driver
610.57.04 the compute-app query returned only the three `C+G` clients --
`kwin_wayland`, the Discord GPU process, and the Microsoft Edge GPU process --
and omitted every type-`G` client that `nvidia-smi -q -d PIDS` and
`nvidia-smi pmon` both reported: `Xwayland`, `plasmashell`,
`xdg-desktop-portal`, `firefox`, `krfb`, and one Electron editor. A probe that
submits on the graphics queue alone was therefore predicted to read
`driver_visibility=graphics`.

It reads `compute-and-graphics`. The `Type` field of `nvidia-smi -q -d PIDS`
names the probe `C+G` at 5 MiB of device memory, it appears in all ten
compute-app samples, and `pmon` reports it at 7% SM. Two runs agree. The
NVIDIA user-mode driver opens a compute context behind a Vulkan device whatever
queue the application submits on, so the graphics queue is what the workload
uses rather than what the driver accounts.

| field | value |
| --- | --- |
| `driver_visibility` | `compute-and-graphics` |
| `pids_type_field` | `C+G` |
| `compute_app_samples` | 10 of 10 |
| `surfaces_agree` | yes |
| `probe_submissions` | 681 |
| `residue` | none |

## What it changes

The compute-client inspection identifies the probe, so a probe surviving one
serving session reaches the next campaign's compute-app list and refuses it on
classification rather than only on the lock. That is the same bidirectional
property the owner lock carries, arriving through the second authority.

`GPU_OWNERSHIP_PROJECT_PATTERN` now names `vulkan-graphics-service-probe`.
Ahead of that name the probe matched the pattern through the `qwen-` fragment
of the checkout path, so the verdict was a property of the directory the tree
sits in: the same binary under `/srv/build/` read `refuse-unknown`. Case 29 of
`scripts/test-gpu-workload-ownership.sh` places the fixture outside any
qwen-named directory and requires `refuse-project`.

The probe stays out of the desktop pattern. Its traffic is project-generated
whatever the driver calls it, and this measurement is the reason the
classification is now stated rather than assumed.

## Conditions

The arm ran under the daily desktop rather than a compositor-only session,
because the question is whether one pid appears in one list and a second client
changes no part of that. `classification-summary.tsv` carries the client roster
on its `desktop_clients` row and `ownership-before.txt` carries the full
classification of each. The probe measured 113 us mean submission latency with
a maximum of 886 us and zero deadline breaches against its 20000 us deadline,
which is the device state the classification was read at rather than a claim
about the probe's cost to a concurrent campaign. That cost is unmeasured and
needs an arm that runs the probe beside compute.
