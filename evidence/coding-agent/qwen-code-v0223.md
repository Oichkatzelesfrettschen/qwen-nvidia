# Qwen Code v0.22.3 pin

The coding lane runs one pinned agent runtime, and this record carries the
identity the pin rests on. `scripts/coding-runtimes.tsv` is the registry,
`scripts/download-qwen-code-v0223.sh` the fetcher,
`scripts/verify-qwen-code.sh` the installed-state check,
`scripts/qwen-code-settings.json` the generated provider configuration, and
`scripts/run-qwen-code.sh` the launch wrapper that owns the child's
environment.

## Pinned release

```text
upstream:  QwenLM/qwen-code
release:   v0.22.3, published 2026-08-28
asset:     qwen-code-linux-x64.tar.gz
bytes:     84633418
sha256:    9db29c26a987bea729a6db5ce2200a4c1178d6f87c4fa4a7900075868c02c04c
```

The digest matches the publisher's own `SHA256SUMS` release artifact, read
from the same release on 2026-08-31, so the registry pin and the publisher
agree on the artifact identity. The archive holds regular files and
directories alone under one `qwen-code/` root with a bundled Node runtime at
`qwen-code/node/bin/node`; the fetcher still refuses link members and
escaping paths on every run, because the rule guards future archives rather
than describing this one. The extracted `qwen-code/bin/qwen` answers
`--version` with `0.22.3`.

## Configuration authority

The generated settings disable the runtime's auto-update, so the repository
owns the upgrade decision through a registry edit and a fetcher run. Both
coder models resolve to the loopback llama-server endpoint
`http://127.0.0.1:8080/v1` under the `openai` provider protocol, and the
credential travels through `QWEN_NVIDIA_LOCAL_API_KEY` from a mode-0600 key
file the wrapper reads: the settings file names the variable and holds no
key. The wrapper gives the child an isolated home directory carrying exactly
the generated settings, removes ambient provider credentials from the
environment, and refuses a non-loopback base URL, an undefined model, and a
key file at any mode other than 0600.

The advertised context windows state the serving intent rather than a
validated claim: `qwen25-coder-7b` at 8192 equals its validated filled
depth, and `qwenseer-2b` at 32768 awaits its own filled-depth arm before the
coding lane may default to it.

## Execution policy

`scripts/coding-runtimes.tsv` holds `execution_policy=refused`. The wrapper
admits an interactive loopback run only under `QWEN_CODE_ALLOW_DIRECT=1`;
the browser-facing path stays closed until the coding-agent service, its
containment, and the full-chain admission pass. `scripts/test-qwen-code-pin.sh`
admits the pin without the network: registry structure, settings rules, the
fetcher's four refusals against crafted archives and digests, and the
wrapper's four refusals plus one admitted exec against a fixture runtime.
