#!/usr/bin/env python3
"""Separate production wrapper. Check/package/plan/dry-run do not write to cloud.
Deploy requires a fresh read-only inventory plus explicit approval tied to its hash,
package hash and completed release gates. Direct Firebase CLI predeploy is denied.
"""
import argparse, hashlib, json, os, re, plistlib, shutil, subprocess, sys, time
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
CONF=ROOT/'Config/Production'
TARGET={'projectId':'forta-aogaku','projectNumber':'505828754933','bucket':'forta-aogaku.firebasestorage.app','bundleId':'com.forta2k25.Aogaku','functionRegion':'asia-northeast1','databaseLocation':'asia-northeast1','aiDatabaseId':'aogaku-ai','storageLocation':'US-CENTRAL1','eventRegion':'us-central1','runtimeServiceAccount':'aogaku-ai-runtime@forta-aogaku.iam.gserviceaccount.com','sharingEnabled':False,'functionsCodebase':'aogaku-ai'}
FUNCTIONS=('aiCreateSource','aiCompleteSource','aiGetSource','aiListSources','aiGetEvidence','aiRetrySource','aiUpdateSource','aiDeleteSource','aiRetrieveContext','aiProcessSource','aiReconcileInputs','aiRejectLateUpload')
GATES=('accountDeletionHookIntegrated','legacyQuotaDeletionGuardsIntegrated','legacyRegressionApproved','devPrivateProfilePassed','iamAndApisReviewed','internalTestPlanApproved','internalTestUIDsConfigured','productionDeploymentAuthorized','retryPolicyReviewed','namedDatabaseBoundaryVerified')
PHASE_GATES={'indexes':('legacyRegressionApproved','productionDeploymentAuthorized'),'rules':('legacyRegressionApproved','productionDeploymentAuthorized'),'functions':GATES,'functions-closed':tuple(g for g in GATES if g!='internalTestUIDsConfigured')}
def load(p):return json.loads(Path(p).read_text())
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def inventory_hash(p):
 data=load(p);data.pop('readAt',None)
 return hashlib.sha256(json.dumps(data,sort_keys=True,separators=(',',':')).encode()).hexdigest()
def require(ok,reason):
 if not ok:raise ValueError('STOP: '+reason)
def normalized_indexes(data):
 indexes=data.get('indexes',[])
 if isinstance(indexes,dict):indexes=indexes.get('indexes',[])
 out=[]
 for i in indexes:
  cg=i.get('collectionGroup') or i['name'].split('/collectionGroups/')[1].split('/')[0]
  out.append({'collectionGroup':cg,'queryScope':i['queryScope'],'fields':[f for f in i['fields'] if f['fieldPath']!='__name__']})
 return {json.dumps(i,sort_keys=True) for i in out}
def normalized_fields(data):
 if 'fieldOverrides' in data:return {json.dumps(i,sort_keys=True) for i in data['fieldOverrides']}
 out=[]
 for f in data.get('fields',[]):
  cg,fld=f['name'].split('/collectionGroups/')[1].split('/fields/')
  if cg=='__default__':continue
  indexes=[]
  for i in f['indexConfig']['indexes']:
   require(len(i['fields'])==1,'unexpected fieldOverride structure')
   indexes.append(dict(queryScope=i['queryScope'],**{k:v for k,v in i['fields'][0].items() if k!='fieldPath'}))
  entry={'collectionGroup':cg,'fieldPath':fld,'indexes':indexes}
  if f.get('ttlConfig'):entry['ttl']=True
  out.append(entry)
 return {json.dumps(i,sort_keys=True) for i in out}
def rules_preserved(base,merged,kind):
 # Default Firestore is immutable; Storage only accepts exact additive deny.
 if kind=='firestore':
  require(merged==base,'default Firestore Rules must stay byte-identical')
  return
 # Only this exact additive deny block is accepted; no existing permission can change.
 paths=['aiSources','aiCourseOfferings','aiUsage','aiInputOwners','aiMaintenance'] if kind=='firestore' else ['ai-inputs','ai-derived']
 addition='    // AI access is through authenticated server APIs only.\n'+'\n'.join('    match /'+p+'/{path=**} { allow read, write: if false; }' for p in paths)+'\n'
 pos=base.rfind('  }');require(pos>0,'unexpected rules nesting')
 require(merged==base[:pos]+addition+base[pos:],'existing '+kind+' Rules changed/deleted, or unapproved additions')
