# Telemetry capture within its declared owner ancestry

Read-only capture of the operator telemetry service reached the user systemd
process above its declared tmux shell owner. Reading that ancestor's executable
failed with `PermissionError` before any telemetry shutdown. The retained
`capture-unbounded-failure.log` records the failed capture.

The holder scan now includes the declared owner and stops there. Parent traversal
reads process stat fields alone. Each descriptor scan brackets its observation
with parent and start-time identity checks; disappearance, identity change, and
unreadable observations within the declared ancestry refuse an absence claim.
Capture binds every process in the declared ancestry to its recorded identity.

`focused-intermediate.log` retains holder detection in the child and owner, refusal of missing
and unreadable observations inside the boundary, ignored ancestors above it, and
deterministic process-exit and identity-change cases, including replacement of
an intermediate ancestor before a positive or negative descriptor observation. The same suite exercises
exact restoration and unsafe-precondition refusals with isolated stand-in services.
The off-device checks execute no CUDA workload. Production and the live telemetry
service remain outside the fixture lifecycle.

The existing restoration mechanism continues to require campaign cleanup,
lease and owner checks, and a permitting device-state latch. The repair changes
capture's observation boundary; it grants no device admission or promotion.

`focused.log` preserves the earlier endpoint-only test run; the final implementation
identity in `implementation.json` belongs to `focused-intermediate.log`.
