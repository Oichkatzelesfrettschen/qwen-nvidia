#!/usr/bin/env python3
"""Publish a fixture PID and exec an exact argv inside an isolated tmux owner."""

import os
import fcntl
import pathlib
import sys


separator = sys.argv.index("--")
pid_file = pathlib.Path(sys.argv[1])
owner_lock = sys.argv[2]
owner_fd = os.open(owner_lock, os.O_RDWR | os.O_NOFOLLOW)
fcntl.flock(owner_fd, fcntl.LOCK_EX)
if owner_fd != 9:
    os.dup2(owner_fd, 9, inheritable=True)
    os.close(owner_fd)
pid_file.write_text(f"{os.getpid()}\n", encoding="ascii")
os.chmod(pid_file, 0o600)
command = sys.argv[separator + 1:]
os.execv(command[0], command)
