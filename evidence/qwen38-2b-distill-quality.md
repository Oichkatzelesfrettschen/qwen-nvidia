# The 2B answers four of five and loses the one the 4B gets

`remote/compare-model-candidate.sh` and `remote/reasoning-span-probe.sh` ran the
2B distill through the same guarded launch path that promoted the 4B over the
base, at `nice 19`, profile `low-async`, temperature 0, one sample per prompt.

## The suite

| Prompt | Expected | 4B base | 2B distill | 4B distill | 9B distill |
| --- | --- | --- | --- | --- | --- |
| 9.11 against 9.9 | 9.9 | correct | correct | correct | correct |
| 14:20 to 17:05 | 2 h 45 min | correct | **3 h 5 min** | correct | correct |
| 40 less 25% | 30 | correct | correct | correct | correct |
| Capital of Australia | Canberra | **empty at the 2048 cap** | correct | correct | correct |
| 17% of 350 | 59.5 | correct | correct | correct | correct |
| | | 4 of 5 | 4 of 5 | **5 of 5** | **5 of 5** |

The two failures are different in kind. The base does not terminate: 2048
predicted tokens and 8338 characters of reasoning produce an empty answer, which
is the reasoning-termination failure. The 2B terminates promptly and states a
wrong interval, which is an arithmetic failure and the mode the publisher's own
`gsm8k_cot` figures predict, 0.640 for the 2B source against 0.785 for the 4B.

One sample per prompt at temperature 0 fixes the generation but not the
estimate: five prompts distinguish these three checkpoints and do not measure an
error rate.

## The cost of that answer

| | 4B base | 2B distill | 4B distill | 9B distill |
| --- | ---: | ---: | ---: | ---: |
| suite wall seconds | 1997.2 | **94.0** | 737.0 | 1208.8 |
| predicted tokens | 4874 | 886 | 2111 | 1923 |
| mean reasoning characters | 3048.6 | 235.2 | 968.8 | 1049.4 |
| mean decode tok/s | 2.455 | 9.732 | 2.887 | 1.611 |
| served decode tok/s | 2.79 | 9.78 | 3.09 | 1.59 |

The 2B finishes the suite 7.8 times faster than the 4B and 21.2 times faster
than the base, and it reaches those figures two ways at once: it decodes 3.4
times faster and it reasons in 24.3% of the 4B's characters.

The 9B buys nothing on this suite. It scores the same 5 of 5 as the 4B and
spends 1.64 times the wall clock doing it, and the reason is decode rather than
verbosity: it emits fewer tokens than the 4B, 1923 against 2111, at 1.611 tok/s
against 2.887. Five prompts of ordinary arithmetic and recall do not reach the
work a larger model is kept for, so this measures that the 9B is not justified
by this suite rather than that it is not justified.

Decode under the guarded serving path is 9.73 tok/s against `llama-bench`'s
9.46, so the guards cost nothing here as they cost nothing on the 4B.

Its chat template still gates `<think>` on
`chat_template_kwargs.enable_thinking`: reasoning off emits no
`reasoning_content` and reasoning on emits it. It ships text-only, with no
projector beside the checkpoint, so the vision profile stays on the base
checkpoint and its revision-matched projector.

## What this settles

The 2B is the only checkpoint measured on this appliance that decodes above 4.5
tok/s, and it answers correctly on four of five prompts including the one the
base fails. It is a candidate for interactive work rather than a replacement:
the interval it got wrong is ordinary arithmetic, and the 4B answers it.

The deployment roles follow from the two tables rather than from either alone:

| Role | Checkpoint |
| --- | --- |
| Interactive, latency first | Qwen3.8-2B distill |
| Balanced default | Qwen3.8-4B distill |
| Deep text, pending a suite that reaches it | Qwen3.8-9B distill |
| Vision | Qwen3.5-4B base with its matched projector |

Untested: everything the suite does not reach. A wider battery across systems
and POSIX work, debugging, extraction, instruction following, and long-context
retrieval would turn five deterministic generations into an error rate and would
give the 9B a domain where its cost buys something. These five prompts separate
the checkpoints and do not measure them.
