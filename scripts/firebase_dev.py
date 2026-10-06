#!/usr/bin/env python3
"""Fail-closed development-only CLI. `check` uses local files and never accesses cloud resources."""
import json
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AI_FUNCTIONS = ['aiCreateSource', 'aiCompleteSource', 'aiGetSource', 'aiListSources', 'aiGetEvidence', 'aiRetrySource',
                'aiUpdateSource', 'aiDeleteSource', 'aiRetrieveContext', 'aiProcessSource', 'aiReconcileInputs', 'aiRejectLateUpload']

def validate(root=ROOT):
    manifest = json.loads((root / 'Config/firebase-development.json').read_text())
    dev = plistlib.loads((root / 'Config/Firebase/Development/GoogleService-Info.plist').read_bytes())
    prod = plistlib.loads((root / 'Aogaku/GoogleService-Info.plist').read_bytes())
    project = manifest.get('projectId', '')
    if not re.fullmatch(r'[a-z][a-z0-9-]{4,28}[a-z0-9]', project) or project == prod.get('PROJECT_ID'):
        raise ValueError('Development project is invalid or equals protected production project')
    if dev.get('PROJECT_ID') != project or dev.get('BUNDLE_ID') != 'com.forta2k25.Aogaku.dev':
        raise ValueError('Development plist and approved project/bundle must match')
    return project

def validate_approved(root=ROOT):
    project = validate(root)
    manifest = json.loads((root / 'Config/firebase-development.json').read_text())
    dev = plistlib.loads((root / 'Config/Firebase/Development/GoogleService-Info.plist').read_bytes())
    if project != 'forta-aogaku-dev':
        raise ValueError('Only forta-aogaku-dev is approved for cloud operations')
    if manifest.get('projectNumber') != '1064661805206' or dev.get('GCM_SENDER_ID') != '1064661805206':
        raise ValueError('Approved Dev project number mismatch')
    if manifest.get('storageBucket') != 'forta-aogaku-dev.firebasestorage.app' or dev.get('STORAGE_BUCKET') != manifest['storageBucket']:
        raise ValueError('Approved Dev bucket mismatch')
    return project

def main():
    action = sys.argv[1] if len(sys.argv) == 2 else ''
    if action not in ['check', 'deploy', 'deploy-workers', 'deploy-processor', 'secret']:
        raise ValueError('Usage: firebase_dev.py check|deploy|deploy-workers|deploy-processor|secret (no arbitrary Firebase arguments)')
    project = validate_approved()
    if action == 'check':
        print(f'Development configuration OK: {project}; no network call')
        return
    # Always specify the validated project; never use the active alias or global default.
    command = ['firebase', '--project', project, '--config', str(ROOT / 'firebase.dev.json')]
    if action == 'secret':
        command += ['functions:secrets:set', 'GROQ_API_KEY']  # Firebase CLI secure interactive prompt.
    elif action == 'deploy-workers':
        command += ['deploy', '--only', 'functions:aiProcessSource,functions:aiRejectLateUpload']
    elif action == 'deploy-processor':
        command += ['deploy', '--only', 'functions:aiProcessSource']
    else:
        command += ['deploy', '--only', ','.join(['functions:' + name for name in AI_FUNCTIONS] + ['firestore', 'storage'])]
    print(f'Target: verified development project {project}', flush=True)
    subprocess.run(command, cwd=ROOT, check=True)

if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError) as error:
        raise SystemExit(f'STOP: {error}; no Firebase operation was started')
