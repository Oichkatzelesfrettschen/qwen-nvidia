#!/usr/bin/env python3
"""Bind a campaign lifecycle registry to positive process-absence evidence."""

import json
import os
import pathlib
import sys


if len(sys.argv) != 6:
    raise SystemExit("usage: campaign-cleanup-record.py LIFECYCLE DEST NONCE REVISION SCRIPT_SHA256")
lifecycle, destination, nonce, revision, script_digest = sys.argv[1:]
processes = []
residue = []
boundaries = set()
completed_boundaries = set()
with open(lifecycle, encoding="utf-8") as handle:
    header = next(handle).rstrip("\n")
    if header != "run_nonce\trevision\tscript_sha256\tsession_id\tpid\tstart_ticks\trole":
        raise SystemExit("campaign lifecycle header mismatch")
    for line in handle:
        row_nonce, row_revision, row_digest, session_id, pid, start, role = line.rstrip("\n").split("\t")
        if (row_nonce, row_revision, row_digest) != (nonce, revision, script_digest):
            raise SystemExit("campaign lifecycle binding mismatch")
        if not session_id.isdigit() or int(session_id) < 1:
            raise SystemExit("campaign session boundary is invalid")
        boundaries.add(int(session_id))
        if role == "boundary_complete":
            if (pid, start) != ("-", "-"):
                raise SystemExit("campaign boundary completion row is invalid")
            completed_boundaries.add(int(session_id))
            continue
        process = {"session_id": int(session_id), "pid": int(pid),
                   "start_ticks": start, "role": role}
        processes.append(process)
        try:
            stat = pathlib.Path("/proc", pid, "stat").read_text(encoding="utf-8")
        except FileNotFoundError:
            continue
        observed = stat[stat.rfind(")") + 2:].split()[19]
        if observed == start:
            residue.append(process)
missing_completions = sorted(boundaries - completed_boundaries)
for proc_entry in pathlib.Path("/proc").iterdir():
    if not proc_entry.name.isdigit():
        continue
    try:
        stat = (proc_entry / "stat").read_text(encoding="utf-8")
        fields = stat[stat.rfind(")") + 2:].split()
    except (FileNotFoundError, ProcessLookupError, PermissionError):
        continue
    session_id = int(fields[3])
    if session_id in boundaries and fields[0] not in ("Z", "X"):
        observed = {"session_id": session_id, "pid": int(proc_entry.name),
                    "start_ticks": fields[19], "role": "boundary_member"}
        if not any(row["pid"] == observed["pid"] and
                   row["start_ticks"] == observed["start_ticks"] for row in residue):
            residue.append(observed)
state = "incomplete" if missing_completions else ("reaped" if not residue else "residue")
payload = {"schema": 1, "state": state,
           "run_nonce": nonce, "revision": revision,
           "campaign_script_sha256": script_digest, "processes": processes,
           "session_boundaries": sorted(boundaries),
           "completed_boundaries": sorted(completed_boundaries),
           "missing_completions": missing_completions, "residue": residue}
target = pathlib.Path(destination)
temporary = target.with_name(target.name + ".new")
descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
os.replace(temporary, target)
raise SystemExit(0 if state == "reaped" else 1)