def reject_known_ai_entries_bypass():
 # Legacy recursive entries grants are preserved in a DIFFERENT database.
 config=load(ROOT/'firebase.production.json')['firestore']
 require(isinstance(config,list) and len(config)==1 and config[0].get('database')=='aogaku-ai','AI deploy must target named database only; default/aliases rejected')
 require(config[0].get('rules')=='Config/AI/firestore.rules' and config[0].get('indexes')=='Config/AI/firestore.indexes.json','named Rules/index artifact mismatch')
 rules=(ROOT/'Config/AI/firestore.rules').read_text()
 require(rules=="rules_version = '2';\nservice cloud.firestore {\n  match /databases/{database}/documents {\n    match /{document=**} { allow read, write: if false; }\n  }\n}\n",'named database must deny ALL client paths')
 require((CONF/'firestore.rules').read_bytes()==(CONF/'baseline.firestore.rules').read_bytes(),'default legacy Rules must remain unchanged')
def validate_functions(names):require(len(names)==12 and set(names)==set(FUNCTIONS),'only exact AI twelve-function allowlist is permitted')
def reject_destructive_plan(plan):
 require(not plan.get('delete') and not plan.get('replaceExisting'),'function/resource deletion or legacy replacement proposed')
 validate_functions(plan.get('functions',[]))
def check(project):
 require(project==TARGET['projectId'],'explicit production Project ID required; no aliases/defaults')
 require(load(CONF/'target.json')==TARGET,'production identity/config mismatch')
 p=plistlib.loads((ROOT/'Aogaku/GoogleService-Info.plist').read_bytes())
 for k,v in [('PROJECT_ID',TARGET['projectId']),('GCM_SENDER_ID',TARGET['projectNumber']),('STORAGE_BUCKET',TARGET['bucket']),('BUNDLE_ID',TARGET['bundleId'])]:require(p.get(k)==v,'Release plist '+k+' mismatch')
 # Build setting verification prevents an accidentally changed Release application identity.
 pbx=(ROOT/'Aogaku.xcodeproj/project.pbxproj').read_text()
 project=json.loads(subprocess.check_output(['plutil','-convert','json','-o','-',str(ROOT/'Aogaku.xcodeproj/project.pbxproj')]))['objects']
 app=next(x for x in project.values() if x.get('isa')=='PBXNativeTarget' and x.get('name')=='Aogaku')
 configurations=project[app['buildConfigurationList']]['buildConfigurations']
 release=next(project[i] for i in configurations if project[i].get('name')=='Release')
 require(release['buildSettings'].get('PRODUCT_BUNDLE_IDENTIFIER')==TARGET['bundleId'],'Release bundle build setting changed')
 for kind in ['firestore','storage']:rules_preserved((CONF/('baseline.'+kind+'.rules')).read_text(),(CONF/(kind+'.rules')).read_text(),kind)
 base=load(CONF/'baseline.indexes.json');merged=load(CONF/'firestore.indexes.json')
 require(normalized_indexes(base)<=normalized_indexes(merged),'existing index removal rejected')
 require(normalized_fields(base)==normalized_fields(merged),'existing fieldOverride change/removal rejected')
 require(normalized_indexes(merged)-normalized_indexes(base)==normalized_indexes(load(ROOT/'firestore.indexes.json')),'only known AI indexes may be added')
 old=load(CONF/'baseline.lifecycle.json')['rule'];new=load(CONF/'storage.lifecycle.proposed.json')['rule']
 require(new[:len(old)]==old and new[len(old):]==[{'action':{'type':'Delete'},'condition':{'age':2,'matchesPrefix':['ai-inputs/'],'matchesSuffix':['.m4a']}}],'lifecycle changes outside AI audio TTL rejected')
 config=load(ROOT/'firebase.production.json')
 require(config['functions'][0]['codebase']=='aogaku-ai' and config['functions'][0]['source']=='build/production-functions','isolated production functions codebase/source required')
 for service in ['functions','firestore','storage']:
  c=config[service][0] if service in ['functions','firestore'] else config[service]
  require(c.get('predeploy')==['python3 "$PROJECT_DIR/scripts/firebase_production.py" hook --project "$GCLOUD_PROJECT"'],'predeploy guard removed/changed')
 require(set(config)=={'functions','firestore','storage'} and len(config['functions'])==1,'unexpected production deployment services/codebases')
 reject_known_ai_entries_bypass()
 require(config['storage']['rules']=='Config/Production/storage.rules','production Storage artifact changed')
 named=load(ROOT/'Config/AI/firestore.indexes.json');require(len(named['indexes'])==1 and named['fieldOverrides']==[{'collectionGroup':'memberships','fieldPath':'userId','indexes':[{'order':'ASCENDING','queryScope':'COLLECTION'},{'order':'DESCENDING','queryScope':'COLLECTION'},{'arrayConfig':'CONTAINS','queryScope':'COLLECTION'},{'order':'ASCENDING','queryScope':'COLLECTION_GROUP'}]}],'named index contract changed')
 # Legacy notification handlers must be byte-identical to the integrated main version.
 original=subprocess.check_output(['git','show','9d596f7b421e81df6776d4d337eb4c650231f371:functions/src/index.ts'],cwd=ROOT).decode()
 current=(ROOT/'functions/src/index.ts').read_text().split('export {aiCreateSource')[0]
 current=current.replace('import {getFirestore} from "firebase-admin/firestore";\n','').replace('const db = getFirestore(admin.app(), "(default)");','const db = admin.firestore();')
 require(current.rstrip()==original.rstrip(),'legacy notification logic changed beyond explicit default database adapter; regression review required')
 return merged
