#!/usr/bin/env python3
"""Offline evidence report. Never approves gates or accesses Firebase/GCP."""
import hashlib, json, re
from datetime import datetime, timezone
from pathlib import Path
from firebase_production import ROOT, GATES, check

def main():
    check('forta-aogaku')
    provenance=json.loads((ROOT/'functions/recovered/deployed/provenance.json').read_text())
    expected={'preDeleteCleanup','deleteAccountServerSide','onAuthUserDelete','askCourseAI','transcribeLectureAudio','generateReactionPaper','onIncomingRequest','onFriendshipCreated','onIncomingRequestDeleted'}
    assert {r['function'] for r in provenance['records']}==expected
    assert provenance['cloudWrites']==0
    for r in provenance['records']:
        code=ROOT/r['sourceDirectory']/r['main']
        assert r['productionVersionVerified'] and hashlib.sha256(code.read_bytes()).hexdigest()==r['codeSha256']
    specs={
      'debug':('account-deletion-final-debug.log',['** BUILD SUCCEEDED **']),
      'domain':('account-deletion-unit.log',['tests 13','pass 13','fail 0']),
      'emulator':('account-deletion-final-emulator.log',['tests 35','pass 35','fail 0','skipped 0']),
      'simulatorDev':('account-deletion-final-xctest.log',['** TEST SUCCEEDED **','Executed 4 tests, with 0 failures']),
      'devDeletion':('account-deletion-formal-dev-e2e.log',['PASS formal account deletion '+m for m in ['prepared','server','direct']]),
      'devRaces':('account-deletion-dev-races-fresh.log',['PASS interrupted upload','PASS upload in progress','PASS processing in progress']),
      'devRetry':('account-deletion-dev-retry.log',['PASS failed source']),
      'devSharingOff':('account-deletion-dev-private.log',['PASS production private profile']),
      'safety':('account-deletion-safety.log',['Ran 11 tests','OK','pass 5','fail 0']),
      'configSafety':('account-deletion-config-safety.log',['Ran 9 tests','OK']),
      'localStore':('account-deletion-store-final.log',['PASS: account erase'])
    }
    tests={}
    for name,(file,needles) in specs.items():
        p=ROOT.parent/file;text=p.read_text() if p.exists() else ''
        passed=all(n in text for n in needles) and not re.search(r'^(?:FAIL|BLOCKED) ',text,re.M)
        tests[name]={'passed':passed,'log':file,'sha256':hashlib.sha256(text.encode()).hexdigest()}
    report={'createdAt':datetime.now(timezone.utc).isoformat(),'sourceRecoveryVerified':True,'recoveredFunctionCount':9,'tests':tests,'allTestsPassed':all(t['passed'] for t in tests.values()),'sharingEnabled':False,'productionCloudMutations':0,'productionApprovalCreated':False,'productionBlockersZero':False,'requiredGates':list(GATES),'pendingProductionConditions':['targeted legacy deletion deployment and installed-version verification','targeted legacy AI quota guard deployment and installed-version verification','production internal-test UID allowlist','production runtime IAM/API and rollout review','explicit production deployment authorization'],'note':'Local/Dev evidence is not permission to deploy. All existing approval gates remain required.'}
    out=ROOT/'build/account-deletion-readiness.json';out.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({'recoveredFunctions':9,'tests':{n:t['passed'] for n,t in tests.items()},'productionBlockersZero':False,'cloudMutations':0}))
    if not report['allTestsPassed']:raise SystemExit(1)
if __name__=='__main__':main()
