# qwen35-08b-bf16: strict CUDA0 admission of the BF16 representation row

`scripts/admit-representation-row.sh` admits the publisher's BF16 artifact of
the 0.8B as a registry row on the promoted closure, against `qwen35-08b-f16`
as the representation control. `checks.tsv` carries the twelve checks and
`admission-summary.tsv` the one-line result; every check passed.

The artifact verifies in place against the pinned publisher digest through
`download-qwen35-08b-bf16.sh` (`fetch.txt`). The header reads `qwen35` at 335
tensors with BF16 holding 99.87% of the bytes and F32 the norms and the
gated-deltanet scalars (`header-census.json`).
`verify-representation-pair.py` reads the F16 and BF16 files as one
architecture, one tokenizer, and one tensor layout with 195 tensors changed in
value type alone (`pair.txt`).

`strict-cuda-placement/` holds the three loads `test-strict-cuda-placement.sh`
runs. `cpu-tensor.log` ends on `token_embd.weight selected CPU buffer CPU
while LLAMA_NO_CPU_FALLBACK is enabled` for a load placed on the host by
`--device none`. `cpu-graph.log` ends on the same line for a load naming
`--device CUDA0 --n-gpu-layers all` with no tensor override: the CUDA backend
refuses the host-placed token embedding at buffer selection, where the Vulkan
check reaches the graph and refuses its GET_ROWS node, so the check reports
`graph_refusal=buffer-selection`. `cuda-positive.log` is the served placement
under `--override-tensor '.*=CUDA0'`: the 1436.03 MiB model buffer, the KV
buffer, the recurrent-state buffer, and the compute buffer all on CUDA0, with
`CUDA_Host` holding the 0.95 MiB output buffer and the 0.57 MiB host compute
scratch every fully offloaded load carries. Two `/completion` requests at
temperature 0 and seed 1 answered the same eight tokens
(`response-1.json`, `response-2.json`); their content digest is the
`completion_sha256` on the summary line.

The device was owned through `gpu-workload-ownership.sh` for the whole run:
three desktop clients before and the same three after, none of them a
`llama-server`, and no named `llama-server` pid after the check ended.
The kernel ring held zero hazard-pattern lines before and after.

The pass admits the artifact as a load subject at its registry ceiling of
8192. It measures no rate and validates no depth: `decode_tok_s` and
`prefill_tok_s` stay `-` until an uninstrumented paired sweep fills them, and
`validated_filled_depth` stays `-` until a filled-depth arm runs at the row's
own tuple. `evidence/ada/representation-08b/` retains the llama-bench triple
that ran the same artifact ahead of the row.