def live_check(snapshot):
 require(snapshot['projectId']==TARGET['projectId'] and snapshot['projectNumber']==TARGET['projectNumber'],'live project number/ID mismatch')
 require(snapshot['bucket']['name']==TARGET['bucket'] and snapshot['bucket']['location']==TARGET['storageLocation'],'live bucket/region mismatch')
 require(snapshot['database']['locationId']==TARGET['databaseLocation'],'live database location mismatch')
 require(any(a.get('bundleId')==TARGET['bundleId'] and a.get('state')=='ACTIVE' for a in snapshot['apps'].get('apps',[])),'Release bundle is not registered in production')
 for kind in ['firestore','storage']:require(snapshot['rules'][kind]['content'] in [(CONF/('baseline.'+kind+'.rules')).read_text(),(CONF/(kind+'.rules')).read_text()],'active '+kind+' rules drift; refresh baseline and re-review')
 merged=load(CONF/'firestore.indexes.json')
 require(normalized_indexes(snapshot['indexes'])<=normalized_indexes(merged),'live index would be deleted')
 require(normalized_fields(snapshot['fields'])==normalized_fields(merged),'live fieldOverrides drift/deletion')
 require(snapshot['bucket'].get('lifecycle',{'rule':[]}) in [load(CONF/'baseline.lifecycle.json'),load(CONF/'storage.lifecycle.proposed.json')],'live lifecycle drift')
 protected={f['name'].split('/')[-1] for f in load(CONF/'baseline.inventory.json')['functions']}
 require(protected<={f['name'].split('/')[-1] for f in snapshot['functions'].get('functions',[])},'existing production function inventory changed; review required')
 for f in snapshot['functions'].get('functions',[]):
  name=f['name'].split('/')[-1]
  if name in FUNCTIONS:require(name not in protected and f.get('labels',{}).get('firebase-functions-codebase')=='aogaku-ai','existing non-AI function replacement rejected: '+name)
 require(not any(snapshot.get('storagePrivacy',{'unverified':True}).values()),'public/inherited Storage IAM or default ACL needs isolation review before private AI uploads')
 require(snapshot['secret']['name'].endswith('/secrets/GROQ_API_KEY'),'existing GROQ secret resource unavailable')
 require(snapshot['secret'].get('latestState')=='ENABLED','GROQ latest version is not enabled; never rotate/overwrite to repair automatically')
