#!/bin/sh
set -eu

# The stand-in for the pinned Vulkan image runtime that lets the image service
# be tested without a device. It reads the same argv the profile template
# renders, writes a PNG of exactly the requested dimensions whose pixels are a
# deterministic function of the seed, and leaves every failure the service is
# built to survive reachable through one environment variable.
#
# QWEN_FAKE_IMAGE_MODE selects the arm:
#   ok              a valid PNG at the requested dimensions, then exit 0
#   fail            an exit status of 3 with no file written
#   truncated       the first half of a valid PNG, then exit 0
#   dimension       a valid PNG one pixel narrower than the request, then exit 0
#   hang            SIGTERM ignored and a long sleep, which the service ends
#                   with SIGKILL after its grace
#   device_refusal  an exit status of 3 with no file written and a message
#                   naming the unresolved --backend value, standing in for the
#                   real runtime's device-selection refusal
#                   (evidence/image-appliance/stable-diffusion-cpp-pin.md)
# QWEN_FAKE_IMAGE_SLEEP_SECONDS delays the exit after the file is written, so a
# test can observe the lease held, read status, or cancel while the job runs.
#
# --model and --backend are accepted and recorded but otherwise unused: no
# profile the image service renders names them yet. They are retained because a
# runtime admitted on this device pins every module to the device
# --list-devices names, and QWEN_FAKE_IMAGE_MODE=device_refusal is the refusal
# that pinning produces. --list-devices is a standalone action, read before any
# other flag, the way a real runtime reads it.

usage() {
    printf 'usage: %s --output PATH --width N --height N --seed N [--steps N] [--prompt TEXT] [--negative-prompt TEXT] [--sampler NAME | --sampling-method NAME] [--cfg VALUE | --cfg-scale VALUE] [--model PATH] [--backend VALUE]\n' \
        "$0" >&2
    printf '       %s --list-devices\n' "$0" >&2
    exit 2
}

if [ "${1:-}" = --list-devices ]; then
    if [ -n "${QWEN_FAKE_IMAGE_DEVICE_DESCRIPTION:-}" ]; then
        printf 'Vulkan0\t%s\n' "$QWEN_FAKE_IMAGE_DEVICE_DESCRIPTION"
        exit 0
    fi
    printf 'Vulkan0\t%s\n' 'NVIDIA GeForce RTX 4070 Ti (NVIDIA)'
    # The Vulkan loader enumerates lavapipe beside the pinned driver when
    # nothing narrows the ICD search path; VK_DRIVER_FILES and
    # VK_ICD_FILENAMES are what scripts/vulkan-runtime-env.sh exports to
    # narrow it, so their absence here
    # stands in for the unrestricted appliance state and their presence
    # stands in for the restriction a caller is required to apply before
    # this or any other invocation.
    if [ -z "${VK_DRIVER_FILES:-}" ] || [ -z "${VK_ICD_FILENAMES:-}" ]; then
        printf 'Vulkan1\t%s\n' 'llvmpipe (LLVM 17.0.0, 256 bits)'
    fi
    exit 0
fi

# QWEN_FAKE_IMAGE_PRIORITY_RECORD names a file this runtime writes its own
# scheduling state into before it parses an argument. The state is recorded at
# the runtime's first instruction rather than afterwards, which is what tests
# that the priority was established by whatever executed this rather than by a
# parent reaching it later.
if [ -n "${QWEN_FAKE_IMAGE_PRIORITY_RECORD:-}" ]; then
    printf 'nice=%s ioclass=%s\n' \
        "$(LC_ALL=C /usr/bin/ps -o ni= -p "$$" | /usr/bin/awk 'NR == 1 {
            gsub(/[[:space:]]/, "", $0); print
        }')" \
        "$(LC_ALL=C /usr/bin/ionice -p "$$" 2>/dev/null || printf unavailable)" \
        >"$QWEN_FAKE_IMAGE_PRIORITY_RECORD"
fi

output=''
width=''
height=''
seed=''
steps=1
prompt=''
negative_prompt=''
sampler=''
cfg=''
model_path=''
backend=''

