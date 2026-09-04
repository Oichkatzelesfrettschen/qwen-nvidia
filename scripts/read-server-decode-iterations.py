#!/usr/bin/env python3
"""Read per-iteration batch composition out of a llama-server -lv 10 log.

`update_slots` in tools/server/server-context.cpp builds one batch per pass:
each slot holding a sampled token adds it and logs `slot decode token, id=N`,
each slot still holding prompt tokens adds a chunk and logs `prompt processing,
n_tokens = N, progress = P`, then `llama_decode` runs and the server logs
`decode: n_batch (effective)`. The lines between two decode lines therefore
describe the batch the second one carried, so the log alone states, for every
pass, how many sequences decoded together and how many were still in prefill.
That is the instrument a concurrency claim rests on: the column count the
mat-mul saw is the count of decoding slots in that pass, and a request whose
history ran through a different sequence of widths than its neighbor has a
different accumulation path even under a deterministic kernel.

The sampled token id on each decode-token line is the reply itself, so the
reader also names the first pass in which slots sharing a burst sampled
different ids, the width of that pass, and whether every earlier pass of the
burst held every slot of it. A burst is the set of tasks whose prompts
arrived ahead of one decode call.

Output is TSV on stdout: a `pass` row per decode call and a `burst` row per
burst, with `--passes` alone or `--bursts` alone selecting one kind.
"""

import argparse
import hashlib
import re
import sys

TIMESTAMP = r"(?P<t>\d+\.\d+\.\d+\.\d+) "
NEW_PROMPT = re.compile(
    TIMESTAMP + r"I slot +operator\(\): id +(?P<slot>\d+) \| task (?P<task>\d+) "
    r"\| new prompt, n_ctx_slot = \d+, n_keep = \d+, task\.n_tokens = (?P<n>\d+)")
PROMPT_CHUNK = re.compile(
    TIMESTAMP + r"I slot +update_slots: id +(?P<slot>\d+) \| task (?P<task>\d+) "
    r"\| prompt processing, n_tokens = +(?P<n>\d+), progress = (?P<p>[0-9.]+)")
DECODE_TOKEN = re.compile(
    TIMESTAMP + r"D slot handle_last_: id +(?P<slot>\d+) \| task (?P<task>\d+) "
    r"\| slot decode token, id=(?P<id>-?\d+), n_ctx = \d+, n_tokens = (?P<n>\d+)")
DECODE_CALL = re.compile(TIMESTAMP + r"D srv +decode: n_batch \(effective\)")
RELEASE = re.compile(
    TIMESTAMP + r"I slot +release: id +(?P<slot>\d+) \| task (?P<task>\d+) "
    r"\| stop processing: n_tokens = (?P<n>\d+)")


def seconds(stamp):
    """common/log.cpp prints minutes.seconds.milliseconds.microseconds."""
    minutes, secs, millis, micros = stamp.split(".")
    return (int(minutes) * 60 + int(secs) + int(millis) / 1000.0
            + int(micros) / 1e6)


def read_log(path):
    passes = []
    pending_decode = []
    pending_prompt = []
    pending_arrived = []
    arrivals = []
    releases = {}
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            match = DECODE_TOKEN.match(line)
            if match:
                pending_decode.append((int(match["slot"]), int(match["task"]),
                                       int(match["id"]), int(match["n"])))
                continue
            match = PROMPT_CHUNK.match(line)
            if match:
                pending_prompt.append((int(match["slot"]), int(match["task"]),
                                       int(match["n"]), float(match["p"])))
                continue
            match = NEW_PROMPT.match(line)
            if match:
                arrivals.append((seconds(match["t"]), int(match["slot"]),
                                 int(match["task"]), int(match["n"]),
                                 len(passes)))
                pending_arrived.append((int(match["slot"]), int(match["task"]),
                                        int(match["n"])))
                continue
            match = DECODE_CALL.match(line)
            if match:
                passes.append({
                    "index": len(passes),
                    "t": seconds(match["t"]),
                    "decode": pending_decode,
                    "prompt": pending_prompt,
                    "arrived": pending_arrived,
                })
                pending_decode = []
                pending_prompt = []
                pending_arrived = []
                continue
            match = RELEASE.match(line)
            if match:
                releases[int(match["task"])] = seconds(match["t"])
    return passes, arrivals, releases


