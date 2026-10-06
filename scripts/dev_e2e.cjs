#!/usr/bin/env node
// Real Dev API integration tests with fictional assets. Credentials stay in ignored, mode-0600 files.
const assert = require('node:assert/strict');
const {readFileSync,writeFileSync,mkdirSync,existsSync,openSync,closeSync,unlinkSync,chmodSync} = require('node:fs');
const {execFileSync} = require('node:child_process');
const {join} = require('node:path');
const {randomUUID,randomBytes,createHash} = require('node:crypto');
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
const stateFile=join(OUT,'e2e-state.json');
const state=existsSync(stateFile) ? JSON.parse(readFileSync(stateFile)) : {runId:Date.now().toString(),users:{},sources:{},results:[]};
const save=()=>writeFileSync(stateFile,JSON.stringify(state,null,2),{mode:0o600});
function hash(...parts) { return createHash('sha256').update(JSON.stringify(parts)).digest('hex'); }
function field(v) {
  if(v===null)return {nullValue:null};
  if(typeof v==='string')return {stringValue:v};
  if(typeof v==='boolean')return {booleanValue:v};
  if(typeof v==='number')return Number.isInteger(v)?{integerValue:String(v)}:{doubleValue:v};
  if(Array.isArray(v))return {arrayValue:{values:v.map(field)}};
  return {mapValue:{fields:Object.fromEntries(Object.entries(v).map(([k,x])=>[k,field(x)]))}};
}
async function seed(path,data) {
  return request(`https://firestore.googleapis.com/v1/projects/${P}/databases/(default)/documents/${path}`,'PATCH',{fields:Object.fromEntries(Object.entries(data).map(([k,v])=>[k,field(v)]))});
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
  state.classId=`ai-dev-e2e-${state.runId}`;
  await seed(`classes/${state.classId}`,{title:'AI入力Dev E2E',testRunId:state.runId});
  state.context={classDocId:state.classId,localCourseId:state.classId,year:2026,semester:'fall',dayID:20732,occurrenceKey:'default'};
  state.courseId=hash(state.classId,2026,'fall');
  for(const role of ['owner','member']) await seed(`aiCourseOfferings/${state.courseId}/memberships/${state.users[role].uid}`,{status:'verified',active:true,testRunId:state.runId});
  save();
}
async function call(name,data,role='owner') {
  guard();
  if(!/^ai(?:CreateSource|CompleteSource|GetSource|ListSources|RetrySource|UpdateSource|DeleteSource|GetEvidence|RetrieveContext)$/.test(name))throw Error('STOP: unexpected callable');
  const u=state.users[role];jwtProject(u.idToken);
  const response=await fetch(`https://${R}-${P}.cloudfunctions.net/${name}`,{method:'POST',headers:{Authorization:`Bearer ${u.idToken}`,'Content-Type':'application/json'},body:JSON.stringify({data}),signal:AbortSignal.timeout(150000)});
  const body=await response.json();
  if(!response.ok || body.error) {const e=Error(body.error?.message || `HTTP ${response.status}`);e.code=body.error?.details?.code || body.error?.status;e.httpStatus=response.status;throw e;}
  return body.result;
}
async function check(label,fn) {
  const startedAt=new Date().toISOString();
  try {const details=await fn();state.results.push({label,status:'PASS',startedAt,details});console.log(`PASS ${label}`);}
  catch(e){const status=e.code==='ASR_NOT_CONFIGURED'?'BLOCKED':'FAIL';state.results.push({label,status,startedAt,error:e.code || e.message});console.log(`${status} ${label}: ${e.code || e.message}`);}
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
  const r=await fetch(u,{method:'PUT',headers:source.upload.headers,body:bytes,signal:AbortSignal.timeout(120000)});
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
  const data={clientRequestId:`${state.runId}-${variant}`,type,title:`Dev E2E ${variant}`,mime:{note:'text/plain',image:'image/jpeg',pdf:'application/pdf',audio:'audio/mp4'}[type],context:state.context,
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
  const retrieval=await call('aiRetrieveContext',{courseOfferingId:ready.courseOfferingId,purpose:'lecture_summary',maxCharacters:30000});
  assert(retrieval.items.some(x=>x.sourceId===source.sourceId));
  const question=await call('aiRetrieveContext',{courseOfferingId:ready.courseOfferingId,purpose:'question',query:'根拠資料',maxCharacters:30000});
  assert(question.items.some(x=>x.sourceId===source.sourceId));
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
  const path=`ai-inputs/${state.users.owner.uid}/${source.sourceId}/original`;
  try {await request(`https://storage.googleapis.com/storage/v1/b/${B}/o/${encodeURIComponent(path)}`);throw Error('Late original still exists');}
  catch(e){if(e.httpStatus!==404)throw e;}
  return {sourceId:source.sourceId,status:'deleted',lateObject:'removed by real Storage trigger'};
}
async function clientRules() {
  const token=state.users.owner.idToken;
  const s=state.sources.note.sourceId;
  const r=await fetch(`https://firestore.googleapis.com/v1/projects/${P}/databases/(default)/documents/aiSources/${s}`,{headers:{Authorization:`Bearer ${token}`}});assert.equal(r.status,403);
  const u=await fetch(`https://firestore.googleapis.com/v1/projects/${P}/databases/(default)/documents/aiCourseOfferings/${state.courseId}/memberships/${state.users.outsider.uid}`,{method:'PATCH',headers:{Authorization:`Bearer ${state.users.outsider.idToken}`,'Content-Type':'application/json'},body:JSON.stringify({fields:{status:field('verified'),active:field(true)}})});assert.equal(u.status,403);
  const storage=await fetch(`https://firebasestorage.googleapis.com/v0/b/${B}/o/${encodeURIComponent(`ai-inputs/${state.users.owner.uid}/${s}/original`)}?alt=media`,{headers:{Authorization:`Firebase ${token}`}});assert.equal(storage.status,403);
  return {sourceDirectRead:403,selfMembershipWrite:403,rawDirectRead:403};
}
async function createFileFixture(label,type='image') {
  const bytes=readFileSync(join(OUT,'assets',type==='pdf'?'sample-document.pdf':'sample-photo.jpg'));
  const data={clientRequestId:`${state.runId}-${label}-${randomUUID()}`,type,title:`Dev E2E ${label}`,mime:type==='pdf'?'application/pdf':'image/jpeg',size:bytes.length,context:state.context};
  return {bytes,data,source:await call('aiCreateSource',data)};
}
async function assertDeletedObjects(sourceId) {
  const deleted=await call('aiGetSource',{sourceId});assert.equal(deleted.status,'deleted');
  const owner=state.users.owner.uid;
  for(const prefix of [`ai-inputs/${owner}/${sourceId}/`,`ai-derived/${owner}/${sourceId}/`]) {
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
async function main() {
  const action=process.argv[2]||'core';
  if(!['prepare','core','pdf','audio','audio-long','permissions','races'].includes(action))throw Error('Usage: dev_e2e.cjs prepare|core|pdf|audio|audio-long|permissions|races');
  guard();await users();
  if(action==='core')for(const type of ['note','image','pdf'])await check(`${type}: create → upload → extract → evidence → list → retrieve`,()=>input(type));
  if(action==='pdf')await check('pdf: retry → text/OCR → page evidence → retrieve',()=>input('pdf'));
  if(action==='audio')await check('audio: create → upload → ASR → timestamps → retrieve',()=>input('audio'));
  if(action==='audio-long')await check('17-minute audio: 15-minute split → two ASR units → timestamps beyond 15 minutes → retrieve',()=>input('audio','audio-long'));
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
  writeFileSync(join(OUT,'e2e-results.json'),JSON.stringify({project:P,runId:state.runId,results:state.results},null,2));
}
main().catch(e=>{console.error(e.code||e.message);process.exitCode=1;});
