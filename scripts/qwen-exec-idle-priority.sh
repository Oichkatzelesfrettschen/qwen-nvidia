#!/bin/sh
set -eu

# Establish nice 19 and the idle I/O class in this process, verify both against
# the kernel, and replace this process with the command named in the argv.
#
# The priority belongs to the process before its first instruction rather than
# to a parent that reaches it afterwards. A parent that spawns a runtime and
# then renices it by pid leaves a window in which the child has already run:
# on the image path that window covers Vulkan instance creation and device
# enumeration, which is the part of a generation that competes with a resident
# language model for the same device. Executing through this wrapper closes the
# window, because `exec` keeps the pid, the process group, and the session the
# spawning parent recorded, so the parent's cancellation target and its wait
# are unchanged while the priority is already in force.
#
# `renice --priority` names an absolute nice value. `renice -n` is relative
# where POSIXLY_CORRECT is set (renice(1), util-linux 2.42.2), and `nice -n 19`
# is always an increment against the caller, so a caller already at a negative
# nice reaches something below 19 through either of those spellings. The
# absolute form is what makes the runtime's priority a property of the runtime
# rather than of whatever launched it.
#
# The idle I/O class is available to an ordinary user (ionice(1)) and is read
# back here as the ioprio value the kernel holds. Whether the block layer acts
# on that class depends on the active elevator: BFQ implements it and kyber
# does not, and this host serves its model directory from an nvme device under
# kyber. The wrapper therefore establishes and proves the class, and it makes
# no claim about the I/O the class produces.
#
# A refusal exits 125, ahead of the runtime, and prints what was expected
# beside what the kernel reported. 125 stays clear of the exit statuses the
# image runtime itself produces, so a caller reads a priority refusal apart
# from a generation failure.

if [ "$#" -lt 1 ]; then
    printf 'usage: %s COMMAND [ARGUMENT...]\n' "$0" >&2
    exit 2
fi

target_nice=19

# The kernel read-back rather than the tool exit status is the gate, so a
# renice that fails reaches the refusal below with the value the process
# actually holds instead of ending the shell on `set -e`.
/usr/bin/renice --priority "$target_nice" --pid "$$" >/dev/null || :

observed_nice=$(
    LC_ALL=C /usr/bin/ps -o ni= -p "$$" |
        /usr/bin/awk 'NR == 1 {
            gsub(/[[:space:]]/, "", $0)
            print
        }'
)

if [ "$observed_nice" != "$target_nice" ]; then
    printf 'priority setup refused: expected=%s observed=%s\n' \
        "$target_nice" "${observed_nice:-unavailable}" >&2
    exit 125
fi

/usr/bin/ionice -c 3 -p "$$" || :

observed_ioclass=$(
    LC_ALL=C /usr/bin/ionice -p "$$" 2>/dev/null || :
)

case $observed_ioclass in
    idle | 'idle:'*)
        ;;
    *)
        printf 'I/O priority setup refused: observed=%s\n' \
            "${observed_ioclass:-unavailable}" >&2
        exit 125
        ;;
esac

printf 'qwen_priority_ready pid=%s nice=%s ioclass=idle\n' "$$" "$target_nice" >&2

exec "$@"
