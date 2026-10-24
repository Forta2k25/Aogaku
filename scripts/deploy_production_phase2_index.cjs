#!/usr/bin/env node
// Phase 2a only: exactly one index POST, metadata GET/read-only IAM POST. No Rules release.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto'),{execFileSync}=require('node:child_process');
const ROOT=path.resolve(__dirname,'..'),P='forta-aogaku',N='505828754933',B=P+'.firebasestorage.app';
const CREATE=`https://firestore.googleapis.com/v1/projects/${P}/databases/(default)/collectionGroups/aiSources/indexes`;
const INDEX=JSON.parse(fs.readFileSync(path.join(ROOT,'Config/Production/firestore.indexes.json'))).indexes.find(i=>i.collectionGroup==='aiSources');
const BODY={queryScope:INDEX.queryScope,fields:INDEX.fields};
const URLs={projectIAM:`https://cloudresourcemanager.googleapis.com/v1/projects/${P}:getIamPolicy`,bucketIAM:`https://storage.googleapis.com/storage/v1/b/${B}/iam?optionsRequestedPolicyVersion=3`,secretIAM:`https://secretmanager.googleapis.com/v1/projects/${P}/secrets/GROQ_API_KEY:getIamPolicy?options.requestedPolicyVersion=3`,queue:`https://cloudtasks.googleapis.com/v2/projects/${P}/locations/asia-northeast1/queues/aiProcessSource`,scheduler:`https://cloudscheduler.googleapis.com/v1/projects/${P}/locations/asia-northeast1/jobs`,functions:`https://cloudfunctions.googleapis.com/v2/projects/${P}/locations/-/functions`};
function guard(url,method,body,apply=false){
 if(method==='GET'&&Object.values(URLs).includes(url))return;
 try{require('./production_cloud.cjs').assertRead(url,method);return;}catch{}
 if(apply&&method==='POST'&&url===CREATE){assert.deepEqual(body,BODY);return;}
 throw Error('STOP: request outside Phase 2a index-only allowlist');
}
function indexSpec(i){return JSON.stringify({collectionGroup:i.name.split('/collectionGroups/')[1].split('/')[0],queryScope:i.queryScope,fields:i.fields.filter(f=>f.fieldPath!=='__name__')});}
function sameMetadata(before,after){for(const k of ['database','bucket','functions','apps','storagePrivacy','secret','rules','fields'])assert.deepEqual(after[k],before[k],'STOP: protected metadata changed: '+k);}
async function main(action){
 assert(['check','apply'].includes(action));const dir=path.join(ROOT,'build/production-phase2');fs.mkdirSync(dir,{recursive:true,mode:0o700});fs.chmodSync(dir,0o700);
 const save=(name,data)=>{const f=path.join(dir,name);fs.writeFileSync(f,JSON.stringify(data,null,2)+'\n',{mode:0o600});fs.chmodSync(f,0o600);};
 const report={phase:'2a',status:'STARTED',attempts:[],mutations:0,partialSuccess:false};const persist=()=>save('index-execution.json',report);persist();
 execFileSync('python3',['scripts/firebase_production.py','check','--project',P],{cwd:ROOT,stdio:'pipe'});
 let bearer;async function token(){if(bearer)return bearer;const lib='/Users/shum/anaconda3/lib/node_modules/firebase-tools/lib',account=require(lib+'/auth.js').getGlobalDefaultAccount(),api=require(lib+'/api.js');const r=await fetch('https://oauth2.googleapis.com/token',{method:'POST',body:new URLSearchParams({client_id:api.clientId(),client_secret:api.clientSecret(),refresh_token:account.tokens.refresh_token,grant_type:'refresh_token'})});const d=await r.json();assert(r.ok&&d.access_token);return bearer=d.access_token;}
 async function request(url,method='GET',body){guard(url,method,body,action==='apply');const write=method==='POST'&&url===CREATE;let attempt;if(write){attempt={url,method,bodySha256:crypto.createHash('sha256').update(JSON.stringify(body)).digest('hex'),status:'UNKNOWN',at:new Date().toISOString()};report.attempts.push(attempt);persist();}const r=await fetch(url,{method,redirect:'error',headers:{Authorization:'Bearer '+await token(),'Content-Type':'application/json'},...(body===undefined?{}:{body:JSON.stringify(body)}),signal:AbortSignal.timeout(45000)});const d=await r.json();if(!r.ok){if(attempt){attempt.status='HTTP_ERROR';persist();}throw Error(`Metadata/index HTTP ${r.status} ${d.error?.status||''}`);}if(attempt){attempt.status='CONFIRMED';report.mutations++;persist();}assert(!d.nextPageToken,'STOP: unexpected pagination');return d;}
 async function extra(){const out={};for(const [k,url] of Object.entries(URLs)){const method=k==='projectIAM'?'POST':'GET';let d=await request(url,method,method==='POST'?{options:{requestedPolicyVersion:3}}:undefined);if(k==='functions')d=(d.functions||[]).map(f=>({name:f.name,updateTime:f.updateTime,state:f.state}));out[k]=d;}return out;}
 try{
  const before=await require('./production_cloud.cjs').inspect();save('before.json',before);execFileSync('python3',['-c',"import sys;sys.path.insert(0,'scripts');import firebase_production as p;s=p.load('build/production-live.json');p.live_check(s);assert len(p.normalized_indexes(s['indexes']))==3;assert len(p.normalized_fields(s['fields']))==8"],{cwd:ROOT,stdio:'pipe'});
  assert.equal(before.projectId,P);assert.equal(before.projectNumber,N);assert.equal(before.bucket.name,B);assert(before.apps.apps.some(a=>a.bundleId==='com.forta2k25.Aogaku'&&a.state==='ACTIVE'));assert(before.indexes.indexes.every(i=>i.state==='READY'));
  const baseline=await extra();save('protected-resources-before.json',baseline);assert.equal(baseline.queue.state,'PAUSED');
  if(action==='check'){report.status='PREFLIGHT_PASS';persist();console.log('Phase 2a preflight PASS: existing indexes3/overrides8; target identity; no mutations');return;}
  // Re-read the exact three indexes/field definitions and Rules immediately before mutation.
  const fresh=await require('./production_cloud.cjs').inspect();sameMetadata(before,fresh);assert.deepEqual(fresh.indexes,before.indexes,'STOP: index drift');
  const operation=await request(CREATE,'POST',BODY);assert(operation.name.startsWith(`projects/${P}/databases/(default)/operations/`));save('index-create-operation.json',operation);
  for(let i=0;i<600;i++){
   const indexes=await request(require('./production_cloud.cjs').urls.indexes),fields=await request(require('./production_cloud.cjs').urls.fields);assert.deepEqual(fields,before.fields,'STOP: fieldOverrides drift');
   const ai=(indexes.indexes||[]).filter(x=>x.name.includes('/collectionGroups/aiSources/')),existing=(indexes.indexes||[]).filter(x=>!x.name.includes('/collectionGroups/aiSources/'));
   assert.deepEqual(existing,before.indexes.indexes,'STOP: existing indexes changed');assert(ai.length<=1&&existing.length===3,'STOP: unexpected index count');
   if(ai.length){assert.equal(indexSpec(ai[0]),JSON.stringify(INDEX));assert(['CREATING','READY'].includes(ai[0].state),'STOP: failed/unexpected AI index state');report.index={name:ai[0].name,state:ai[0].state};persist();if(ai[0].state==='READY')break;}
   assert(i<599,'STOP: index not READY within bounded verification window');await new Promise(r=>setTimeout(r,3000));
  }
  const after=await require('./production_cloud.cjs').inspect();save('after-index.json',after);sameMetadata(before,after);assert.equal(after.indexes.indexes.length,4);assert(after.indexes.indexes.every(i=>i.state==='READY'));const afterExtra=await extra();save('protected-resources-after-index.json',afterExtra);assert.deepEqual(afterExtra,baseline,'STOP: IAM/queue/Scheduler/Functions drift');
  report.status='READY';report.indexCount=4;report.fieldOverridesUnchanged=true;report.protectedResourcesUnchanged=true;report.rulesUnchanged=true;report.completedAt=new Date().toISOString();persist();console.log(JSON.stringify({phase:'2a',status:'READY',indexCount:4,fieldOverrides:8,mutations:report.mutations,partialSuccess:false,rulesReleased:false}));
 }catch(e){report.status='STOPPED';report.error=e.message;report.partialSuccess=report.mutations>0||report.attempts.some(a=>a.status==='UNKNOWN');persist();console.error(JSON.stringify({status:report.status,error:e.message,partialSuccess:report.partialSuccess,mutations:report.mutations}));throw e;}
}
module.exports={guard,BODY,CREATE};
if(require.main===module)main(process.argv[2]).catch(()=>{process.exitCode=1});
