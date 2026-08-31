# The 0.8B value-format triple: Q8_0 against F16 against BF16

One checkpoint at three value formats through the production binary and the
served flags on CUDA0, mirrored forward and reverse.
`verify-representation-pair.py` reads the BF16 and derived F16 as structurally
identical with 195 tensors changed in value type alone.

| format | decode tg128@d512 | prefill pp512 | tok/s per column, ne11 7 / 8 / 9 |
| --- | ---: | ---: | --- |
| Q8_0 | 307.6 | 22280 | 225.0 / 223.9 / 173.6 |
| F16 | 203.0 | 21914 | 161.9 / 155.4 / 146.4 |
| BF16 | 198.6 | 19619 | 154.6 / 149.7 / 152.3 |

Q8_0 decodes 1.51 times faster than F16 at equal pp512 prefill, which is the
bandwidth ceiling stated in one row: half the streamed bytes at the same
tensor-core throughput. Q8_0 drops 22% per token at nine columns, the same
cliff Q6_K shows in ../b789-clean-calibration/, and both dense formats decline
gently with no step, so the cliff is dispatch rather than geometry;
../mmvq-crossover-ad104/ carries the extension experiment that moves it. BF16
prefill trails F16 by 10.5% at pp512 with decode inside noise, an open
observation: single depth, mirrored and consistent, mechanism unread.
