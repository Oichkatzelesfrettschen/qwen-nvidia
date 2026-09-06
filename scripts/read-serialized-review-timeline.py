#!/usr/bin/env python3
"""Read the generate-then-review timeline out of one client-list sample file.

The image admission samples the driver's compute-client list, the lease's
flock state, and device-global memory at ten hertz through the page turn,
one row per observation:

    STAMP\tLEASE\tclient\tPID, PROCESS_NAME, USED_MIB
    STAMP\tLEASE\tmemory\tUSED_MIB
    STAMP\tLEASE\ttick

LEASE is `held` or `free`. This reader derives the phases the serialized
sequence claims and states whether the order held: the language child is
every llama-server pid the first sample already lists, the generation is the
interval the image runtime's basename appears in, the release is the first
`free` tick after the runtime's last sample, and the reviewer is the first
server pid outside the initial set. The sequence is serialized where the
reviewer's first sample lies after the release; a reviewer seen while the
runtime is still listed or the lease still held refutes it. Device memory is
reported per phase as the maximum of the memory rows inside the phase, except
`floor_from_the_reviewers_first_sample`, the minimum from the reviewer's first
sample onward; the sampler sees process residency rather than the review's end,
so no figure here is "after the review". A phase with no memory row reads null.
`--reviewer-pid` names the child the router spawned for the reviewer, read from
the running process rather than guessed, and without it any server pid outside
the initial set is taken as the reviewer.

A ten-hertz sampler can miss a run shorter than its interval, so a runtime or
reviewer absent from every sample is reported as `not_observed` rather than
inferred either way; the caller decides what that means for its arm.
"""
import argparse
import json
import sys


def parse_rows(path):
    rows = []
    with open(path, encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, 1):
            line = line.rstrip("\n")
            if not line:
                continue
            fields = line.split("\t")
            if len(fields) < 3:
                raise ValueError("%s:%d: fewer than three fields" % (path, line_number))
            try:
                stamp = float(fields[0])
            except ValueError:
                raise ValueError("%s:%d: stamp is not a number" % (path, line_number)) from None
            if fields[1] not in ("held", "free"):
                raise ValueError("%s:%d: lease state is neither held nor free" % (path, line_number))
            kind = fields[2]
            if kind not in ("client", "memory", "tick"):
                raise ValueError("%s:%d: row kind %r is unknown" % (path, line_number, kind))
            payload = fields[3] if len(fields) > 3 else ""
            rows.append((stamp, fields[1], kind, payload))
    if not rows:
        raise ValueError("%s holds no rows" % path)
    return rows


def client_fields(payload):
    parts = [part.strip() for part in payload.split(",")]
    if len(parts) < 3:
        return None
    try:
        pid = int(parts[0])
    except ValueError:
        return None
    name = ",".join(parts[1:-1])
    used = parts[-1].split()[0] if parts[-1] else ""
    try:
        used_mib = int(used)
    except ValueError:
        used_mib = None
    return pid, name, used_mib


def basename(name):
    return name.rsplit("/", 1)[-1]


