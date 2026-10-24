#!/usr/bin/env node
// Fresh Phase4 resume: exact remaining eight CREATEs; seventeen existing Functions immutable.
// No PATCH/DELETE, project IAM edits, Secret payloads, queue edits or CLI auto-public.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto'),{execFileSync}=require('node:child_process');
const cloud=require('./production_cloud.cjs'),p1=require('./provision_production_phase1.cjs'),p3a=require('./deploy_production_phase3a.cjs'),p3b=require('./deploy_production_phase3b.cjs');
const ROOT=path.resolve(__dirname,'..'),DIR=path.join(ROOT,'build/production-phase4-resume'),P='forta-aogaku',N='505828754933',R='asia-northeast1',B=P+'.firebasestorage.app',SA='aogaku-ai-runtime@'+P+'.iam.gserviceaccount.com';
const ALL_NAMES=['aiCreateSource','aiCompleteSource','aiGetSource','aiListSources','aiGetEvidence','aiRetrySource','aiUpdateSource','aiDeleteSource','aiRetrieveContext','aiProcessSource','aiReconcileInputs','aiRejectLateUpload'];
const FIRST_FOUR=ALL_NAMES.slice(0,4),NAMES=ALL_NAMES.slice(4);
const ORIGINAL=path.join(ROOT,'build/production-phase4');
const EXPECTED_SHA='34ef21c5a5f3816693809465c1e79ef2a762119db9686e3ed186130a146cf0a8';
const G='https://cloudfunctions.googleapis.com/v2/',parent=`projects/${P}/locations/${R}`,resource=n=>parent+'/functions/'+n;
const Q='projects/'+P+'/locations/'+R+'/queues/aiProcessSource',JOB='projects/'+P+'/locations/'+R+'/jobs/firebase-schedule-aiReconcileInputs-'+R;
const {hash,sourceManifest}=p3a,sha=x=>crypto.createHash('sha256').update(x).digest('hex'),load=p=>JSON.parse(fs.readFileSync(path.join(ROOT,p),'utf8'));
const secret=s=>`https://secretmanager.googleapis.com/v1/projects/${P}/secrets/${s}`;
function save(n,x){fs.mkdirSync(DIR,{recursive:true,mode:0o700});const f=path.join(DIR,n+'.json');fs.writeFileSync(f,JSON.stringify(p3b.safeMetadata(x),null,2)+'\n',{mode:0o600});fs.chmodSync(f,0o600);}
function env(){return {GCLOUD_PROJECT:P,FIREBASE_CONFIG:JSON.stringify({projectId:P,storageBucket:B}),AI_FIRESTORE_DATABASE_ID:'aogaku-ai',AI_RUNTIME_SERVICE_ACCOUNT:SA,AI_INPUT_ALLOWED_UIDS:'[]',AI_SHARING_ENABLED:'false'};}
function payload(n,source){
 assert(ALL_NAMES.includes(n));const eps=load('build/production-endpoints.json'),e=eps[n];assert.equal(e.platform,'gcfv2');assert.deepEqual(e.region,[R]);
 const lib='/Users/shum/anaconda3/lib/node_modules/firebase-tools/lib',backend=require(lib+'/deploy/functions/backend.js');
 assert.equal(require(path.join(lib,'../package.json')).version,'14.17.0');
 const endpoint={...e,id:n,project:P,region:R,runtime:'nodejs22',codebase:'aogaku-ai',serviceAccount:SA,availableMemoryMb:e.availableMemoryMb||256,minInstances:0,maxInstances:e.maxInstances||3,concurrency:1,cpu:e.cpu==='gcf_gen1'?backend.memoryToGen1Cpu(e.availableMemoryMb||256):backend.memoryToGen2Cpu(e.availableMemoryMb||256),timeoutSeconds:e.timeoutSeconds||120,environmentVariables:env(),source:{storageSource:source},labels:{'deployment-tool':'aogaku-phase4-guard'}};
 const out=require(lib+'/gcp/cloudfunctionsv2.js').functionFromEndpoint(endpoint);out.environment='GEN_2';return out;
}
function scheduler(f){assert.equal(f.name,resource('aiReconcileInputs'));assert.equal(f.serviceConfig.serviceAccountEmail,SA);assert(new URL(f.serviceConfig.uri).hostname.endsWith('.run.app'));return {name:JOB,schedule:'every 15 minutes',timeZone:'UTC',attemptDeadline:'600s',httpTarget:{uri:f.serviceConfig.uri,httpMethod:'POST',oidcToken:{serviceAccountEmail:SA,audience:f.serviceConfig.uri}}};}
function validate(url,method='GET',body,c={}){
 const u=new URL(url);assert(!u.pathname.endsWith(':access'),'STOP: Secret payload access prohibited');assert.equal(u.protocol,'https:');assert(!u.username&&!u.password);
 const names=[...ALL_NAMES,...(c.legacyNames||[])];
 if(method==='GET'){
  if(c.operations?.has(url)||c.runReads?.has(url)||c.extraReads?.has(url))return;
  if(names.some(n=>[G+resource(n),G+resource(n)+':getIamPolicy?options.requestedPolicyVersion=3','https://cloudfunctions.googleapis.com/v1/'+resource(n),'https://cloudfunctions.googleapis.com/v1/'+resource(n)+':getIamPolicy'].includes(url)))return;
  if(['GROQ_API_KEY','OPENAI_API_KEY','IMPORT_API_KEY'].some(s=>[secret(s),secret(s)+'/versions?pageSize=100',secret(s)+':getIamPolicy?options.requestedPolicyVersion=3'].includes(url)))return;
  if(Object.values(p1.policies).some(p=>p.get===url&&p.getMethod!=='POST'))return;
  if([SA,'aogaku-ai-account-deletion@'+P+'.iam.gserviceaccount.com'].some(a=>url===`https://iam.googleapis.com/v1/projects/${P}/serviceAccounts/${a}/keys?keyTypes=USER_MANAGED`))return;
 }
 if(method==='POST'&&Object.values(p1.policies).some(p=>p.get===url&&p.getMethod==='POST')){assert.deepEqual(body,{options:{requestedPolicyVersion:3}});return;}
 try{cloud.assertRead(url,method);return;}catch{}
 if(method==='POST'&&names.some(n=>url===G+resource(n)+':generateDownloadUrl')){assert.deepEqual(body,{});return;}
 if(method==='POST'&&c.legacyNames?.some(n=>url==='https://cloudfunctions.googleapis.com/v1/'+resource(n)+':generateDownloadUrl')){assert.deepEqual(body,{versionId:c.versionId});assert(/^\d+$/.test(String(c.versionId)));return;}
 assert(c.apply,'STOP: Phase4 cloud mutation not authorized');
 if(method==='POST'&&url===G+parent+'/functions:generateUploadUrl'){assert.deepEqual(body,{});return;}
 if(method==='POST'&&NAMES.some(n=>url===G+parent+'/functions?functionId='+n)){const n=new URL(url).searchParams.get('functionId');assert(!c.created.includes(n));assert(c.sources.has(hash(body.buildConfig.source.storageSource)));assert.deepEqual(body,payload(n,body.buildConfig.source.storageSource));return;}
 if(method==='POST'&&c.iamWrite?.url===url){
  const fn=c.iamWrite.function;assert(c.created.includes(fn));
  const metadata=url===G+resource('aiProcessSource')+':setIamPolicy';
  if(metadata)assert.equal(fn,'aiProcessSource');
  else {assert(['aiProcessSource','aiReconcileInputs','aiRejectLateUpload'].includes(fn));assert.equal(url,'https://run.googleapis.com/v1/'+parent+'/services/'+fn.toLowerCase()+':setIamPolicy');}
  assert.deepEqual(c.iamWrite.allowed,[{member:'serviceAccount:'+SA,roles:[metadata?'projects/'+P+'/roles/aogakuAIFunctionMetadata':'roles/run.invoker']}]);
  assert(body.policy.etag);assert.deepEqual(body,{policy:p1.merge(c.iamWrite.before,c.iamWrite.allowed)});assert(!body.policy.bindings.some(b=>b.members.some(m=>['allUsers','allAuthenticatedUsers'].includes(m))));return;
 }
 if(method==='POST'&&url===`https://cloudscheduler.googleapis.com/v1/projects/${P}/locations/${R}/jobs`){assert(c.created.includes('aiReconcileInputs'));assert.deepEqual(body,scheduler(c.schedulerFunction));return;}
 if(method==='POST'&&url===`https://cloudscheduler.googleapis.com/v1/${JOB}:pause`){assert(c.created.includes('aiReconcileInputs'));assert.deepEqual(body,{});return;}
 throw Error('STOP: outside Phase4 exact resource allowlist');
}
function dependencies(){return Object.fromEntries(['scripts/deploy_production_phase4.cjs','scripts/production_cloud.cjs','scripts/provision_production_phase1.cjs','scripts/deploy_production_phase3a.cjs','scripts/deploy_production_phase3b.cjs','scripts/firebase_production.py','build/production-endpoints.json'].map(p=>[p,sha(fs.readFileSync(path.join(ROOT,p)))]));}
function artifact(){const a=load('build/production-phase4-resume/artifact.json');assert.deepEqual(a.names,NAMES);assert.deepEqual(a.protectedFunctions,FIRST_FOUR);assert.equal(a.sourceSha256,EXPECTED_SHA);assert.deepEqual(a.dependencies,dependencies());assert.equal(a.profile,'closed');assert.equal(a.publicInvoker,false);assert.equal(a.sourceSha256,hash(sourceManifest(path.join(DIR,'candidate.zip'))));assert.equal(a.zipSha256,sha(fs.readFileSync(path.join(DIR,'candidate.zip'))));assert.equal(a.wrapperSha256,sha(fs.readFileSync(__filename)));assert.deepEqual(a.environment,env());return a;}
function protectedSame(b,a,created){
 for(const k of Object.keys(b.metadata).filter(k=>!['readAt','functions'].includes(k)))assert.deepEqual(p3b.metadataCore(k,a.metadata[k]),p3b.metadataCore(k,b.metadata[k]),'STOP: protected metadata drift '+k);
 for(const k of ['iam','keys','secrets'])assert.deepEqual(a[k],b[k],'STOP: protected '+k+' drift');
 assert.equal(a.functions.length,b.functions.length+created.length);assert.deepEqual(a.functions.filter(f=>!b.functions.some(x=>x.name===f.name)).map(f=>f.name.split('/').pop()).sort(),[...created].sort());
 for(const f of b.functions)assert.deepEqual(a.functions.find(x=>x.name===f.name),f,'STOP: legacy Function changed '+f.name);
 for(const k of ['apis','serviceAccounts','queue'])assert.deepEqual(a.resources[k],b.resources[k],'STOP: Phase1 '+k+' changed');
 for(const k of ['scheduler','eventarc']){
  const key=k==='scheduler'?'jobs':'triggers',old=b.resources[k].data[key]||[],current=a.resources[k].data[key]||[];
  for(const x of old)assert.deepEqual(current.find(y=>y.name===x.name),x,'STOP: existing '+k+' changed');
  const additions=current.filter(y=>!old.some(x=>x.name===y.name));
  if(k==='scheduler'){assert.equal(additions.length,created.includes('aiReconcileInputs')?1:0);if(additions.length){assert.equal(additions[0].name,JOB);assert.equal(additions[0].state,'PAUSED');}}
  else{assert.equal(additions.length,created.includes('aiRejectLateUpload')?1:0);if(additions.length){const f=a.functions.find(f=>f.name===resource('aiRejectLateUpload'));assert.equal(additions[0].name,f.eventTrigger.trigger);}}
 }
}
async function main(action,name){
 assert(['prepare','capture','preflight','create','postcheck','audit'].includes(action));if(action==='create')assert(NAMES.includes(name));else assert(!name);
 fs.mkdirSync(DIR,{recursive:true,mode:0o700});fs.chmodSync(DIR,0o700);
 execFileSync('python3',['scripts/firebase_production.py','check','--project',P],{cwd:ROOT,stdio:'pipe'});
 if(action==='prepare'){
  assert(!fs.existsSync(path.join(DIR,'execution.json')),'STOP: preserve in-progress artifact');
  execFileSync('python3',['scripts/firebase_production.py','package','--project',P,'--profile','closed'],{cwd:ROOT,stdio:'inherit'});
  const src=path.join(ROOT,'build/production-functions');assert(fs.readFileSync(path.join(src,'.env.forta-aogaku'),'utf8').includes('AI_INPUT_ALLOWED_UIDS=[]\n'));
  const zip=path.join(DIR,'candidate.zip');
  execFileSync('python3',['-c',"import pathlib,zipfile,sys; r=pathlib.Path(sys.argv[1]); z=zipfile.ZipFile(sys.argv[2],'w',zipfile.ZIP_DEFLATED); files=sorted(list((r/'lib').rglob('*.js'))+[r/'package.json',r/'package-lock.json']); [z.write(p,p.relative_to(r)) for p in files]; z.close()",src,zip]);fs.chmodSync(zip,0o600);
  const files=sourceManifest(zip);assert.equal(hash(files),EXPECTED_SHA,'STOP: candidate differs from immutable successful four');assert(Object.keys(files).every(p=>p.startsWith('lib/ai/')||['lib/production.js','package.json','package-lock.json'].includes(p)));assert(!Object.keys(files).some(f=>/fixture|\.env|plist|credential|test/i.test(f)));
  save('artifact',{phase:'4-resume',names:NAMES,protectedFunctions:FIRST_FOUR,dependencies:dependencies(),profile:'closed',environment:env(),publicInvoker:false,queueState:'PAUSED',schedulerState:'PAUSED',sourceSha256:hash(files),zipSha256:sha(fs.readFileSync(zip)),wrapperSha256:sha(fs.readFileSync(__filename)),files,payloads:Object.fromEntries(NAMES.map(n=>[n,payload(n,{bucket:'APPROVED_STAGING',object:'FRESH_ISSUED_SOURCE'})]))});
  console.log('Phase4 exact closed artifact prepared; no cloud mutation');return;
 }
 const a=action==='capture'?null:artifact(),jp=path.join(DIR,'execution.json'),j=fs.existsSync(jp)?JSON.parse(fs.readFileSync(jp)):{phase:'4-resume',artifactSha256:a?.sourceSha256,created:[],verified:{},attempts:[],status:'STARTED',partialSuccess:false};
 if(action!=='audit'){assert(j.status!=='STOPPED'&&!j.partialSuccess,'STOP: previous failure requires user review');if(a)assert.equal(j.artifactSha256,a.sourceSha256);}
 let token,tokenAt=0;const operations=new Set(),sources=new Set(),runReads=new Set(),extraReads=new Set(),legacyNames=load('Config/Production/baseline.inventory.json').functions.map(f=>f.name.split('/').pop());assert.equal(legacyNames.length,13);
 const persist=()=>save('execution',j);
 async function bearer(){if(!token||Date.now()-tokenAt>2700000){const lib='/Users/shum/anaconda3/lib/node_modules/firebase-tools/lib',account=require(lib+'/auth.js').getGlobalDefaultAccount(),api=require(lib+'/api.js');const r=await fetch('https://oauth2.googleapis.com/token',{method:'POST',body:new URLSearchParams({client_id:api.clientId(),client_secret:api.clientSecret(),refresh_token:account.tokens.refresh_token,grant_type:'refresh_token'}),signal:AbortSignal.timeout(45000)});const d=await r.json();assert(r.ok&&d.access_token,'OAuth refresh failed');token=d.access_token;tokenAt=Date.now();}return token;}
 async function request(url,method='GET',body,c={}){
  validate(url,method,body,{apply:action==='create',created:j.created,operations,sources,runReads,extraReads,legacyNames,...c});
  const mutation=method!=='GET'&&!url.includes(':getIamPolicy')&&!url.endsWith(':generateDownloadUrl');
  const attempt=mutation?{function:name,method,resource:url,bodySha256:hash(body),at:new Date().toISOString(),status:'UNKNOWN'}:null;if(attempt){j.attempts.push(attempt);persist();}
  const r=await fetch(url,{method,redirect:'error',headers:{Authorization:'Bearer '+await bearer(),'Content-Type':'application/json'},...(body===undefined?{}:{body:JSON.stringify(body)}),signal:AbortSignal.timeout(45000)});const d=await r.json().catch(()=>({}));if(!r.ok){if(attempt){attempt.status='HTTP_ERROR';attempt.httpStatus=r.status;persist();}const err=Error('HTTP '+r.status+' '+method+' '+new URL(url).hostname+new URL(url).pathname+' '+(d.error?.status||''));err.httpStatus=r.status;throw err;}assert(!d.nextPageToken,'STOP: pagination');if(attempt){attempt.status='CONFIRMED';persist();}return d;
 }
 async function snapshot(){
  const metadata=await cloud.inspect();execFileSync('python3',['-c','import sys;sys.path.insert(0,"scripts");import firebase_production as p;s=p.load("build/production-live.json");p.live_check(s);p.require_named_ready(s,True,True)'],{cwd:ROOT,stdio:'pipe'});
  await cloud.resourcesMetadata();const resources=load('build/production-resources-live.json').records;assert(Object.values(resources).every(r=>r.httpStatus===200));assert.equal(resources.queue.data.state,'PAUSED');
  const functions=(await request(cloud.urls.functions)).functions||[],iam={},keys={},secrets={};
  for(const [k,p]of Object.entries(p1.policies))iam[k]=await request(p.get,p.getMethod||'GET',p.getMethod==='POST'?{options:{requestedPolicyVersion:3}}:undefined);
  for(const s of ['GROQ_API_KEY','OPENAI_API_KEY','IMPORT_API_KEY']){secrets[s]={metadata:await request(secret(s)),versions:await request(secret(s)+'/versions?pageSize=100')};iam[s]=await request(secret(s)+':getIamPolicy?options.requestedPolicyVersion=3');}
  for(const f of functions.filter(f=>legacyNames.includes(f.name.split('/').pop())||FIRST_FOUR.includes(f.name.split('/').pop()))){const n=f.name.split('/').pop(),url=f.environment==='GEN_1'?'https://cloudfunctions.googleapis.com/v1/'+f.name+':getIamPolicy':'https://run.googleapis.com/v1/'+f.serviceConfig.service+':getIamPolicy';runReads.add(url);iam[n]=await request(url);}
  for(const sa of [SA,'aogaku-ai-account-deletion@'+P+'.iam.gserviceaccount.com']){keys[sa]=await request(`https://iam.googleapis.com/v1/projects/${P}/serviceAccounts/${sa}/keys?keyTypes=USER_MANAGED`);assert(!(keys[sa].keys||[]).length);}
  return p3b.safeMetadata({metadata,resources,functions,iam,keys,secrets});
 }
 async function installed(n,f,label){
  const v1=f.environment==='GEN_1',base=v1?'https://cloudfunctions.googleapis.com/v1/':G,meta=v1?await request(base+resource(n)):f;
  const d=await request(base+resource(n)+':generateDownloadUrl','POST',v1?{versionId:meta.versionId}:{},{versionId:meta.versionId});const u=new URL(d.downloadUrl);assert.equal(u.protocol,'https:');assert(u.hostname==='storage.googleapis.com'||u.hostname.endsWith('.storage.googleapis.com'));assert(!u.username&&!u.password&&!u.port);
  const r=await fetch(u,{redirect:'error',signal:AbortSignal.timeout(45000)});assert(r.ok,'SourceCodeGet HTTP '+r.status);const bytes=Buffer.from(await r.arrayBuffer());assert(bytes.length<=100*1024*1024);const file=path.join(DIR,n+'-'+label+'.zip');fs.writeFileSync(file,bytes,{mode:0o600});fs.chmodSync(file,0o600);const files=sourceManifest(file);assert.equal((await request(G+resource(n))).updateTime,f.updateTime,'STOP: Function changed during source check');return {sourceSha256:hash(files),files,updateTime:f.updateTime};
 }
 async function privateIAM(f){const runUrl='https://run.googleapis.com/v1/'+f.serviceConfig.service;runReads.add(runUrl);const run=await request(runUrl);assert(run.metadata?.annotations?.['run.googleapis.com/invoker-iam-disabled']!=='true','STOP: Run IAM checking disabled');const url='https://run.googleapis.com/v1/'+f.serviceConfig.service+':getIamPolicy';runReads.add(url);const p=await request(url);assert(!(p.bindings||[]).some(b=>b.members.some(m=>['allUsers','allAuthenticatedUsers'].includes(m))),'STOP: public invoker');return p;}
 function assertRuntime(n,f){assert.equal(f.name,resource(n));assert.equal(f.state,'ACTIVE');assert.equal(f.environment,'GEN_2');assert.equal(f.buildConfig.runtime,'nodejs22');assert.equal(f.buildConfig.entryPoint,n);assert.equal(f.labels['firebase-functions-codebase'],'aogaku-ai');assert.equal(f.serviceConfig.serviceAccountEmail,SA);const v=f.serviceConfig.environmentVariables;for(const [k,value]of Object.entries(env()))assert.equal(v[k],value,'STOP: runtime env '+k);assert(!(f.serviceConfig.secretEnvironmentVariables||[]).length);const expected=payload(n,{bucket:'CHECK_ONLY',object:'CHECK_ONLY'}).serviceConfig;for(const k of ['availableMemory','availableCpu','timeoutSeconds','maxInstanceCount','maxInstanceRequestConcurrency'])assert.equal(f.serviceConfig[k],expected[k],'STOP: runtime contract '+k);assert.equal(f.serviceConfig.minInstanceCount||0,expected.minInstanceCount||0);assert(/^projects\/forta-aogaku\/locations\/asia-northeast1\/services\/[a-z0-9-]+$/.test(f.serviceConfig.service));if(n==='aiRejectLateUpload'){assert.equal(f.eventTrigger.triggerRegion,'us-central1');assert.equal(f.eventTrigger.eventType,'google.cloud.storage.object.v1.finalized');assert.deepEqual(f.eventTrigger.eventFilters,[{attribute:'bucket',value:B}]);assert.equal(f.eventTrigger.serviceAccountEmail,SA);}else assert(!f.eventTrigger);}
 async function binding(urlGet,urlSet,fn,allowed){runReads.add(urlGet);const before=await request(urlGet);const desired=p1.merge(before,allowed);if(hash(before)!==hash(desired))await request(urlSet,'POST',{policy:desired},{iamWrite:{url:urlSet,before,allowed,function:fn}});const after=await request(urlGet);p1.preserved(before,after);p1.noUnplannedAdditions(before,after,allowed);save(fn+'-resource-iam',{resource:urlGet,before,after,allowed});}
 async function wait(d){assert(new RegExp('^projects/'+P+'/locations/'+R+'/operations/[A-Za-z0-9_-]+$').test(d.name));if(d.metadata?.target)assert.equal(d.metadata.target,resource(name));const url=G+d.name;operations.add(url);for(let i=0;i<300;i++){const x=await request(url);save(name+'-operation',x);if(x.done){assert(!x.error,'STOP: Function operation failed '+(x.error?.code||'')+' '+(x.error?.message||'').replace(/https:\/\/\S+/g,'[URL]'));return;}if(i%6===0)console.log(name+': private closed Function build in progress');await new Promise(r=>setTimeout(r,5000));}throw Error('STOP: Function operation timeout');}
 try{
  const before=await snapshot();save(action+(name?'-'+name:'')+'-before',before);
  if(action==='capture'){assert(!fs.existsSync(path.join(DIR,'captured.json')));assert.equal(before.functions.length,17);assert(!before.functions.some(f=>NAMES.includes(f.name.split('/').pop())));for(const n of FIRST_FOUR){const f=await request(G+resource(n));assertRuntime(n,f);await privateIAM(f);}save('captured',before);console.log('Fresh production capture PASS; cloud mutations=0');return;}
  if(action==='preflight'){
   assert(!fs.existsSync(path.join(DIR,'baseline.json')));protectedSame(load('build/production-phase4-resume/captured.json'),before,[]);
   assert.equal(load('build/production-phase3b/e2e.json').status,'PASS');assert.equal(load('build/production-phase3b/previous-fixture-cleanup.json').status,'PASS');
   const sources={};for(const f of before.functions){const n=f.name.split('/').pop();sources[n]=await installed(n,f,'baseline');}
   const originalArtifact=JSON.parse(fs.readFileSync(path.join(ORIGINAL,'artifact.json'))),originalSources=JSON.parse(fs.readFileSync(path.join(ORIGINAL,'legacy-sources.json')));assert.equal(originalArtifact.sourceSha256,EXPECTED_SHA);
   for(const n of FIRST_FOUR)assert.deepEqual(sources[n].files,originalArtifact.files,'STOP: successful four artifact drift '+n);
   for(const n of legacyNames)assert.deepEqual(sources[n].files,originalSources[n].files,'STOP: existing thirteen source drift '+n);
   for(const n of ['preDeleteCleanup','deleteAccountServerSide','onAuthUserDelete'])assert.equal(sources[n].sourceSha256,'d44148dbddb59e660524af5451ad8ed6d6123d39e5e28e04df3a1f6feea71a5f');
   for(const n of ['askCourseAI','transcribeLectureAudio','generateReactionPaper'])assert.equal(sources[n].sourceSha256,'ca3d2a13858f7c498b5edf4f385386e3273dfc1dbdbca168f97443cb0211e8b8');
   const log=fs.readFileSync(path.join(DIR,'emulator.log'),'utf8');assert(log.includes('pass 50')&&log.includes('fail 0')&&log.includes('skipped 0'),'STOP: required Emulator regression');
   const closed=fs.readFileSync(path.join(DIR,'closed-regression.log'),'utf8');assert(closed.includes('fail 0')&&closed.includes('skipped 0'),'STOP: closed exact artifact regression');
   save('baseline',before);save('legacy-sources',sources);save('approval',{phase:'4',profile:'closed',authority:'Current user explicitly reapproved remaining eight only, one by one with fresh current seventeen metadata/source/IAM baseline. First four must not be recreated or updated. All private, empty UID, sharing OFF, paused queue and Scheduler. Minimum actual-resource IAM only; no Phase5/public ingress authorization.',artifactSha256:a.sourceSha256,zipSha256:a.zipSha256,wrapperSha256:a.wrapperSha256,baselineSha256:hash(before),approvedAt:new Date().toISOString(),targets:NAMES,protectedFunctions:FIRST_FOUR,legacySources:sources,phase5Authorized:false});j.status='PREFLIGHT_PASS';persist();console.log('Fresh closed-profile approval/preflight PASS; cloud mutations=0');return;
  }
  const baseline=load('build/production-phase4-resume/baseline.json'),approval=load('build/production-phase4-resume/approval.json');assert.equal(approval.artifactSha256,a.sourceSha256);assert.equal(approval.wrapperSha256,sha(fs.readFileSync(__filename)));assert.equal(approval.baselineSha256,hash(baseline));protectedSame(baseline,before,j.created);
  if(action==='create'){
   assert.equal(NAMES[j.created.length],name,'STOP: individual sequential allowlist order');assert(!before.functions.some(f=>f.name===resource(name)),'STOP: no replacing an existing Function');
   const upload=await request(G+parent+'/functions:generateUploadUrl','POST',{}),u=new URL(upload.uploadUrl);assert.equal(u.hostname,'storage.googleapis.com');assert(!u.username&&!u.password&&!u.port);assert(u.pathname.split('/')[1]===upload.storageSource.bucket&&upload.storageSource.bucket.includes(N)&&upload.storageSource.bucket.includes(R));assert.equal(decodeURIComponent(u.pathname.slice(upload.storageSource.bucket.length+2)),upload.storageSource.object);
   const put=await fetch(u,{method:'PUT',redirect:'error',headers:{'Content-Type':'application/zip'},body:fs.readFileSync(path.join(DIR,'candidate.zip')),signal:AbortSignal.timeout(60000)});if(!put.ok){const text=await put.text();save('staging-error',{httpStatus:put.status,category:/<Code>([^<]+)<\/Code>/.exec(text)?.[1]||'UNKNOWN',generation:'GEN_2',headers:['Content-Type: application/zip'],credentialHeader:false});throw Error('STOP: staging PUT HTTP '+put.status);}save(name+'-staging',{status:'PASS',generation:'GEN_2',headers:['Content-Type: application/zip'],credentialHeader:false});sources.add(hash(upload.storageSource));
   await wait(await request(G+parent+'/functions?functionId='+name,'POST',payload(name,upload.storageSource)));
   j.created.push(name);persist();const f=await request(G+resource(name));assertRuntime(name,f);await privateIAM(f);
   const actual=await installed(name,f,'installed');assert.deepEqual(actual.files,a.files,'STOP: installed source mismatch');j.verified[name]={...actual,runService:f.serviceConfig.service,uri:f.serviceConfig.uri,environment:'GEN_2',runtime:'nodejs22',region:R,trigger:name==='aiRejectLateUpload'?'Storage/Eventarc':name==='aiProcessSource'?'TaskQueue HTTPS':name==='aiReconcileInputs'?'Scheduler HTTPS':'Callable HTTPS',serviceAccount:SA,closed:true};persist();
   if(['aiProcessSource','aiReconcileInputs','aiRejectLateUpload'].includes(name)){
    const base='https://run.googleapis.com/v1/'+f.serviceConfig.service;await binding(base+':getIamPolicy',base+':setIamPolicy',name,[{member:'serviceAccount:'+SA,roles:['roles/run.invoker']}]);
    if(name==='aiProcessSource')await binding(G+resource(name)+':getIamPolicy?options.requestedPolicyVersion=3',G+resource(name)+':setIamPolicy',name,[{member:'serviceAccount:'+SA,roles:['projects/'+P+'/roles/aogakuAIFunctionMetadata']}]);
   }
   if(name==='aiReconcileInputs'){
    // Creation can briefly enable the job; the exact installed closed handler is a
    // no-op before any DB access. Pause immediately, then prove PAUSED by GET.
    await request(`https://cloudscheduler.googleapis.com/v1/projects/${P}/locations/${R}/jobs`,'POST',scheduler(f),{schedulerFunction:f});
    await request(`https://cloudscheduler.googleapis.com/v1/${JOB}:pause`,'POST',{});const url=`https://cloudscheduler.googleapis.com/v1/${JOB}`;extraReads.add(url);assert.equal((await request(url)).state,'PAUSED');
   }
   const after=await snapshot();save(name+'-after',after);protectedSame(baseline,after,j.created);await privateIAM(await request(G+resource(name)));j.status='INDIVIDUAL_PASS';persist();console.log(name+': created/source verified/private IAM/protected state PASS; queue PAUSED');return;
  }
  if(action==='audit'){save('stop-audit',{status:'PROTECTED_STATE_UNCHANGED',created:j.created,queueState:before.resources.queue.data.state,partialSuccess:j.partialSuccess});console.log('Read-only audit finished; no resume or repair');return;}
  assert.deepEqual(j.created,NAMES);const actual={};for(const f of before.functions){const n=f.name.split('/').pop();actual[n]=await installed(n,f,'final');if(ALL_NAMES.includes(n)){assertRuntime(n,await request(G+resource(n)));assert.deepEqual(actual[n].files,a.files);await privateIAM(await request(G+resource(n)));}else assert.deepEqual(actual[n],load('build/production-phase4-resume/legacy-sources.json')[n],'STOP: legacy full source changed');}
  const f=await request(G+resource('aiRejectLateUpload')),url='https://eventarc.googleapis.com/v1/'+f.eventTrigger.trigger;extraReads.add(url);const t=await request(url);assert(t.name.includes('/locations/us-central1/'));assert.equal(t.serviceAccount,SA);assert.equal(t.destination.cloudRun.region,R);assert.equal(t.destination.cloudRun.service,load('build/production-phase4-resume/execution.json').verified.aiRejectLateUpload.runService.split('/').pop());assert(t.eventFilters.some(x=>x.attribute==='bucket'&&x.value===B));assert(t.eventFilters.some(x=>x.attribute==='type'&&x.value==='google.cloud.storage.object.v1.finalized'));assert(!(t.conditions&&Object.values(t.conditions).some(x=>x.code&&x.code!=='OK')));
  save('eventarc',t);save('postcheck',{status:'CONTROL_PLANE_PASS',created:NAMES,allAINames:ALL_NAMES,protectedFunctions:FIRST_FOUR,legacySources:actual,sourceSha256:a.sourceSha256,protectedResourcesUnchanged:true,publicInvoker:false,allowedUIDs:[],sharingEnabled:false,queueState:'PAUSED',schedulerState:'PAUSED',phase5Authorized:false});j.status='CONTROL_PLANE_PASS';persist();console.log('All twelve installed/private/closed/source + all thirteen legacy full sources + protected state PASS');
 }catch(e){{j.status='STOPPED';j.partialSuccess=j.attempts.length>0||j.created.length>0;j.error=e.message;persist();}console.error(JSON.stringify({status:'STOPPED',created:j.created,error:e.message,partialSuccess:j.partialSuccess}));throw e;}
}
module.exports={validate,payload,scheduler,protectedSame,env,NAMES,ALL_NAMES,FIRST_FOUR,JOB,main};
if(require.main===module)main(process.argv[2],process.argv[3]).catch(()=>process.exitCode=1);
