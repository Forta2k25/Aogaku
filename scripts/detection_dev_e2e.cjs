#!/usr/bin/env node
// Explicit Dev-only synthetic input tests. Private registry is ignored, chmod 0600.
const fs=require('node:fs'),assert=require('node:assert/strict'),crypto=require('node:crypto'),path=require('node:path');
const {execFileSync}=require('node:child_process'),c=require('./dev_cloud.cjs');
const P=c.PROJECT,B=c.BUCKET,D='aogaku-ai',out=path.join(c.ROOT,'build/detection-dev-e2e');
fs.mkdirSync(out,{recursive:true,mode:0o700});const file=path.join(out,'registry.json');
const existedAtStart=fs.existsSync(file);
const state=existedAtStart?JSON.parse(fs.readFileSync(file)):{projectId:P,run:crypto.randomUUID(),users:[],sources:[],results:[]};assert.equal(state.projectId,P);
const save=()=>fs.writeFileSync(file,JSON.stringify(state,null,2),{mode:0o600});
const field=x=>typeof x==='number'?{integerValue:String(x)}:{stringValue:x};
const docURL=(db,p)=>`https://firestore.googleapis.com/v1/projects/${P}/databases/${db}/documents/${p}`;
function jwt(token){const claims=JSON.parse(Buffer.from(token.split('.')[1],'base64url'));assert.equal(claims.aud,P);assert.equal(claims.iss,'https://securetoken.google.com/'+P);}
let key;
async function auth(action,data){const r=await fetch('https://identitytoolkit.googleapis.com/v1/accounts:'+action+'?key='+encodeURIComponent(key),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(data),signal:AbortSignal.timeout(30000)});assert(r.ok,'DEV_AUTH_HTTP_'+r.status);return r.json();}
async function call(name,data,user=state.users[0]){c.guard();assert(/^ai(CreateSource|CompleteSource|GetSource|ListSources|GetEvidence|RetrieveContext|DeleteSource|RetrySource)$/.test(name));jwt(user.idToken);const r=await fetch(`https://${c.REGION}-${P}.cloudfunctions.net/${name}`,{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+user.idToken},body:JSON.stringify({data}),signal:AbortSignal.timeout(150000)});const value=await r.json();if(!r.ok){const e=Error(value.error?.details?.code||value.error?.status||'DEV_CALL_FAILED');e.code=e.message;throw e;}return value.result;}
async function ready(id){const end=Date.now()+300000;while(Date.now()<end){const s=await call('aiGetSource',{sourceId:id});if(s.status==='ready')return s;if(s.status==='failed'||s.status==='partial_ready')throw Error('DEV_PROCESSING_'+(s.error?.code||s.status));await new Promise(r=>setTimeout(r,5000));}throw Error('DEV_READY_TIMEOUT');}
async function upload(source,bytes){assert(source.upload);const u=new URL(source.upload.url);assert(u.protocol==='https:'&&(u.hostname===B||u.hostname==='storage.googleapis.com'&&u.pathname.startsWith('/'+B+'/')));const r=await fetch(u,{method:'PUT',headers:source.upload.headers,body:bytes,signal:AbortSignal.timeout(120000)});assert.equal(r.status,200);}
async function evidence(id){const items=[];let after,version;do{const v=await call('aiGetEvidence',{sourceId:id,...(after?{after}:{})});if(version)assert.equal(v.activeVersion,version);version=v.activeVersion;items.push(...v.items);after=v.nextCursor;}while(after);return items;}
async function input(type){
 const bytes=type==='note'?null:fs.readFileSync(path.join(out,{image:'sample-photo.jpg',pdf:'sample-document.pdf',audio:'sample-audio.m4a'}[type]));
 const data={clientRequestId:state.run+'-'+type,type,title:'Synthetic detection '+type,mime:{note:'text/plain',image:'image/jpeg',pdf:'application/pdf',audio:'audio/mp4'}[type],context:state.context,...(bytes?{size:bytes.length}:{text:'検索拡張生成では根拠資料を検索し、出典を保存して回答を検証する。架空の講義メモ。'}),...(type==='audio'?{durationSeconds:120}:{})};
 assert(!state.sources.some(x=>x.type===type),'Avoid re-running a completed billable input');const s=await call('aiCreateSource',data);state.sources.push({type,sourceId:s.sourceId,data});save();assert.equal(s.courseOfferingId,'2026:'+state.classId);assert.equal(s.courseSnapshot.yearSource,'syllabus');assert.equal(s.courseSnapshot.year,2026);
 assert.equal((await call('aiCreateSource',data)).sourceId,s.sourceId);if(bytes)await upload(s,bytes);await call('aiCompleteSource',{sourceId:s.sourceId});const source=await ready(s.sourceId),items=await evidence(s.sourceId);assert(items.length);assert(items.every(x=>x.locator.endChar>x.locator.startChar));
 if(type==='image'){assert.equal(source.pipelineVersion,'image-ai-v2');assert(items.every(x=>x.method==='multimodal_ai'));assert.equal(source.recognition.model,'qwen/qwen3.8-27b');assert(source.recognition.totalTokens>0);assert(source.recognition.estimatedCostUSD>0);}
 if(type==='audio'){assert.equal(source.recognition.model,'whisper-large-v3-turbo');assert.equal(source.recognition.inputTokens,null);assert(source.recognition.billedAudioSeconds>=10);assert(items.every(x=>x.locator.endMs>x.locator.startMs));}
 if(type==='pdf'){assert(items.some(x=>x.method==='pdf_text'&&x.locator.pageNumber===1));assert(items.some(x=>x.method==='vision_ocr'&&x.locator.pageNumber===2));}
 const retrieval=await call('aiRetrieveContext',{courseOfferingId:source.courseOfferingId,purpose:'lecture_summary',maxCharacters:30000});assert(retrieval.items.some(x=>x.sourceId===s.sourceId));
 await assert.rejects(call('aiGetEvidence',{sourceId:s.sourceId},state.users[1]));
 const doc=await c.request(docURL(D,'aiSources/'+s.sourceId));assert.equal(doc.fields.ownerUserId.stringValue,state.users[0].uid);assert(doc.fields.activeRun.stringValue);assert.equal(doc.fields.knowledgeVisibility.stringValue,'private');
 await assert.rejects(c.request(docURL('(default)','aiSources/'+s.sourceId)),e=>e.httpStatus===404);
 const direct=await fetch(docURL(D,'aiSources/'+s.sourceId),{headers:{Authorization:'Bearer '+state.users[0].idToken}});assert.equal(direct.status,403);
 const raw=doc.fields.storagePath.stringValue;assert(raw.startsWith('ai-inputs/aogaku-ai/'+state.users[0].uid+'/'));
 if(type!=='audio'){const r=await fetch(`https://firebasestorage.googleapis.com/v0/b/${B}/o/${encodeURIComponent(raw)}?alt=media`,{headers:{Authorization:'Bearer '+state.users[0].idToken}});assert.equal(r.status,403);}
 const detail={type,status:'PASS',chunks:items.length,pipelineVersion:source.pipelineVersion,recognition:source.recognition||null,duplicate:true,privateAccessDenied:true,namedBoundary:true};state.results.push(detail);save();console.log('PASS '+type+' extraction/evidence/retrieval/privacy/duplicate');
}
async function main(){c.guard();assert(!fs.existsSync(file),'Fresh registry required; never recreate fixture after a failure');key=execFileSync('python3',['-c','import plistlib;print(plistlib.load(open("Config/Firebase/Development/GoogleService-Info.plist","rb"))["API_KEY"])'],{cwd:c.ROOT,encoding:'utf8'}).trim();
 for(let n=0;n<2;n++){const user=await auth('signUp',{returnSecureToken:true});jwt(user.idToken);state.users.push({uid:user.localId,idToken:user.idToken,refreshToken:user.refreshToken});save();}console.log('PASS automatic anonymous Auth (two synthetic Dev accounts; no login UI)');
 for(let n=0;n<20;n++){const id=String(crypto.randomInt(90000,100000));try{await c.request(docURL('(default)','classes')+'?documentId='+id,'POST',{fields:{class_name:field('Synthetic detection class'),teacher_name:field('架空の教員'),url:field('https://syllabus.aoyama.ac.jp/shousai.ashx?YR=2026&FN=dev-'+id),testRunId:field(state.run)}});state.classId=id;save();break;}catch(e){if(e.httpStatus!==409)throw e;}}assert(state.classId);
 const uuid=crypto.randomUUID();state.context={classDocId:state.classId,localCourseUUID:uuid,localCourseId:uuid,year:2026,semester:'fall',dayID:20734,syllabusUrl:'https://syllabus.aoyama.ac.jp/shousai.ashx?YR=2026&FN=dev-'+state.classId,courseName:'Synthetic detection class',teacherName:'架空の教員'};save();
 for(const type of ['note','image','pdf','audio'])await input(type);
 const usage=await c.request(docURL(D,'aiUsage/'+state.users[0].uid+'/periods'));assert(usage.documents.some(x=>x.fields.providerCalls));console.log('PASS named usage/provider counters');
 state.status='DEV_DETECTION_E2E_PASS';save();console.log(state.status);
}
main().catch(e=>{const safeError=/^[A-Z0-9_]+$/.test(e.message)?e.message:e.name;if(!existedAtStart){state.status='DEV_DETECTION_E2E_STOP';state.safeError=safeError;save();}console.error('STOP '+safeError+' (private registry retained unchanged on refused rerun; no mutation replay)');process.exitCode=1});
