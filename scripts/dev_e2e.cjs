#!/usr/bin/env node
// Real Dev API integration tests with fictional assets. Credentials stay in ignored, mode-0600 files.
const assert = require('node:assert/strict');
const {readFileSync,writeFileSync,mkdirSync,existsSync,openSync,closeSync,unlinkSync,chmodSync} = require('node:fs');
const {execFileSync} = require('node:child_process');
const {join} = require('node:path');
const {randomUUID,randomBytes,randomInt,createHash} = require('node:crypto');
const {ROOT,PROJECT:P,REGION:R,BUCKET:B,guard,request} = require('./dev_cloud.cjs');
const OUT=join(ROOT,'scripts/output-dev');
mkdirSync(OUT,{recursive:true,mode:0o700});
chmodSync(OUT,0o700);
const lockFile=join(OUT,'e2e.lock');
if(existsSync(lockFile)) {
  const pid=Number(readFileSync(lockFile,'utf8'));
  let active=true;
  try {process.kill(pid,0);}catch(e){if(e.code==='ESRCH')active=false;else throw e;}
  if(active)throw Error('Another Dev E2E run is active; wait for it to finish');
  unlinkSync(lockFile);
}
const lock=openSync(lockFile,'wx',0o600);closeSync(lock);writeFileSync(lockFile,String(process.pid));
process.on('exit',()=>{if(existsSync(lockFile))unlinkSync(lockFile);});
const stateFile=join(OUT,'e2e-state-named-v1.json');
const historicalFile=join(OUT,'e2e-state.json');
const priorUsers={}; // Fresh named-database fixtures; preserve all prior credentials/results.
const state=existsSync(stateFile) ? JSON.parse(readFileSync(stateFile)) : {runId:Date.now().toString(),users:priorUsers,sources:{},results:[]};
const resultsStart=state.results.length;
let activeOwner=null;
const ownerUser=()=>activeOwner||state.users.owner;
const save=()=>writeFileSync(stateFile,JSON.stringify(state,null,2),{mode:0o600});
function hash(...parts) { return createHash('sha256').update(JSON.stringify(parts)).digest('hex'); }
const AI_DATABASE='aogaku-ai';
const databaseFor=path=>/^(aiSources|aiCourseOfferings|aiUsage|aiInputOwners|aiMaintenance)(\/|$)/.test(path)?AI_DATABASE:'(default)';
function field(v) {
  if(v===null)return {nullValue:null};
  if(typeof v==='string')return {stringValue:v};
  if(typeof v==='boolean')return {booleanValue:v};
  if(typeof v==='number')return Number.isInteger(v)?{integerValue:String(v)}:{doubleValue:v};
  if(Array.isArray(v))return {arrayValue:{values:v.map(field)}};
  return {mapValue:{fields:Object.fromEntries(Object.entries(v).map(([k,x])=>[k,field(x)]))}};
}
async function seed(path,data) {
  if(/\/memberships\/[^/]+$/.test(path))data={...data,userId:path.split('/').at(-1)};
  return request(`https://firestore.googleapis.com/v1/projects/${P}/databases/${databaseFor(path)}/documents/${path}`,'PATCH',{fields:Object.fromEntries(Object.entries(data).map(([k,v])=>[k,field(v)]))});
}
function jwtProject(token) {
  const claims=JSON.parse(Buffer.from(token.split('.')[1],'base64url'));
  if(claims.aud!==P || claims.iss!==`https://securetoken.google.com/${P}`)throw Error('STOP: auth token is outside Dev');
}
async function users() {
  guard();
  const key=execFileSync('python3',['-c','import plistlib;print(plistlib.load(open("Config/Firebase/Development/GoogleService-Info.plist","rb"))["API_KEY"])'],{cwd:ROOT,encoding:'utf8'}).trim();
  for(const role of ['owner','member','outsider']) {
    const u=state.users[role] || {id:`aie2e${{owner:'o',member:'m',outsider:'x'}[role]}${state.runId}`,password:randomBytes(24).toString('base64url')};
    state.users[role]=u;save();
    const response=await fetch(`https://identitytoolkit.googleapis.com/v1/accounts:${u.uid?'signInWithPassword':'signUp'}?key=${encodeURIComponent(key)}`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email:`${u.id}@aogaku.app`,password:u.password,returnSecureToken:true})});
    const data=await response.json();
    if(!response.ok)throw Error(`Dev Auth HTTP ${response.status}: ${data.error?.message || 'failed'}`);
    jwtProject(data.idToken);
    Object.assign(u,{uid:data.localId,idToken:data.idToken});state.users[role]=u;save();
    await seed(`users/${u.uid}`,{id:u.id,idLower:u.id,name:`AI Dev E2E ${role}`,grade:1,faculty:'開発テスト',department:'AI入力'});
  }
  if(!state.classId) state.classId=await createTestClass(2026,'AI入力Dev E2E');
  const owned=await request(`https://firestore.googleapis.com/v1/projects/${P}/databases/(default)/documents/classes/${state.classId}`);
  assert.equal(owned.fields.testRunId.stringValue,state.runId); // Never overwrite another catalog record.
  state.localCourseUUID ||= randomUUID();
  state.context={classDocId:state.classId,localCourseId:state.localCourseUUID,localCourseUUID:state.localCourseUUID,year:2026,semester:'fall',dayID:20732,occurrenceKey:'default',
    syllabusUrl:`https://syllabus.aoyama.ac.jp/shousai.ashx?YR=2026&FN=dev-${state.classId}`,courseName:'AI入力Dev E2E',teacherName:'架空の教員'};
  state.courseId=`2026:${state.classId}`;
  for(const role of ['owner','member']) await seed(`aiCourseOfferings/${state.courseId}/memberships/${state.users[role].uid}`,{status:'verified',active:true,testRunId:state.runId});
  save();
}
async function freshRegressionOwner() {
  guard();
  const key=execFileSync('python3',['-c','import plistlib;print(plistlib.load(open("Config/Firebase/Development/GoogleService-Info.plist","rb"))["API_KEY"])'],{cwd:ROOT,encoding:'utf8'}).trim();
  const password=randomBytes(24).toString('base64url'),email=`ai-regression-${randomUUID()}@example.test`;
  const r=await fetch(`https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=${encodeURIComponent(key)}`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email,password,returnSecureToken:true})});
  if(!r.ok)throw Error('Fresh Dev regression account creation failed');
  const u=await r.json();jwtProject(u.idToken);activeOwner={uid:u.localId,idToken:u.idToken,email,password};
  state.users['regression-'+u.localId]=activeOwner;save();
  await seed(`users/${u.localId}`,{idLower:'regression-'+u.localId,name:'Fictional regression owner',testRunId:state.runId});
}
async function createTestClass(year,name) {
  for(let i=0;i<20;i++) {
    const classId=String(randomInt(90000,100000));
    const data={class_name:name,teacher_name:'架空の教員',url:`https://syllabus.aoyama.ac.jp/shousai.ashx?YR=${year}&FN=dev-${classId}`,testRunId:state.runId};
    try {
      await request(`https://firestore.googleapis.com/v1/projects/${P}/databases/(default)/documents/classes?documentId=${classId}`,'POST',{fields:Object.fromEntries(Object.entries(data).map(([k,v])=>[k,field(v)]))});
      save();return classId;
    }catch(e){if(e.httpStatus!==409)throw e;}
  }
  throw Error('Cannot allocate an unused five-digit synthetic class');
}
async function transport(url,options,label) {
  for(let attempt=0;attempt<4;attempt++) {
    try {return await fetch(url,options);}
    catch(e) {
      const code=e.cause?.code;
      if(attempt===3 || !['UND_ERR_SOCKET','ECONNRESET','ETIMEDOUT','EAI_AGAIN','ENOTFOUND','UND_ERR_CONNECT_TIMEOUT'].includes(code))throw e;
      console.log(`RETRY ${label}: ${code}; same request`);
      await new Promise(r=>setTimeout(r,1000*(attempt+1)));
    }
  }
}
async function call(name,data,role='owner') {
  guard();
  if(!/^ai(?:CreateSource|CompleteSource|GetSource|ListSources|RetrySource|UpdateSource|DeleteSource|GetEvidence|RetrieveContext|LinkSourceOffering)$/.test(name))throw Error('STOP: unexpected callable');
  const u=role==='owner'?ownerUser():state.users[role];jwtProject(u.idToken);
  const response=await transport(`https://${R}-${P}.cloudfunctions.net/${name}`,{method:'POST',headers:{Authorization:`Bearer ${u.idToken}`,'Content-Type':'application/json'},body:JSON.stringify({data}),signal:AbortSignal.timeout(150000)},name);
  const body=await response.json();
  if(!response.ok || body.error) {const e=Error(body.error?.message || `HTTP ${response.status}`);e.code=body.error?.details?.code || body.error?.status;e.httpStatus=response.status;throw e;}
  return body.result;
}
async function retrievePages(data,role='owner') {
  const items=[];let after,seen=new Set();
  for(let page=0;page<200;page++) {
    const r=await call('aiRetrieveContext',{...data,...(after?{after}:{})},role);items.push(...r.items);
    if(!r.nextCursor)return {...r,items};
    assert(!seen.has(r.nextCursor),'Repeated retrieval cursor');seen.add(r.nextCursor);after=r.nextCursor;
  }
  throw Error('Retrieval page bound exceeded');
}
async function check(label,fn) {
  const startedAt=new Date().toISOString();
  try {const details=await fn();state.results.push({label,status:'PASS',startedAt,details});console.log(`PASS ${label}`);}
  catch(e){const status=e.code==='ASR_NOT_CONFIGURED'?'BLOCKED':'FAIL';state.results.push({label,status,startedAt,error:e.code || e.message,transportCause:e.cause?.code || null});console.log(`${status} ${label}: ${e.code || e.message}`);}
  save();
}
async function denied(fn,codes) {
  try {await fn();}catch(e){if(codes.includes(e.code))return;throw e;}
  throw Error('Unauthorized operation succeeded');
}
async function upload(source,bytes) {
  const u=new URL(source.upload.url);
  const bucketScoped=u.hostname===B || (u.hostname==='storage.googleapis.com' && decodeURIComponent(u.pathname).startsWith(`/${B}/`));
  if(u.protocol!=='https:' || !bucketScoped)throw Error('STOP: signed upload URL is outside Dev bucket');
  const r=await transport(u,{method:'PUT',headers:source.upload.headers,body:bytes,signal:AbortSignal.timeout(120000)},'signed upload');
  if(r.status===412){
    const objectPath=decodeURIComponent(u.pathname).replace(`/${B}/`,'');
    const metadata=await request(`https://storage.googleapis.com/storage/v1/b/${B}/o/${encodeURIComponent(objectPath)}`);
    assert.equal(Number(metadata.size),bytes.length);assert.equal(metadata.md5Hash,createHash('md5').update(bytes).digest('base64'));return;
  }
  if(!r.ok)throw Error(`Dev upload HTTP ${r.status}`);
}
async function waitReady(sourceId,timeout=240000) {
  const until=Date.now()+timeout;
  while(Date.now()<until) {
    const source=await call('aiGetSource',{sourceId});
    if(['ready','partial_ready'].includes(source.status))return source;
    if(source.status==='failed') {const e=Error(source.error?.code||'processing failed');e.code=source.error?.code;throw e;}
    await new Promise(r=>setTimeout(r,5000));
  }
  throw Error('Processing timeout');
}
async function input(type,variant=type) {
  const filename=variant==='audio-long' ? 'sample-long-audio.m4a' : {image:'sample-photo.jpg',pdf:'sample-document.pdf',audio:'sample-audio.m4a'}[type];
  const bytes=filename ? readFileSync(join(OUT,'assets',filename)) : null;
  const data={clientRequestId:`${state.runId}-${variant}-${process.env.AI_E2E_PHASE || "annual-v2"}`,type,title:`Dev E2E ${variant}`,mime:{note:'text/plain',image:'image/jpeg',pdf:'application/pdf',audio:'audio/mp4'}[type],context:state.context,
    ...(bytes?{size:bytes.length}: {text:'検索拡張生成 RAG では根拠資料を検索し、出典を保存して回答を検証する。これはDev E2E専用の架空のメモです。'}),...(type==='audio'?{durationSeconds:variant==='audio-long'?1020:120}:{})};
  const source=await call('aiCreateSource',data);
  state.sources[variant]={sourceId:source.sourceId,data};save();
  const duplicate=await call('aiCreateSource',data);assert.equal(duplicate.sourceId,source.sourceId);
  if(source.upload) {
    await upload(source,bytes);
    const again=await fetch(source.upload.url,{method:'PUT',headers:source.upload.headers,body:bytes});assert.equal(again.status,412);
  }
  await call('aiCompleteSource',{sourceId:source.sourceId});
  if(source.status==='failed' || source.status==='partial_ready')await call('aiRetrySource',{sourceId:source.sourceId});
  const ready=await waitReady(source.sourceId);
  assert.equal(ready.status,'ready');
  const evidence=await call('aiGetEvidence',{sourceId:source.sourceId});
  if(variant==='audio-long') {
    let cursor=evidence.nextCursor;
    while(cursor){const page=await call('aiGetEvidence',{sourceId:source.sourceId,after:cursor});evidence.items.push(...page.items);cursor=page.nextCursor;}
    assert.equal(ready.coverage.totalUnits,2);assert(evidence.items.some(x=>x.locator.endMs>900000));
  }
  assert(evidence.items.length>0);
  if(type==='pdf') {assert.deepEqual([...new Set(evidence.items.map(x=>x.locator.pageNumber))].sort(),[1,2]);assert(evidence.items.some(x=>x.method==='pdf_text'));assert(evidence.items.some(x=>x.method==='vision_ocr'));}
  if(type==='image')assert(evidence.items.every(x=>x.method==='vision_ocr' && x.locator.imageIndex===1));
  if(type==='note')assert(evidence.items.every(x=>x.locator.endChar>x.locator.startChar));
  if(type==='audio')assert(evidence.items.every(x=>x.locator.startMs>=0 && x.locator.endMs>x.locator.startMs));
  let retrieval=await call('aiRetrieveContext',{courseOfferingId:ready.courseOfferingId,purpose:'lecture_summary',maxCharacters:30000});
  let found=retrieval.items.some(x=>x.sourceId===source.sourceId);
  while(!found&&retrieval.nextCursor){retrieval=await call('aiRetrieveContext',{courseOfferingId:ready.courseOfferingId,purpose:'lecture_summary',maxCharacters:30000,after:retrieval.nextCursor});found=retrieval.items.some(x=>x.sourceId===source.sourceId);}
  assert(found);
  let question=await call('aiRetrieveContext',{courseOfferingId:ready.courseOfferingId,purpose:'question',query:'根拠資料',maxCharacters:30000});
  let matched=question.items.some(x=>x.sourceId===source.sourceId);
  while(!matched&&question.nextCursor){question=await call('aiRetrieveContext',{courseOfferingId:ready.courseOfferingId,purpose:'question',query:'根拠資料',maxCharacters:30000,after:question.nextCursor});matched=question.items.some(x=>x.sourceId===source.sourceId);}
  assert(matched);
  const list=await call('aiListSources',{context:state.context});assert(list.items.some(x=>x.sourceId===source.sourceId));
  return {sourceId:source.sourceId,status:ready.status,coverage:ready.coverage,locators:evidence.items.map(x=>x.locator),methods:[...new Set(evidence.items.map(x=>x.method))]};
}
async function permissionChecks() {
  const s=state.sources.note;
  if(!s)throw Error('note prerequisite missing');
  await denied(()=>call('aiGetEvidence',{sourceId:s.sourceId},'member'),['NOT_FOUND']);
  await call('aiUpdateSource',{sourceId:s.sourceId,knowledgeVisibility:'course'});
  assert((await call('aiGetEvidence',{sourceId:s.sourceId},'member')).items.length>0);
  await denied(()=>call('aiGetEvidence',{sourceId:s.sourceId},'outsider'),['NOT_FOUND']);
  await denied(()=>call('aiDeleteSource',{sourceId:s.sourceId},'member'),['FORBIDDEN']);
  await call('aiUpdateSource',{sourceId:s.sourceId,knowledgeVisibility:'private'});
  await denied(()=>call('aiGetEvidence',{sourceId:s.sourceId},'member'),['NOT_FOUND']);
  const search=await call('aiRetrieveContext',{courseOfferingId:state.courseId,purpose:'lecture_summary'},'member');
  assert(!search.items.some(x=>x.sourceId===s.sourceId));
  await denied(()=>call('aiCreateSource',{...s.data,text:'同じ受付IDで内容を変える'}),['REQUEST_CONFLICT']);
  return {sharing:'granted then revoked',outsider:'denied',duplicate:'same ID; conflicting content denied'};
}
async function lateDelete() {
  const bytes=readFileSync(join(OUT,'assets/sample-photo.jpg'));
  const data={clientRequestId:`${state.runId}-late-${randomUUID()}`,type:'image',title:'Dev E2E delayed upload',mime:'image/jpeg',size:bytes.length,context:state.context};
  const source=await call('aiCreateSource',data);
  await call('aiDeleteSource',{sourceId:source.sourceId});
  await upload(source,bytes); // Deliberately finish the already-issued URL after deletion.
  assert.equal((await call('aiCompleteSource',{sourceId:source.sourceId})).status,'deleted');
  await denied(()=>call('aiCreateSource',data),['SOURCE_DELETED']);
  await new Promise(r=>setTimeout(r,15000));
  const deleted=await call('aiGetSource',{sourceId:source.sourceId});assert.equal(deleted.status,'deleted');
  const path=`ai-inputs/aogaku-ai/${ownerUser().uid}/${source.sourceId}/original`;
  try {await request(`https://storage.googleapis.com/storage/v1/b/${B}/o/${encodeURIComponent(path)}`);throw Error('Late original still exists');}
  catch(e){if(e.httpStatus!==404)throw e;}
  return {sourceId:source.sourceId,status:'deleted',lateObject:'removed by real Storage trigger'};
}
async function clientRules() {
  const s=(state.sources['private-note']||state.sources.note).sourceId;
  const doc=await request(`https://firestore.googleapis.com/v1/projects/${P}/databases/aogaku-ai/documents/aiSources/${s}`);
  const actualOwner=Object.values(state.users).find(u=>u.uid===doc.fields.ownerUserId.stringValue);assert(actualOwner?.idToken,'Fresh source owner token missing');const token=actualOwner.idToken;jwtProject(token);
  const r=await fetch(`https://firestore.googleapis.com/v1/projects/${P}/databases/aogaku-ai/documents/aiSources/${s}`,{headers:{Authorization:`Bearer ${token}`}});assert.equal(r.status,403);
  const u=await fetch(`https://firestore.googleapis.com/v1/projects/${P}/databases/aogaku-ai/documents/aiCourseOfferings/${state.courseId}/memberships/${state.users.outsider.uid}`,{method:'PATCH',headers:{Authorization:`Bearer ${state.users.outsider.idToken}`,'Content-Type':'application/json'},body:JSON.stringify({fields:{status:field('verified'),active:field(true)}})});assert.equal(u.status,403);
  const storage=await fetch(`https://firebasestorage.googleapis.com/v0/b/${B}/o/${encodeURIComponent(`ai-inputs/aogaku-ai/${ownerUser().uid}/${s}/original`)}?alt=media`,{headers:{Authorization:`Firebase ${token}`}});assert.equal(storage.status,403);
  return {sourceDirectRead:403,selfMembershipWrite:403,rawDirectRead:403};
}
async function createFileFixture(label,type='image') {
  const bytes=readFileSync(join(OUT,'assets',type==='pdf'?'sample-document.pdf':'sample-photo.jpg'));
  const data={clientRequestId:`${state.runId}-${label}-${randomUUID()}`,type,title:`Dev E2E ${label}`,mime:type==='pdf'?'application/pdf':'image/jpeg',size:bytes.length,context:state.context};
  return {bytes,data,source:await call('aiCreateSource',data)};
}
async function assertDeletedObjects(sourceId) {
  const deleted=await call('aiGetSource',{sourceId});assert.equal(deleted.status,'deleted');
  const owner=ownerUser().uid;
  for(const prefix of [`ai-inputs/aogaku-ai/${owner}/${sourceId}/`,`ai-derived/aogaku-ai/${owner}/${sourceId}/`]) {
    const result=await request(`https://storage.googleapis.com/storage/v1/b/${B}/o?prefix=${encodeURIComponent(prefix)}`);
    assert.equal((result.items||[]).length,0);
  }
  const search=await call('aiRetrieveContext',{courseOfferingId:state.courseId,purpose:'lecture_summary'});
  assert(!search.items.some(x=>x.sourceId===sourceId));
}
async function deleteWhileProcessing() {
  const {bytes,source}=await createFileFixture('processing-delete','pdf');
  await upload(source,bytes);await call('aiCompleteSource',{sourceId:source.sourceId});
  let observed;
  for(let i=0;i<100;i++) {
    const s=await call('aiGetSource',{sourceId:source.sourceId});
    if(['extracting','indexing'].includes(s.status)){observed=s.status;break;}
    if(['ready','partial_ready','failed'].includes(s.status))break;
    await new Promise(r=>setTimeout(r,200));
  }
  if(!observed)throw Error('Could not observe active processing; race test is inconclusive');
  await call('aiDeleteSource',{sourceId:source.sourceId});
  await new Promise(r=>setTimeout(r,15000));
  await assertDeletedObjects(source.sourceId);
  return {sourceId:source.sourceId,observed,status:'deleted',noOriginalOrDerivedObjects:true,noRetrieval:true};
}
async function deleteDuringUpload() {
  const {bytes,source}=await createFileFixture('inflight-delete');
  let resume;
  const paused=new Promise(r=>{resume=r});
  const stream=new ReadableStream({async start(controller){controller.enqueue(bytes.subarray(0, Math.min(4096,bytes.length-1)));await paused;controller.enqueue(bytes.subarray(Math.min(4096,bytes.length-1)));controller.close();}});
  // upload() already validates signed destinations; validate this stream's destination too.
  const url=new URL(source.upload.url);
  if(url.hostname!=='storage.googleapis.com'||!decodeURIComponent(url.pathname).startsWith(`/${B}/`))throw Error('STOP: wrong streaming bucket');
  const inFlight=fetch(url,{method:'PUT',headers:source.upload.headers,body:stream,duplex:'half'});
  await new Promise(r=>setTimeout(r,750));
  await call('aiDeleteSource',{sourceId:source.sourceId});resume();
  const response=await inFlight;assert.equal(response.status,200);
  await new Promise(r=>setTimeout(r,15000));
  await assertDeletedObjects(source.sourceId);
  return {sourceId:source.sourceId,uploadStartedBeforeDelete:true,uploadFinishedAfterDelete:true,noResurrection:true};
}
async function interruptedUploadRetry() {
  const {bytes,data,source}=await createFileFixture('interrupted-retry');
  const controller=new AbortController();
  const stream=new ReadableStream({start(s){s.enqueue(bytes.subarray(0,Math.min(4096,bytes.length-1)));}});
  const url=new URL(source.upload.url);
  if(url.hostname!=='storage.googleapis.com'||!decodeURIComponent(url.pathname).startsWith(`/${B}/`))throw Error('STOP: wrong retry bucket');
  const uploadAttempt=fetch(url,{method:'PUT',headers:source.upload.headers,body:stream,duplex:'half',signal:controller.signal}).catch(e=>e);
  await new Promise(r=>setTimeout(r,750));controller.abort();
  const aborted=await uploadAttempt;assert.equal(aborted.name,'AbortError');
  await denied(()=>call('aiCompleteSource',{sourceId:source.sourceId}),['UPLOAD_INCOMPLETE']);
  const retry=await call('aiCreateSource',data);assert.equal(retry.sourceId,source.sourceId);
  await upload(retry,bytes);await call('aiCompleteSource',{sourceId:source.sourceId});
  const ready=await waitReady(source.sourceId);assert.equal(ready.status,'ready');
  return {sourceId:source.sourceId,interruption:'aborted HTTP stream',retry:'same receipt, ready'};
}
async function retryFailedSource() {
  const {bytes,source}=await createFileFixture('failed-retry');
  await upload(source,bytes);await call('aiCompleteSource',{sourceId:source.sourceId});
  await waitReady(source.sourceId);
  const url=`https://firestore.googleapis.com/v1/projects/${P}/databases/aogaku-ai/documents/aiSources/${source.sourceId}`;
  const before=await request(url);
  assert.equal(before.fields.ownerUserId.stringValue,ownerUser().uid);
  assert.equal(before.fields.status.stringValue,'ready');
  // Inject a failure only into this run's freshly created fictional source; retain original and evidence.
  await request(url+'?updateMask.fieldPaths=status&updateMask.fieldPaths=error&updateMask.fieldPaths=updatedAt','PATCH',{
    fields:{status:field('failed'),error:field({code:'DEV_E2E_INJECTED',retryable:true}),updatedAt:field(Date.now())}});
  assert.equal((await call('aiGetSource',{sourceId:source.sourceId})).status,'failed');
  await call('aiRetrySource',{sourceId:source.sourceId});
  const ready=await waitReady(source.sourceId);assert.equal(ready.status,'ready');assert.equal(ready.error,null);
  const after=await request(url);
  assert(Number(after.fields.attempts.integerValue)>Number(before.fields.attempts.integerValue));
  assert((await call('aiGetEvidence',{sourceId:source.sourceId})).items.length>0);
  const search=await retrievePages({courseOfferingId:state.courseId,purpose:'lecture_summary'});
  assert(search.items.some(x=>x.sourceId===source.sourceId));
  return {sourceId:source.sourceId,failure:'injected test-only state',retry:'real aiRetrySource → worker → ready',sameReceipt:true};
}
async function offeringIdentity() {
  const classId=await createTestClass(2026,'2026年度の架空授業');
  const localUUID=randomUUID();
  const c={...state.context,classDocId:classId,localCourseUUID:localUUID,localCourseId:localUUID,year:2025,
    syllabusUrl:`https://syllabus.aoyama.ac.jp/shousai.ashx?YR=2026&FN=dev-${classId}`,courseName:'2026年度の架空授業',teacherName:'旧年度の教員'};
  const data={clientRequestId:randomUUID(),type:'note',title:'年度識別テスト',mime:'text/plain',text:'年度識別のカント資料',context:c};
  const first=await call('aiCreateSource',data);await waitReady(first.sourceId);
  assert.equal(first.courseOfferingId,`2026:${classId}`);assert.equal(first.courseSnapshot.yearSource,'syllabus');
  const url=`https://firestore.googleapis.com/v1/projects/${P}/databases/(default)/documents/classes/${classId}`;
  assert.equal((await request(url)).fields.testRunId.stringValue,state.runId);
  await seed(`classes/${classId}`,{class_name:'2027年度の別授業',teacher_name:'新年度の教員',url:`https://example.test/?YR=2027`,testRunId:state.runId});
  const later=await call('aiCreateSource',{...data,clientRequestId:randomUUID(),context:{...c,year:2027,syllabusUrl:'https://example.test/?YR=2027',courseName:'2027年度の別授業',teacherName:'新年度の教員'}});
  await waitReady(later.sourceId);assert.equal(later.courseOfferingId,`2027:${classId}`);
  assert.deepEqual((await call('aiGetSource',{sourceId:first.sourceId})).courseSnapshot,first.courseSnapshot);
  assert.equal((await call('aiCreateSource',data)).courseOfferingId,first.courseOfferingId);
  const listed=await call('aiListSources',{context:c});assert.deepEqual(listed.items.map(x=>x.sourceId),[first.sourceId]);
  const found=await call('aiRetrieveContext',{courseOfferingId:first.courseOfferingId,query:'カント'});assert.deepEqual(found.items.map(x=>x.sourceId),[first.sourceId]);
  const local={...c,classDocId:undefined,syllabusUrl:'',year:2026,localCourseId:'#####'};
  const a=await call('aiCreateSource',{...data,clientRequestId:randomUUID(),context:local});await waitReady(a.sourceId);
  const b=await call('aiCreateSource',{...data,clientRequestId:randomUUID(),context:{...local,localCourseUUID:randomUUID()}});await waitReady(b.sourceId);
  assert.notEqual(a.courseOfferingId,b.courseOfferingId);
  const u=await call('aiCreateSource',{...data,clientRequestId:randomUUID(),context:{...local,localCourseUUID:randomUUID(),year:undefined}});await waitReady(u.sourceId);
  assert.equal(u.courseSnapshot.year,null);assert.equal(u.courseSnapshot.resolution,'unresolved');
  await denied(()=>call('aiUpdateSource',{sourceId:a.sourceId,knowledgeVisibility:'course'}),['SHARING_DISABLED']); // Private profile rejects before offering/membership checks.
  await denied(()=>call('aiLinkSourceOffering',{sourceId:a.sourceId,classDocId:classId}),['CLASS_YEAR_MISMATCH']);
  const target=await createTestClass(2026,'明示的に確定した授業');
  await denied(()=>call('aiLinkSourceOffering',{sourceId:a.sourceId,classDocId:target},'outsider'),['FORBIDDEN']);
  const linked=await call('aiLinkSourceOffering',{sourceId:a.sourceId,classDocId:target});
  assert.equal(linked.courseOfferingId,`2026:${target}`);assert.deepEqual(linked.courseSnapshot,a.courseSnapshot);
  assert.equal(linked.canonicalSnapshot.courseName,'明示的に確定した授業');assert.equal(linked.knowledgeVisibility,'private');
  assert.equal((await call('aiRetrieveContext',{courseOfferingId:linked.courseOfferingId,query:'カント'})).items.length,1);
  await seed(`classes/${target}`,{class_name:'翌年度に再利用した別授業',url:'https://example.test/?YR=2027',testRunId:state.runId});
  assert.deepEqual((await call('aiLinkSourceOffering',{sourceId:a.sourceId,classDocId:target})).canonicalSnapshot,linked.canonicalSnapshot);
  return {urlYearPriority:true,reusedClassDocId:classId,oldOffering:first.courseOfferingId,newOffering:later.courseOfferingId,
    snapshotFrozen:true,oldReceiptStable:true,uuidSeparated:true,noYearUnresolved:true,explicitLink:true,otherOwnerRejected:true};
}
async function productionRules() {
  const u=ownerUser(),other=state.users.outsider,doc=`users/${u.uid}/lectureNotes/production-preparation-${state.runId}`;
  const base=`https://firestore.googleapis.com/v1/projects/${P}/databases/(default)/documents/`;
  const headers={Authorization:`Bearer ${u.idToken}`,'Content-Type':'application/json'};
  const saved=await fetch(base+doc,{method:'PATCH',headers,body:JSON.stringify({fields:{text:field('fictional production regression')}})});assert.equal(saved.status,200);
  assert.equal((await fetch(base+doc,{headers})).status,200);
  assert.equal((await fetch(base+doc,{headers:{Authorization:`Bearer ${other.idToken}`}})).status,403);
  const name=`avatars/${u.uid}.jpg`,bytes=readFileSync(join(OUT,'assets/sample-photo.jpg'));
  const put=`https://firebasestorage.googleapis.com/v0/b/${B}/o?uploadType=media&name=${encodeURIComponent(name)}`;
  assert.equal((await fetch(put,{method:'POST',headers:{Authorization:`Firebase ${u.idToken}`,'Content-Type':'image/jpeg'},body:bytes})).status,200);
  assert.equal((await fetch(put,{method:'POST',headers:{Authorization:`Firebase ${other.idToken}`,'Content-Type':'image/jpeg'},body:bytes})).status,403);
  assert.equal((await fetch(`https://firebasestorage.googleapis.com/v0/b/${B}/o/${encodeURIComponent(name)}?alt=media`,{headers:{Authorization:`Firebase ${other.idToken}`}})).status,200);
  await clientRules();
  const indexes=await request(`https://firestore.googleapis.com/v1/projects/${P}/databases/(default)/collectionGroups/-/indexes`);
  assert.equal(indexes.indexes.length,4);assert(indexes.indexes.every(i=>i.state==='READY'));
  const named=await request(`https://firestore.googleapis.com/v1/projects/${P}/databases/aogaku-ai/collectionGroups/-/indexes`);assert.equal(named.indexes.length,1);assert.equal(named.indexes[0].state,'READY');
  const mf=await request(`https://firestore.googleapis.com/v1/projects/${P}/databases/aogaku-ai/collectionGroups/memberships/fields/userId`);assert(mf.indexConfig.indexes.some(i=>i.queryScope==='COLLECTION_GROUP'&&i.state==='READY'));
  const fields=await request(`https://firestore.googleapis.com/v1/projects/${P}/databases/(default)/collectionGroups/-/fields?filter=indexConfig.usesAncestorConfig=false`);
  assert.equal(fields.fields.filter(f=>!f.name.includes('/__default__/')).length,8);
  return {lectureNotesOwnerOnly:true,avatarsOwnerWriteAuthenticatedRead:true,aiDirectAccessDenied:true,indexesReady:4,fieldOverrides:8};
}
async function schemaRules() {
  const {AI_DOCUMENT_PATHS}=require('../functions/lib/ai/schema');
  const probe='schema-'+randomUUID(),base=`https://firestore.googleapis.com/v1/projects/${P}/databases/(default)/documents/`;
  const own=ownerUser();jwtProject(own.idToken);jwtProject(state.users.outsider.idToken);
  const report={project:P,probe,canonicalChecks:[],legacyChecks:[],boundaryChecks:[]},cleanup=new Set();
  const probeURL=path=>base.replace('/databases/(default)/','/databases/'+databaseFor(path)+'/')+path;
  const client=async(path,uidToken,method='GET',body)=>fetch(probeURL(path),{method,headers:{'Content-Type':'application/json',...(uidToken?{Authorization:'Bearer '+uidToken}:{})},...(body?{body:JSON.stringify(body)}:{})});
  const payload={fields:{schemaAuditRun:field(probe)}};
  try {
    for(const template of AI_DOCUMENT_PATHS){
      // An isolated synthetic ID, never the live accountSweep or another source.
      const path=template.replace(/\{[^}]+\}/g,probe).replace('/accountSweep','/'+probe);
      for(const [role,token] of [['anonymous',null],['owner',own.idToken],['outsider',state.users.outsider.idToken]]){
        const read=(await client(path,token)).status,write=(await client(path,token,'PATCH',payload)).status;
        if(write===200)cleanup.add(path);
        report.canonicalChecks.push({template,role,read,write});
      }
    }
    const review=`classReviews/${probe}/entries/${own.uid}`;
    const write=(await client(review,own.idToken,'PATCH',payload)).status;
    if(write===200)cleanup.add(review);
    report.legacyChecks.push({operation:'review self write',status:write},{operation:'review anonymous read',status:(await client(review,null)).status});
    const query=await fetch(base.slice(0,-1)+':runQuery',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({structuredQuery:{from:[{collectionId:'entries',allDescendants:true}],limit:1}})});
    report.legacyChecks.push({operation:'public entries collectionGroup query',status:query.status});
    // These deliberately unsupported names are attack probes, not schema.
    for(const root of ['aiSources','aiCourseOfferings','aiUsage','aiInputOwners','aiMaintenance']){
      const path=`${root}/${probe}/entries/${own.uid}`,create=(await client(path,own.idToken,'PATCH',payload)).status;
      if(create===200)cleanup.add(path);
      report.boundaryChecks.push({root,create,anonymousRead:(await client(path,null)).status});
    }
  } finally {
    for(const path of cleanup){
      const snap=await request(probeURL(path));assert.equal(snap.fields.schemaAuditRun.stringValue,probe);
      await request(probeURL(path),'DELETE'); // Only this run's marked Dev documents.
    }
    report.cleanedSyntheticDocuments=cleanup.size;
    writeFileSync(join(OUT,'schema-rules-'+probe+'.json'),JSON.stringify(report,null,2),{mode:0o600});
  }
  assert(report.canonicalChecks.every(c=>c.read===403&&c.write===403),'canonical schema direct access changed');
  assert(report.legacyChecks.every(c=>c.status===200),'legacy entries permissions changed');
  if(!report.boundaryChecks.every(c=>c.create===403&&c.anonymousRead===403)){
    const e=Error('Arbitrary AI entries paths remain client-accessible despite canonical schema naming');e.code='RULES_SCHEMA_BOUNDARY_BYPASS';throw e;
  }
  return report;
}
async function privateProfile() {
  const {sourceId}=await input('note','private-note');
  const previous=sourceId; // A freshly owned fixture, never another run/user's source.
  const own=await call('aiGetSource',{sourceId});assert.equal(own.sharingEnabled,false);
  await denied(()=>call('aiUpdateSource',{sourceId,knowledgeVisibility:'course'}),['SHARING_DISABLED']);
  await denied(()=>call('aiUpdateSource',{sourceId,rawVisibility:'course'}),['SHARING_DISABLED']);
  const before=await call('aiRetrieveContext',{courseOfferingId:state.courseId,purpose:'lecture_summary'},'member');assert.equal(before.items.length,0);
  await denied(()=>call('aiGetEvidence',{sourceId},'member'),['NOT_FOUND']);
  // Even a verified user cannot read material that was shared BEFORE the feature was disabled.
  if(previous) {
    const u=`https://firestore.googleapis.com/v1/projects/${P}/databases/aogaku-ai/documents/aiSources/${previous}`;
    const snap=await request(u);assert.equal(snap.fields.ownerUserId.stringValue,ownerUser().uid);
    await request(u+'?updateMask.fieldPaths=knowledgeVisibility','PATCH',{fields:{knowledgeVisibility:field('course')}});
    try {assert.equal((await retrievePages({courseOfferingId:state.courseId,purpose:'lecture_summary'},'member')).items.length,0);await denied(()=>call('aiGetEvidence',{sourceId:previous},'member'),['NOT_FOUND']);}
    finally {await request(u+'?updateMask.fieldPaths=knowledgeVisibility','PATCH',{fields:{knowledgeVisibility:field('private')}});}
  }
  return {sharingEnabled:false,verifiedMembershipCannotBypass:true,ownerEvidenceWorks:true};
}
async function deletedAccount(mode='direct') {
  const key=execFileSync('python3',['-c','import plistlib;print(plistlib.load(open("Config/Firebase/Development/GoogleService-Info.plist","rb"))["API_KEY"])'],{cwd:ROOT,encoding:'utf8'}).trim();
  const password=randomBytes(24).toString('base64url');
  const auth=await fetch(`https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=${encodeURIComponent(key)}`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email:`ai-delete-${randomUUID()}@example.test`,password,returnSecureToken:true})});
  if(!auth.ok)throw Error('Synthetic deletion account creation failed');
  const user=await auth.json();jwtProject(user.idToken);assert(!Object.values(state.users).some(x=>x.uid===user.localId));
  state.users.deletionProbe={uid:user.localId,idToken:user.idToken};save();
  const note=await call('aiCreateSource',{clientRequestId:randomUUID(),type:'note',title:'Deletion probe',mime:'text/plain',text:'カントの削除検証',context:state.context},'deletionProbe');
  const imageBytes=readFileSync(join(OUT,'assets/sample-photo.jpg'));
  const image=await call('aiCreateSource',{clientRequestId:randomUUID(),type:'image',title:'Deletion upload probe',mime:'image/jpeg',size:imageBytes.length,context:state.context},'deletionProbe');
  const prefix=`ai-inputs/aogaku-ai/${user.localId}/${image.sourceId}/`;
  // A future task cannot finish before deletion; prove real queue cancellation, not just an empty job ledger.
  const queue=`projects/${P}/locations/${R}/queues/aiProcessSource`;
  const taskId='delete-probe-'+randomUUID();
  const taskName=queue+'/tasks/'+taskId;
  const worker=await request(`https://cloudfunctions.googleapis.com/v2/projects/${P}/locations/${R}/functions/aiProcessSource`);
  assert(worker.serviceConfig.uri.startsWith('https://'));
  assert.equal(worker.name,`projects/${P}/locations/${R}/functions/aiProcessSource`);
  await request('https://cloudtasks.googleapis.com/v2/'+queue+'/tasks','POST',{task:{name:taskName,scheduleTime:new Date(Date.now()+600000).toISOString(),httpRequest:{httpMethod:'POST',url:worker.serviceConfig.uri,headers:{'Content-Type':'application/json'},body:Buffer.from(JSON.stringify({data:{databaseId:AI_DATABASE,sourceId:image.sourceId,taskId}})).toString('base64'),oidcToken:{serviceAccountEmail:`aogaku-ai-runtime@${P}.iam.gserviceaccount.com`}}}});
  await seed(`aiSources/${image.sourceId}/jobs/${taskId}`,{taskId,createdAt:Date.now(),testOnly:true});
  // Legacy trees and old quota must be deleted too; only this disposable Dev UID.
  await seed(`users/${user.localId}`,{idLower:'delete-'+user.localId});
  await seed(`users/${user.localId}/courseChats/course/messages/m`,{content:'fictional chat'});
  await seed(`users/${user.localId}/lectureNotes/course/nested/n`,{text:'fictional note'});
  await seed(`privateUsage/${user.localId}/counters/test`,{count:1});
  const orphan=`aiCourseOfferings/orphan-${user.localId}/memberships/${user.localId}`;await seed(orphan,{status:'verified',active:true});
  const deletionCall=async(name,data)=>{
    assert(['preDeleteCleanup','deleteAccountServerSide'].includes(name));
    const r=await fetch(`https://${R}-${P}.cloudfunctions.net/${name}`,{method:'POST',headers:{Authorization:`Bearer ${user.idToken}`,'Content-Type':'application/json'},body:JSON.stringify({data})});
    const b=await r.json();if(!r.ok||b.error)throw Error('Dev deletion '+name+': '+JSON.stringify(b.error));return b.result;
  };
  if(mode==='prepared') {
    assert.deepEqual(await deletionCall('preDeleteCleanup',{uid:user.localId}),{ok:true,aiAccountDeletionVersion:1});
    // Before Auth deletion, a still-valid ID token cannot read or accept new AI inputs.
    await denied(()=>call('aiGetSource',{sourceId:note.sourceId},'deletionProbe'),['ACCOUNT_DELETED']);
    await denied(()=>call('aiCreateSource',{clientRequestId:randomUUID(),type:'note',title:'blocked',mime:'text/plain',text:'blocked',context:state.context},'deletionProbe'),['ACCOUNT_DELETED']);
    const r=await fetch(`https://identitytoolkit.googleapis.com/v1/accounts:delete?key=${encodeURIComponent(key)}`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({idToken:user.idToken})});
    if(!r.ok)throw Error('Dev client Auth deletion failed');
  } else if(mode==='server') assert.deepEqual(await deletionCall('deleteAccountServerSide',{}),{ok:true});
  else {assert.equal(mode,'direct');await request(`https://identitytoolkit.googleapis.com/v1/projects/${P}/accounts:delete`,'POST',{localId:user.localId});}

  await denied(()=>call('aiGetSource',{sourceId:note.sourceId},'deletionProbe'),['ACCOUNT_DELETED','UNAUTHENTICATED']);
  const jobs=await request(`https://cloudscheduler.googleapis.com/v1/projects/${P}/locations/${R}/jobs`);
  const job=(jobs.jobs||[]).find(j=>j.name.endsWith('/firebase-schedule-aiReconcileInputs-'+R));
  if(!job)throw Error('AI reconcile scheduler missing');
  await request('https://cloudscheduler.googleapis.com/v1/'+job.name+':run','POST',{});
  const root=`https://firestore.googleapis.com/v1/projects/${P}/databases/aogaku-ai/documents/aiSources/`;
  for(let i=0;i<100;i++) {
    const [a,b]=await Promise.all([request(root+note.sourceId),request(root+image.sourceId)]);
    assert.equal(a.fields.ownerUserId.stringValue,user.localId);assert.equal(b.fields.ownerUserId.stringValue,user.localId);
    if(a.fields.status.stringValue==='deleted'&&b.fields.status.stringValue==='deleted')break;
    if(i===99)throw Error('Account cleanup did not finish');await new Promise(r=>setTimeout(r,1000));
  }
  await upload(image,imageBytes);
  for(let i=0;i<90;i++) {
    const objects=await request(`https://storage.googleapis.com/storage/v1/b/${B}/o?prefix=${encodeURIComponent(prefix)}`);
    if(!objects.items?.length)break;
    if(i===89)throw Error('Late upload after account deletion remains');await new Promise(r=>setTimeout(r,1000));
  }
  for(const id of [note.sourceId,image.sourceId]) {
    const snap=await request(root+id);assert.deepEqual(Object.keys(snap.fields).sort(),['ownerUserId','sourceId','status','updatedAt']);
    const jobs=await request(root+id+'/jobs');assert.equal(jobs.documents?.length||0,0);
    for(const p of [`ai-inputs/aogaku-ai/${user.localId}/${id}/`,`ai-derived/aogaku-ai/${user.localId}/${id}/`]){const objects=await request(`https://storage.googleapis.com/storage/v1/b/${B}/o?prefix=${encodeURIComponent(p)}`);assert.equal(objects.items?.length||0,0);}
  }
  const usage=await request(`https://firestore.googleapis.com/v1/projects/${P}/databases/aogaku-ai/documents/aiUsage/${user.localId}/periods`);assert.equal(usage.documents?.length||0,0);
  await assert.rejects(request('https://cloudtasks.googleapis.com/v2/'+taskName),e=>e.httpStatus===404);
  for(const path of [`privateUsage/${user.localId}/counters`,`users/${user.localId}/courseChats/course/messages`,`users/${user.localId}/lectureNotes/course/nested`]) {
    for(let i=0;i<60;i++){const docs=await request(`https://firestore.googleapis.com/v1/projects/${P}/databases/${databaseFor(path)}/documents/${path}`);if(!docs.documents?.length)break;if(i===59)throw Error('Legacy cleanup not finished: '+path);await new Promise(r=>setTimeout(r,1000));}
  }
  await assert.rejects(request(`https://firestore.googleapis.com/v1/projects/${P}/databases/(default)/documents/users/${user.localId}`),e=>e.httpStatus===404);
  const namedRoot=`https://firestore.googleapis.com/v1/projects/${P}/databases/aogaku-ai/documents/`;
  await assert.rejects(request(namedRoot+orphan),e=>e.httpStatus===404);
  assert.equal((await request(namedRoot+'aiInputOwners/'+user.localId)).fields.state.stringValue,'deleted');
  assert.equal((await request(`https://firestore.googleapis.com/v1/projects/${P}/databases/(default)/documents/accountDeletionFences/${user.localId}`)).fields.state.stringValue,'deleted');
  const lateTask=queue+'/tasks/late-worker-'+randomUUID();
  await request('https://cloudtasks.googleapis.com/v2/'+queue+'/tasks','POST',{task:{name:lateTask,scheduleTime:new Date(Date.now()+600000).toISOString(),httpRequest:{httpMethod:'POST',url:worker.serviceConfig.uri,headers:{'Content-Type':'application/json'},body:Buffer.from(JSON.stringify({data:{databaseId:AI_DATABASE,sourceId:note.sourceId,taskId:lateTask.split('/').at(-1)}})).toString('base64'),oidcToken:{serviceAccountEmail:`aogaku-ai-runtime@${P}.iam.gserviceaccount.com`}}}});
  await request('https://cloudtasks.googleapis.com/v2/'+lateTask+':run','POST',{});
  for(let i=0;i<60;i++){try{await request('https://cloudtasks.googleapis.com/v2/'+lateTask);}catch(e){if(e.httpStatus===404)break;throw e;}if(i===59)throw Error('Late worker did not complete');await new Promise(r=>setTimeout(r,1000));}
  assert.equal((await request(root+note.sourceId)).fields.status.stringValue,'deleted');assert.equal((await request(namedRoot+'aiUsage/'+user.localId+'/periods')).documents?.length||0,0);
  return {mode,orphanMembershipPurged:true,crossDatabaseFences:true,lateWorkerRejected:true,legacyTreesAndQuotaPurged:true,syntheticAccountOnly:true,authDeleted:true,staleTokenRejected:true,originalAndDerivedPurged:true,jobsPurged:true,realDelayedTaskCancelled:true,lateUploadRemoved:true};
}
async function main() {
  const action=process.argv[2]||'core';
  if(!['prepare','core','pdf','audio','audio-long','permissions','races','retry','offering','private','private-inputs','production-rules','schema-rules','account-delete','account-flows'].includes(action))throw Error('Usage: dev_e2e.cjs prepare|core|pdf|audio|audio-long|permissions|races|retry|offering|schema-rules');
  guard();await users();
  if(process.argv.includes('--fresh-owner')){assert(['races','retry','private-inputs','private'].includes(action));await freshRegressionOwner();}
  if(action==='core')for(const type of ['note','image','pdf'])await check(`${type}: create → upload → extract → evidence → list → retrieve`,()=>input(type));
  if(action==='pdf')await check('pdf: retry → text/OCR → page evidence → retrieve',()=>input('pdf'));
  if(action==='audio')await check('audio: create → upload → ASR → timestamps → retrieve',()=>input('audio'));
  if(action==='audio-long')await check('17-minute audio: 15-minute split → two ASR units → timestamps beyond 15 minutes → retrieve',()=>input('audio','audio-long'));
  if(action==='offering')await check('annual offering: URL priority/reused ID/frozen snapshot/UUID/unresolved/explicit link',offeringIdentity);
  if(action==='private-inputs')for(const type of ['note','image','pdf','audio'])await check(`private profile ${type}: fresh input → extract → owner evidence/list/retrieve`,()=>input(type,'private-'+type));
  if(action==='production-rules')await check('Dev production Rules regression: lectureNotes/avatars/client denial/indexes',productionRules);
  if(action==='schema-rules')await check('Dev schema isolation: canonical denial + legacy entries compatibility + arbitrary client path denial',schemaRules);
  if(action==='private')await check('production private profile: sharing OFF/verified membership blocked/owner evidence',privateProfile);
  if(action==='account-flows')for(const mode of ['prepared','server','direct'])await check(`formal account deletion ${mode}: admission/tasks/media/legacy quota/late upload`,()=>deletedAccount(mode));
  if(action==='account-delete')await check('deleted Auth account → cleanup → no evidence, originals, derived, jobs or late upload',deletedAccount);
  if(action==='retry')await check('failed source → aiRetrySource → same receipt → ready → evidence/retrieve',retryFailedSource);
  if(action==='races') {
    await check('interrupted upload → same receipt → retry → ready',interruptedUploadRetry);
    await check('upload in progress → delete → upload finishes → no resurrection',deleteDuringUpload);
    await check('processing in progress → delete → no originals, derived objects or retrieval',deleteWhileProcessing);
  }
  if(action==='core'||action==='permissions') {
    await check('sharing/revocation/other-course user/duplicate conflict',permissionChecks);
    await check('Firestore and Storage client permissions',clientRules);
    await check('delete → delayed upload → trigger cleanup → no resurrection',lateDelete);
  }
  if(state.results.slice(resultsStart).some(x=>x.status!=='PASS'))process.exitCode=1;
  writeFileSync(join(OUT,'e2e-results-named-latest.json'),JSON.stringify({project:P,runId:state.runId,results:state.results.slice(resultsStart)},null,2));
  writeFileSync(join(OUT,'e2e-results-named-v1.json'),JSON.stringify({project:P,runId:state.runId,results:state.results},null,2));
}
main().catch(e=>{console.error(e.code||e.message);process.exitCode=1;});