def package(profile="pilot"):
 subprocess.run(['npm','--prefix','functions','run','build'],cwd=ROOT,check=True)
 out=ROOT/'build/production-functions';out.mkdir(parents=True,exist_ok=True)
 # Rebuild only this isolated generated directory. No development config, fixtures or legacy code.
 shutil.rmtree(out/'lib',ignore_errors=True);(out/'lib').mkdir()
 shutil.copytree(ROOT/'functions/lib/ai',out/'lib/ai')
 shutil.copy2(ROOT/'functions/lib/production.js',out/'lib/production.js')
 pkg=load(ROOT/'functions/package.json');pkg['main']='lib/production.js';pkg['scripts']={};pkg['name']='aogaku-ai-production'
 (out/'package.json').write_text(json.dumps(pkg,indent=2)+'\n')
 shutil.copy2(ROOT/'functions/package-lock.json',out/'package-lock.json')
 # Local discovery only. node_modules is never uploaded or part of source hashing.
 link=out/'node_modules'
 if not link.exists():link.symlink_to(ROOT/'functions/node_modules',target_is_directory=True)
 require(profile in ['closed','pilot'],'unknown production profile')
 operator=load(ROOT/'Config/firebase-production.local.json') if (ROOT/'Config/firebase-production.local.json').exists() else {'allowedUIDs':[]}
 if profile=='closed':operator={'allowedUIDs':[]}
 require(set(operator)=={'allowedUIDs'} and isinstance(operator['allowedUIDs'],list),'only explicit private test UID list is supported')
 require(all(isinstance(u,str) and re.fullmatch(r'[A-Za-z0-9_-]{1,128}',u) for u in operator['allowedUIDs']),'invalid pilot UID or wildcard rollout')
 (out/'.env.forta-aogaku').write_text('AI_FIRESTORE_DATABASE_ID=aogaku-ai\nAI_RUNTIME_SERVICE_ACCOUNT='+TARGET['runtimeServiceAccount']+'\nAI_SHARING_ENABLED=false\nAI_INPUT_ALLOWED_UIDS='+json.dumps(operator['allowedUIDs'],separators=(',',':'))+'\n')
 script="const loader=require(require('node:path').join(require('node:path').dirname(require('node:path').dirname(require.resolve('firebase-functions'))),'runtime/loader.js'));loader.loadStack(process.cwd()).then(s=>console.log(JSON.stringify(s))).catch(e=>{console.error(e.name);process.exit(1)});"
 env={**os.environ,'GCLOUD_PROJECT':TARGET['projectId'],'FIREBASE_CONFIG':json.dumps({'projectId':TARGET['projectId'],'storageBucket':TARGET['bucket']}),'AI_SHARING_ENABLED':'false','AI_INPUT_ALLOWED_UIDS':'','AI_RUNTIME_SERVICE_ACCOUNT':TARGET['runtimeServiceAccount']}
 stack=json.loads(subprocess.check_output(['node','-e',script],cwd=out,env=env));endpoints=stack['endpoints']
 validate_functions(endpoints.keys())
 require(all(e.get('serviceAccountEmail') in ['params.AI_RUNTIME_SERVICE_ACCOUNT','{{ params.AI_RUNTIME_SERVICE_ACCOUNT }}'] for e in endpoints.values()),'runtime SA parameter mismatch')
 require(all(e.get('region')==['asia-northeast1'] for e in endpoints.values()),'runtime function region mismatch')
 trigger=endpoints['aiRejectLateUpload']['eventTrigger']
 require(trigger.get('region')=='us-central1' and trigger['eventFilters']['bucket']==TARGET['bucket'],'storage/Eventarc region/bucket mismatch')
 (ROOT/'build/production-stack.json').write_text(json.dumps(stack,indent=2)+'\n')
 (ROOT/'build/production-endpoints.json').write_text(json.dumps(endpoints,indent=2)+'\n')
 return out
