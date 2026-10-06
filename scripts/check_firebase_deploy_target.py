#!/usr/bin/env python3
"""Predeploy hook: local allowlist only, no network calls."""
import sys
from firebase_dev import validate_approved

try:
    approved = validate_approved()
    if len(sys.argv) != 2 or sys.argv[1] != approved:
        raise ValueError('Selected Firebase project differs from approved development project')
    print('Development deploy target validated')
except (OSError, ValueError, KeyError) as error:
    raise SystemExit(f'STOP: {error}')
