#!/usr/bin/env python3
"""Emit an unterminated retirement record and exceed the native deadline."""

import sys
import time

sys.stdout.write("teardown_exclusion=order")
sys.stdout.flush()
time.sleep(10)