def analyze(rows, runtime_basename, server_basename="llama-server", reviewer_pid=None):
    stamps = sorted({row[0] for row in rows})
    first_stamp = stamps[0]
    initial_servers = set()
    for stamp, _lease, kind, payload in rows:
        if stamp != first_stamp or kind != "client":
            continue
        parsed = client_fields(payload)
        if parsed and basename(parsed[1]) == server_basename:
            initial_servers.add(parsed[0])
    runtime_stamps = []
    reviewer_stamps = []
    reviewer_pids = set()
    runtime_peak = None
    reviewer_peak = None
    for stamp, _lease, kind, payload in rows:
        if kind != "client":
            continue
        parsed = client_fields(payload)
        if not parsed:
            continue
        pid, name, used_mib = parsed
        if basename(name) == runtime_basename:
            runtime_stamps.append(stamp)
            if used_mib is not None and (runtime_peak is None or used_mib > runtime_peak):
                runtime_peak = used_mib
        elif basename(name) == server_basename and pid not in initial_servers \
                and (reviewer_pid is None or pid == reviewer_pid):
            reviewer_stamps.append(stamp)
            reviewer_pids.add(pid)
            if used_mib is not None and (reviewer_peak is None or used_mib > reviewer_peak):
                reviewer_peak = used_mib
    result = {
        "initial_server_pids": sorted(initial_servers),
        "runtime": "not_observed",
        "reviewer": "not_observed",
        "lease_release_after_runtime": None,
        "serialized": None,
    }
    if runtime_stamps:
        result["runtime"] = {
            "first_seen": min(runtime_stamps),
            "last_seen": max(runtime_stamps),
            "samples": len(runtime_stamps),
            "peak_client_mib": runtime_peak,
        }
        release = None
        for stamp, lease, kind, _payload in rows:
            if kind == "tick" and lease == "free" and stamp > max(runtime_stamps):
                release = stamp
                break
        result["lease_release_after_runtime"] = release
    if reviewer_stamps:
        result["reviewer"] = {
            "first_seen": min(reviewer_stamps),
            "last_seen": max(reviewer_stamps),
            "samples": len(reviewer_stamps),
            "pids": sorted(reviewer_pids),
            "peak_client_mib": reviewer_peak,
        }
    if runtime_stamps and reviewer_stamps:
        release = result["lease_release_after_runtime"]
        reviewer_first = min(reviewer_stamps)
        reviewer_last = max(reviewer_stamps)
        # Every tick from the reviewer's first sample to its last has to read
        # free: a held lease anywhere in the review window is the overlap the
        # lease exists to prevent, whether the holder is this runtime or
        # another workload. Bounding this by the runtime's last sample would
        # make the window empty exactly when the ordering check passes.
        held_while_reviewer = [
            stamp for stamp, lease, kind, _payload in rows
            if kind == "tick" and lease == "held" and reviewer_first <= stamp <= reviewer_last
        ]
        runtime_while_reviewer = [
            stamp for stamp in runtime_stamps if stamp >= reviewer_first
        ]
        result["held_ticks_during_review"] = len(held_while_reviewer)
        result["runtime_samples_during_review"] = len(runtime_while_reviewer)
        result["serialized"] = bool(
            release is not None and reviewer_first > release and reviewer_first > max(runtime_stamps)
            and not held_while_reviewer and not runtime_while_reviewer)
        result["reviewer_after_release_s"] = (
            round(reviewer_first - release, 3) if release is not None else None)
    # device-global memory per phase
    memory = [(stamp, int(payload.split()[0])) for stamp, _lease, kind, payload in rows
              if kind == "memory" and payload.split() and payload.split()[0].isdigit()]

    def peak(lo, hi):
        values = [used for stamp, used in memory if lo <= stamp <= hi]
        return max(values) if values else None

    def floor(lo, hi):
        values = [used for stamp, used in memory if lo <= stamp <= hi]
        return min(values) if values else None

    last_stamp = stamps[-1]
    phases = {}
    if runtime_stamps:
        phases["before_generation"] = floor(first_stamp, min(runtime_stamps))
        phases["during_generation"] = peak(min(runtime_stamps), max(runtime_stamps))
    if reviewer_stamps:
        phases["during_review"] = peak(min(reviewer_stamps), max(reviewer_stamps))
        # The sampler observes process residency rather than the review's
        # own end, so no phase here is "after the review": the reviewer child
        # stays a compute client past its reply. What the rows do state is the
        # floor from the reviewer's first sample onward, which bounds the
        # occupancy the sequence leaves behind, and the count of samples it
        # read is stated beside it so a one-sample figure reads as one sample.
        floor_start = min(reviewer_stamps)
        floor_values = [used for stamp, used in memory if stamp >= floor_start]
        phases["floor_from_the_reviewers_first_sample"] = min(floor_values) if floor_values else None
        result["floor_samples"] = len(floor_values)
    result["device_memory_mib"] = phases
    result["samples"] = len(stamps)
    result["span_s"] = round(last_stamp - first_stamp, 3)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("samples", help="the client-list sample file")
    parser.add_argument("--runtime", required=True, help="the image runtime's basename, sd-cli on the appliance")
    parser.add_argument("--server", default="llama-server", help="the router child's basename")
    parser.add_argument("--reviewer-pid", type=int, default=None,
                        help="the reviewer child's pid, where the caller resolved it")
    arguments = parser.parse_args()
    try:
        rows = parse_rows(arguments.samples)
    except (OSError, ValueError) as error:
        print("read-serialized-review-timeline: %s" % error, file=sys.stderr)
        return 2
    print(json.dumps(analyze(rows, arguments.runtime, arguments.server, arguments.reviewer_pid),
                     sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