def artifact_hash():
 h=hashlib.sha256()
 paths=list((CONF).glob('*'))+list((ROOT/'Config/AI').glob('*'))+[ROOT/'firebase.production.json',ROOT/'scripts/firebase_production.py',ROOT/'scripts/production_cloud.cjs',ROOT/'scripts/firebase_prompt_guard.cjs',ROOT/'Aogaku/GoogleService-Info.plist']
 # Account/legacy integration and regression evidence are part of the reviewed artifact.
 paths+=list((ROOT/'functions/recovered/deployed').rglob('*'))
 paths+=list((ROOT/'functions/src/legacy-account').rglob('*.js'))+list((ROOT/'functions/src/legacy-ai').rglob('*.ts'))
 paths+=[ROOT/'functions/src/account-deletion-entry.ts',ROOT/'functions/test/deployed-legacy.test.cjs',ROOT/'Aogaku/AuthManager.swift']
 paths += [ROOT/'scripts'/n for n in ['firebase_legacy_production.py','firebase_legacy_prompt_guard.cjs','prepare_legacy_production.py','verify_legacy_install.cjs']]
 paths=[p for p in paths if p.is_file()]
 paths+=list((ROOT/'build/production-functions/lib').rglob('*.js'))+[ROOT/'build/production-functions/package.json',ROOT/'build/production-functions/package-lock.json',ROOT/'build/production-functions/.env.forta-aogaku']
 for p in sorted(paths):h.update(str(p.relative_to(ROOT)).encode());h.update(p.read_bytes())
 return h.hexdigest()
def deploy_command(phase):
 only={'functions':','.join('functions:aogaku-ai:'+n for n in FUNCTIONS),'rules':'firestore:aogaku-ai,firestore:rules,storage','indexes':'firestore:aogaku-ai,firestore:indexes'}[phase]
 return ['firebase','deploy','--project',TARGET['projectId'],'--config','firebase.production.json','--only',only,'--non-interactive']
def require_named_ready(snapshot,index_ready=True,rules_ready=False):
 named=snapshot.get('aiDatabase') or {}
 require(named.get('name')=='projects/forta-aogaku/databases/aogaku-ai' and named.get('locationId')=='asia-northeast1' and named.get('type')=='FIRESTORE_NATIVE' and named.get('deleteProtectionState')=='DELETE_PROTECTION_ENABLED','named production database is not freshly verified; creation requires separate approval')
 if index_ready:
  indexes=(snapshot.get('aiIndexes') or {}).get('indexes',[])
  require(len(indexes)==1 and indexes[0].get('state')=='READY','named AI index must be READY before Rules/Functions')
  require(normalized_indexes({'indexes':indexes})==normalized_indexes(load(ROOT/'Config/AI/firestore.indexes.json')),'named index definition drift')
  fields=snapshot.get('aiFields') or {}
  require(normalized_fields(fields)==normalized_fields(load(ROOT/'Config/AI/firestore.indexes.json')),'named membership lookup fieldOverride not verified')
  require(all(i.get('state')=='READY' for f in fields.get('fields',[]) if '/memberships/fields/userId' in f.get('name','') for i in f.get('indexConfig',{}).get('indexes',[])),'named membership indexes must be READY')
 if rules_ready:
  require((snapshot.get('aiRules') or {}).get('content')==(ROOT/'Config/AI/firestore.rules').read_text(),'named database closed Rules release is not verified')
def approval_check(approval,snapshot_path,phase,profile="pilot"):
 if phase=='rules':reject_known_ai_entries_bypass()
 require_named_ready(load(snapshot_path),phase!='indexes',phase=='functions')
 require(approval['target']==TARGET,'approval identity mismatch')
 require(approval['phase']==phase,'approval phase mismatch')
 require(approval['artifactSha256']==artifact_hash(),'approval does not match current artifacts')
 require(approval['inventorySha256']==inventory_hash(snapshot_path),'approval inventory mismatch')
 require(0<=time.time()-Path(snapshot_path).stat().st_mtime<300,'inventory must be re-read within five minutes')
 require(time.time()<approval.get('expiresAt',0)<time.time()+3600,'approval expiry missing/stale')
 require(all(approval.get('gates',{}).get(g) is True for g in PHASE_GATES["functions-closed" if phase=="functions" and profile=="closed" else phase]),'release gates/explicit production authorization incomplete')
 reject_destructive_plan({'functions':list(FUNCTIONS),'delete':approval.get('delete'),'replaceExisting':approval.get('replaceExisting')})
