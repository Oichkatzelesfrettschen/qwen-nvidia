#!/usr/bin/env python3
"""Hold read-server-decode-iterations.py to a synthetic -lv 10 log.

The fixture writes the four line shapes the reader consumes -- prompt arrival,
decode call, per-slot sampled token, and slot release -- in the order
update_slots emits them, for three bursts: a width-3 burst whose prompts
enter one decode call and whose slots part at the third token, a width-1
burst, and a width-5 burst whose prompts enter two decode calls so its first
members decode beside the others' prefill. The assertions are the reader's
claims: the burst grouping, the prefill pass count, the first divergence and
the width of the pass that produced it, the full-width history flag, the
full-width pass count and span, and the per-slot reproducibility rows.
"""

import pathlib
import subprocess
import sys
import tempfile

READER = pathlib.Path(__file__).resolve().parent / "read-server-decode-iterations.py"


class Log:
    def __init__(self):
        self.lines = []
        self.micros = 0

    def stamp(self):
        self.micros += 1000
        minutes, rest = divmod(self.micros, 60_000_000)
        seconds, rest = divmod(rest, 1_000_000)
        millis, micros = divmod(rest, 1000)
        return "%d.%02d.%03d.%03d" % (minutes, seconds, millis, micros)

    def arrive(self, slot, task, n):
        self.lines.append("%s I slot   operator(): id  %d | task %d | new prompt, n_ctx_slot = 4096, "
                          "n_keep = 0, task.n_tokens = %d" % (self.stamp(), slot, task, n))

    def decode(self):
        self.lines.append("%s D srv        decode: n_batch (effective) = 2048, off = 0" % self.stamp())

    def token(self, slot, task, token, n):
        self.lines.append("%s D slot handle_last_: id  %d | task %d | slot decode token, id=%d, "
                          "n_ctx = 4096, n_tokens = %d, truncated = 0" % (self.stamp(), slot, task, token, n))

    def release(self, slot, task, n):
        self.lines.append("%s I slot      release: id  %d | task %d | stop processing: n_tokens = %d, "
                          "truncated = 0" % (self.stamp(), slot, task, n))

    def gap(self, seconds):
        self.micros += int(seconds * 1_000_000)


def burst_three(log, base):
    # Task ids are unique across the log, the way the server numbers them.
    members = ((0, base), (1, base + 2), (2, base + 1))
    for slot, task in members:
        log.arrive(slot, task, 400)
    log.decode()  # the prefill pass carries all three prompts
    replies = {base: [17, 78, 17, 579], base + 2: [17, 78, 579, 5721],
               base + 1: [17, 78, 17, 579]}
    for position in range(4):
        for slot, task in members:
            log.token(slot, task, replies[task][position], 400 + position)
        log.decode()
    for slot, task in members:
        log.release(slot, task, 404)


def burst_one(log):
    log.arrive(0, 3, 400)
    log.decode()
    for position, token in enumerate((1, 2, 3, 4)):
        log.token(0, 3, token, 400 + position)
        log.decode()
    log.release(0, 3, 404)


def burst_five(log):
    early = [(0, 10), (1, 11), (2, 12), (3, 13)]
    late = [(4, 14)]
    for slot, task in early:
        log.arrive(slot, task, 500)
    log.decode()  # four prompts fill n_batch; the fifth waits
    for slot, task in early:
        log.token(slot, task, 9, 500)
    for slot, task in late:
        log.arrive(slot, task, 500)
    log.decode()  # four decoding beside one prefill
    for slot, task in early:
        log.token(slot, task, 9, 501)
    for slot, task in late:
        log.token(slot, task, 9, 500)
    log.decode()
    for slot, task in early + late:
        log.token(slot, task, 9, 502 if (slot, task) in early else 501)
    log.decode()
    for slot, task in early + late:
        log.token(slot, task, 8 if slot == 4 else 9, 503 if (slot, task) in early else 502)
    log.decode()
    for slot, task in early + late:
        log.release(slot, task, 505)


def main():
    log = Log()
    burst_three(log, 0)
    log.gap(1.0)
    burst_three(log, 20)
    log.gap(1.0)
    burst_one(log)
    log.gap(1.0)
    burst_five(log)
    with tempfile.TemporaryDirectory() as directory:
        path = pathlib.Path(directory) / "server.log"
        path.write_text("\n".join(log.lines) + "\n")
        output = subprocess.run([sys.executable, str(READER), "--bursts", str(path)],
                                check=True, capture_output=True, text=True).stdout
        passes = subprocess.run([sys.executable, str(READER), "--passes", str(path)],
                                check=True, capture_output=True, text=True).stdout
    rows = [line.split("\t") for line in output.splitlines() if line and not line.startswith("#")]
    bursts = [row for row in rows if row[0] == "burst"]
    slots = [row for row in rows if row[0] == "slot"]
    failures = []

    def check(condition, description):
        print(("ok " if condition else "FAIL ") + description)
        if not condition:
            failures.append(description)

    check(len(bursts) == 4, "four bursts are grouped by arrival gap")
    check([row[2] for row in bursts] == ["3", "3", "1", "5"], "burst widths read 3, 3, 1, 5")
    three = bursts[0]
    check(three[3] == "1" and three[4] == "no", "the width-3 burst prefilled in one pass")
    check(three[7] == "3" and three[8] == "3", "the width-3 burst parts at token 3 in a width-3 pass")
    check(three[9] == "yes", "every pass of the width-3 burst held the whole burst")
    check(three[6] == "2", "the width-3 burst holds two distinct replies")
    check(three[10] == "4" and three[11] == "4", "the width-3 burst decoded in four passes, all full width")
    one = bursts[2]
    check(one[7] == "none" and one[9] == "yes", "a width-1 burst has nothing to part from and is full width")
    five = bursts[3]
    check(five[3] == "2" and five[4] == "yes", "the width-5 burst prefilled in two passes")
    check(five[9] == "no", "the width-5 burst's history holds a pass below full width")
    check(five[7] == "3" and five[8] == "5", "the width-5 burst parts at token 3 in a width-5 pass")
    check(five[11] == "3", "three passes of the width-5 burst held all five")
    reproducible = {(row[1], row[2]): row[3] for row in slots}
    check(reproducible.get(("3", "0")) == "1" and reproducible.get(("3", "1")) == "1",
          "each width-3 slot answers the same way in both bursts")
    pass_rows = [line.split("\t") for line in passes.splitlines()[1:]]
    check(pass_rows[0][3] == "0" and pass_rows[0][4] == "3" and pass_rows[0][5] == "1200",
          "the first pass carries three prompts of 400 tokens and no decode")
    check(pass_rows[1][3] == "3", "the second pass decodes three slots")
    if failures:
        print("read_server_decode_iterations=rejected failures=%d" % len(failures), file=sys.stderr)
        sys.exit(1)
    print("read_server_decode_iterations=accepted")


if __name__ == "__main__":
    main()
