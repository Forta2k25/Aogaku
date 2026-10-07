#!/usr/bin/env python3
"""Build a separate Dev artifact with exactly the three recovered deletion handlers."""
import json, os, shutil, subprocess
from pathlib import Path
from firebase_dev import ROOT, validate_approved
NAMES = ['preDeleteCleanup', 'deleteAccountServerSide', 'onAuthUserDelete']
def prepare():
    project = validate_approved()
    subprocess.run(['npm', '--prefix', 'functions', 'run', 'build'], cwd=ROOT, check=True)
    target = ROOT / 'build/development-account-functions'
    if target.exists(): shutil.rmtree(target)
    (target / 'lib').mkdir(parents=True)
    for name in ['ai', 'legacy-account']:
        shutil.copytree(ROOT / 'functions/lib' / name, target / 'lib' / name)
    shutil.copy2(ROOT / 'functions/lib/account-deletion-entry.js', target / 'lib/account-deletion-entry.js')
    package = json.loads((ROOT / 'functions/package.json').read_text())
    package['main'] = 'lib/account-deletion-entry.js'; package['scripts'] = {}
    (target / 'package.json').write_text(json.dumps(package, indent=2)+'\n')
    shutil.copy2(ROOT / 'functions/package-lock.json', target / 'package-lock.json')
    (target / 'node_modules').symlink_to(ROOT / 'functions/node_modules', target_is_directory=True)
    (target / ('.env.'+project)).write_text('AI_FIRESTORE_DATABASE_ID=aogaku-ai\nAI_ACCOUNT_DELETION_SERVICE_ACCOUNT=aogaku-ai-account-deletion@forta-aogaku-dev.iam.gserviceaccount.com\nAI_RUNTIME_SERVICE_ACCOUNT=aogaku-ai-runtime@forta-aogaku-dev.iam.gserviceaccount.com\nAI_SHARING_ENABLED=false\nAI_INPUT_ALLOWED_UIDS=[]\n')
    # SDK discovery is local; verifies generation and region preservation and no provider secrets.
    code = "const path=require('path'),assert=require('assert/strict');const loader=require(path.join(path.dirname(path.dirname(require.resolve('./functions/node_modules/firebase-functions'))),'runtime/loader.js'));(async()=>{const stack=await loader.loadStack(process.argv[1]);assert.deepEqual(Object.keys(stack.endpoints).sort(),['deleteAccountServerSide','onAuthUserDelete','preDeleteCleanup']);for(const [name,e] of Object.entries(stack.endpoints)){assert.equal(e.platform,name==='onAuthUserDelete'?'gcfv1':'gcfv2');assert.deepEqual(e.region,['asia-northeast1']);assert.equal((e.secretEnvironmentVariables||[]).length,0);}console.log('PASS: exactly three deletion handlers; generations/region preserved; no secrets');})().catch(e=>{console.error(e);process.exit(1)});"
    subprocess.run(['node','-e',code,str(target)], cwd=ROOT,env={**os.environ,'GCLOUD_PROJECT':project,'FIREBASE_CONFIG':json.dumps({'projectId':project,'storageBucket':'forta-aogaku-dev.firebasestorage.app'})},check=True)
    return target
if __name__ == '__main__': prepare()