BURST_GAP_S = 0.25


def bursts_of(arrivals):
    """Group prompts by arrival time.

    A burst's requests leave one client loop inside a few milliseconds while
    two bursts are separated by a whole reply, so a gap above BURST_GAP_S
    between consecutive arrivals is a burst boundary. Grouping by the decode
    call a prompt entered would split a burst whose prompts exceed n_batch,
    which is the case the composition read exists to expose.
    """
    groups = []
    last = None
    for t, slot, task, n_tokens, _pass_index in sorted(arrivals):
        if last is None or t - last > BURST_GAP_S:
            groups.append([])
        groups[-1].append((slot, task, n_tokens))
        last = t
    return groups


def full_width(ordered, producing_width, length, width):
    """Whether every decode pass up to `length` tokens held the whole burst.

    The first token of each reply comes out of the prefill pass, whose decode
    width is whatever else was decoding, so the check starts at the second
    token; a burst that prefilled in two passes has some members' second
    tokens produced beside the others' prompts and reads `no` here.
    """
    earlier = {producing_width[task][k]
               for task in ordered for k in range(1, length)}
    if not earlier:
        return "-"
    return "yes" if earlier == {width} else "no"


def burst_rows(passes, arrivals, releases):
    rows = []
    replies_by_slot = {}
    for burst_index, members in enumerate(bursts_of(arrivals)):
        tasks = {task for _slot, task, _n in members}
        width = len(tasks)
        # Each task's reply, in pass order, with the width of the pass that
        # produced each token: the decode-token line is logged in the pass
        # after the one that sampled it, so the producing pass is the previous.
        replies = {task: [] for task in tasks}
        producing_width = {task: [] for task in tasks}
        prefill_passes = 0
        prefill_split = False
        arrival_pass = {task: pass_index for _t, _slot, task, _n, pass_index
                        in arrivals if task in tasks}
        # The burst's passes run from its first prompt's entry to its last
        # release, so a task id the server reused later stays out of it.
        first_pass = min(arrival_pass.values())
        last_time = max(releases.get(task, float("inf")) for task in tasks)
        burst_passes = [record for record in passes
                        if record["index"] >= first_pass and record["t"] <= last_time]
        for record in burst_passes:
            pass_index = record["index"]
            prompt_tasks = {task for task, entered in arrival_pass.items()
                            if entered == pass_index}
            prompt_tasks |= {task for _slot, task, _n, _p in record["prompt"]
                             if task in tasks}
            if prompt_tasks:
                prefill_passes += 1
                if len(prompt_tasks) != width:
                    prefill_split = True
            decoding = [entry for entry in record["decode"] if entry[1] in tasks]
            previous = passes[pass_index - 1] if pass_index else None
            previous_width = (len(previous["decode"]) if previous else 0)
            for _slot, task, token, _n in decoding:
                replies[task].append(token)
                producing_width[task].append(previous_width)
        ordered = sorted(tasks)
        lengths = {len(replies[task]) for task in ordered}
        first_divergence = ""
        divergence_width = ""
        history_full_width = ""
        if width == 1 and lengths:
            # One sequence has nothing to part from; every pass it decoded
            # in held the whole burst by construction.
            first_divergence, divergence_width = "none", "-"
            history_full_width = full_width(ordered, producing_width, min(lengths), width)
        if width > 1 and lengths:
            shortest = min(lengths)
            for position in range(shortest):
                ids = {replies[task][position] for task in ordered}
                if len(ids) > 1:
                    first_divergence = position + 1
                    widths = {producing_width[task][position] for task in ordered}
                    divergence_width = "/".join(str(w) for w in sorted(widths))
                    history_full_width = full_width(
                        ordered, producing_width, position + 1, width)
                    break
            if not first_divergence:
                first_divergence = "none"
                divergence_width = "-"
                history_full_width = full_width(
                    ordered, producing_width, shortest, width)
        distinct = len({tuple(replies[task]) for task in ordered})
        # The passes in which every member of the burst decoded together are
        # the full-width regime: their count and span give the iteration cost
        # at exactly this column count, free of prefill and of any pass a
        # member sat out.
        full = [record["t"] for record in burst_passes
                if {entry[1] for entry in record["decode"]} >= tasks
                and len(record["decode"]) == width]
        decode_passes = sum(1 for record in burst_passes
                            if any(entry[1] in tasks for entry in record["decode"]))
        full_span = "%.6f" % (full[-1] - full[0]) if len(full) > 1 else "0"
        slot_of = {task: slot for slot, task, _n in members}
        for task in ordered:
            replies_by_slot.setdefault((width, slot_of[task]), set()).add(
                tuple(replies[task]))
        rows.append("\t".join(str(v) for v in (
            "burst", burst_index, width, prefill_passes,
            "yes" if prefill_split else "no",
            min(lengths) if lengths else 0, distinct,
            first_divergence, divergence_width, history_full_width,
            decode_passes, len(full), full_span)))
    # Each slot's reply per burst, as a digest, so two runs are comparable by
    # eye and a reply's identity survives the log it came from.
    for burst_index, members in enumerate(bursts_of(arrivals)):
        last_time = max(releases.get(task, float("inf")) for _s, task, _n in members)
        for slot, task, _n in sorted(members):
            ids = [entry[2] for record in passes if record["t"] <= last_time
                   for entry in record["decode"] if entry[1] == task]
            digest = hashlib.sha256(
                ",".join(str(i) for i in ids).encode()).hexdigest()[:12]
            rows.append("\t".join(str(v) for v in (
                "reply", burst_index, len(members), slot, len(ids), digest)))
    # Whether a slot answers the same way in every burst of its width: a slot
    # whose reply is fixed across bursts while its neighbors differ from it
    # states a position effect, and a slot whose reply moves between bursts
    # states one that is not fixed by position.
    for (width, slot), variants in sorted(replies_by_slot.items()):
        rows.append("\t".join(str(v) for v in (
            "slot", width, slot, len(variants))))
    return rows


