#!/usr/bin/env python3
"""Dev-only explicit Functions subset; never deploy Rules, Scheduler or Storage trigger."""
import os, subprocess, shutil, time, sys
from pathlib import Path
from firebase_dev import ROOT, validate_approved
NAMES = ('aiCreateSource','aiCompleteSource','aiGetSource','aiListSources','aiGetEvidence','aiRetrySource','aiUpdateSource','aiDeleteSource','aiRetrieveContext','aiLinkSourceOffering','aiProcessSource')
if __name__ == '__main__':
    assert sys.argv[1:] in ([], ['--image-route']), 'Only optional --image-route is allowed'
    names = ('aiListSources', 'aiProcessSource') if sys.argv[1:] else NAMES
    assert validate_approved() == 'forta-aogaku-dev'
    import json
    snapshot = ROOT/'build/detection-dev-before.json'
    assert 0 <= time.time() - snapshot.stat().st_mtime < 300, 'Fresh Dev baseline required'
    before = json.loads(snapshot.read_text())
    assert before['project'] == {'projectId':'forta-aogaku-dev','projectNumber':'1064661805206'}
    assert before['database']['name'] == 'projects/forta-aogaku-dev/databases/aogaku-ai'
    existing={f['name'].split('/')[-1] for f in before['functions']['functions']}
    assert set(NAMES)<=existing, 'Existing Dev Functions only; no creation inferred'
    cli=Path(shutil.which('firebase')).resolve()
    command=['node','--require',str(ROOT/'scripts/firebase_prompt_guard.cjs'),str(cli),'deploy','--project','forta-aogaku-dev','--config','firebase.named-dev.json','--only',','.join('functions:'+n for n in names),'--non-interactive']
    assert '--force' not in command
    subprocess.run(command,cwd=ROOT,env={**os.environ,'AOGAKU_DEV_RETRY_APPROVED':'true','AOGAKU_FIREBASE_PROMPT_PRELOAD':'true'},check=True)
