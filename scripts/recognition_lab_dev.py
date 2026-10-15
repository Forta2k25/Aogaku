#!/usr/bin/env python3
"""Only the isolated Recognition Lab callable in forta-aogaku-dev. No arbitrary CLI args."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from firebase_dev import ROOT, validate_approved

FUNCTION = 'recognitionLabRun'

def check():
    assert validate_approved() == 'forta-aogaku-dev'
    config = json.loads((ROOT / 'firebase.recognition-lab.json').read_text())
    assert set(config) == {'functions'} and len(config['functions']) == 1
    codebase = config['functions'][0]
    assert codebase['source'] == 'recognition-lab/functions' and codebase['codebase'] == 'recognition-lab'
    private = json.loads((ROOT / 'Config/recognition-lab.local.json').read_text())
    assert private['projectId'] == 'forta-aogaku-dev'
    uids = private['allowedUIDs']
    import re
    assert isinstance(uids, list) and uids and len(uids) == len(set(uids))
    assert all(isinstance(uid, str) and re.fullmatch(r'[A-Za-z0-9_-]{1,128}', uid) for uid in uids)
    env = (ROOT / 'recognition-lab/functions/.env.forta-aogaku-dev').read_text().splitlines()
    assert env == ['RECOGNITION_LAB_ENABLED=true', 'RECOGNITION_LAB_ALLOWED_UIDS=' + json.dumps(uids, separators=(',', ':'))]
    print('PASS: Dev identity, separate codebase, explicit private allowlist, only recognitionLabRun')

def main():
    assert len(sys.argv) == 2 and sys.argv[1] in ['check', 'deploy', 'register-device', 'enable-anonymous']
    check()
    if sys.argv[1] == 'check': return
    if sys.argv[1] in ['register-device', 'enable-anonymous']:
        action = sys.argv[1]
        data = None
        if action == 'register-device':
            import getpass
            data = getpass.getpass('Paste the Lab device UID (hidden): ').strip()
        subprocess.run(['node', str(ROOT / 'scripts/recognition_lab_device.cjs'), action],
                       input=data, text=True, cwd=ROOT, check=True)
        return
    cli = Path(shutil.which('firebase')).resolve()
    subprocess.run(['node', '--require', str(ROOT / 'scripts/firebase_prompt_guard.cjs'), str(cli), 'deploy',
                    '--project', 'forta-aogaku-dev', '--config', 'firebase.recognition-lab.json', '--only',
                    'functions:recognition-lab:' + FUNCTION, '--non-interactive'], cwd=ROOT,
                   env={**os.environ, 'AOGAKU_DEV_RETRY_APPROVED': 'true', 'AOGAKU_FIREBASE_PROMPT_PRELOAD': 'true'}, check=True)

if __name__ == '__main__': main()
