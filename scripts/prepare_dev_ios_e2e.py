#!/usr/bin/env python3
"""Prepare ignored test resources from this run's Dev-only, synthetic test account."""
import json
import shutil
from pathlib import Path
from firebase_dev import ROOT, validate_approved

project = validate_approved()
state = json.loads((ROOT / 'scripts/output-dev/e2e-state.json').read_text())
user = state['users']['owner']
destination = ROOT / 'AogakuTests/DevFixtures'
destination.mkdir(parents=True, exist_ok=True)
destination.chmod(0o700)
credentials = destination / 'dev-e2e-credentials.json'
credentials.write_text(json.dumps({'projectId': project, 'email': user['id'] + '@aogaku.app',
    'password': user['password'], 'uid': user['uid'], 'context': state['context']}))
credentials.chmod(0o600)
for name in ['sample-photo.jpg', 'sample-document.pdf', 'sample-audio.m4a']:
    shutil.copyfile(ROOT / 'scripts/output-dev/assets' / name, destination / name)
print('Prepared ignored Dev XCTest resources; credentials were not printed')
