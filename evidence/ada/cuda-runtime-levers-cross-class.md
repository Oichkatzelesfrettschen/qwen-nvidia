# The CUDA runtime levers across all three runtime classes

`evidence/ada/cuda-runtime-levers.md` measured CUDA graphs, kernel fusion, and
programmatic dependent launch on the 2B distill alone, which left every lever
default resting on one class. `scripts/run-cuda-lever-campaign.sh` measures the
same three on the 0.8B Q8_0 and the 4B distill Q4_K_M, and the promoted defaults
survive all three: graphs on, fusion on, PDL unset.

## Why the arms are interleaved rather than grouped

A lever here moves one to ten percent and a sweep's own forward-to-reverse
instability reaches six, so the two are separated by adjacency rather than by
margin. Each subject profile runs between two default arms and the reported
ratio is against the mean of the defaults touching it, forward and again
reversed. A campaign that ran every default first would attribute the session's
drift to whichever lever ran last.

The drift floor is the spread across that campaign's own default arms, and it is
what each ratio is read against:

| class | default prefill spread | default decode spread |
| --- | ---: | ---: |
| 0.8B Q8_0 | 6.3% | 3.0% |
| 4B Q4_K_M | 2.0% | 1.2% |

## What each lever is worth, per class

Each figure is the mean of the forward and reverse arms against their adjacent
defaults. A negative decode figure is what disabling the lever costs, so it is
the lever's own value.

| lever | class | prefill | decode | reading |
| --- | --- | ---: | ---: | --- |
| no-graphs | 2B | +6.1% | -7.6% | both outside the floor |
| no-graphs | 0.8B | +10.1% | -8.5% | both outside the floor |
| no-graphs | 4B | +5.5% | -1.7% | both outside the floor |
| no-fusion | 2B | -4.2% | -5.8% | decode outside the floor |
| no-fusion | 0.8B | +0.5% | -7.3% | decode outside the floor |
| no-fusion | 4B | -2.0% | -4.4% | decode outside the floor |
| pdl | 2B | -0.6% | +0.2% | inside the floor on both |
| pdl | 0.8B | -1.3% | -1.0% | inside the floor on both |
| pdl | 4B | +0.2% | -0.2% | inside the floor on both |

Graphs buy decode and cost prefill on every class, which is the mechanism
stated directly: graph replay removes per-node launch overhead from a decode
step issuing many small kernels, and it adds capture and instantiation work to a
prefill step whose kernels are large enough for that overhead to vanish beside
them. The size of the decode gain falls with the checkpoint -- 8.5% on the 0.8B,
7.6% on the 2B, 1.7% on the 4B -- because a larger model does more work per
launch, so the fixed launch cost graphs remove is a smaller share of the step.
The 4B's 1.7% clears its own 1.2% floor by a narrow margin and is the weakest
evidence in the table.

Fusion buys decode on every class and its prefill effect changes sign across
them, staying inside the floor on the 0.8B and the 4B. Decode is what the
appliance is judged on, so fusion stays on and the prefill direction is
unresolved rather than reported.

PDL moves nothing on any class. Three classes agreeing that it sits inside their
own drift is a stronger statement than the 2B's single arm, and it stays unset.

## The token-identity control

Each profile also ran one greedy completion at temperature 0, top-k 1, a fixed
seed, and 32 tokens, with llama-cli's own rate line removed before hashing so
the digest reports emitted tokens rather than timing. Every arm of both
campaigns produced one digest per class -- `2dd7d13e20d7017d` on the 0.8B and
`b988b771534f70c2` on the 4B -- so all three levers are scheduling changes with
no numerical-policy effect, and the rate arms are readable as rate arms. A
digest that differed would have made the paired ratio a comparison between two
different computations.

## The device the campaigns ran on

Both held `/tmp/qwen-ad104-gpu-0.lock` for their whole run through
`scripts/gpu-workload-ownership.sh`, and both recorded the desktop client set
before every arm with a change between adjacent arms ending the campaign. The
set read `kwin_wayland` alone throughout, so no browser context entered or left
during either campaign; a browser GPU process holds a CUDA context on this
workstation and its arrival moves the measured quantity by more than PDL does.

## Falsifiers

A repeat in which the 4B's graphs decode figure falls inside its drift floor
would leave that class's graph default unsupported while the other two still
carry it. A repeat in which PDL clears the floor on two classes in the same
direction would move it from unset to a candidate. A token digest differing
between a subject and its adjacent default reclassifies that lever as a
numerical-policy change and withdraws its rate figure.
