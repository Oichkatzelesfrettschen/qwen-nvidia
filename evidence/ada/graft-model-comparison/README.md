# DiscoBSD Graft model comparison

The 2026-09-22 PDT comparison used the promoted CUDA closure
`39a6bc778ef4`, llama.cpp's OpenAI-compatible chat endpoint, a 16384-token
context, Jinja tool parsing, temperature zero, a 512-token chat reasoning
budget, and a 2048-token reply cap. The three `record_symbols` inputs came
from Graft's graph for `flash_swap.c`, `kern_mman.c`, and `sig_machdep.c`.
They require seven exact node IDs. The first four rows below used the same
request bytes per file. The earlier Klear request used the same target IDs
and source text with a 6144-token reply cap, so its timing is contextual.

| Model | Exact-ID requests | Observed request time | Boundary |
| --- | ---: | ---: | --- |
| Qwenseer-2B Q4_K_M | 3/3 | 2.43-3.55 s | All seven IDs returned |
| Qwen3-4B-Instruct-2507 Q8_0 | 1/3 | 2.15-3.96 s | Five IDs copied target metadata |
| Qwen3.8-4B-Distill Q4_K_M | 3/3 | 3.02-4.92 s | All seven IDs returned |
| Qwen2.5-Coder-7B Q4_K_M | 0/1 | 26.43 s | First reply reached token cap without a call; two later requests were void |
| Klear-AgentForge-8B Q6_K | 3/3 | 15.23-59.86 s | Earlier run with a larger reply cap |

The first run's 4B Instruct server stopped after its first response when the
runtime guard measured 176 MB of swap-in during a one-second sample while
other compiler work occupied the host. The 7B coder server later stopped at
101 MB of swap-in during a sample. Both server exits are host-runtime evidence,
not grades for the requests that lacked responses. The stable retry produced
all three 4B Instruct and 4B Distill responses. The native server and Graft
pilot had already shown Klear's exact-ID compatibility; another 8B load was
not needed to distinguish the two small-model finalists.

The six source-grounded questions gave Qwenseer and the 4B distill four of
six mechanical passes each. The mechanical rubric checks named enforcing
symbols, discriminating terms, and invented identifiers; it does not prove
prose truth. Reading the returned text against `lib/libc/arm/sys/sbrk.c`
rejects Qwenseer's claim that a refused `sbrk` returns the old break. The
4B distill returned `(void *)-1` with `_curbrk` unchanged and described the
current USB re-arm condition, but its `flash_swap_append` answer claimed the
caller must guarantee the program-page alignment that the function checks
itself. These findings select the distill as the best tested endpoint for
structured Graft records and source fidelity, while leaving generated
summaries advisory rather than verified code facts.

Raw requests, responses, launch records and server-monitor logs remain in
`.local-artifacts/research/graft-llama-discobsd/model-comparison-five-matched/`,
`model-comparison-four-retry/`, `qwenseer-six-contracts/`, and
`distill-six-contracts/`. The earlier Klear records remain in
`model-contracts-scheduler-repaired/`. All paths are relative to the
qwen-nvidia repository's ignored `.local-artifacts/research/graft-llama-discobsd/`
root. The elapsed times include workstation scheduling, power and thermal
state; they do not establish a controlled throughput ranking.
