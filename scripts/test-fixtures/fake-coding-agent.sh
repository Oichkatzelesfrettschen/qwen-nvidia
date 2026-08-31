#!/bin/sh
set -eu

# Stand-in for the pinned Qwen Code runtime inside coding-service tests.
# The behavior is part of the repository state the job was opened over: the
# worktree's FIXTURE_BEHAVIOR file names what the agent does, so a test
# selects a behavior by choosing a base commit rather than by a side
# channel the real runtime would lack.

mode=${1:-apply}
behavior=$(cat FIXTURE_BEHAVIOR 2>/dev/null || echo edit)

case $behavior in
edit)
    [ "$mode" = plan ] && { echo "plan: edit hello.txt"; exit 0; }
    printf 'hello from the fixture agent\n' >hello.txt
    ;;
many-files)
    index=0
    while [ "$index" -lt 20 ]; do
        printf 'file %s\n' "$index" >"generated-$index.txt"
        index=$((index + 1))
    done
    ;;
big-patch)
    dd if=/dev/zero bs=1024 count=300 2>/dev/null | tr '\0' 'a' >big.txt
    ;;
sleep-trap)
    trap '' TERM
    sleep 60
    ;;
daemon)
    setsid sh -c 'sleep 300' &
    printf 'daemon spawned\n' >daemon.txt
    ;;
push)
    git push origin HEAD 2>push-error.txt || printf 'push refused\n' >push.txt
    ;;
home-probe)
    printf '%s\n' "$HOME" >home.txt
    ls "$HOME/.ssh" >ssh.txt 2>&1 || printf 'no ssh state\n' >>ssh.txt
    ;;
symlink)
    ln -s /etc/passwd escape-link
    ;;
*)
    printf 'unknown fixture behavior %s\n' "$behavior" >&2
    exit 1
    ;;
esac
printf '{"event":"done","mode":"%s","behavior":"%s"}\n' "$mode" "$behavior"
