#!/bin/sh
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
    printf 'usage: %s SSH_TARGET [LOCAL_PORT [REMOTE_PORT]]\n' "$0" >&2
    exit 2
fi

ssh_target=$1
local_port=${2:-8080}
remote_port=${3:-8080}
broker_local_port=${QWEN_WEB_BROKER_LOCAL_PORT:-8571}
broker_remote_port=${QWEN_WEB_BROKER_PORT:-8571}

case $local_port:$remote_port:$broker_local_port:$broker_remote_port in
    *[!0-9:]* | :* | *:)
        printf 'ports must be integers from 1024 through 65535\n' >&2
        exit 2
        ;;
esac
if [ "$local_port" -lt 1024 ] || [ "$local_port" -gt 65535 ] || \
   [ "$remote_port" -lt 1024 ] || [ "$remote_port" -gt 65535 ] || \
   [ "$broker_local_port" -lt 1024 ] || [ "$broker_local_port" -gt 65535 ] || \
   [ "$broker_remote_port" -lt 1024 ] || [ "$broker_remote_port" -gt 65535 ]; then
    printf 'ports must be integers from 1024 through 65535\n' >&2
    exit 2
fi
if [ "$local_port" -eq "$broker_local_port" ]; then
    printf 'the local server and broker ports must differ\n' >&2
    exit 2
fi

printf 'Open http://127.0.0.1:%s after the tunnel reports no error.\n' "$local_port"
printf 'Broker endpoint http://127.0.0.1:%s forwards to remote port %s.\n' \
    "$broker_local_port" "$broker_remote_port"
if [ "$local_port" -ne "$remote_port" ]; then
    printf 'Launch the remote session with QWEN_WEB_BROKER_ORIGIN=http://127.0.0.1:%s.\n' \
        "$local_port"
fi
# Both tunnel endpoints bind loopback. The laptop exposes no unauthenticated
# llama.cpp listener to its LAN, and the browser remains on the client machine
# rather than competing with Raven2 for shared DDR4 or graphics scheduling.
exec ssh -N -T \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -L "127.0.0.1:$local_port:127.0.0.1:$remote_port" \
    -L "127.0.0.1:$broker_local_port:127.0.0.1:$broker_remote_port" \
    "$ssh_target"
