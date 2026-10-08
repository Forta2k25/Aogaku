#!/usr/bin/env node
// Dev-only Router cohort and fresh E2E. Course PDFs require separate explicit approval.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict'),{execFileSync}=require('node:child_process');
const c=require('./dev_cloud.cjs'),P=c.PROJECT,D='aogaku-ai',R=c.REGION;
const NAMES=['aiCreateSource','aiCompleteSource','aiGetSource','aiListSources','aiGetEvidence','aiRetrySource','aiUpdateSource','aiDeleteSource','aiRetrieveContext','aiProcessSource'];
const referenceOnly=process.argv.includes('--reference-only');
const out=path.join(c.ROOT,referenceOnly?'build/visual-router-reference-dev':'build/visual-router-dev'),baseline=path.join(out,'before.json'),registry=path.join(out,'registry.json');
function assertReferenceRun(resuming,exists,args){if(resuming)assertReferenceApproval(args);assert(resuming?exists:!exists,'Never replay provider-billed fixtures');}
function assertReferenceApproval(args){assert(args.includes('--reference-only')&&args.includes('--approve-reference-provider-send'),'Specific course PDF provider consent required; synthetic approval is insufficient');}
const queueURL=`https://cloudtasks.googleapis.com/v2/projects/${P}/locations/${R}/queues/aiProcessSource`;
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
let checking='startup';
function save(file,value){fs.mkdirSync(out,{recursive:true,mode:0o700});fs.writeFileSync(file,JSON.stringify(value,null,2),{mode:0o600});}
async function read(url){c.guard();c.assertURL(url);for(let attempt=1;attempt<=5;attempt++){
 const r=await fetch(url,{headers:{Authorization:'Bearer '+await c.token()},signal:AbortSignal.timeout(60000)}).catch(e=>({status:0,ok:false,error:e}));
 if(r.ok)return r.json();if(![0,429,500,502,503,504].includes(r.status)||attempt===5){const e=Error('Dev read failed');e.httpStatus=r.status;throw e;}
 console.log(JSON.stringify({read:new URL(url).hostname,path:new URL(url).pathname,attempt,status:r.status||'timeout'}));await sleep([2000,5000,10000,20000][attempt-1]);
}}
async function snapshot(){
 const project=await read(`https://cloudresourcemanager.googleapis.com/v1/projects/${P}`);assert.equal(project.projectId,P);assert.equal(project.projectNumber,c.NUMBER);
 const urls={functions:`https://cloudfunctions.googleapis.com/v2/projects/${P}/locations/-/functions`,database:`https://firestore.googleapis.com/v1/projects/${P}/databases/${D}`,bucket:`https://storage.googleapis.com/storage/v1/b/${c.BUCKET}`,queue:queueURL,scheduler:`https://cloudscheduler.googleapis.com/v1/projects/${P}/locations/${R}/jobs`,eventarc:`https://eventarc.googleapis.com/v1/projects/${P}/locations/${R}/triggers`,rules:`https://firebaserules.googleapis.com/v1/projects/${P}/releases`,secret:`https://secretmanager.googleapis.com/v1/projects/${P}/secrets/GROQ_API_KEY/versions`,projectIAM:`https://cloudresourcemanager.googleapis.com/v1/projects/${P}:getIamPolicy`};
 const value={project:{projectId:P,projectNumber:c.NUMBER}};
 for(const[k,url]of Object.entries(urls))value[k]=k==='projectIAM'?await c.request(url,'POST',{options:{requestedPolicyVersion:3}}):await read(url);
 assert.equal(value.database.locationId,R);assert.equal(value.bucket.name,c.BUCKET);
 for(const db of ['(default)',D])for(const [key,suffix]of [['indexes','collectionGroups/-/indexes'],['fields','collectionGroups/-/fields?filter=indexConfig.usesAncestorConfig=false']])value[db+key]=await read(`https://firestore.googleapis.com/v1/projects/${P}/databases/${db}/${suffix}`);
 value.functionIAM={};value.runIAM={};
 for(const f of value.functions.functions){value.functionIAM[f.name]=await read('https://cloudfunctions.googleapis.com/v2/'+f.name+':getIamPolicy');if(f.serviceConfig.service)value.runIAM[f.serviceConfig.service]=await read('https://run.googleapis.com/v2/'+f.serviceConfig.service+':getIamPolicy');}
 return value;
}
const byName=b=>Object.fromEntries(b.functions.functions.map(f=>[f.name.split('/').pop(),f]));
function protectedCheck(b,a){
 for(const k of ['project','database','bucket','scheduler','eventarc','rules','secret','projectIAM','functionIAM','runIAM','(default)indexes','(default)fields','aogaku-aiindexes','aogaku-aifields']){
  checking=k;const actual=structuredClone(a[k]),expected=structuredClone(b[k]);
  if(k==='database')for(const v of [actual,expected]){delete v.earliestVersionTime;delete v.etag;} // moving retention watermark
  if(k==='eventarc')for(const v of [actual,expected])for(const trigger of v?.triggers||[])trigger.eventFilters?.sort((a,b)=>a.attribute.localeCompare(b.attribute)); // filter conjunction order is not configuration drift
  if(k==='scheduler')for(const v of [actual,expected])for(const job of v.jobs||[]){delete job.scheduleTime;delete job.lastAttemptTime;delete job.status;} // existing enabled Dev job telemetry, not config/state
  assert.deepEqual(actual,expected,'Protected Dev drift: '+k);
 }
 const bf=byName(b),af=byName(a);assert.deepEqual(Object.keys(af).sort(),Object.keys(bf).sort());
 for(const name of Object.keys(bf)){
  checking=name;if(!NAMES.includes(name)){assert.deepEqual(af[name],bf[name],'Unselected Function changed: '+name);continue;}
  assert.equal(af[name].state,'ACTIVE');assert.equal(af[name].buildConfig.runtime,bf[name].buildConfig.runtime);
  for(const k of ['environmentVariables','serviceAccountEmail','secretEnvironmentVariables','ingressSettings']){
   checking=name+' '+k;const actual=structuredClone(af[name].serviceConfig[k]),expected=bf[name].serviceConfig[k];
   // GCF adds this generated Functions Framework contract to older HTTP revisions.
   // No admission/env values are ignored; require the exact HTTP value when absent before.
   if(k==='environmentVariables'&&expected.FUNCTION_SIGNATURE_TYPE===undefined&&actual.FUNCTION_SIGNATURE_TYPE!==undefined){assert.equal(actual.FUNCTION_SIGNATURE_TYPE,'http');delete actual.FUNCTION_SIGNATURE_TYPE;}
   assert.deepEqual(actual,expected,name+' '+k);
  }
  assert.deepEqual(af[name].eventTrigger,bf[name].eventTrigger);assert.equal(af[name].serviceConfig.environmentVariables.AI_FIRESTORE_DATABASE_ID,D);assert.equal(af[name].serviceConfig.environmentVariables.AI_SHARING_ENABLED,'false');
 }
 for(const k of ['name','rateLimits','retryConfig']){checking='queue '+k;assert.deepEqual(a.queue[k],b.queue[k]);}
}
async function prepare(){assert(!fs.existsSync(baseline),'Fresh baseline only; existing evidence must be retained');const b=await snapshot();assert.equal(b.queue.state,'RUNNING');assert(!b.queue.stats?.tasksCount);save(baseline,b);await c.request(queueURL+':pause','POST',{});assert.equal((await read(queueURL)).state,'PAUSED');await sleep(5000);const q=await read(queueURL+'/tasks?pageSize=100');assert(!(q.tasks||[]).length,'Queue must be drained');save(path.join(c.ROOT,'build/detection-dev-before.json'),{...b,queue:await read(queueURL)});console.log('PASS fresh Dev protected preflight; queue PAUSED and drained');}
async function sourceCheck(functions){fs.mkdirSync(out,{recursive:true,mode:0o700});for(const f of functions.filter(f=>NAMES.includes(f.name.split('/').pop()))){checking='source '+f.name.split('/').pop();const d=await c.request('https://cloudfunctions.googleapis.com/v2/'+f.name+':generateDownloadUrl','POST',{}),u=new URL(d.downloadUrl);assert.equal(u.protocol,'https:');assert(u.hostname==='storage.googleapis.com'||u.hostname.endsWith('.storage.googleapis.com'));const r=await fetch(u,{signal:AbortSignal.timeout(60000)});assert(r.ok);const bytes=Buffer.from(await r.arrayBuffer());assert(bytes.length<100*1024*1024);const file=path.join(out,f.name.split('/').pop()+'-source.zip');fs.writeFileSync(file,bytes,{mode:0o600});for(const name of ['package.json','package-lock.json','lib/ai/visualRouter.js','lib/ai/visualExtraction.js','lib/ai/index.js','lib/ai/pricing.js'])assert(execFileSync('unzip',['-p',file,name]).equals(fs.readFileSync(path.join(c.ROOT,'functions',name))),'Installed source mismatch');}console.log('PASS installed Router modules and dependency manifests for all ten Functions');}
async function audit(){const b=JSON.parse(fs.readFileSync(baseline)),a=await snapshot();save(path.join(out,'observed.json'),a);protectedCheck(b,a);assert.equal(a.queue.state,'PAUSED');await sourceCheck(a.functions.functions);save(path.join(out,'after-paused.json'),a);await c.request(queueURL+':resume','POST',{});assert.equal((await read(queueURL)).state,'RUNNING');console.log('PASS Dev cohort ACTIVE/config/IAM/protected state; queue restored RUNNING');}
async function referencePreflight(){
 assert(referenceOnly,'Separate reference run required');assert(!fs.existsSync(baseline),'Fresh reference baseline only');
 const previous=JSON.parse(fs.readFileSync(path.join(c.ROOT,'build/visual-router-dev/final.json'))),a=await snapshot();
 save(path.join(out,'preflight-observed.json'),a);protectedCheck(previous,a);assert.deepEqual(a.functions,previous.functions,'Dev Functions changed since synthetic audit');assert.equal(a.queue.state,'RUNNING');
 await sourceCheck(a.functions.functions);save(baseline,a);save(path.join(out,'after-paused.json'),a);
 console.log('PASS fresh reference Dev preflight; deployed source exact; no deploy or queue/config mutation needed');
}
async function e2e(){if(referenceOnly)assertReferenceApproval(process.argv);const resuming=process.argv.includes('--resume-failed-reference');assert(!resuming||referenceOnly,'Only the approved reference source can resume');assertReferenceRun(resuming,fs.existsSync(registry),process.argv);assert.equal((await read(queueURL)).state,'RUNNING');
 const fixtures=require('./visual_router_fixtures.cjs'),dir=path.join(c.ROOT,'build/visual-router-fixtures'),m=referenceOnly?{images:[],pdfs:[]}:fixtures.generate(dir),state=resuming?JSON.parse(fs.readFileSync(registry)):{projectId:P,run:crypto.randomUUID(),sources:[],results:[]};assert.equal(state.projectId,P);const persist=()=>save(registry,state);persist();
 const key=execFileSync('python3',['-c','import plistlib;print(plistlib.load(open("Config/Firebase/Development/GoogleService-Info.plist","rb"))["API_KEY"])'],{cwd:c.ROOT,encoding:'utf8'}).trim();
 const r=resuming?null:await fetch('https://identitytoolkit.googleapis.com/v1/accounts:signUp?key='+encodeURIComponent(key),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({returnSecureToken:true})});assert(resuming||r.ok);const user=resuming?{localId:state.user.uid,idToken:state.user.idToken,refreshToken:state.user.refreshToken}:await r.json();const claims=JSON.parse(Buffer.from(user.idToken.split('.')[1],'base64url'));assert.equal(claims.aud,P);assert.equal(claims.sub,user.localId);state.user={uid:user.localId,idToken:user.idToken,refreshToken:user.refreshToken};persist();
 const old=JSON.parse(fs.readFileSync(path.join(c.ROOT,'build/detection-dev-e2e/registry.json')));assert.equal(old.projectId,P);state.context=old.context;persist();
 async function call(name,data){assert(NAMES.includes(name));c.guard();const r=await fetch(`https://${R}-${P}.cloudfunctions.net/${name}`,{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+user.idToken},body:JSON.stringify({data}),signal:AbortSignal.timeout(150000)});const v=await r.json();assert(r.ok,'DEV_CALL_'+name+'_'+r.status+'_'+v.error?.message);return v.result;}
 const caps=(await call('aiListSources',{context:state.context})).inputCapabilities;assert.equal(caps.image.pipelineVersion,'image-auto-v1');assert.equal(caps.pdf.pipelineVersion,'pdf-auto-v1');assert.equal(caps.image.fallback,false);
 const ui=[];
 const reference=path.join(c.ROOT,'build/visual-router-before/science.pdf');
 // A provided course PDF is never silently included with synthetic permission.
 if(referenceOnly){assert(fs.existsSync(reference));const data=fs.readFileSync(reference);assert.equal(data.subarray(0,5).toString(),'%PDF-');const hash=crypto.createHash('sha256').update(data).digest('hex');if(resuming)assert.equal(state.reference.sha256,hash,'Reference file changed since initial upload');state.reference={sha256:hash,bytes:data.length,providerConsent:'explicit-course-pdf-dev-only'};persist();}
 const cases=[...m.images.map(f=>({...f,type:'image'})),...m.pdfs.map(f=>({...f,type:'pdf'})),...(referenceOnly?[{file:'science.pdf',path:reference,type:'pdf',kind:'reference'}]:[])];
 for(const [i,f]of cases.entries()){
  checking='E2E '+f.file;const bytes=fs.readFileSync(f.path||path.join(dir,f.file)),request={clientRequestId:state.run+'-'+i,type:f.type,title:(f.kind==='reference'?'Provided reference ':'Synthetic Router ')+f.file,mime:f.type==='image'?'image/png':'application/pdf',size:bytes.length,context:state.context};
  const source=resuming?await call('aiGetSource',{sourceId:state.sources[0].sourceId}):await call('aiCreateSource',request);assert.equal(source.pipelineVersion,f.type+'-auto-v1');if(resuming){assert.equal(state.sources.length,1);assert.equal(source.status,'failed');assert.equal(source.error?.retryable,true);assert.equal(source.error?.code,'IMAGE_AI_RATE_LIMIT');state.explicitRetries=(state.explicitRetries||0)+1;persist();await call('aiRetrySource',{sourceId:source.sourceId});}else{state.sources.push({sourceId:source.sourceId,file:f.file});persist();}
  if(!resuming){const u=new URL(source.upload.url);assert.equal(u.hostname,'storage.googleapis.com');assert(u.pathname.startsWith('/'+c.BUCKET+'/'));const uploaded=await fetch(u,{method:'PUT',headers:source.upload.headers,body:bytes});assert.equal(uploaded.status,200);await call('aiCompleteSource',{sourceId:source.sourceId});}
  let ready;const end=Date.now()+600000;while(Date.now()<end){ready=await call('aiGetSource',{sourceId:source.sourceId});if(ready.status==='ready')break;assert(!['failed','partial_ready'].includes(ready.status),'PROCESSING_'+ready.error?.code);await sleep(5000);}assert.equal(ready.status,'ready');
  const routes=ready.recognition.routing.pages.map(p=>p.route);const expected=f.type==='pdf'?f.expected:[f.expected];
  // Real handwriting recognition may be more legible than the low-confidence oracle.
  if(!['handwritten','reference'].includes(f.kind))assert.deepEqual(routes,expected,'Unexpected real route: '+f.file);
  if(f.kind==='reference'){assert.equal(routes.length,30);assert.equal(routes[3],'multimodal_ai','Scientific Method must preserve cycle meaning');assert.equal(routes[5],'native_text','Simple embedded text must stay native');assert.equal(routes[26],'multimodal_ai','Image-driven page must stay AI');}
  const pages=ready.recognition.routing.pages;assert(pages.every(p=>p.route!=='multimodal_ai'||(p.provider==='groq'&&p.model==='qwen/qwen3.8-27b'&&p.totalTokens>0)));assert(pages.every(p=>p.route!=='native_text'||(p.totalTokens===0&&p.ocrUnits===0)));
  const items=[];let after;do{const e=await call('aiGetEvidence',{sourceId:source.sourceId,...(after?{after}:{})});assert.equal(e.activeVersion,ready.activeVersion);items.push(...e.items);after=e.nextCursor;}while(after);
  assert(items.length);for(const item of items)assert.equal(item.method,pages.find(p=>f.type==='pdf'?p.pageNumber===item.locator.pageNumber:p.imageIndex===item.locator.imageIndex).route);
  const retrieved=await call('aiRetrieveContext',{courseOfferingId:ready.courseOfferingId,purpose:'lecture_summary',maxCharacters:30000});assert(retrieved.items.some(p=>p.sourceId===source.sourceId));
  assert.equal((await call('aiCreateSource',request)).sourceId,source.sourceId,'duplicate receipt');
  const doc=await read(`https://firestore.googleapis.com/v1/projects/${P}/databases/${D}/documents/aiSources/${source.sourceId}`);assert.equal(doc.fields.pipelineVersion.stringValue,f.type+'-auto-v1');await assert.rejects(read(`https://firestore.googleapis.com/v1/projects/${P}/databases/(default)/documents/aiSources/${source.sourceId}`),e=>e.httpStatus===404);
  const result={file:f.file,counts:ready.recognition.routing.counts,ocrUnits:ready.recognition.routing.ocrUnits,inputTokens:ready.recognition.inputTokens,outputTokens:ready.recognition.outputTokens,totalTokens:ready.recognition.totalTokens,estimatedCostUSD:ready.recognition.estimatedCostUSD,processingMs:ready.processingMs,routes,status:'PASS'};state.results.push(result);save(path.join(out,'result-'+i+'.json'),{source:ready,items});ui.push({status:ready.status,pipelineVersion:ready.pipelineVersion,recognition:ready.recognition,items});persist();console.log(JSON.stringify(result));
 }
 fs.mkdirSync(path.join(c.ROOT,'AogakuTests/DevFixtures'),{recursive:true});save(path.join(c.ROOT,referenceOnly?'AogakuTests/DevFixtures/visual-router-reference-dev-results.json':'AogakuTests/DevFixtures/visual-router-dev-results.json'),ui);state.status='VISUAL_ROUTER_DEV_E2E_PASS';persist();console.log(state.status);
}
async function referenceAccess(){
 assert(referenceOnly);c.guard();const state=JSON.parse(fs.readFileSync(registry));assert.equal(state.projectId,P);assert.equal(state.status,'VISUAL_ROUTER_DEV_E2E_PASS');assert.equal(state.sources.length,1);
 const source=JSON.parse(fs.readFileSync(path.join(out,'result-0.json'))).source;
 const adminSource=await read(`https://firestore.googleapis.com/v1/projects/${P}/databases/${D}/documents/aiSources/${source.sourceId}`);
 assert.equal(adminSource.fields.ownerUserId.stringValue,state.user.uid);const storagePath=adminSource.fields.storagePath.stringValue;assert(storagePath.startsWith('ai-inputs/'+D+'/'+state.user.uid+'/'));
 const docURL=`https://firestore.googleapis.com/v1/projects/${P}/databases/${D}/documents/aiSources/${source.sourceId}`;
 const checks=[];
 for(const [role,token]of [['anonymous',null],['owner',state.user.idToken]])for(const service of ['Firestore read','Firestore write','Storage read']){
  const url=service.startsWith('Firestore')?docURL:`https://firebasestorage.googleapis.com/v0/b/${c.BUCKET}/o/${encodeURIComponent(storagePath)}?alt=media`;
  const options={headers:token?{Authorization:(service==='Storage read'?'Firebase ':'Bearer ')+token}:{},redirect:'error',signal:AbortSignal.timeout(45000)};
  if(service==='Firestore write'){options.method='PATCH';options.headers['Content-Type']='application/json';options.body=JSON.stringify({fields:{privacyProbe:{booleanValue:true}}});}
  const r=await fetch(service==='Firestore write'?url+'?updateMask.fieldPaths=privacyProbe':url,options);await r.body?.cancel();assert.equal(r.status,403,'Direct reference access '+service);checks.push({role,service,httpStatus:r.status});
 }
 state.directAccess=checks;save(registry,state);console.log('PASS reference PDF direct access denied: anonymous/owner Firestore read/write and Storage read 6/6');
}
async function cleanup(){const state=JSON.parse(fs.readFileSync(registry));assert.equal(state.projectId,P);assert.equal(state.status,'VISUAL_ROUTER_DEV_E2E_PASS');const r=await fetch('https://identitytoolkit.googleapis.com/v1/projects/'+P+'/accounts:delete',{method:'POST',headers:{Authorization:'Bearer '+await c.token(),'Content-Type':'application/json'},body:JSON.stringify({localId:state.user.uid})});assert(r.ok);state.status='CLEANUP_REQUESTED';delete state.user.idToken;delete state.user.refreshToken;save(registry,state);console.log('Disposable Dev Auth deletion requested; owner fence cleanup verification pending');}
async function final(){const b=JSON.parse(fs.readFileSync(baseline)),a=await snapshot(),deployed=JSON.parse(fs.readFileSync(path.join(out,'after-paused.json')));protectedCheck(b,a);assert.deepEqual(a.functions,deployed.functions,'Functions changed after verified deployment');assert.equal(a.queue.state,'RUNNING');const state=JSON.parse(fs.readFileSync(registry));assert.equal(state.status,'CLEANUP_REQUESTED');const end=Date.now()+120000;let owner;
 while(Date.now()<end){owner=await read(`https://firestore.googleapis.com/v1/projects/${P}/databases/${D}/documents/aiInputOwners/${state.user.uid}`);if(owner.fields.state.stringValue==='deleted')break;await sleep(3000);}assert.equal(owner.fields.state.stringValue,'deleted');
 for(const source of state.sources){const v=await read(`https://firestore.googleapis.com/v1/projects/${P}/databases/${D}/documents/aiSources/${source.sourceId}`);assert.equal(v.fields.status.stringValue,'deleted');assert(!(await read(`https://firestore.googleapis.com/v1/projects/${P}/databases/${D}/documents/aiSources/${source.sourceId}/runs`)).documents?.length);}
 for(const prefix of ['ai-inputs','ai-derived'])assert(!(await read(`https://storage.googleapis.com/storage/v1/b/${c.BUCKET}/o?prefix=${encodeURIComponent(prefix+'/'+D+'/'+state.user.uid+'/')}`)).items?.length);
 assert(!(await read(`https://firestore.googleapis.com/v1/projects/${P}/databases/${D}/documents/aiUsage/${state.user.uid}/periods`)).documents?.length);
 state.status='VISUAL_ROUTER_DEV_E2E_PASS_CLEANED';save(registry,state);save(path.join(out,'final.json'),a);console.log('PASS final protected Dev audit; disposable Auth/'+state.sources.length+' sources/runs/usage/raw/derived cleaned; tombstones retained; queue RUNNING; existing Scheduler config unchanged');
}
async function main(){const action=process.argv[2];assert(['prepare','audit','reference-preflight','e2e','reference-access','cleanup','final'].includes(action));await ({prepare,audit,'reference-preflight':referencePreflight,e2e,'reference-access':referenceAccess,cleanup,final}[action])();}
module.exports={NAMES,protectedCheck,assertReferenceApproval,assertReferenceRun};if(require.main===module)main().catch(e=>{console.error('SAFE STOP '+e.name+' '+(e.httpStatus||'')+' check='+checking+' (private evidence retained; no mutation replay)');process.exitCode=1});
