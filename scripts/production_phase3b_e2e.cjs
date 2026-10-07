#!/usr/bin/env node
// Production tests ONLY freshly created disposable UIDs. No real-user inventory.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),{execFileSync}=require('node:child_process'),crypto=require('node:crypto');
const ROOT=path.resolve(__dirname,'..'),DIR=path.join(ROOT,'build/production-phase3b'),P='forta-aogaku',N='505828754933',B=P+'.firebasestorage.app',R='asia-northeast1',DB='aogaku-ai';
const load=n=>JSON.parse(fs.readFileSync(path.join(DIR,n+'.json'),'utf8'));
const save=(n,x)=>{const p=path.join(DIR,n+'.json');fs.writeFileSync(p,JSON.stringify(x,null,2)+'\n',{mode:0o600});fs.chmodSync(p,0o600);};
const queue=`https://cloudtasks.googleapis.com/v2/projects/${P}/locations/${R}/queues/aiProcessSource`;
function field(v){if(v===null)return {nullValue:null};if(typeof v==='string')return {stringValue:v};if(typeof v==='boolean')return {booleanValue:v};if(typeof v==='number')return {integerValue:String(v)};return {mapValue:{fields:Object.fromEntries(Object.entries(v).map(([k,v])=>[k,field(v)]))}};}
function decode(v){if(v.stringValue!==undefined)return v.stringValue;if(v.integerValue!==undefined)return Number(v.integerValue);if(v.booleanValue!==undefined)return v.booleanValue;if(v.nullValue!==undefined)return null;if(v.mapValue)return Object.fromEntries(Object.entries(v.mapValue.fields||{}).map(([k,v])=>[k,decode(v)]));throw Error('Unsupported fixture field');}
const plain=d=>Object.fromEntries(Object.entries(d.fields||{}).map(([k,v])=>[k,decode(v)]));
function jwt(token,uid){const c=JSON.parse(Buffer.from(token.split('.')[1],'base64url'));assert.equal(c.aud,P);assert.equal(c.iss,'https://securetoken.google.com/'+P);assert.equal(c.sub,uid);return c;}
const hash=(...s)=>crypto.createHash('sha256').update(JSON.stringify(s)).digest('hex');
async function main(){
 assert(!process.env.FIRESTORE_EMULATOR_HOST&&!process.env.FIREBASE_AUTH_EMULATOR_HOST&&!process.env.STORAGE_EMULATOR_HOST,'STOP: cloud/emulator mix');
 const deployment=load('execution');assert.equal(deployment.status,'CONTROL_PLANE_PASS');assert.deepEqual(deployment.updated,require('./deploy_production_phase3b.cjs').NAMES);
 assert(!fs.existsSync(path.join(DIR,'e2e.json')),'STOP: preserve prior E2E, no automatic replay');
 const baseline=load('postcheck-after'),registry={uids:[],paths:[],objects:[],tasks:[]},proof={phase:'3b',artifactSha256:deployment.artifactSha256,runId:crypto.randomUUID(),startedAt:new Date().toISOString(),results:[],status:'STARTED',deferredPhase4:['new AI callable admission','late worker rejection','late upload Storage trigger'],realUsersUsed:0};
 const persist=()=>{save('e2e',proof);save('fixture-registry',registry);};persist();
 let bearer,tokenAt=0;
 async function oauth(){if(!bearer||Date.now()-tokenAt>2700000){const lib='/Users/shum/anaconda3/lib/node_modules/firebase-tools/lib',a=require(lib+'/auth.js').getGlobalDefaultAccount(),api=require(lib+'/api.js');const r=await fetch('https://oauth2.googleapis.com/token',{method:'POST',body:new URLSearchParams({client_id:api.clientId(),client_secret:api.clientSecret(),refresh_token:a.tokens.refresh_token,grant_type:'refresh_token'}),signal:AbortSignal.timeout(45000)});const d=await r.json();assert(r.ok&&d.access_token);bearer=d.access_token;tokenAt=Date.now();}return bearer;}
 async function request(url,method='GET',body,allow404=false){
  const r=await fetch(url,{method,redirect:'error',headers:{Authorization:'Bearer '+await oauth(),'Content-Type':'application/json'},...(body===undefined?{}:{body:JSON.stringify(body)}),signal:AbortSignal.timeout(45000)});const d=await r.json().catch(()=>({}));if(r.status===404&&allow404)return null;assert(r.ok,'Fixture '+method+' HTTP '+r.status+' '+(d.error?.status||''));return d;
 }
 const project=await request(`https://cloudresourcemanager.googleapis.com/v1/projects/${P}`);assert.equal(project.projectId,P);assert.equal(project.projectNumber,N);
 assert.equal((await request(`https://storage.googleapis.com/storage/v1/b/${B}`)).name,B);assert.equal((await request(queue)).state,'PAUSED');
 for(const n of require('./deploy_production_phase3b.cjs').NAMES){const f=await request(`https://cloudfunctions.googleapis.com/v2/projects/${P}/locations/${R}/functions/${n}`);assert.equal(f.updateTime,baseline.functions.find(x=>x.name===f.name).updateTime);assert.equal(f.buildConfig.runtime,'nodejs22');}
 const plist=JSON.parse(execFileSync('python3',['-c','import json,plistlib;d=plistlib.load(open("Aogaku/GoogleService-Info.plist","rb"));assert d["PROJECT_ID"]=="forta-aogaku" and d["GCM_SENDER_ID"]=="505828754933" and d["BUNDLE_ID"]=="com.forta2k25.Aogaku" and d["STORAGE_BUCKET"]=="forta-aogaku.firebasestorage.app";print(json.dumps({"apiKey":d["API_KEY"]}))'],{cwd:ROOT,encoding:'utf8'}));
 const users={};
 async function create(role){const password=crypto.randomBytes(32).toString('base64url'),email=`ai-phase3b-${role}-${proof.runId}@example.test`;const r=await fetch('https://identitytoolkit.googleapis.com/v1/accounts:signUp?key='+encodeURIComponent(plist.apiKey),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email,password,returnSecureToken:true}),signal:AbortSignal.timeout(45000)});const d=await r.json();assert(r.ok,'Disposable Auth signup HTTP '+r.status+' '+(d.error?.message||''));jwt(d.idToken,d.localId);assert(!registry.uids.includes(d.localId));registry.uids.push(d.localId);users[role]={uid:d.localId,idToken:d.idToken,email,password};persist();return users[role];}
 async function freshAuth(u){
  assert(registry.uids.includes(u.uid));
  const r=await fetch('https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key='+encodeURIComponent(plist.apiKey),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email:u.email,password:u.password,returnSecureToken:true}),signal:AbortSignal.timeout(45000)});
  const d=await r.json();assert(r.ok,'Disposable reauthentication HTTP '+r.status);assert.equal(d.localId,u.uid);jwt(d.idToken,u.uid);u.idToken=d.idToken;
 }
 function docURL(database,p){assert(['(default)',DB].includes(database));assert(registry.paths.some(x=>x.database===database&&x.path===p),'STOP: unregistered fixture path');return `https://firestore.googleapis.com/v1/projects/${P}/databases/${database}/documents/${p}`;}
 function register(database,p,uid){assert(registry.uids.includes(uid),'STOP: UID not created in this run');assert(!p.includes('..')&&p.split('/').length%2===0);assert(p.split('/').some(s=>s===uid||s.startsWith('p3b-'+uid+'-')||s===hash(proof.runId,uid,'source',0)||s===hash(proof.runId,uid,'source',1)||s===hash(proof.runId,uid,'source',2)||s==='local:'+uid+':'+proof.runId),'STOP: fixture not UID-scoped');if(!registry.paths.some(x=>x.database===database&&x.path===p))registry.paths.push({database,path:p,uid});}
 async function seed(database,p,uid,data){register(database,p,uid);await request(docURL(database,p),'PATCH',{fields:Object.fromEntries(Object.entries({...data,testRunId:proof.runId}).map(([k,v])=>[k,field(v)]))});persist();}
 async function get(database,p){return request(docURL(database,p),'GET',undefined,true);}
 async function storage(p,uid){assert(registry.uids.includes(uid));assert([`ai-inputs/${DB}/${uid}/`,`ai-derived/${DB}/${uid}/`,`users/${uid}/transcriptionUploads/`,`avatars/${uid}.jpg`].some(prefix=>p.startsWith(prefix)));registry.objects.push({path:p,uid});persist();const url=`https://storage.googleapis.com/upload/storage/v1/b/${B}/o?uploadType=media&name=${encodeURIComponent(p)}&ifGenerationMatch=0`;const r=await fetch(url,{method:'POST',redirect:'error',headers:{Authorization:'Bearer '+await oauth(),'Content-Type':'text/plain'},body:'Synthetic account deletion fixture',signal:AbortSignal.timeout(45000)});assert(r.ok,'Synthetic Storage create HTTP '+r.status);return r.json();}
 async function quotaEmpty(u){
  assert(registry.uids.includes(u.uid));
  const url=docURL('(default)',`privateUsage/${u.uid}`);
  assert.equal(await request(url,'GET',undefined,true),null,'Legacy usage root recreated');
  const result=await request(url+'/counters?pageSize=100');
  assert(!(result.documents||[]).length&&!result.nextPageToken,'Legacy quota counters recreated');
 }
 async function task(id,uid){assert(registry.uids.includes(uid));assert.equal((await request(queue)).state,'PAUSED');registry.tasks.push({id,uid});persist();await request(queue+'/tasks','POST',{task:{name:queue.replace('https://cloudtasks.googleapis.com/v2/','')+'/tasks/'+id,scheduleTime:new Date(Date.now()+86400000).toISOString(),httpRequest:{httpMethod:'POST',url:`https://${R}-${P}.cloudfunctions.net/preDeleteCleanup`,headers:{'Content-Type':'application/json'},body:Buffer.from(JSON.stringify({data:{syntheticTest:true}})).toString('base64')}}});}
 async function setup(u,paged=false){const uid=u.uid;await seed('(default)',`users/${uid}`,uid,{idLower:uid,name:'Disposable Phase3b test'});await seed('(default)',`usernames/${uid}`,uid,{uid});await seed('(default)',`users/${uid}/courseChats/test/messages/test`,uid,{text:'synthetic conversation'});await seed('(default)',`users/${uid}/lectureNotes/test/nested/test`,uid,{text:'synthetic note'});await seed('(default)',`privateUsage/${uid}/counters/month`,uid,{count:3});register('(default)',`privateUsage/${uid}`,uid);register('(default)',`accountDeletionFences/${uid}`,uid);
  await seed(DB,`aiInputOwners/${uid}`,uid,{state:'active'});await seed(DB,`aiUsage/${uid}/periods/day`,uid,{count:3});register(DB,`aiUsage/${uid}`,uid);
  const offering='local:'+uid+':'+proof.runId;await seed(DB,`aiCourseOfferings/${offering}`,uid,{ownerUserId:uid});await seed(DB,`aiCourseOfferings/${offering}/lectures/test`,uid,{test:true});await seed(DB,`aiCourseOfferings/${offering}/memberships/${uid}`,uid,{userId:uid,status:'verified'});
  for(let i=0;i<(paged?101:2);i++)await seed(DB,`aiCourseOfferings/p3b-${uid}-missing-${i}/memberships/${uid}`,uid,{userId:uid,status:'verified'});
  for(let i=0;i<3;i++){const sid=hash(proof.runId,uid,'source',i),job=hash(proof.runId,uid,'task',i);await seed(DB,`aiSources/${sid}`,uid,{sourceId:sid,ownerUserId:uid,status:['awaiting_upload','queued','processing'][i],sourceType:['image','audio','pdf'][i],courseOfferingId:offering,noteText:'synthetic private text',leaseToken:'fixture-only'});await seed(DB,`aiSources/${sid}/jobs/${job}`,uid,{taskId:job});await seed(DB,`aiSources/${sid}/runs/test/chunks/test`,uid,{text:'synthetic derived text'});register(DB,`aiSources/${sid}/runs/test`,uid);await task(job,uid);await storage(`ai-inputs/${DB}/${uid}/${sid}/original`,uid);await storage(`ai-derived/${DB}/${uid}/${sid}/derived.txt`,uid);}
  await storage(`ai-inputs/${DB}/${uid}/orphan/original`,uid);await storage(`ai-derived/${DB}/${uid}/orphan/derived.txt`,uid);await storage(`avatars/${uid}.jpg`,uid);await storage(`users/${uid}/transcriptionUploads/old.m4a`,uid);
 }
 async function call(name,u,data={}){assert(['preDeleteCleanup','deleteAccountServerSide','askCourseAI','transcribeLectureAudio','generateReactionPaper'].includes(name));assert(registry.uids.includes(u.uid));jwt(u.idToken,u.uid);const r=await fetch(`https://${R}-${P}.cloudfunctions.net/${name}`,{method:'POST',redirect:'error',headers:{Authorization:'Bearer '+u.idToken,'Content-Type':'application/json'},body:JSON.stringify({data}),signal:AbortSignal.timeout(540000)});const d=await r.json().catch(()=>({}));return {status:r.status,body:d};}
 async function authDelete(u){assert(registry.uids.includes(u.uid));jwt(u.idToken,u.uid);const r=await fetch('https://identitytoolkit.googleapis.com/v1/accounts:delete?key='+encodeURIComponent(plist.apiKey),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({idToken:u.idToken}),signal:AbortSignal.timeout(45000)});assert(r.ok,'Disposable Auth delete HTTP '+r.status);}
 async function contentGone(u,legacy){const uid=u.uid,owner=await get(DB,`aiInputOwners/${uid}`),fence=await get('(default)',`accountDeletionFences/${uid}`);if(plain(owner||{}).state!=='deleted'||plain(fence||{}).state!=='deleted')return false;
  for(const p of registry.paths.filter(x=>x.uid===uid)){if(p.path.startsWith('aiSources/')&&p.path.split('/').length===2){const d=plain(await get(p.database,p.path)||{});if(d.status!=='deleted'||Object.keys(d).some(k=>!['sourceId','ownerUserId','status','updatedAt'].includes(k)))return false;}else if([`aiInputOwners/${uid}`,`accountDeletionFences/${uid}`].includes(p.path))continue;else if(!legacy&&p.database==='(default)'&&p.path.startsWith(`users/${uid}`))continue;else if(await get(p.database,p.path))return false;}
  for(const o of registry.objects.filter(x=>x.uid===uid)){if(!legacy&&o.path.startsWith(`users/${uid}/`))continue;if(await request(`https://storage.googleapis.com/storage/v1/b/${B}/o/${encodeURIComponent(o.path)}`,'GET',undefined,true))return false;}
  for(const t of registry.tasks.filter(x=>x.uid===uid))if(await request(queue+'/tasks/'+t.id,'GET',undefined,true))return false;
  return true;
 }
 async function waitGone(u,legacy){for(let i=0;i<36;i++){if(await contentGone(u,legacy))return;await new Promise(r=>setTimeout(r,5000));}throw Error('Cleanup post-check timed out');}
 const control=await create('control');await seed('(default)',`privateUsage/${control.uid}/counters/month`,control.uid,{count:7});await seed(DB,`aiUsage/${control.uid}/periods/day`,control.uid,{count:7});await seed(DB,`aiCourseOfferings/p3b-${control.uid}-missing-control/memberships/${control.uid}`,control.uid,{userId:control.uid,status:'verified'});await storage(`ai-inputs/${DB}/${control.uid}/control/original`,control.uid);await storage(`ai-derived/${DB}/${control.uid}/control/derived.txt`,control.uid);
 async function controlSame(){for(const p of registry.paths.filter(x=>x.uid===control.uid)){const d=await get(p.database,p.path);assert(d,'Control UID data removed');assert.equal(plain(d).testRunId,proof.runId);if(p.path.includes('/periods/')||p.path.includes('/counters/'))assert.equal(plain(d).count,7);}for(const o of registry.objects.filter(x=>x.uid===control.uid))assert(await request(`https://storage.googleapis.com/storage/v1/b/${B}/o/${encodeURIComponent(o.path)}`),'Control object removed');}
 try{
  for(const route of ['preDeleteCleanup','deleteAccountServerSide','onAuthUserDelete']){
   const u=await create(route);await setup(u,route==='preDeleteCleanup');await freshAuth(u);console.log(route+': isolated synthetic fixtures created; queue PAUSED');
   if(route==='onAuthUserDelete')await authDelete(u);else{const response=await call(route,u,{});assert.equal(response.status,200,route+' HTTP '+response.status+' '+(response.body.error?.message||''));assert.equal(response.body.result.ok,true);if(route==='preDeleteCleanup')assert.equal(response.body.result.aiAccountDeletionVersion,1);}
   await waitGone(u,route!=='preDeleteCleanup');
   if(route==='preDeleteCleanup'){
    // Auth is intentionally still present here. Repeat the deployed Callable
    // against the same completed tombstones, with no new fixtures or tasks.
    await freshAuth(u);
    const again=await call(route,u,{});assert.equal(again.status,200,'Idempotent preDelete retry failed');assert.equal(again.body.result.ok,true);
    await waitGone(u,false);await quotaEmpty(u);await controlSame();
   }
   for(const n of ['askCourseAI','transcribeLectureAudio','generateReactionPaper']){
    // Legacy ASR validates object existence before reserving quota. A new,
    // synthetic, non-empty probe reaches that fence after the deletion cleanup.
    // It is explicitly cleaned by this harness, not a Phase4 finalize trigger.
    const probe=`users/${u.uid}/transcriptionUploads/quota-probe.m4a`;
    const object=n==='transcribeLectureAudio'?await storage(probe,u.uid):null;
    const data=n==='transcribeLectureAudio'?{storagePath:probe,durationSeconds:10}:{prompt:'synthetic blocked request',transcript:'synthetic blocked transcript',targetLength:400};
    const r=await call(n,u,data);
    if(object)await request(`https://storage.googleapis.com/storage/v1/b/${B}/o/${encodeURIComponent(probe)}?ifGenerationMatch=${object.generation}`,'DELETE',undefined,true);
    assert(r.status!==200&&r.body.error,'Legacy AI accepted deleting UID');assert(['ACCOUNT_DELETED','Unauthenticated','unauthenticated'].some(s=>String(r.body.error.message).includes(s))||r.body.error.status==='UNAUTHENTICATED','Unexpected legacy rejection');
   }
   await quotaEmpty(u);await controlSame();assert.equal((await request(queue)).state,'PAUSED');
   if(route==='preDeleteCleanup'){await authDelete(u);await waitGone(u,true);}
   proof.results.push({route,status:'PASS',namedContentGone:true,storageActiveObjectsGone:true,tasksCancelled:true,legacyQuotaGone:true,legacyAIDenied:true,quotaNotRegenerated:true,otherSyntheticUIDUnchanged:true,minimalTombstonesRetained:true,idempotentCallableRetry:route==='preDeleteCleanup',authTriggerAfterCompletedCleanup:route!=='onAuthUserDelete'});persist();console.log('PASS '+route+': actual deployed handler, Tasks cancellation, dual database/Storage cleanup, no quota regeneration, control UID unchanged');
  }
  // Final isolated control cleanup through the updated Auth trigger only.
  register(DB,`aiInputOwners/${control.uid}`,control.uid);register('(default)',`accountDeletionFences/${control.uid}`,control.uid);register('(default)',`users/${control.uid}`,control.uid);await authDelete(control);await waitGone(control,true);
  proof.status='PASS';proof.completedAt=new Date().toISOString();proof.fixtureAccountsDeleted=registry.uids.length;proof.queueState=(await request(queue)).state;persist();console.log('Phase3b production E2E PASS: three independent disposable deletion routes; no real users; Phase4 tests deferred');
 }catch(e){proof.status='STOPPED';proof.error=e.message;persist();console.error('STOP Phase3b E2E: '+e.message+'; no retry, other route or Phase4 progression');process.exitCode=1;}
}
module.exports={jwt,field,decode};
if(require.main===module)main().catch(e=>{console.error('STOP Phase3b E2E: '+e.message);process.exitCode=1});
