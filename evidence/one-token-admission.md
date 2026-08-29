# One-token admission: every static-admitted row against the device

Static admission reads what a file declares. It establishes an architecture, a
chat template, a vocabulary, and a streamed byte count, and it says nothing
about whether the artifact parses completely, whether its tensor types have
kernels in this build, whether the graph constructs, whether the device holds
it, or whether a token comes out. A runtime class is a shared throughput
expectation and those five properties belong to a particular file, so this stage
runs every row rather than one representative per class.

## Terms

```text
harness:   remote/run-one-token-admission.sh
admission: remote/test-strict-vulkan-placement.sh, called rather than reimplemented
profile:   paced-60, through radv-low-priority-env.sh
geometry:  ctx 128, batch 128, ubatch 128, one thread, one parallel slot
priority:  nice 19, taskset core 0, ionice idle
listener:  torn down for the duration; the device is exclusive
control:   Qwen3.8-2B Distill Q4_K_M, after each new runtime class and each refusal
```

The admission is four claims per row, all required: CPU tensor placement is
rejected, CPU graph placement is rejected, a strict Vulkan server answers a
two-token completion with HTTP 200 and `"tokens_predicted":2`, and the model, KV,
and compute buffers each name `Vulkan0` with no CPU fallback reached.

## Results

Fourteen rows, fourteen accepted, six control arms all accepted.

| candidate | architecture | load |
| --- | --- | --- |
| qwen38-2b-distill-gguf | qwen35 | accepted |
| qwen38-2b-uncensored | qwen35 | accepted |
| qwen35-2b-hauhau | qwen35 | accepted |
| qwen35-2b-unsloth | qwen35 | accepted |
| qwen35-2b-unredacted | qwen35 | accepted |
| qwen35-2b-unredacted-i1 | qwen35 | accepted |
| qwen35-2b-heretic | qwen35 | accepted |
| qwenseer-2b | qwen35 | accepted |
| qwen2vl-2b-platinum | qwen2vl | accepted |
| qwen35-08b-opus-reason | qwen35 | accepted |
| qwen35-08b-bartowski | qwen35 | accepted |
| qwen3-zero-coder-v2-08b | qwen3 | accepted |
| qwen35-08b-unsloth-unc | qwen35 | accepted |
| qwen3-zero-coder-08b | qwen3 | accepted |

The prediction registered before the run was that `qwen2vl-2b-platinum` would
fail, because it is the only `qwen2vl` architecture in the set and the only row
whose template names no tool path, so a build-support gap would appear there
first. **Falsified**: it loaded, placed every layer on the device, and answered
like the rest. The pinned build constructs a `qwen2vl` graph.

The load is text-only. A projector encodes images into one checkpoint's
embedding space and admitting it is a separate arm, so `projector` reads
`not-run` for every row. A row that loads and decodes without one is admitted
for text rather than refused for vision, and stays a throughput and quality
subject.

## What the digest check caught, and what it corrected

One row refused on its first load attempt. `qwen38-2b-uncensored` recorded
`043f440a...` when it was fetched and read `61713f6d...` when it was loaded, at
an identical 1,274,396,640 bytes. Three consecutive reads returned the second
value, so the file on disk is stable.

The publisher settles it. Hugging Face stores a GGUF as a Git LFS object and its
tree API returns that object's `lfs.oid`, which is the SHA-256 of the file. That
oid is `61713f6d...`: **the artifact is correct and the record was wrong.**
Auditing all fourteen against the publisher found thirteen recorded digests
matching exactly and only this one differing, so the fault is isolated and its
mechanism is unisolated.

The consequence is larger than the incident. A publisher digest is available at
every pinned revision, so a candidate fetch is verifiable at fetch time and does
not rest on an observation. `remote/fetch-candidate-artifact.sh` now queries the
oid and refuses an artifact that disagrees with it, and its output distinguishes
`verified_sha256` from `observed_sha256` for a repository that publishes outside
LFS, because an unverifiable fetch stated as unverified is a different claim from
one that passed a check. The row was reverified against the publisher and its
load then accepted.

## What this stage does not establish

A row that produces two tokens at a 128-token context has not been shown to
serve at depth, to hold a filled cache, to reach a useful rate, or to answer
correctly. Throughput belongs to the runtime class and quality to the weights;
this stage is binary admission and nothing else.

Records are retained as `evidence/one-token-admission/admission-summary.tsv`.
The summary carries `qwen38-2b-uncensored` twice, as the refusal and then the
acceptance, because the refusal is what the digest check did and removing it
would hide the event this file exists to record.
