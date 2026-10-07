#!/usr/bin/env python3
"""Separate, explicitly authorized maintenance wrapper; never deploy the whole codebase."""
import argparse,hashlib,json,os,shutil,subprocess,time
from pathlib import Path
from firebase_production import ROOT,TARGET,check,require,load,sha,inventory_hash,require_named_ready
GROUPS={'quota':('askCourseAI','transcribeLectureAudio','generateReactionPaper'),'deletion':('preDeleteCleanup','deleteAccountServerSide','onAuthUserDelete')}
MODES=('candidate','rollback-before-pilot','safety-recovery')
def artifact_hash(mode):
 h=hashlib.sha256();base=ROOT/'build'/('production-legacy-'+mode)
 paths=[p for p in base.rglob('*') if p.is_file() and 'node_modules' not in p.relative_to(base).parts]
 paths += [ROOT/'scripts'/p for p in ['firebase_legacy_production.py','firebase_legacy_prompt_guard.cjs','firebase_prompt_guard.cjs','prepare_legacy_production.py','production_cloud.cjs','verify_legacy_install.cjs']]
 for p in sorted(paths):h.update(str(p.relative_to(ROOT)).encode());h.update(p.read_bytes())
 return h.hexdigest()
def command(group,mode):
 require(group in GROUPS and mode in MODES,'unknown maintenance group/mode')
 return ['firebase','deploy','--project','forta-aogaku','--config','build/firebase.legacy-'+mode+'.json','--only',','.join('functions:default:'+n for n in GROUPS[group]),'--non-interactive']
def approve(a,group,mode,inventory):
 require(a.get('target')==TARGET and a.get('group')==group and a.get('mode')==mode,'maintenance approval identity/group/mode mismatch')
 require(a.get('artifactSha256')==artifact_hash(mode) and a.get('inventorySha256')==inventory_hash(inventory),'maintenance artifact/inventory changed')
 require(0<=time.time()-Path(inventory).stat().st_mtime<300 and time.time()<a.get('expiresAt',0)<time.time()+3600,'fresh inventory/approval required')
 require(a.get('authorizeNamedUpdates')==list(GROUPS[group]),'explicit same-name replacement approval required')
 require(not a.get('delete') and not a.get('generationMigration'),'deletion/generation migration forbidden')
 for gate in ['productionDeploymentAuthorized','legacyRegressionApproved','iamAndApisReviewed','rollbackReviewed']:require(a.get('gates',{}).get(gate) is True,'maintenance gate missing: '+gate)
 if mode=='rollback-before-pilot':require(a.get('noAIInputsEverAccepted') is True,'original-behavior rollback forbidden after AI inputs')
 named_inventory=ROOT/'build/production-live.json'
 require(0<=time.time()-named_inventory.stat().st_mtime<300,'fresh named database inventory required before Phase 3')
 require(a.get('namedInventorySha256')==inventory_hash(named_inventory),'named database inventory approval missing/changed')
 require_named_ready(load(named_inventory),True,True)
 current={r['name']:r for r in load(inventory)['records']};baseline={r['name']:r for r in load(ROOT/'Config/Production/legacy-baseline.json')['records']}
 expected=a.get('expectedUpdateTimes',{})
 for name in GROUPS[group]:
  r=current[name];require(r['updateTime']==expected.get(name),'unexpected deployed version: '+name)
  installation=load(ROOT/'build/legacy-production-installation.json') if (ROOT/'build/legacy-production-installation.json').exists() else {'groups':{}}
  known=installation.get('groups',{}).get(group,{}).get('functions',[])
  require(r['updateTime']==baseline[name]['updateTime'] or any(f.get('name')==name and f.get('sourceVerified') is True and f.get('updateTime')==r['updateTime'] for f in known),'deployed source version not recovered/verified: '+name)
  require(r['environment']==baseline[name]['environment'] and r['codebase']=='default','generation/codebase drift')
 return current

def main():
 p=argparse.ArgumentParser();p.add_argument('action',choices=['package','plan','deploy','hook']);p.add_argument('--project',required=True);p.add_argument('--group',choices=GROUPS,default='quota');p.add_argument('--mode',choices=MODES,default='candidate');p.add_argument('--approval');args=p.parse_args();check(args.project)
 if args.action in ['package','plan']:
  subprocess.run(['python3','scripts/prepare_legacy_production.py'],cwd=ROOT,check=True)
  plan={'target':TARGET,'commands':{g:command(g,args.mode) for g in GROUPS},'artifactSha256':artifact_hash(args.mode),'authorizeNamedUpdates':list(GROUPS[args.group]),'mode':args.mode,'cloudMutationExecuted':False,'phaseOrder':['quota','deletion'],'noDeletionAllowed':True}
  (ROOT/'build/legacy-production-plan.json').write_text(json.dumps(plan,indent=2)+'\n');print('Legacy maintenance plan/package validated offline; no deploy performed');return
 if args.action=='hook':
  session=os.environ.get('AOGAKU_LEGACY_SESSION');require(session,'direct legacy Firebase deploy forbidden');a=load(session);approve(a,a['group'],a['mode'],ROOT/'build/production-legacy-live.json');return
 require(args.approval,'explicit phase approval file required')
 require(subprocess.check_output(['node','--version']).decode().startswith('v22.'),'production deploy requires reviewed Node22 CLI runtime')
 subprocess.run(['node','scripts/production_cloud.cjs'],cwd=ROOT,check=True)
 subprocess.run(['node','scripts/production_cloud.cjs','legacy'],cwd=ROOT,check=True)
 a=load(args.approval);approve(a,args.group,args.mode,ROOT/'build/production-legacy-live.json')
 session=ROOT/'build/legacy-production-session.json';session.write_text(json.dumps(a));session.chmod(0o600)
 try:
  cli=Path(shutil.which('firebase')).resolve();c=['node','--require',str(ROOT/'scripts/firebase_legacy_prompt_guard.cjs'),str(cli),*command(args.group,args.mode)[1:]]
  subprocess.run(c,cwd=ROOT,env={**os.environ,'AOGAKU_LEGACY_SESSION':str(session),'AOGAKU_FIREBASE_PROMPT_PRELOAD':'false','AOGAKU_LEGACY_PROMPT_PRELOAD':'true'},check=True)
  subprocess.run(['node','scripts/verify_legacy_install.cjs',args.mode,args.group],cwd=ROOT,check=True)
 finally:session.unlink(missing_ok=True)
if __name__=='__main__':
 try:main()
 except (ValueError,KeyError,subprocess.CalledProcessError) as e:raise SystemExit(str(e))
