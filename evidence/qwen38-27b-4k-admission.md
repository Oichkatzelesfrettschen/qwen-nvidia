# Qwen3.8-27B 4K Admission Gates

The first load for each 27B quant uses one slot, 4,096 tokens, Q8 K plus Q4 V,
zero checkpoints, zero RAM cache, no MTP, and strict `Vulkan0` placement. The
Qwen3.8 architecture contributes approximately 104 MiB of 4K KV and exactly
149.625 MiB of live recurrent tensor data before alignment. A 64 MiB provisional
compute allowance and rounding produce these Vulkan preflight gates:

| Quant | File MiB | Provisional Vulkan gate | Required MemAvailable with file copy and 4 GiB desktop reserve |
| --- | ---: | ---: | ---: |
| `UD-Q2_K_XL` | 9,373.647 | 10,240 MiB | 23.154 GiB |
| `UD-IQ3_XXS` | 10,428.296 | 11,264 MiB | 25.184 GiB |
| `UD-IQ3_S` | 11,483.081 | 12,288 MiB | 27.214 GiB |
| `UD-IQ4_XS` | 13,592.573 | 14,336 MiB | 31.274 GiB |

The host gate deliberately covers the Vulkan working set, a simultaneous
file-backed model image, and 4 GiB left for the desktop. It protects the loading
peak until measurement proves that RADV and llama.cpp avoid the second resident
copy. The 30 GiB physical host cannot admit the `UD-IQ4_XS` loading peak under
that conservative rule. `UD-IQ3_S` requires nearly every non-reserved byte and
is not a practical active-desktop candidate.

The model opens only when the live preflight accepts both host memory and the
RADV aggregate budget. A successful load replaces the 64 MiB compute estimate
and rounded gate with the exact startup memory breakdown. A rejected preflight
is a capacity result; swap does not convert it into permission to load.

The refreshed verified-artifact preflights reject host capacity and accept
Vulkan capacity for both resident candidates. `UD-Q2_K_XL` reports
15,474,085,888 available host bytes against a 24,861,367,200-byte requirement.
`UD-IQ3_XXS` reports 15,480,442,880 available host bytes against a
27,040,988,064-byte requirement. Both commands return 3, and no llama.cpp
process opens either model. The exact outputs are retained under
`evidence/model-admission/`.