while [ "$#" -gt 0 ]; do
    case $1 in
        --output) [ "$#" -ge 2 ] || usage; output=$2; shift 2 ;;
        --width) [ "$#" -ge 2 ] || usage; width=$2; shift 2 ;;
        --height) [ "$#" -ge 2 ] || usage; height=$2; shift 2 ;;
        --seed) [ "$#" -ge 2 ] || usage; seed=$2; shift 2 ;;
        --steps) [ "$#" -ge 2 ] || usage; steps=$2; shift 2 ;;
        --prompt) [ "$#" -ge 2 ] || usage; prompt=$2; shift 2 ;;
        --negative-prompt) [ "$#" -ge 2 ] || usage; negative_prompt=$2; shift 2 ;;
        --sampler) [ "$#" -ge 2 ] || usage; sampler=$2; shift 2 ;;
        # sd-cli's own long flag names, accepted as aliases so a caller can
        # drive a pinned binary directly with the names
        # evidence/image-appliance/stable-diffusion-cpp-pin.md
        # records (--sampling-method, --cfg-scale) while
        # scripts/image-service.py's rendered profile argv keeps --sampler and
        # --cfg unchanged.
        --sampling-method) [ "$#" -ge 2 ] || usage; sampler=$2; shift 2 ;;
        --cfg) [ "$#" -ge 2 ] || usage; cfg=$2; shift 2 ;;
        --cfg-scale) [ "$#" -ge 2 ] || usage; cfg=$2; shift 2 ;;
        --model) [ "$#" -ge 2 ] || usage; model_path=$2; shift 2 ;;
        --backend) [ "$#" -ge 2 ] || usage; backend=$2; shift 2 ;;
        *) usage ;;
    esac
done

[ -n "$output" ] && [ -n "$width" ] && [ -n "$height" ] && [ -n "$seed" ] || usage

# The pinned runtime picks its encoder from the output path's own extension
# and appends `.png` itself when that extension is absent or unrecognized
# (examples/cli/main.cpp at de298c225bed97c3f9026b73cd7b71e7879bd41b: the
# EncodedImageFormat lookup in examples/common/media_io.cpp recognizes only
# .jpg/.jpeg/.jpe/.png/.webp, lines 458-472 build the base path from the
# requested output unchanged for every other extension, and lines 549-557
# unconditionally append ".png" when the resolved format stayed UNKNOWN).
# Mirroring that rule here is what let a caller passing an extensionless
# `--output` reproduce the defect image-service.py hit against the real
# binary: the fixture used to write the exact path it was given and never
# saw the mismatch a caller of the naive path would.
resolved_output=$output
case $(printf '%s' "$output" | tr '[:upper:]' '[:lower:]') in
    *.jpg | *.jpeg | *.jpe | *.png | *.webp) ;;
    *) resolved_output=${output}.png ;;
esac

mode=${QWEN_FAKE_IMAGE_MODE:-ok}
# QWEN_FAKE_IMAGE_FORCE_MODE overrides QWEN_FAKE_IMAGE_MODE outright, which is
# what a test needs to reach a harness's own safety net: a harness that sets
# QWEN_FAKE_IMAGE_MODE=device_refusal on its refusal-control invocation itself
# leaves nothing its caller passes able to out-argue it through the ordinary
# variable, and a test proving that check catches a runtime answering ok anyway
# needs a second, higher-precedence
# variable to force that answer.
if [ -n "${QWEN_FAKE_IMAGE_FORCE_MODE:-}" ]; then
    mode=$QWEN_FAKE_IMAGE_FORCE_MODE
fi
sleep_seconds=${QWEN_FAKE_IMAGE_SLEEP_SECONDS:-0}

