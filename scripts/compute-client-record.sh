#!/bin/sh
# The during-run compute-client record both device admission harnesses retain.
#
# A harness samples `nvidia-smi --query-compute-apps=pid,process_name,used_memory`
# while its job runs and counts the ticks whose record names the runtime, which
# is how a run proves the runtime reached the card. The record therefore has to
# carry that name: a scrub that loses it reports every run as rejected whatever
# the device did, and it fails that way silently because the count simply reads
# zero.
#
# Driver 615.71.09 answers with three csv fields, so the name is the second and
# the used memory the last; an earlier driver on this host answered without the
# pid, leaving two, which is why the field count rather than a fixed index
# selects the name. process_name carries the whole command line for a browser or
# a compositor, so the record keeps the executable's basename and drops the
# arguments with it, along with the pid the comparison never needs.
#
# Input is the sampler's raw file, one `STAMP\tLEASE\tCSV` line per client and a
# `STAMP\tLEASE\ttick` line per sample. A sampler that records its own lines --
# the geometry harness writes `runtime pid=... device_fds=...` beside each tick
# -- has them carried through, because only a row nvidia-smi wrote as csv is a
# row this reduces. Output is the same shape with the client field reduced to
# `NAME BYTES UNIT`. scripts/test-admit-client-scrub.sh drives this function
# with recorded rows from both driver forms.

qwen_compute_client_record() {
    awk -F '\t' -v OFS='\t' '
        index($3, ", ") == 0 { print; next }
        {
            fields = split($3, row, ", ")
            name = fields >= 3 ? row[2] : row[1]
            split(name, argv0, " ")
            n = split(argv0[1], path, "/")
            split(row[fields], memory, " ")
            print $1, $2, path[n] " " memory[1] " " memory[2]
        }'
}
