#!/bin/sh
set -eu

# Stand in for nvidia-smi's compute-client listing on a host with no card, or
# with a card whose driver answers. geometry-resident-driver.py holds the
# profile row's residency allowance against this reading, so what the
# allowance does when the reading is absent, zero or over the ceiling is only
# testable by supplying each. The mode is the first argument and the worker's
# process id the second, which the driver substitutes for {pid}:
#
#   held      the pid holds 128 MiB, inside every allowance the tree declares
#   over      the pid holds 4096 MiB, past the 512 MiB a bounded row allows
#   absent    the listing names other processes and not this one
#   unread    the probe fails the way a driver that did not answer does

mode=$1
pid=$2
case $mode in
    held) printf '%s, 128\n' "$pid" ;;
    over) printf '%s, 4096\n' "$pid" ;;
    absent) printf '%s, 173\n' "$((pid + 1))" ;;
    unread) printf 'Unable to determine the device of process %s\n' "$pid" >&2; exit 9 ;;
    *) printf 'fake-residency-probe: unknown mode %s\n' "$mode" >&2; exit 2 ;;
esac