def pass_rows(passes):
    rows = []
    for record in passes:
        decode_slots = sorted(slot for slot, _task, _id, _n in record["decode"])
        prompt_tokens = sum(n for _s, _t, n, _p in record["prompt"])
        prompt_slots = len(record["prompt"]) + len(record["arrived"])
        prompt_tokens += sum(n for _slot, _task, n in record["arrived"])
        rows.append("\t".join(str(v) for v in (
            "pass", record["index"], "%.6f" % record["t"],
            len(decode_slots), prompt_slots, prompt_tokens,
            ",".join(str(s) for s in decode_slots) or "-",
            ",".join(str(token) for _s, _t, token, _n in record["decode"]) or "-")))
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("log")
    parser.add_argument("--passes", action="store_true",
                        help="emit the per-pass rows alone")
    parser.add_argument("--bursts", action="store_true",
                        help="emit the per-burst rows alone")
    args = parser.parse_args()
    passes, arrivals, releases = read_log(args.log)
    if not passes:
        sys.exit("the log holds no decode call; it needs -lv 10")
    if not arrivals:
        sys.exit("the log holds no prompt arrival")
    want_passes = args.passes or not args.bursts
    want_bursts = args.bursts or not args.passes
    if want_passes:
        print("kind\tpass\tt_s\tdecode_slots\tprompt_slots\tprompt_tokens"
              "\tslot_ids\tsampled_ids")
        print("\n".join(pass_rows(passes)))
    if want_bursts:
        print("kind\tburst\twidth\tprefill_passes\tprefill_split\treply_tokens"
              "\tdistinct_replies\tfirst_divergence\tdivergence_pass_width"
              "\thistory_full_width\tdecode_passes\tfull_width_passes"
              "\tfull_width_span_s")
        print("# reply rows: kind\tburst\twidth\tslot\ttokens\tsha256_12")
        print("# slot rows: kind\twidth\tslot\tdistinct_replies_across_bursts")
        print("\n".join(burst_rows(passes, arrivals, releases)))


if __name__ == "__main__":
    main()