def main():
 p=argparse.ArgumentParser();p.add_argument('action',choices=['check','package','plan','dry-run','deploy','hook']);p.add_argument('--project',required=True);p.add_argument('--phase',choices=['functions','rules','indexes'],default='functions');p.add_argument('--approval');p.add_argument('--profile',choices=['closed','pilot'],default='pilot');args=p.parse_args()
 check(args.project)
 if args.phase=='rules' and args.action in ['plan','dry-run','deploy']:reject_known_ai_entries_bypass()
 if args.action=='deploy':
  require(not (args.phase=='functions' and args.profile=='closed'),'closed Phase4 uses scripts/deploy_production_phase4.cjs; CLI automatically publishes callable ingress')
  require(args.approval,'explicit reviewed production approval file required; none supplied')
 if args.action=='check':print('Production configuration preservation/identity/allowlist guards PASS (offline).');return
 if args.action=='hook':
  session=os.environ.get('AOGAKU_PRODUCTION_SESSION');require(session,'direct Firebase deploy forbidden: use approved production wrapper')
  receipt=load(session);live_path=ROOT/'build/production-live.json';live_check(load(live_path));approval_check(receipt,live_path,receipt['phase'],receipt.get('profile','pilot'));return
 package(args.profile)
 if args.action in ['dry-run','deploy']:
  subprocess.run(['node','scripts/production_cloud.cjs'],cwd=ROOT,check=True);live_check(load(ROOT/'build/production-live.json'))
 plan={'target':TARGET,'profile':args.profile,'functions':list(FUNCTIONS),'delete':[],'replaceExisting':[],'artifactSha256':artifact_hash(),'commands':{phase:deploy_command(phase) for phase in ['indexes','rules','functions']},'requiredGates':list(GATES),'phaseRequiredGates':{k:list(v) for k,v in PHASE_GATES.items()},'cloudMutationExecuted':False,'excludedFunctions':['aiLinkSourceOffering'],'lifecycleApply':'manual reviewed merge with ifMetagenerationMatch; never full-bucket replacement'}
 (ROOT/'build/production-plan.json').write_text(json.dumps(plan,indent=2)+'\n')
 if args.action=='deploy':
  if args.profile=='pilot':require('AI_INPUT_ALLOWED_UIDS=[]\n' not in (ROOT/'build/production-functions/.env.forta-aogaku').read_text(),'internal pilot UID list is empty; production input stays disabled')
  require(args.approval,'explicit reviewed production approval file required; none supplied')
  # Refresh above is read-only; fail before any CLI mutation if authorization is incomplete.
  for group in ['quota','deletion']:
   if args.phase=='functions':subprocess.run(['node','scripts/verify_legacy_install.cjs','candidate',group],cwd=ROOT,check=True)
  receipt=load(args.approval);live_path=ROOT/'build/production-live.json';approval_check(receipt,live_path,args.phase,args.profile)
  require(receipt.get('profile','pilot')==args.profile,'profile approval mismatch')
  require(subprocess.check_output(['node','--version']).decode().startswith('v22.'),'production deploy requires Node22 CLI runtime')
  session=ROOT/'build/production-session.json';session.write_text(json.dumps(receipt));session.chmod(0o600)
  try:
   cli=Path(shutil.which('firebase')).resolve()
   command=['node','--require',str(ROOT/'scripts/firebase_prompt_guard.cjs'),str(cli),*deploy_command(args.phase)[1:]]
   subprocess.run(command,cwd=ROOT,env={**os.environ,'AOGAKU_PRODUCTION_SESSION':str(session),'AOGAKU_FIREBASE_PROMPT_PRELOAD':'true'},check=True)
  finally:session.unlink(missing_ok=True)
 else:print(f'{args.action}: production twelve-function package validated; no cloud writes. See build/production-plan.json')
if __name__=='__main__':
 try:main()
 except (ValueError,KeyError,subprocess.CalledProcessError) as e:print(str(e),file=sys.stderr);sys.exit(1)
