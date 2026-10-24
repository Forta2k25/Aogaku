#!/usr/bin/env python3
"""Offline, isolated six-handler update and compatible rollback artifacts."""
import json,os,shutil,subprocess,hashlib
from pathlib import Path
from firebase_production import ROOT,TARGET,check,require
NAMES=('askCourseAI','transcribeLectureAudio','generateReactionPaper','preDeleteCleanup','deleteAccountServerSide','onAuthUserDelete')
def prepare():
 check('forta-aogaku')
 live=json.loads((ROOT/'build/production-legacy-live.json').read_text());require(live['projectId']==TARGET['projectId'] and live['projectNumber']==TARGET['projectNumber'],'legacy identity mismatch')
 records={r['name']:r for r in live['records']};require(set(records)==set(NAMES),'six legacy handlers required')
 proof=json.loads((ROOT/'functions/recovered/deployed/provenance.json').read_text())
 for r in proof['records']:
  if r['function'] in records:
   require(r['updateTime']==records[r['function']]['updateTime'],'legacy deployed source version drift')
   f=ROOT/r['sourceDirectory']/r['main'];require(hashlib.sha256(f.read_bytes()).hexdigest()==r['codeSha256'],'recovered code changed')
 require(all(r['codebase']=='default' for r in records.values()),'existing codebases changed; do not migrate automatically')
 subprocess.run(['npm','--prefix','functions','run','build'],cwd=ROOT,check=True)
 for mode in ['candidate','rollback-before-pilot','safety-recovery']:
  out=ROOT/'build'/('production-legacy-'+mode);shutil.rmtree(out,ignore_errors=True);(out/'lib').mkdir(parents=True)
  if mode!='rollback-before-pilot':
   for name in ['ai','legacy-ai','legacy-account']:shutil.copytree(ROOT/'functions/lib'/name,out/'lib'/name)
   modules="const ai=require('./legacy-ai'),account=require('./legacy-account');"
  else:
   original=ROOT/'functions/recovered/deployed';shutil.copy2(original/'12ed370d671b/lib/index.js',out/'lib/original-ai.js')
   code=(original/'aad2425fe638/index.js').read_text();code=code[code.index('// 共通: Query'):]
   header="const {onCall,HttpsError}=require('firebase-functions/v2/https');const {setGlobalOptions}=require('firebase-functions/v2/options');const functionsV1=require('firebase-functions/v1');const admin=require('firebase-admin');if(!admin.apps.length)admin.initializeApp();setGlobalOptions({region:'asia-northeast1',memory:'1GiB',timeoutSeconds:540,secrets:['IMPORT_API_KEY']});\n"
   (out/'lib/original-account.js').write_text(header+code)
   modules="const ai=require('./original-ai'),account=require('./original-account');"
  config={}
  for name,r in records.items():
   c=dict(r)
   if mode!='rollback-before-pilot' and name in ['preDeleteCleanup','deleteAccountServerSide','onAuthUserDelete']:
    c['serviceAccount']='aogaku-ai-account-deletion@forta-aogaku.iam.gserviceaccount.com';c['secretBindings']=[]
   if name=='onAuthUserDelete':c.update(timeoutSeconds=540,availableMemory='512M',maxInstanceCount=20)
   config[name]=c
  (out/'lib/metadata.json').write_text(json.dumps(config))
  entry=modules+"\nconst metadata=require('./metadata.json');\nfor(const [name,m]of Object.entries(metadata)){const h=(ai[name]||account[name]);const f=(...args)=>h(...args);f.run=h.run;Object.defineProperty(f,'__endpoint',{get:()=>{const e={...h.__endpoint};e.region=['asia-northeast1'];e.serviceAccountEmail=m.serviceAccount;e.timeoutSeconds=m.timeoutSeconds;e.availableMemoryMb=parseInt(m.availableMemory);e.ingressSettings=m.ingressSettings;if(m.environment==='GEN_2')e.cpu=Number(m.availableCpu||1);for(const [k,v]of [['maxInstances',m.maxInstanceCount],['minInstances',m.minInstanceCount]]){if(v!==undefined)e[k]=v;else delete e[k];}e.secretEnvironmentVariables=m.secretBindings.map(s=>({key:s.key,secret:s.secret}));return e;}});if(h.__requiredAPIs)f.__requiredAPIs=h.__requiredAPIs;exports[name]=f;}\n"
  (out/'lib/index.js').write_text(entry)
  pkg=json.loads((ROOT/'functions/package.json').read_text());pkg.update(main='lib/index.js',scripts={},name='aogaku-legacy-'+mode)
  (out/'package.json').write_text(json.dumps(pkg,indent=2)+'\n');shutil.copy2(ROOT/'functions/package-lock.json',out/'package-lock.json');(out/'node_modules').symlink_to(ROOT/'functions/node_modules',target_is_directory=True)
  (out/'.env.forta-aogaku').write_text('AI_FIRESTORE_DATABASE_ID=aogaku-ai\nAI_RUNTIME_SERVICE_ACCOUNT=aogaku-ai-runtime@forta-aogaku.iam.gserviceaccount.com\nAI_ACCOUNT_DELETION_SERVICE_ACCOUNT=aogaku-ai-account-deletion@forta-aogaku.iam.gserviceaccount.com\nAI_INPUT_ALLOWED_UIDS=[]\nAI_SHARING_ENABLED=false\n')
  configFile={'functions':[{'source':str(out.relative_to(ROOT)),'codebase':'default','runtime':'nodejs22','ignore':['node_modules','.git','*.private.json','*-debug.log','.secret.*'],'predeploy':['python3 "$PROJECT_DIR/scripts/firebase_legacy_production.py" hook --project "$GCLOUD_PROJECT"']}]}
  (ROOT/'build'/('firebase.legacy-'+mode+'.json')).write_text(json.dumps(configFile,indent=2)+'\n')
  script="const path=require('path');const loader=require(path.join(path.dirname(path.dirname(require.resolve('firebase-functions'))),'runtime/loader.js'));loader.loadStack(process.cwd()).then(s=>console.log(JSON.stringify(s))).catch(e=>{console.error(e);process.exit(1)});"
  env={**os.environ,'GCLOUD_PROJECT':'forta-aogaku','FIREBASE_CONFIG':json.dumps({'projectId':'forta-aogaku','storageBucket':TARGET['bucket']})}
  stack=json.loads(subprocess.check_output(['node','-e',script],cwd=out,env=env));eps=stack['endpoints'];require(set(eps)==set(NAMES),'legacy package export leak')
  for name,e in eps.items():require(e['platform']==('gcfv2' if records[name]['environment']=='GEN_2' else 'gcfv1') and e['region']==['asia-northeast1'],'generation/region migration rejected')
  (ROOT/'build'/('legacy-'+mode+'-endpoints.json')).write_text(json.dumps(eps,indent=2)+'\n')
 print('PASS: six-function candidate, Node22 pre-pilot rollback, safety-preserving recovery artifacts; no cloud operations')
if __name__=='__main__':prepare()
