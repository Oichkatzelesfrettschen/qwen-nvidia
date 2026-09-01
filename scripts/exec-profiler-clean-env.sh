#!/bin/sh
set -eu

# Run a profiler with an allowlisted environment, then exec the command its
# argv names.
#
# Nsight Systems records the capturing process's environment into its report:
# `TARGET_INFO_SYSTEM_ENV` holds a `DeviceEnvironment` string carrying every
# exported variable, and `nsys export --type sqlite` carries it forward. A
# capture taken from an ordinary interactive shell therefore absorbs whatever
# that shell exported, which is how a third-party API key and a session token
# reached eight committed `.nsys-rep` files in this tree.
#
# `env -i` starts the child from an empty environment and the assignments
# below name everything it gets. An allowlist rather than a denylist, because
# a denylist protects against the variable names somebody thought of: the key
# that leaked sat beside a `shell_environment_policy` exclusion naming it,
# which the profiler never consulted because it ran outside that tool.
#
# The command still reaches the device: CUDA needs the driver's device nodes
# rather than environment state, and the two CUDA variables passed through are
# the ones a measurement arm legitimately varies.
#
# usage: exec-profiler-clean-env.sh COMMAND [ARGUMENT...]
#   scripts/exec-profiler-clean-env.sh nsys profile -o OUT llama-bench ...
#   scripts/exec-profiler-clean-env.sh ncu --set full llama-bench ...
#
# QWEN_PROFILER_EXTRA_PATH prepends one directory to the fixed PATH, for a
# build tree whose binaries live outside the system prefixes.

if [ "$#" -lt 1 ]; then
    printf 'usage: %s COMMAND [ARGUMENT...]\n' "$0" >&2
    exit 2
fi

profiler_path=/opt/cuda/bin:/usr/local/cuda/bin:/usr/bin:/bin
if [ -n "${QWEN_PROFILER_EXTRA_PATH:-}" ]; then
    case $QWEN_PROFILER_EXTRA_PATH in
        *:*)
            printf 'QWEN_PROFILER_EXTRA_PATH names one directory: %s\n' \
                "$QWEN_PROFILER_EXTRA_PATH" >&2
            exit 2
            ;;
    esac
    [ -d "$QWEN_PROFILER_EXTRA_PATH" ] || {
        printf 'QWEN_PROFILER_EXTRA_PATH is not a directory: %s\n' \
            "$QWEN_PROFILER_EXTRA_PATH" >&2
        exit 2
    }
    profiler_path=$QWEN_PROFILER_EXTRA_PATH:$profiler_path
fi

user_name=$(id -un)

exec env -i \
    HOME="${HOME:?}" \
    USER="$user_name" \
    LOGNAME="$user_name" \
    PATH="$profiler_path" \
    SHELL=/bin/sh \
    TERM="${TERM:-dumb}" \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TMPDIR="${TMPDIR:-/tmp}" \
    CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}" \
    CUDA_MODULE_LOADING="${CUDA_MODULE_LOADING:-LAZY}" \
    "$@"
