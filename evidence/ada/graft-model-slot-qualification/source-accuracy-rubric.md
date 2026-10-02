# Fixed source accuracy rubric

The rubric freezes source-grounded discriminators before reviewing the fresh
model replies. The source revision is
`0c85040e3bda01913d687fca538b3fa49f6af82b` in
`Oichkatzelesfrettschen/discobsd-2040-unofficial`. Each symbol below carries the
prefix `sys/arch/rp2040/`. The sample remains the ten IDs in
`../graft-deep-pilot/accuracy-sample.txt`.

Review each distinct factual claim as supported, unsupported, contradicted, or
withheld. Preserve the original summary and a source witness for each verdict.
Missing or blank summaries fail coverage. Report per-symbol factual agreement
separately from exact repeated text. Broad purpose statements can be supported
without inventing implementation details; omitted details are separate from
incorrect claims. Source establishes implementation, not measured board behavior.

| Symbol | Source-grounded mechanism | Decisive discriminator |
| --- | --- | --- |
| `dev/flash.c#dhara_nand_copy` | Lines 374-404 copy one 1024-byte Dhara page through static scratch in 256-byte program chunks, check scratch ownership and destination bounds, and propagate read/program errors. `flash.h` defines both sizes. | Byte-by-byte copying contradicts the chunk loop. Caller serialization is a constraint, not a lock acquired by this function. |
| `dev/flash.c#flsize` | Lines 549-562 lazily set up the device and return partition sector count shifted right once; invalid device or failed setup returns zero. Partition counts use 512-byte sectors; RP2040 `DEV_BSIZE` is 1024. | The return value counts 1024-byte logical blocks, not bytes or unchanged 512-byte sectors. |
| `dev/uart.c#uartclose` | Lines 232-243 select the static minor-indexed tty, reject an absent address with ENODEV, then call `ttywflush` and `ttyclose`. `sys/kern/tty.c` lines 222-227 wait for output and flush input; lines 738-744 flush both queues and clear tty state and process group. | The function does not free an allocated tty. Output draining precedes queue/state cleanup. |
| `dev/uart.h#uart_rx_ready` | Lines 83-87 return true when the receive-FIFO-empty flag is clear. `UART_FR_RXFE` is 0x10. | Empty means false, rather than ready. |
| `dev/usb.c#usb_e15_critical` | Lines 386-392 compare unsigned timer elapsed since SOF against inclusive 800..998 microseconds. Bulk-IN kick delays AVAILABLE handoff inside that interval. | Reversed interval or unconditional transmission avoidance contradicts the predicate/caller. The predicate itself neither sleeps nor sends. |
| `dev/usb.c#usbgetc` | Lines 1188-1200 raise tty priority, poll `usb_service` while the RX ring is empty, consume one byte, advance the tail, and restore priority. `usb_service` lines 851-950 handle SOF, reset, setup, completions, pending TX, and RX rearming. | The read is blocking/polled, not an empty-ring immediate return. E15 handling is indirect through service/kick, rather than a predicate in `usbgetc`. |
| `dev/usb.h#usbopen` | Line 103 declares the open interface. The implementation at `usb.c` lines 1030-1063 uses static `usbttys[0]`, sets tty defaults/handler, enforces exclusive open, feeds pre-open RX bytes, and delegates to `ttyopen`. | The sampled symbol is a prototype. Claims of tty allocation or endpoint/buffer initialization in `usbopen` contradict its body. |
| `rp2040/exec_hsaout.c#exec_hsaout_text` | Lines 222-256 validate headers and text length, choose the SwapRAM owner-checked or static codec workspace, expand text, check CRC through `hsx_load`, release the owned workspace, and return the result. `hsx_stream.c` checks exact output length, complete compressed input, decoder progress/finish, and computes CRC. | Packed-text restoration includes length and CRC checks. A successful decompression alone is insufficient. The function restores text rather than loading data or setting up a process stack. |
| `rp2040/machdep.c#bzero` | Lines 997-1041 return for zero length, write an alignment prefix, use an unrolled aligned-word loop, finish remaining words and trailing bytes. | Zero length causes no alignment write. Descriptions limited to byte-at-a-time clearing contradict the word paths. |
| `rp2040/machdep.c#swap_cursor_init` | Lines 203-227 reuse a valid tagged scratch index, otherwise sample seven ROSC bits up to eight times with rejection and index-zero fallback, calculate aligned `swapnext`, and publish it. Lines 230-244 publish the tag/index to watchdog scratch0. | The mechanism persists watchdog scratch state rather than writing flash metadata. Sampling is bounded and retains a deterministic fallback. |

## Replay queries

Run `rg -n` with the ten symbol names on the pinned pilot paths, then `sed -n`
over the function ranges above. Follow the tty callees with
`git show <source-revision>:sys/kern/tty.c` and the same range queries. Resolve
the block-size macro with
`git grep -n 'define.*DEV_BSIZE' <source-revision> -- sys`. Follow
`hsx_load`, `hsx_expand`, `usb_service`, `usb_tx_kick`, and
`swap_cursor_publish` with `rg -n` and read each complete body. These queries
read the pinned source and write only command output; they execute no board
operation.
