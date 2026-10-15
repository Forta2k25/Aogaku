#!/usr/bin/env python3
"""Offline final preparation evidence; never grants production execution approval."""
import hashlib, json, subprocess
from datetime import datetime, timezone
from pathlib import Path
import firebase_production as prod
import firebase_legacy_production as legacy

def main():
    prod.check(prod.TARGET['projectId'])
    root=prod.ROOT
    phases=prod.load(root/'Config/Production/rollout.phases.json')
    assert phases['target']==prod.TARGET and not phases['cloudMutationExecuted']
    assert [p['id'] for p in phases['phases']]==list(range(1,7))
    queue=prod.load(root/'Config/Production/queue.create.json')
    assert 'state' not in queue
    assert prod.load(root/'Config/Production/queue.lifecycle.plan.json')['requiredState']=='PAUSED'
    env=(root/'build/production-functions/.env.forta-aogaku').read_text()
    assert 'AI_INPUT_ALLOWED_UIDS=[]\n' in env and 'AI_SHARING_ENABLED=false\n' in env
    prod.validate_functions(prod.load(root/'build/production-endpoints.json').keys())
    packages={}
    for mode in legacy.MODES:
        endpoints=prod.load(root/'build'/('legacy-'+mode+'-endpoints.json'))
        assert set(endpoints)==set(sum(legacy.GROUPS.values(),()))
        assert all(e['region']==['asia-northeast1'] for e in endpoints.values())
        packages[mode]=legacy.artifact_hash(mode)
    specs={
        'domain':('rollout-unit.log',['tests 13','pass 13','fail 0']),
        'emulator':('rollout-final-emulator.log',['tests 38','pass 38','fail 0','skipped 0']),
        'safety':('rollout-safety.log',['Ran 11 tests','Ran 5 tests','pass 7','fail 0']),
    }
    tests={}
    for name,(file,needles) in specs.items():
        content=(root.parent/file).read_text()
        tests[name]={'passed':all(n in content for n in needles),'log':file,'sha256':hashlib.sha256(content.encode()).hexdigest()}
    assert all(t['passed'] for t in tests.values()), 'Final local evidence missing'
    previous=prod.load(root/'build/account-deletion-readiness.json')
    assert previous['allTestsPassed'], 'Prior Dev/deletion evidence missing'
    assert not (root/'build/production-session.json').exists()
    assert not (root/'build/legacy-production-session.json').exists()
    report={
        'createdAt':datetime.now(timezone.utc).isoformat(),
        'status':'DEPLOY_APPROVAL_PENDING',
        'branch':subprocess.check_output(['git','branch','--show-current'],cwd=root,text=True).strip(),
        'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),
        'codeConfigurationBlockers':[], 'codeConfigurationBlockerCount':0,
        'productionInstalledGatesSatisfied':False,
        'pendingExecutionConditions':['Phase-specific explicit approval','Approved API/IAM/resource provisioning and verification','Six legacy production updates with installed source verification','Production internal UID supplied before Phase 5','Approved disposable internal production E2E'],
        'tests':tests,'priorDevEvidenceRetained':True,
        'aiClosedArtifactSha256':prod.artifact_hash(),'legacyArtifactSha256':packages,
        'productionMutationsThisTurn':0,'executionApprovalCreated':False,'sharingEnabled':False,
        'note':'Zero means unresolved preparation blockers only. Production has not been deployed, verified, or authorized by this report.'
    }
    path=root/'build/final-rollout-readiness.json'
    path.write_text(json.dumps(report,indent=2)+'\n');path.chmod(0o600)
    print(json.dumps({'status':report['status'],'codeConfigurationBlockerCount':0,'tests':{k:v['passed'] for k,v in tests.items()},'productionInstalledGatesSatisfied':False,'productionMutationsThisTurn':0}))

if __name__=='__main__':main()