# The argv the service rendered is recorded when a test asks for it, so a
# check on template substitution reads what the runtime received rather than
# what the service intended to send.
if [ -n "${QWEN_FAKE_IMAGE_ARGV_LOG:-}" ]; then
    {
        printf 'output=%s\n' "$output"
        printf 'width=%s\n' "$width"
        printf 'height=%s\n' "$height"
        printf 'seed=%s\n' "$seed"
        printf 'steps=%s\n' "$steps"
        printf 'sampler=%s\n' "$sampler"
        printf 'cfg=%s\n' "$cfg"
        printf 'prompt=%s\n' "$prompt"
        printf 'negative_prompt=%s\n' "$negative_prompt"
        printf 'model_path=%s\n' "$model_path"
        printf 'backend=%s\n' "$backend"
        printf 'nice=%s\n' "$(ps -o ni= -p $$ | tr -d ' ')"
        printf 'timeout=%s\n' "${QWEN_IMAGE_RUNTIME_TIMEOUT_SECONDS:-unset}"
        printf 'vk_driver_files=%s\n' "${VK_DRIVER_FILES:-unset}"
        printf 'vk_icd_filenames=%s\n' "${VK_ICD_FILENAMES:-unset}"
    } >"$QWEN_FAKE_IMAGE_ARGV_LOG"
fi

if [ "$mode" = fail ]; then
    printf 'fake image runtime refused the request\n' >&2
    exit 3
fi

if [ "$mode" = device_refusal ]; then
    printf "backend '%s' was not found\n" "$backend" >&2
    exit 3
fi

if [ "$mode" = hang ]; then
    # The signal is ignored rather than handled, which is the arm that reaches
    # the service's SIGKILL after the termination grace. The wait is a loop of
    # short sleeps because the process group signal ends the sleep itself: a
    # single long sleep would return and let this script exit as though it had
    # honoured the signal it ignores.
    trap '' TERM INT HUP
    while :; do
        sleep 1
    done
fi

# A SIGTERM in every other arm ends the runtime the way a cancellation expects:
# the partial file goes and the exit status names the signal's own convention.
trap 'rm -f -- "$resolved_output"; exit 143' TERM
trap 'rm -f -- "$resolved_output"; exit 130' INT

emit_width=$width
if [ "$mode" = dimension ]; then
    emit_width=$((width - 1))
    [ "$emit_width" -ge 1 ] || emit_width=1
fi

# The pixels come from a counter seeded by --seed, so one seed reproduces one
# image byte for byte on one host. Deflate output varies across zlib versions,
# so a caller compares the artifact name against the SHA-256 of its own bytes
# rather than against a digest recorded elsewhere.
QWEN_FAKE_IMAGE_WIDTH=$emit_width \
QWEN_FAKE_IMAGE_HEIGHT=$height \
QWEN_FAKE_IMAGE_SEED=$seed \
QWEN_FAKE_IMAGE_OUTPUT=$resolved_output \
QWEN_FAKE_IMAGE_TRUNCATE=$([ "$mode" = truncated ] && echo 1 || echo 0) \
python3 - <<'PYTHON'
import binascii
import os
import struct
import zlib

width = int(os.environ["QWEN_FAKE_IMAGE_WIDTH"])
height = int(os.environ["QWEN_FAKE_IMAGE_HEIGHT"])
seed = int(os.environ["QWEN_FAKE_IMAGE_SEED"])
output = os.environ["QWEN_FAKE_IMAGE_OUTPUT"]
truncate = os.environ["QWEN_FAKE_IMAGE_TRUNCATE"] == "1"


def chunk(kind, body):
    return (
        struct.pack(">I", len(body))
        + kind
        + body
        + struct.pack(">I", binascii.crc32(kind + body) & 0xFFFFFFFF)
    )


state = (seed & 0xFFFFFFFF) or 0x9E3779B9
raw = bytearray()
for row in range(height):
    raw.append(0)
    for column in range(width):
        # A linear congruential step gives one deterministic byte per channel
        # without a dependency outside the standard library.
        for _ in range(3):
            state = (state * 1103515245 + 12345) & 0x7FFFFFFF
            raw.append((state >> 16) & 0xFF)

png = bytearray(b"\x89PNG\r\n\x1a\x0a")
png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(bytes(raw), 6))
png += chunk(b"IEND", b"")
if truncate:
    png = png[: len(png) // 2]

with open(output, "wb") as handle:
    handle.write(bytes(png))
PYTHON

if [ "$sleep_seconds" != 0 ]; then
    sleep "$sleep_seconds"
fi

exit 0
