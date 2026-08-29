#!/bin/sh
set -eu

# Stand in for radv-low-priority-env.sh where a test drives the launch chain off
# the appliance. The real wrapper resolves the RADV ICD and scrubs the ambient
# GGML_VK_* set, both of which need the device's own driver files; this one
# passes the caller's environment through so a test reads what the campaign
# asked for.

exec "$@"
