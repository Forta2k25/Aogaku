#!/usr/bin/env node
// Three existing deletion Functions only, REST PATCH, no IAM/API/Secret mutation.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),{execFileSync}=require('node:child_process');
const p3a=require('./deploy_production_phase3a.cjs'),cloud=require('./production_cloud.cjs'),phase1=require('./provision_production_phase1.cjs');
const ROOT=path.resolve(__dirname,'..'),DIR=path.join(ROOT,'build/production-phase3b');
const P='forta-aogaku',N='505828754933',B=P+'.firebasestorage.app',R='asia-northeast1';
const NAMES=['preDeleteCleanup','deleteAccountServerSide','onAuthUserDelete'];
const parent=`projects/${P}/locations/${R}`,resource=n=>parent+'/functions/'+n,G1='https://cloudfunctions.googleapis.com/v1/',G2='https://cloudfunctions.googleapis.com/v2/';
const {hash,sourceManifest}=p3a;
// Firestore documents this output-only field as continuously updated:
// https://docs.cloud.google.com/firestore/docs/reference/rest/v1/projects.databases
// Retain raw values in evidence; compare every persistent DB setting/updateTime.
function metadataCore(k,value){
 if(k!=='aiDatabase')return value;
 assert(Number.isFinite(Date.parse(value.earliestVersionTime)),'STOP: invalid retention timestamp');
 return Object.fromEntries(Object.entries(value).filter(([key])=>!['etag','earliestVersionTime'].includes(key)));
}
const load=p=>JSON.parse(fs.readFileSync(path.join(ROOT,p),'utf8'));
function safeMetadata(x){
 if(Array.isArray(x))return x.map(safeMetadata);
 if(x&&typeof x==='object'){
  const out={};for(const [k,v]of Object.entries(x)){
   if(k==='sourceUploadUrl'){const u=new URL(v);out.sourceUploadBucket=u.pathname.split('/')[1];}
   else if(['environmentVariables','buildEnvironmentVariables'].includes(k))out[k]=v?.redacted===true&&typeof v.sha256==='string'?v:{redacted:true,keys:Object.keys(v).sort(),sha256:hash(v)};
   else if(/^(?:access_token|refresh_token|idToken|credential|password)$/i.test(k))out[k]='[REDACTED]';
   else out[k]=safeMetadata(v);
  }return out;
 }
 if(typeof x==='string'&&/^https:\/\//.test(x)&&/[?&](?:X-Goog-|GoogleAccessId=|Signature=)/i.test(x))return '[REDACTED_SIGNED_URL]';
 return x;
}
const save=(n,x)=>{const p=path.join(DIR,n+'.json');fs.writeFileSync(p,JSON.stringify(safeMetadata(x),null,2)+'\n',{mode:0o600});fs.chmodSync(p,0o600);};
const secret=s=>`https://secretmanager.googleapis.com/v1/projects/${P}/secrets/${s}`;
const mask=n=>n==='onAuthUserDelete'?'sourceUploadUrl,runtime,timeout':'buildConfig.source,buildConfig.runtime';
const base=n=>n==='onAuthUserDelete'?G1:G2;
function uploadHeaders(n){
 assert(NAMES.includes(n));
 // The v1 upload API requires the range header. v2 documents content-type only.
 // Never add Bearer credentials to either signed PUT.
 return n==='onAuthUserDelete'?{'Content-Type':'application/zip','x-goog-content-length-range':'0,104857600'}:{'Content-Type':'application/zip'};
}
function patch(n,source){return n==='onAuthUserDelete'?{name:resource(n),sourceUploadUrl:source,runtime:'nodejs22',timeout:'540s'}:{name:resource(n),buildConfig:{source:{storageSource:source},runtime:'nodejs22'}};}
function validate(url,method='GET',body,c={}){
 const reads=new Set([...NAMES.flatMap(n=>[G1+resource(n),G2+resource(n),G1+resource(n)+':getIamPolicy']),...['GROQ_API_KEY','OPENAI_API_KEY','IMPORT_API_KEY'].flatMap(s=>[secret(s),secret(s)+'/versions?pageSize=100',secret(s)+':getIamPolicy?options.requestedPolicyVersion=3']),...Object.values(phase1.policies).filter(p=>p.getMethod!=='POST').map(p=>p.get),...['aogaku-ai-runtime','aogaku-ai-account-deletion'].map(a=>`https://iam.googleapis.com/v1/projects/${P}/serviceAccounts/${a}@${P}.iam.gserviceaccount.com/keys?keyTypes=USER_MANAGED`)]);
 if(method==='GET'&&(reads.has(url)||c.operations?.has(url)||c.runIAM?.has(url)))return;
 if(method==='POST'&&Object.values(phase1.policies).some(p=>p.get===url&&p.getMethod==='POST')){assert.deepEqual(body,{options:{requestedPolicyVersion:3}});return;}
 try{cloud.assertRead(url,method);return;}catch{}
 try{p3a.validate(url,method,body,{apply:false});return;}catch{}
 if(method==='POST'&&NAMES.some(n=>url===base(n)+resource(n)+':generateDownloadUrl')){assert.deepEqual(body,url.startsWith(G1)?{versionId:c.versionId}:{});if(url.startsWith(G1))assert(/^\d+$/.test(String(c.versionId)));return;}
 assert(c.apply===true&&NAMES.includes(c.name),'STOP: no approved individual update');
 if(method==='POST'&&url===base(c.name)+parent+'/functions:generateUploadUrl'){assert.deepEqual(body,{});return;}
 if(method==='PATCH'&&url===base(c.name)+resource(c.name)+'?updateMask='+mask(c.name)){
  const source=c.name==='onAuthUserDelete'?body?.sourceUploadUrl:body?.buildConfig?.source?.storageSource;
  assert(c.sources?.has(hash(source)),'STOP: unissued source');assert.deepEqual(body,patch(c.name,source));return;
 }
 throw Error('STOP: request outside Phase 3b allowlist');
}
function artifact(){
 const a=load('build/production-phase3b/artifact.json');assert.deepEqual(a.names,NAMES);assert.equal(a.phase4Exports,false);assert.equal(a.newDependencies,false);assert(a.runtimeSAPreserved&&a.secretBindingsPreserved);assert.equal(a.sourceSha256,hash(a.files));assert.equal(require('node:crypto').createHash('sha256').update(fs.readFileSync(path.join(DIR,'candidate.zip'))).digest('hex'),a.zipSha256);
 const actual={};function walk(d){for(const e of fs.readdirSync(d,{withFileTypes:true})){const p=path.join(d,e.name);if(e.isDirectory())walk(p);else if(e.isFile())actual[path.relative(path.join(DIR,'candidate'),p)]=require('node:crypto').createHash('sha256').update(fs.readFileSync(p)).digest('hex');else assert(e.name==='node_modules'&&e.isSymbolicLink());}}walk(path.join(DIR,'candidate'));assert.deepEqual(actual,a.files);assert.equal(Object.keys(actual).length,8);return a;
}
function runtimeCore(n,f){
 if(n==='onAuthUserDelete'){const out=p3a.runtimeCore(f);delete out.runtime;delete out.timeout;return out;}
 const s=structuredClone(f.serviceConfig);delete s.revision;
 const b=Object.fromEntries(Object.entries(f.buildConfig).filter(([k])=>!['build','source','sourceProvenance','runtime'].includes(k)));
 return {name:f.name,environment:f.environment,serviceConfig:s,buildConfig:b,eventTrigger:f.eventTrigger||null,labels:f.labels};
}
function assertRuntime(n,f,updated){
 assert.equal(f.name,resource(n));assert.equal(n==='onAuthUserDelete'?f.runtime:f.buildConfig.runtime,'nodejs22');
 if(n==='onAuthUserDelete'){assert.equal(f.status,'ACTIVE');assert.equal(f.eventTrigger.eventType,'providers/firebase.auth/eventTypes/user.delete');assert.equal(f.serviceAccountEmail,P+'@appspot.gserviceaccount.com');assert.equal(f.timeout,'540s');assert(!(f.secretEnvironmentVariables||[]).length);}
 else{assert.equal(f.environment,'GEN_2');assert.equal(f.state,'ACTIVE');assert(!f.eventTrigger);assert.equal(f.serviceConfig.serviceAccountEmail,N+'-compute@developer.gserviceaccount.com');assert.equal(f.buildConfig.entryPoint,n);const secrets=f.serviceConfig.secretEnvironmentVariables;assert.equal(secrets.length,1);assert.equal(secrets[0].key,'IMPORT_API_KEY');assert.equal(secrets[0].secret,'IMPORT_API_KEY');assert.equal(String(secrets[0].version),'2');assert([P,N].includes(String(secrets[0].projectId)));}
}
function protectedSame(b,a,updated){
 for(const k of Object.keys(b.metadata).filter(k=>!['readAt','functions'].includes(k)))assert.deepEqual(metadataCore(k,a.metadata[k]),metadataCore(k,b.metadata[k]),'STOP: metadata drift '+k);
 assert.deepEqual(a.metadata.functions,b.metadata.functions,'STOP: Function inventory/labels drift');
 for(const k of ['resources','iam','secrets','keys'])assert.deepEqual(a[k],b[k],'STOP: protected '+k+' drift');
 assert.equal(a.functions.length,13);assert.equal(b.functions.length,13);
 for(const f of b.functions){const current=a.functions.find(x=>x.name===f.name);assert(current);if(!updated.includes(f.name.split('/').pop()))assert.deepEqual(current,f,'STOP: unrelated Function changed '+f.name);}
 for(const n of NAMES){assertRuntime(n,a.legacy[n],updated.includes(n));assert.deepEqual(runtimeCore(n,a.legacy[n]),runtimeCore(n,b.legacy[n]),'STOP: runtime/SA/trigger/IAM/Secret settings drift '+n);}
}
function uploadTarget(n,d,current){
 const u=new URL(d.uploadUrl);assert.equal(u.protocol,'https:');assert.equal(u.hostname,'storage.googleapis.com');assert(!u.username&&!u.password&&!u.port);
 const bucket=u.pathname.split('/')[1];
 if(n==='onAuthUserDelete'){assert.equal(bucket,current.sourceUploadBucket);assert(/^uploads-\d+\.asia-northeast1\.cloudfunctions\.appspot\.com$/.test(bucket));}
 else{assert(d.storageSource?.bucket&&d.storageSource.object);assert.equal(bucket,d.storageSource.bucket);assert(bucket.includes(N)&&bucket.includes(R),'STOP: Gen2 staging project/region mismatch');assert.equal(decodeURIComponent(u.pathname.slice(bucket.length+2)),d.storageSource.object);assert(!d.storageSource.object.includes('..'));}
 return u;
}
async function main(action,name){
 assert(['capture','preflight','update','postcheck','audit-stop'].includes(action));if(action==='update')assert(NAMES.includes(name));else assert(!name);
 fs.mkdirSync(DIR,{recursive:true,mode:0o700});execFileSync('python3',['scripts/firebase_production.py','check','--project',P],{cwd:ROOT,stdio:'pipe'});
 const a=action==='capture'?null:artifact(),journalPath=path.join(DIR,'execution.json');
 const j=fs.existsSync(journalPath)?JSON.parse(fs.readFileSync(journalPath)):{phase:'3b',target:{projectId:P,projectNumber:N,bucket:B,bundleId:'com.forta2k25.Aogaku'},artifactSha256:a?.sourceSha256||null,attempts:[],updated:[],verified:{},status:'STARTED',partialSuccess:false};
 assert(action==='audit-stop'||j.status!=='STOPPED'&&!j.partialSuccess,'STOP: prior error/partial needs review');if(a)assert.equal(j.artifactSha256,a.sourceSha256);
 let token,tokenAt=0;const operations=new Set(),sources=new Set(),runIAM=new Set();const persist=()=>save('execution',j);
 async function bearer(){if(!token||Date.now()-tokenAt>2700000){const lib='/Users/shum/anaconda3/lib/node_modules/firebase-tools/lib',account=require(lib+'/auth.js').getGlobalDefaultAccount(),api=require(lib+'/api.js');const r=await fetch('https://oauth2.googleapis.com/token',{method:'POST',body:new URLSearchParams({client_id:api.clientId(),client_secret:api.clientSecret(),refresh_token:account.tokens.refresh_token,grant_type:'refresh_token'}),signal:AbortSignal.timeout(45000)});const d=await r.json();assert(r.ok&&d.access_token);token=d.access_token;tokenAt=Date.now();}return token;}
 async function request(url,method='GET',body,extra={}){
  validate(url,method,body,{apply:action==='update',name,operations,sources,runIAM,...extra});
  const mutation=method==='PATCH'||url.endsWith(':generateUploadUrl');const attempt=mutation?{function:name,action:method==='PATCH'?'FUNCTION_PATCH':'GENERATE_UPLOAD_URL',at:new Date().toISOString(),status:'UNKNOWN'}:null;if(attempt){j.attempts.push(attempt);persist();}
  const r=await fetch(url,{method,redirect:'error',headers:{Authorization:'Bearer '+await bearer(),'Content-Type':'application/json'},...(body===undefined?{}:{body:JSON.stringify(body)}),signal:AbortSignal.timeout(45000)});const d=await r.json().catch(()=>({}));if(!r.ok){if(attempt){attempt.status='HTTP_ERROR';attempt.httpStatus=r.status;persist();}throw Error('HTTP '+r.status+' '+(d.error?.status||''));}assert(!d.nextPageToken,'STOP: pagination');if(attempt){attempt.status='CONFIRMED';persist();}return method==='GET'?safeMetadata(d):d;
 }
 async function snapshot(){
  const metadata=await cloud.inspect();assert.equal(metadata.projectId,P);assert.equal(metadata.projectNumber,N);assert.equal(metadata.bucket.name,B);assert(metadata.apps.apps.some(a=>a.bundleId==='com.forta2k25.Aogaku'&&a.state==='ACTIVE'));assert.equal(metadata.aiDatabase.locationId,R);assert.equal(metadata.aiDatabase.deleteProtectionState,'DELETE_PROTECTION_ENABLED');
  await cloud.resourcesMetadata();const resources=load('build/production-resources-live.json').records;assert(Object.values(resources).every(r=>r.httpStatus===200));assert.equal(resources.queue.data.state,'PAUSED');
  const functions=(await request(cloud.urls.functions)).functions||[];assert.equal(functions.length,13);const iam={},secrets={},keys={},legacy={};
  for(const [k,p]of Object.entries(phase1.policies))iam[k]=await request(p.get,p.getMethod||'GET',p.getMethod==='POST'?{options:{requestedPolicyVersion:3}}:undefined);
  for(const s of ['GROQ_API_KEY','OPENAI_API_KEY','IMPORT_API_KEY']){secrets[s]={metadata:await request(secret(s)),versions:await request(secret(s)+'/versions?pageSize=100')};iam[s]=await request(secret(s)+':getIamPolicy?options.requestedPolicyVersion=3');}
  for(const n of NAMES){legacy[n]=await request(base(n)+resource(n));const url=n==='onAuthUserDelete'?G1+resource(n)+':getIamPolicy':'https://run.googleapis.com/v1/'+legacy[n].serviceConfig.service+':getIamPolicy';runIAM.add(url);iam[n]=await request(url);}
  for(const n of p3a.NAMES)iam[n]=await request(G1+resource(n)+':getIamPolicy');
  for(const s of ['aogaku-ai-runtime','aogaku-ai-account-deletion']){keys[s]=await request(`https://iam.googleapis.com/v1/projects/${P}/serviceAccounts/${s}@${P}.iam.gserviceaccount.com/keys?keyTypes=USER_MANAGED`);assert(!(keys[s].keys||[]).length);}
  return {metadata,resources,functions,iam,secrets,keys,legacy};
 }
 async function download(n,f,label){const d=await request(base(n)+resource(n)+':generateDownloadUrl','POST',n==='onAuthUserDelete'?{versionId:f.versionId}:{},{versionId:f.versionId});const u=new URL(d.downloadUrl);assert.equal(u.protocol,'https:');assert(u.hostname==='storage.googleapis.com'||u.hostname.endsWith('.storage.googleapis.com'));assert(!u.username&&!u.password&&!u.port);const r=await fetch(u,{redirect:'error',signal:AbortSignal.timeout(45000)});assert(r.ok,'SourceCodeGet HTTP '+r.status);const bytes=Buffer.from(await r.arrayBuffer());assert(bytes.length<=100*1024*1024);const zip=path.join(DIR,n+'-'+label+'.zip');fs.writeFileSync(zip,bytes,{mode:0o600});const files=sourceManifest(zip);assert.equal((await request(base(n)+resource(n))).updateTime,f.updateTime,'STOP: source changed during verification');return {zipSha256:require('node:crypto').createHash('sha256').update(bytes).digest('hex'),sourceSha256:hash(files),files,entrySha256:files['lib/index.js']||files['index.js'],updateTime:f.updateTime};}
 async function operation(d){const prefix=name==='onAuthUserDelete'?/^operations\/[A-Za-z0-9_=-]+$/:new RegExp('^projects/'+P+'/locations/'+R+'/operations/[A-Za-z0-9_-]+$');assert(prefix.test(d.name),'STOP: operation name');if(d.metadata?.target)assert.equal(d.metadata.target,resource(name));const url=base(name)+d.name;operations.add(url);save(name+'-operation-initial',d);for(let i=0;i<300;i++){const current=await request(url);save(name+'-operation',current);if(current.done){assert(!current.error,'STOP: Function operation failed '+(current.error?.code||''));return;}if(i%6===0)console.log(name+': individual build in progress');await new Promise(r=>setTimeout(r,5000));}throw Error('STOP: operation timeout');}
 try{
  const before=await snapshot();save(action+(name?'-'+name:'')+'-before',before);
  if(action==='capture'){
   assert(!fs.existsSync(journalPath)&&!fs.existsSync(path.join(DIR,'initial-production-legacy-live.json')),'STOP: preserve capture');
   const records=[],captured={};
   for(const n of NAMES){assertRuntime(n,before.legacy[n],false);captured[n]=await download(n,before.legacy[n],'original');assert.equal(captured[n].sourceSha256,'2304cabbe6917c0f42baf91784488c466e86df570ff23a5679070546151631c5','STOP: current Node22 source drift');records.push({name:n,updateTime:before.legacy[n].updateTime,environment:n==='onAuthUserDelete'?'GEN_1':'GEN_2',runtime:'nodejs22'});}
   save('captured-source',captured);
   save('initial-production-legacy-live',{projectId:P,projectNumber:N,readAt:new Date().toISOString(),records});
   console.log('Fresh resumed capture PASS: actual sources, metadata, IAM, Secrets references, trigger/SA/runtime; no signed URLs/credentials persisted; mutations=0');return;
  }
  if(action==='audit-stop'){
   const baseline=load('build/production-phase3b/baseline.json');
   protectedSame(baseline,before,j.updated);
   assert(!j.attempts.some(a=>a.action==='FUNCTION_PATCH'),'STOP: PATCH was attempted; inspect actual target state');
   const expected=load('build/production-phase3b/original-source.json'),actual={};
   for(const n of NAMES){actual[n]=await download(n,before.legacy[n],'stopped-after');assert.deepEqual(actual[n],expected[n],'STOP: deployed source changed after staging failure');}
   save('stop-audit',{status:'PASS_UNCHANGED',checkedAt:new Date().toISOString(),functionPatches:0,functionsUpdated:[],sources:actual,protectedResourcesUnchanged:true,queueState:before.resources.queue.data.state,reason:j.error});
   console.log('Read-only stop audit PASS: zero Function PATCH; all 13 Functions/updateTime and all protected settings unchanged; queue PAUSED');return;
  }
  if(action==='preflight'){
   assert(!fs.existsSync(path.join(DIR,'baseline.json')),'STOP: preserve existing baseline');
   // The baseline for this resumed execution is freshly retrieved above.
   // Original recovery hashes are immutable provenance, not an old approval.
   protectedSame(load('build/production-phase3b/capture-before.json'),before,[]);
   const source={};for(const n of NAMES){assertRuntime(n,before.legacy[n],false);assert.equal(before.legacy[n].updateTime,a.before[n].updateTime);source[n]=await download(n,before.legacy[n],'before');assert.equal(source[n].entrySha256,a.before[n].entrySha256);assert.equal(source[n].zipSha256,a.before[n].zipSha256);}
   const runtimeLog=fs.readFileSync(path.join(DIR,'database-runtime-regression.log'),'utf8');assert(runtimeLog.includes('pass 5')&&runtimeLog.includes('fail 0')&&runtimeLog.includes('skipped 0'),'STOP: exact artifact runtime DB gate missing');
   for(const n of NAMES){const currentFiles=load('build/production-phase3b/captured-source.json')[n].files;assert.deepEqual(Object.keys(a.files).sort(),Object.keys(currentFiles).sort());for(const file of Object.keys(a.files))if(file!=='lib/ai/databases.js')assert.equal(a.files[file],currentFiles[file],'STOP: unrelated source change '+file);}
   const log=fs.readFileSync(path.join(DIR,'emulator-before-sequential.log'),'utf8');assert(log.includes('pass 50')&&log.includes('fail 0')&&log.includes('skipped 0'),'STOP: regression gate missing');
   save('baseline',before);save('original-source',source);save('approval',{phase:'3b',approvedAt:new Date().toISOString(),authority:'Current user explicitly approved correcting missing-runtime DB defaults in the current Node22 Phase3b handlers, three fresh individual source updates, disposable three-route E2E, then ownership-verified prior fixture cleanup only.',targets:NAMES,artifactSha256:a.sourceSha256,zipSha256:a.zipSha256,wrapperSha256:hash(fs.readFileSync(__filename,'utf8')),baselineSha256:hash(before),currentSources:source,mutationFields:{GEN_2:['buildConfig.source','buildConfig.runtime'],GEN_1:['sourceUploadUrl','runtime','timeout']},IAMSecretSAPreserved:true,phase4Authorized:false,tests:'Emulator 50 PASS / 0 fail / 0 skip; exact artifact DB env cases 5 PASS / 0 fail / 0 skip'});j.status='PREFLIGHT_PASS';persist();console.log('Phase3b fresh preflight PASS; cloud mutations=0');return;
  }
  const b=load('build/production-phase3b/baseline.json'),approval=load('build/production-phase3b/approval.json');assert.equal(approval.artifactSha256,a.sourceSha256);assert.equal(approval.wrapperSha256,hash(fs.readFileSync(__filename,'utf8')));assert.equal(approval.baselineSha256,hash(b));assert.deepEqual(approval.targets,NAMES);protectedSame(b,before,j.updated);
  if(action==='update'){
   assert.equal(name,NAMES[j.updated.length],'STOP: order/repeated update');const fresh=await download(name,before.legacy[name],'immediate-before');assert.deepEqual(fresh,approval.currentSources[name]);
   const d=await request(base(name)+parent+'/functions:generateUploadUrl','POST',{});const u=uploadTarget(name,d,before.legacy[name]);const source=name==='onAuthUserDelete'?d.uploadUrl:d.storageSource;sources.add(hash(source));
   const bytes=fs.readFileSync(path.join(DIR,'candidate.zip'));assert.equal(require('node:crypto').createHash('sha256').update(bytes).digest('hex'),a.zipSha256);
   const attempt={action:'SIGNED_SOURCE_UPLOAD',function:name,at:new Date().toISOString(),status:'UNKNOWN',generation:name==='onAuthUserDelete'?'GEN_1':'GEN_2',method:'PUT',contentLength:bytes.length,headers:uploadHeaders(name),stagingBucket:u.pathname.split('/')[1]};j.attempts.push(attempt);persist();
   const r=await fetch(u,{method:'PUT',redirect:'error',headers:uploadHeaders(name),body:bytes,signal:AbortSignal.timeout(45000)});
   if(!r.ok){const body=await r.text();attempt.status='HTTP_ERROR';attempt.httpStatus=r.status;attempt.storageErrorCode=body.match(/<Code>([A-Za-z0-9_]{1,80})<\/Code>/)?.[1]||null;persist();throw Error('Source staging HTTP '+r.status+(attempt.storageErrorCode?' '+attempt.storageErrorCode:''));}
   attempt.status='CONFIRMED';persist();assert.deepEqual(await request(base(name)+resource(name)),before.legacy[name],'STOP: target drift before PATCH');
   console.log(name+': exact source/runtime PATCH; existing SA/IAM/Secret preserved');await operation(await request(base(name)+resource(name)+'?updateMask='+mask(name),'PATCH',patch(name,source)));
   const installed=await request(base(name)+resource(name));assertRuntime(name,installed,true);assert.deepEqual(runtimeCore(name,installed),runtimeCore(name,b.legacy[name]));const actual=await download(name,installed,'installed');assert.deepEqual(actual.files,a.files,'STOP: actual source differs from approved artifact');j.updated.push(name);j.verified[name]=actual;const after=await snapshot();save('update-'+name+'-after',after);protectedSame(b,after,j.updated);j.status='VERIFIED_'+name;persist();console.log(name+': exact installed SHA verified; other resources unchanged');return;
  }
  assert.deepEqual(j.updated,NAMES);for(const n of NAMES){const actual=await download(n,before.legacy[n],'final');assert.deepEqual(actual.files,a.files);assert.deepEqual(actual,j.verified[n]);}const after=await snapshot();save('postcheck-after',after);protectedSame(b,after,NAMES);j.status='CONTROL_PLANE_PASS';j.completedAt=new Date().toISOString();j.protectedResourcesUnchanged=true;persist();console.log('Phase3b control-plane post-check PASS: other 10 Functions and all protected resources unchanged');
 }catch(e){j.status='STOPPED';j.error=e.message;j.partialSuccess=j.attempts.some(a=>a.action==='FUNCTION_PATCH'&&['UNKNOWN','CONFIRMED'].includes(a.status));persist();console.error('STOP Phase3b: '+e.message+'; partialSuccess='+j.partialSuccess+'; no retry/rollback');process.exitCode=1;}
}
module.exports={validate,artifact,patch,mask,runtimeCore,metadataCore,safeMetadata,protectedSame,uploadTarget,uploadHeaders,NAMES,parent,resource,G1,G2};
if(require.main===module)main(...process.argv.slice(2)).catch(e=>{console.error('STOP: '+e.message);process.exitCode=1;});
