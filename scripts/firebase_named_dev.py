#!/usr/bin/env python3
"""Only aogaku-ai database + existing AI handlers in the validated Dev project."""
import sys,json,os,subprocess,shutil
from pathlib import Path
from firebase_dev import ROOT,validate_approved,AI_FUNCTIONS

def check():
    assert validate_approved()=='forta-aogaku-dev'
    config=json.loads((ROOT/'firebase.named-dev.json').read_text())
    assert config['firestore']==[{'database':'aogaku-ai','rules':'Config/AI/firestore.rules','indexes':'Config/AI/firestore.indexes.json','predeploy':['python3 "$PROJECT_DIR/scripts/firebase_named_dev.py" check']}]
    assert config['functions']['source']=='functions'
    assert (ROOT/'Config/AI/firestore.rules').read_text()=="rules_version = '2';\nservice cloud.firestore {\n  match /databases/{database}/documents {\n    match /{document=**} { allow read, write: if false; }\n  }\n}\n"
    env=(ROOT/'functions/.env.forta-aogaku-dev').read_text()
    assert 'AI_FIRESTORE_DATABASE_ID=aogaku-ai' in env and 'AI_SHARING_ENABLED=false' in env
    assert 'storage' not in config
    return config
if __name__=='__main__':
    check(); action=sys.argv[1]
    if action=='check': print('PASS: Dev identity, named-only deny Rules, sharing OFF');sys.exit()
    assert action in ['rules','functions']
    cli=Path(shutil.which('firebase')).resolve()
    assert cli.is_file()
    only='firestore:aogaku-ai,firestore:rules' if action=='rules' else ','.join('functions:'+n for n in AI_FUNCTIONS)
    subprocess.run(['node','--require',str(ROOT/'scripts/firebase_prompt_guard.cjs'),str(cli),'deploy','--project','forta-aogaku-dev','--config','firebase.named-dev.json','--only',only,'--non-interactive'],cwd=ROOT,env={**os.environ,'AOGAKU_DEV_RETRY_APPROVED':'true','AOGAKU_FIREBASE_PROMPT_PRELOAD':'true'},check=True)
