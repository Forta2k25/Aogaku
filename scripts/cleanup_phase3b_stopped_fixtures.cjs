#!/usr/bin/env node
// Only the two Auth accounts owned by the archived, stopped synthetic E2E.
// Verify every registered document/object/task BEFORE the first Auth deletion.
// The installed, verified Gen1 Auth trigger performs all data cleanup.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const ROOT=path.resolve(__dirname,'..'),DIR=path.join(ROOT,'build/production-phase3b');
const P='forta-aogaku',N='505828754933',B=P+'.firebasestorage.app',DB='aogaku-ai',R='asia-northeast1';
const decode=require('./production_phase3b_e2e.cjs').decode;
const plain=d=>Object.fromEntries(Object.entries(d?.fields||{}).map(([k,v])=>[k,decode(v)]));
const hash=(...s)=>crypto.createHash('sha256').update(JSON.stringify(s)).digest('hex');
const expectedFixtureEmail=(role,run)=>`ai-phase3b-${role}-${run}@example.test`.toLowerCase();
function scoped(p,uid,run){return p.split('/').some(s=>s===uid||s.startsWith('p3b-'+uid+'-')||s==='local:'+uid+':'+run||[0,1,2].some(i=>s===hash(run,uid,'source',i)));}
function validateRegistry(reg,run){
 assert.equal(new Set(reg.uids).size,2);assert.equal(reg.uids.length,2);
 for(const uid of reg.uids)assert(/^[A-Za-z0-9_-]{20,128}$/.test(uid));
 for(const p of reg.paths){assert(reg.uids.includes(p.uid));assert(['(default)',DB].includes(p.database));assert(!p.path.includes('..')&&p.path.split('/').length%2===0&&scoped(p.path,p.uid,run));}
 for(const o of reg.objects){assert(reg.uids.includes(o.uid));assert([`ai-inputs/${DB}/${o.uid}/`,`ai-derived/${DB}/${o.uid}/`,`users/${o.uid}/transcriptionUploads/`,`avatars/${o.uid}.jpg`].some(prefix=>o.path.startsWith(prefix)));assert(!o.path.includes('..'));}
 for(const t of reg.tasks){assert(reg.uids.includes(t.uid));assert([0,1,2].some(i=>t.id===hash(run,t.uid,'task',i)));}
}
async function main(){
 const load=f=>JSON.parse(fs.readFileSync(f));
 const e2e=load(path.join(DIR,'e2e.json')),execution=load(path.join(DIR,'execution.json')),context=load(path.join(ROOT,'build/phase3b-runtime-recovery-context.json'));
 assert.equal(e2e.status,'PASS');assert.equal(e2e.artifactSha256,execution.artifactSha256);assert.deepEqual(e2e.results.map(r=>r.route),['preDeleteCleanup','deleteAccountServerSide','onAuthUserDelete']);assert(e2e.results.every(r=>r.status==='PASS'));assert.equal(execution.status,'CONTROL_PLANE_PASS');assert(execution.protectedResourcesUnchanged);
 assert(/^build\/production-phase3b-runtime-stop-\d{8}-\d{6}$/.test(context.previousRunDirectory));
 const oldDir=path.join(ROOT,context.previousRunDirectory),old=load(path.join(oldDir,'e2e.json')),registry=load(path.join(oldDir,'fixture-registry.json'));
 assert.equal(old.status,'STOPPED');assert.equal(old.realUsersUsed,0);assert(old.error.includes('AI_DATABASE_MISMATCH'));assert.equal(old.results.length,0);validateRegistry(registry,old.runId);
 assert(registry.uids.every(uid=>!load(path.join(DIR,'fixture-registry.json')).uids.includes(uid)));
 const output=path.join(DIR,'previous-fixture-cleanup.json');assert(!fs.existsSync(output),'STOP: preserve previous cleanup attempt; no automatic replay');
 const proof={status:'STARTED',artifactSha256:execution.artifactSha256,oldRunId:old.runId,startedAt:new Date().toISOString(),targets:registry.uids,results:[],ownershipVerified:false,realUsersUsed:0,dataDeletesByOperator:0,authDeleteAttempts:[]};
 const save=()=>{fs.writeFileSync(output,JSON.stringify(proof,null,2)+'\n',{mode:0o600});fs.chmodSync(output,0o600);};save();
 let bearer,at=0;
 async function token(){if(!bearer||Date.now()-at>2700000){const lib='/Users/shum/anaconda3/lib/node_modules/firebase-tools/lib',a=require(lib+'/auth.js').getGlobalDefaultAccount(),api=require(lib+'/api.js');const r=await fetch('https://oauth2.googleapis.com/token',{method:'POST',body:new URLSearchParams({client_id:api.clientId(),client_secret:api.clientSecret(),refresh_token:a.tokens.refresh_token,grant_type:'refresh_token'}),signal:AbortSignal.timeout(45000)});const d=await r.json();assert(r.ok&&d.access_token);bearer=d.access_token;at=Date.now();}return bearer;}
 const authBase=`https://identitytoolkit.googleapis.com/v1/projects/${P}/accounts`;
 const queue=`https://cloudtasks.googleapis.com/v2/projects/${P}/locations/${R}/queues/aiProcessSource`;
 const allowed=new Set([`https://cloudresourcemanager.googleapis.com/v1/projects/${P}`,`https://storage.googleapis.com/storage/v1/b/${B}`,queue,...require('./deploy_production_phase3b.cjs').NAMES.map(n=>`https://cloudfunctions.googleapis.com/v2/projects/${P}/locations/${R}/functions/${n}`)]);
 const doc=(database,p)=>`https://firestore.googleapis.com/v1/projects/${P}/databases/${database}/documents/${p}`;
 for(const p of registry.paths)allowed.add(doc(p.database,p.path));
 for(const uid of registry.uids){allowed.add(doc(DB,`aiInputOwners/${uid}`));allowed.add(doc('(default)',`accountDeletionFences/${uid}`));allowed.add(doc('(default)',`users/${uid}`));allowed.add(doc('(default)',`privateUsage/${uid}`)+'/counters?pageSize=100');allowed.add(doc(DB,`aiUsage/${uid}`)+'/periods?pageSize=100');}
 for(const o of registry.objects)allowed.add(`https://storage.googleapis.com/storage/v1/b/${B}/o/${encodeURIComponent(o.path)}`);
 for(const t of registry.tasks){allowed.add(queue+'/tasks/'+t.id);allowed.add(queue+'/tasks/'+t.id+'?responseView=FULL');}
 async function request(url,method='GET',body){
  if(method==='GET')assert(allowed.has(url));
  else if(url===authBase+':lookup'){assert.equal(method,'POST');assert.deepEqual(body,{localId:registry.uids});}
  else {assert.equal(url,authBase+':delete');assert.equal(method,'POST');assert(proof.ownershipVerified);assert(registry.uids.includes(body?.localId));assert.deepEqual(Object.keys(body),['localId']);}
  const r=await fetch(url,{method,redirect:'error',headers:{Authorization:'Bearer '+await token(),'Content-Type':'application/json'},...(body===undefined?{}:{body:JSON.stringify(body)}),signal:AbortSignal.timeout(45000)});if(r.status===404&&method==='GET')return null;const d=await r.json().catch(()=>({}));assert(r.ok,'Stopped fixture '+method+' HTTP '+r.status+' '+(d.error?.status||''));return d;
 }
 async function bounded(items,fn){let cursor=0;await Promise.all(Array.from({length:4},async()=>{while(cursor<items.length)await fn(items[cursor++]);}));}
 async function gone(uid){
  if(plain(await request(doc(DB,`aiInputOwners/${uid}`))).state!=='deleted'||plain(await request(doc('(default)',`accountDeletionFences/${uid}`))).state!=='deleted')return false;
  for(const p of registry.paths.filter(x=>x.uid===uid)){
   const d=await request(doc(p.database,p.path));
   if(p.path===`aiInputOwners/${uid}`||p.path===`accountDeletionFences/${uid}`)continue;
   if(p.path.startsWith('aiSources/')&&p.path.split('/').length===2){const s=plain(d);if(s.ownerUserId!==uid||s.status!=='deleted'||Object.keys(s).some(k=>!['sourceId','ownerUserId','status','updatedAt'].includes(k)))return false;}
   else if(d)return false;
  }
  for(const o of registry.objects.filter(x=>x.uid===uid))if(await request(`https://storage.googleapis.com/storage/v1/b/${B}/o/${encodeURIComponent(o.path)}`))return false;
  for(const t of registry.tasks.filter(x=>x.uid===uid))if(await request(queue+'/tasks/'+t.id))return false;
  for(const [database,p,sub]of [['(default)',`privateUsage/${uid}`,'counters'],[DB,`aiUsage/${uid}`,'periods']]){const result=await request(doc(database,p)+`/${sub}?pageSize=100`);if(result.nextPageToken||(result.documents||[]).length)return false;}
  return !await request(doc('(default)',`users/${uid}`));
 }
 try {
  const project=await request(`https://cloudresourcemanager.googleapis.com/v1/projects/${P}`);assert.equal(project.projectId,P);assert.equal(project.projectNumber,N);assert.equal((await request(`https://storage.googleapis.com/storage/v1/b/${B}`)).name,B);assert.equal((await request(queue)).state,'PAUSED');
  for(const n of require('./deploy_production_phase3b.cjs').NAMES){const f=await request(`https://cloudfunctions.googleapis.com/v2/projects/${P}/locations/${R}/functions/${n}`);assert.equal(f.updateTime,execution.verified[n].updateTime);assert.equal(f.buildConfig.runtime,'nodejs22');}
  const users=(await request(authBase+':lookup','POST',{localId:registry.uids})).users||[];assert.equal(users.length,2);
  for(const u of users){assert(registry.uids.includes(u.localId));assert(['control','preDeleteCleanup'].some(role=>u.email===expectedFixtureEmail(role,old.runId)));assert(Number(u.createdAt)>=Date.parse(old.startedAt)-10000&&Number(u.createdAt)<Date.parse(old.startedAt)+3600000);}
  await bounded(registry.paths,async p=>{const d=await request(doc(p.database,p.path));if(d)assert.equal(plain(d).testRunId,old.runId,'STOP: fixture document ownership drift');});
  const md5=crypto.createHash('md5').update('Synthetic account deletion fixture').digest('base64');
  await bounded(registry.objects,async o=>{const d=await request(`https://storage.googleapis.com/storage/v1/b/${B}/o/${encodeURIComponent(o.path)}`);assert(d,'STOP: unexpected missing stopped object');assert.equal(d.name,o.path);assert.equal(d.md5Hash,md5);assert(Date.parse(d.timeCreated)>=Date.parse(old.startedAt)-10000&&Date.parse(d.timeCreated)<Date.parse(old.startedAt)+3600000);});
  await bounded(registry.tasks,async t=>{const d=await request(queue+'/tasks/'+t.id+'?responseView=FULL');assert(d,'STOP: unexpected missing stopped Task');assert.equal(d.httpRequest.url,`https://${R}-${P}.cloudfunctions.net/preDeleteCleanup`);assert.deepEqual(JSON.parse(Buffer.from(d.httpRequest.body,'base64').toString()),{data:{syntheticTest:true}});});
  proof.ownershipVerified=true;save();console.log('PASS: stopped run Auth identity, registered document testRunId, object digest/creation time and Task body verified; fresh 3-route E2E already PASS');
  for(const uid of registry.uids){
   const attempt={uid,status:'UNKNOWN',at:new Date().toISOString()};proof.authDeleteAttempts.push(attempt);save();
   await request(authBase+':delete','POST',{localId:uid});attempt.status='CONFIRMED';save();
   let complete=false;for(let i=0;i<60;i++){if(await gone(uid)){complete=true;break;}await new Promise(r=>setTimeout(r,5000));}
   assert(complete,'STOP: updated Auth trigger did not finish prior fixture cleanup');
   assert.equal((await request(queue)).state,'PAUSED');proof.results.push({uid,status:'PASS',namedDefaultStorageTasksCleaned:true,minimalTombstonesRetained:true});save();console.log('PASS: one registered previous synthetic UID cleaned by corrected Auth trigger');
  }
  assert(!(await request(authBase+':lookup','POST',{localId:registry.uids})).users?.length);
  proof.status='PASS';proof.completedAt=new Date().toISOString();proof.queueState=(await request(queue)).state;save();console.log('Previous stopped fixture cleanup PASS: two owned synthetic accounts only; no manual data deletion, queue PAUSED');
 } catch(e){proof.status='STOPPED';proof.error=e.message;save();console.error('STOP previous fixture cleanup: '+e.message+'; no retry');process.exitCode=1;}
}
module.exports={validateRegistry,scoped,expectedFixtureEmail};
if(require.main===module)main().catch(e=>{console.error('STOP previous fixture cleanup: '+e.message);process.exitCode=1;});
