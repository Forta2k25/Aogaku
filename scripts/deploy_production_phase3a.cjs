#!/usr/bin/env node
// Phase 3a ONLY: three existing Gen1 callables, one source-only PATCH at a time.
// No Firebase deploy CLI, IAM/API/Secret/config mutation, creation, deletion,
// retries of mutations, force, or automatic rollback. Signed URLs stay in memory.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict'),{execFileSync}=require('node:child_process');
const ROOT=path.resolve(__dirname,'..'),DIR=path.join(ROOT,'build/production-phase3a');
const P='forta-aogaku',N='505828754933',B=P+'.firebasestorage.app',R='asia-northeast1';
const NAMES=['askCourseAI','transcribeLectureAudio','generateReactionPaper'];
const G='https://cloudfunctions.googleapis.com/v1/',parent=`projects/${P}/locations/${R}`,resource=n=>parent+'/functions/'+n;
const cloud=require('./production_cloud.cjs'),phase1=require('./provision_production_phase1.cjs');
const load=p=>JSON.parse(fs.readFileSync(path.join(ROOT,p),'utf8'));
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const canonical=x=>Array.isArray(x)?x.map(canonical):x&&typeof x==='object'?Object.fromEntries(Object.keys(x).sort().map(k=>[k,canonical(x[k])])):x;
const hash=x=>sha(JSON.stringify(canonical(x)));
function save(n,x){const p=path.join(DIR,n+'.json');fs.writeFileSync(p,JSON.stringify(x,null,2)+'\n',{mode:0o600});fs.chmodSync(p,0o600);}
const secretURL=s=>`https://secretmanager.googleapis.com/v1/projects/${P}/secrets/${s}`;
const extraReads=new Set([
 ...NAMES.flatMap(n=>[G+resource(n),G+resource(n)+':getIamPolicy']),
 ...['GROQ_API_KEY','OPENAI_API_KEY'].flatMap(s=>[secretURL(s),secretURL(s)+'/versions?pageSize=100',secretURL(s)+':getIamPolicy?options.requestedPolicyVersion=3']),
 ...Object.values(phase1.policies).filter(p=>p.getMethod!=='POST').map(p=>p.get),
 ...['aogaku-ai-runtime','aogaku-ai-account-deletion'].map(a=>`https://iam.googleapis.com/v1/projects/${P}/serviceAccounts/${a}@${P}.iam.gserviceaccount.com/keys?keyTypes=USER_MANAGED`)
]);
function validate(url,method='GET',body,c={}){
 if(method==='GET'&&(extraReads.has(url)||c.operations?.has(url)))return;
 if(method==='POST'&&Object.values(phase1.policies).some(p=>p.get===url&&p.getMethod==='POST')){assert.deepEqual(body,{options:{requestedPolicyVersion:3}});return;}
 try{cloud.assertRead(url,method);return;}catch{}
 if(method==='POST'&&NAMES.some(n=>url===G+resource(n)+':generateDownloadUrl')){assert.deepEqual(Object.keys(body),['versionId']);assert(/^\d+$/.test(String(body.versionId)));return;}
 assert(c.apply===true&&NAMES.includes(c.name),'STOP: no approved individual update');
 if(method==='POST'&&url===G+parent+'/functions:generateUploadUrl'){assert.deepEqual(body,{});return;}
 if(method==='PATCH'&&url===G+resource(c.name)+'?updateMask=sourceUploadUrl'){
  assert.deepEqual(Object.keys(body).sort(),['name','sourceUploadUrl']);assert.equal(body.name,resource(c.name));assert(c.uploadUrls?.has(body.sourceUploadUrl),'STOP: unissued source URL');return;
 }
 throw Error('STOP: request outside Phase 3a source-only allowlist');
}
function runtimeCore(f){return Object.fromEntries(['name','runtime','entryPoint','httpsTrigger','eventTrigger','serviceAccountEmail','availableMemoryMb','timeout','environmentVariables','buildEnvironmentVariables','secretEnvironmentVariables','ingressSettings','vpcConnector','vpcConnectorEgressSettings','minInstances','maxInstances','labels','dockerRegistry','buildServiceAccount','automaticUpdatePolicy','securityLevel'].filter(k=>f[k]!==undefined).map(k=>[k,f[k]]));}
function assertRuntime(n,f){
 assert.equal(f.name,resource(n));assert.equal(f.runtime,'nodejs22');assert.equal(f.entryPoint,n);assert(f.httpsTrigger?.url&&!f.eventTrigger);assert.equal(f.serviceAccountEmail,P+'@appspot.gserviceaccount.com');assert.equal(f.status,'ACTIVE');
 const expected=n==='transcribeLectureAudio'?['GROQ_API_KEY','OPENAI_API_KEY']:['OPENAI_API_KEY'];
 assert.deepEqual((f.secretEnvironmentVariables||[]).map(s=>s.key).sort(),expected);
 for(const s of f.secretEnvironmentVariables){assert.equal(s.secret,s.key);assert.equal(String(s.version),'1');assert([P,N].includes(String(s.projectId)));}
}
function assertArtifact(){
 const a=load('build/production-phase3a/artifact.json');assert.deepEqual(a.names,NAMES);assert.deepEqual(a.exportedFunctions,NAMES);assert.equal(a.namedSourceWrites,false);assert.equal(a.newDependencies,false);
 assert.equal(a.sourceSha256,hash(a.files));assert.equal(a.zipSha256,sha(fs.readFileSync(path.join(DIR,'candidate.zip'))));
 const actual={};function walk(d){for(const e of fs.readdirSync(d,{withFileTypes:true})){const p=path.join(d,e.name);if(e.isDirectory())walk(p);else if(e.isFile())actual[path.relative(path.join(DIR,'candidate'),p)]=sha(fs.readFileSync(p));else assert(e.name==='node_modules'&&e.isSymbolicLink(),'unexpected artifact link');}}
 walk(path.join(DIR,'candidate'));assert.deepEqual(actual,a.files);
 assert.equal(sha(fs.readFileSync(path.join(ROOT,'functions/lib/legacy-ai/index.js'))),a.legacyCodeSha256);assert.equal(sha(fs.readFileSync(path.join(ROOT,'functions/lib/legacy-ai/account-state.js'))),a.files['lib/legacy-ai/account-state.js']);
 assert.equal(Object.keys(a.files).length,5);return a;
}
function sourceManifest(zip){
 const code="import sys,json,zipfile,hashlib; z=zipfile.ZipFile(sys.argv[1]); names=[n for n in z.namelist() if not n.endswith('/')]; assert len(names)==len(set(names)); assert all(not n.startswith('/') and '..' not in n.split('/') for n in names); print(json.dumps({n:hashlib.sha256(z.read(n)).hexdigest() for n in sorted(names)},sort_keys=True))";
 return JSON.parse(execFileSync('python3',['-c',code,zip],{encoding:'utf8'}));
}
function metadataCore(k,value){
 // Observed with two read-only consecutive GETs: named DB etag changes on
 // every response while ALL other fields (including updateTime) stay equal.
 // This phase never updates/deletes a database, so retain the raw token in
 // evidence, but compare every resource field instead of this opaque token.
 return k==='aiDatabase'?Object.fromEntries(Object.entries(value).filter(([key])=>key!=='etag')):value;
}
function uploadTarget(url,baseline){
 const u=new URL(url);assert.equal(u.protocol,'https:');assert.equal(u.hostname,'storage.googleapis.com');assert(!u.username&&!u.password&&!u.port);
 const existing=[...new Set(NAMES.map(n=>new URL(baseline.legacy[n].sourceUploadUrl).pathname.split('/')[1]))];
 assert.equal(existing.length,1,'STOP: existing source staging bucket ambiguous');
 assert(/^uploads-\d+\.asia-northeast1\.cloudfunctions\.appspot\.com$/.test(existing[0]),'STOP: unexpected existing Gen1 staging bucket');
 assert.equal(u.pathname.split('/')[1],existing[0],'STOP: issued staging bucket differs from current three Functions');
 assert(/^\/[A-Za-z0-9.-]+\/[A-Za-z0-9-]+\.zip$/.test(u.pathname),'STOP: invalid source staging path');
 return u;
}
function protectedSame(b,a,updated){
 for(const k of Object.keys(b.metadata).filter(k=>!['readAt','functions'].includes(k)))assert.deepEqual(metadataCore(k,a.metadata[k]),metadataCore(k,b.metadata[k]),'STOP: metadata drift '+k);
 assert.deepEqual(a.metadata.functions,b.metadata.functions,'STOP: Function inventory/labels drift');
 assert.deepEqual(a.resources,b.resources,'STOP: API/SA/queue/Scheduler/Eventarc drift');
 assert.deepEqual(a.iam,b.iam,'STOP: IAM drift');assert.deepEqual(a.secrets,b.secrets,'STOP: Secret metadata/version drift');assert.deepEqual(a.keys,b.keys,'STOP: SA keys drift');
 assert.equal(a.functions.length,b.functions.length);
 for(const f of b.functions){const current=a.functions.find(x=>x.name===f.name);assert(current,'STOP: Function disappeared');if(!updated.includes(f.name.split('/').pop()))assert.deepEqual(current,f,'STOP: unrelated Function changed '+f.name);}
 for(const n of NAMES){assertRuntime(n,a.legacy[n]);assert.deepEqual(runtimeCore(a.legacy[n]),runtimeCore(b.legacy[n]),'STOP: runtime/trigger/Secret/config changed '+n);}
}
async function main(action,name){
 assert(['preflight','update','postcheck'].includes(action));if(action==='update')assert(NAMES.includes(name));else assert(!name);
 fs.mkdirSync(DIR,{recursive:true,mode:0o700});fs.chmodSync(DIR,0o700);
 execFileSync('python3',['scripts/firebase_production.py','check','--project',P],{cwd:ROOT,stdio:'pipe'});
 const artifact=assertArtifact(),journalPath=path.join(DIR,'execution.json');
 const journal=fs.existsSync(journalPath)?JSON.parse(fs.readFileSync(journalPath)):{phase:'3a',target:{projectId:P,projectNumber:N,bucket:B,bundleId:'com.forta2k25.Aogaku'},artifactSha256:artifact.sourceSha256,attempts:[],updated:[],verified:{},status:'STARTED',partialSuccess:false};
 assert(journal.status!=='STOPPED'&&!journal.partialSuccess,'STOP: prior error/partial needs user review');assert.equal(journal.artifactSha256,artifact.sourceSha256);
 const persist=()=>save('execution',journal);let token,tokenAt=0;const operations=new Set(),uploadUrls=new Set();
 async function bearer(){if(!token||Date.now()-tokenAt>2700000){
  const lib='/Users/shum/anaconda3/lib/node_modules/firebase-tools/lib',account=require(lib+'/auth.js').getGlobalDefaultAccount(),api=require(lib+'/api.js');assert(account?.tokens?.refresh_token);
  const r=await fetch('https://oauth2.googleapis.com/token',{method:'POST',body:new URLSearchParams({client_id:api.clientId(),client_secret:api.clientSecret(),refresh_token:account.tokens.refresh_token,grant_type:'refresh_token'}),signal:AbortSignal.timeout(45000)});const d=await r.json();assert(r.ok&&d.access_token,'OAuth refresh failed');token=d.access_token;tokenAt=Date.now();
 }return token;}
 async function request(url,method='GET',body){
  validate(url,method,body,{apply:action==='update',name,operations,uploadUrls});
  const mutation=method==='PATCH'||url.endsWith(':generateUploadUrl');const attempt=mutation?{action:method==='PATCH'?'SOURCE_PATCH':'GENERATE_UPLOAD_URL',function:name,at:new Date().toISOString(),status:'UNKNOWN'}:null;
  if(attempt){journal.attempts.push(attempt);persist();}
  const r=await fetch(url,{method,redirect:'error',headers:{Authorization:'Bearer '+await bearer(),'Content-Type':'application/json'},...(body===undefined?{}:{body:JSON.stringify(body)}),signal:AbortSignal.timeout(45000)});const d=await r.json().catch(()=>({}));
  if(!r.ok){if(attempt){attempt.status='HTTP_ERROR';attempt.httpStatus=r.status;persist();}throw Error('HTTP '+r.status+' '+new URL(url).hostname+' '+(d.error?.status||''));}
  assert(!d.nextPageToken,'STOP: unexpected pagination');if(attempt){attempt.status='CONFIRMED';persist();}return d;
 }
 async function snapshot(){
  const metadata=await cloud.inspect();assert.equal(metadata.projectId,P);assert.equal(metadata.projectNumber,N);assert.equal(metadata.bucket.name,B);assert(metadata.apps.apps.some(a=>a.bundleId==='com.forta2k25.Aogaku'&&a.state==='ACTIVE'));assert(!metadata.storagePrivacy.publicBucketIAM&&!metadata.storagePrivacy.publicDefaultACL);
  assert.equal(metadata.aiDatabase.name,`projects/${P}/databases/aogaku-ai`);assert.equal(metadata.aiDatabase.locationId,R);assert.equal(metadata.aiDatabase.deleteProtectionState,'DELETE_PROTECTION_ENABLED');
  await cloud.resourcesMetadata();const resources=load('build/production-resources-live.json').records;assert(Object.values(resources).every(r=>r.httpStatus===200));assert.equal(resources.queue.data.state,'PAUSED');
  const functions=(await request(cloud.urls.functions)).functions||[];assert.equal(functions.length,13);
  const iam={},legacy={},keys={},secrets={};
  for(const [key,p]of Object.entries(phase1.policies))iam[key]=await request(p.get,p.getMethod||'GET',p.getMethod==='POST'?{options:{requestedPolicyVersion:3}}:undefined);
  for(const s of ['GROQ_API_KEY','OPENAI_API_KEY']){const versions=await request(secretURL(s)+'/versions?pageSize=100');assert(versions.versions?.some(v=>v.name.endsWith('/versions/1')&&v.state==='ENABLED'));secrets[s]={metadata:await request(secretURL(s)),versions};iam[s]=await request(secretURL(s)+':getIamPolicy?options.requestedPolicyVersion=3');}
  for(const n of NAMES){legacy[n]=await request(G+resource(n));assertRuntime(n,legacy[n]);assert.equal(functions.find(f=>f.name===resource(n))?.environment,'GEN_1');iam[n]=await request(G+resource(n)+':getIamPolicy');}
  for(const a of ['aogaku-ai-runtime','aogaku-ai-account-deletion']){keys[a]=await request(`https://iam.googleapis.com/v1/projects/${P}/serviceAccounts/${a}@${P}.iam.gserviceaccount.com/keys?keyTypes=USER_MANAGED`);assert.equal((keys[a].keys||[]).length,0);}
  return {metadata,resources,functions,iam,secrets,keys,legacy};
 }
 async function download(n,f,label){
  const d=await request(G+resource(n)+':generateDownloadUrl','POST',{versionId:f.versionId});const u=new URL(d.downloadUrl);
  assert.equal(u.protocol,'https:');assert(!u.username&&!u.password&&!u.port);assert(u.hostname==='storage.googleapis.com'||u.hostname.endsWith('.storage.googleapis.com'));
  const r=await fetch(u,{redirect:'error',signal:AbortSignal.timeout(45000)});assert(r.ok,'SourceCodeGet download HTTP '+r.status);const bytes=Buffer.from(await r.arrayBuffer());assert(bytes.length<=100*1024*1024);
  const zip=path.join(DIR,n+'-'+label+'.zip');fs.writeFileSync(zip,bytes,{mode:0o600});fs.chmodSync(zip,0o600);const files=sourceManifest(zip);assert.equal((await request(G+resource(n))).versionId,f.versionId,'STOP: source changed during verification');return {zipSha256:sha(bytes),sourceSha256:hash(files),files,entrySha256:files['lib/index.js'],versionId:f.versionId,updateTime:f.updateTime};
 }
 async function waitOperation(d){
  assert(/^operations\/[A-Za-z0-9_=-]+$/.test(d.name),'STOP: unexpected operation name');
  if(d.metadata?.target)assert.equal(d.metadata.target,resource(name),'STOP: operation target mismatch');
  const url=G+d.name;operations.add(url);save(name+'-operation-initial',d);
  for(let i=0;i<300;i++){const current=await request(url);save(name+'-operation',current);if(current.done){assert(!current.error,'STOP: Function operation failed '+(current.error?.code||''));return;}if(i%4===0)console.log(name+': source update building; protected configuration unchanged');await new Promise(r=>setTimeout(r,5000));}throw Error('STOP: operation timeout');
 }
 try{
  const before=await snapshot();save(action+(name?'-'+name:'')+'-before',before);
  if(action==='preflight'){
   assert(!fs.existsSync(path.join(DIR,'baseline.json')),'STOP: fresh baseline already exists');
   const old=load('build/production-phase2b-named/postcheck-after.json');
   for(const k of Object.keys(old.metadata).filter(k=>k!=='readAt'))assert.deepEqual(metadataCore(k,before.metadata[k]),metadataCore(k,old.metadata[k]),'STOP: drift since Phase 2b '+k);
   assert.deepEqual(before.resources,old.resources,'STOP: Phase 1 resources drift');
   for(const [k,p]of Object.entries(phase1.policies))assert.deepEqual(before.iam[k],old.protected['iam-'+k],'STOP: prior IAM drift '+k);
   assert.deepEqual(before.secrets.GROQ_API_KEY.versions,old.protected.versions,'STOP: Groq versions changed');
   assert.deepEqual(before.functions.map(({name,updateTime,state,environment})=>({name,updateTime,state,environment})),old.protected.functions,'STOP: existing Function updateTime changed');
   const source={};for(const n of NAMES){assert.equal(before.legacy[n].updateTime,artifact.before[n].updateTime);source[n]=await download(n,before.legacy[n],'before');assert.equal(source[n].zipSha256,artifact.before[n].zipSha256);assert.equal(source[n].entrySha256,artifact.before[n].codeSha256);}
   const log=fs.readFileSync(path.join(ROOT,'build/production-phase3a-emulator-before-fixed.log'),'utf8');assert(log.includes('pass 48')&&log.includes('fail 0')&&log.includes('skipped 0'),'STOP: regression gate missing');
   save('baseline',before);save('original-source',source);
   save('approval',{phase:'3a',approvedAt:new Date().toISOString(),authority:'Current user explicitly approved these three source-only individual updates; no Phase 3b authorization.',targets:NAMES,artifactSha256:artifact.sourceSha256,zipSha256:artifact.zipSha256,baselineSha256:hash(before),currentSources:source,mutationFields:['sourceUploadUrl'],secretVersion:'1',tests:'48 PASS / 0 fail / 0 skip'});
   journal.status='PREFLIGHT_PASS';persist();console.log('Phase 3a fresh preflight PASS: identities, actual sources, Gen1/Node22/Tokyo, fixed Secrets, IAM, Phase2 unchanged; cloud mutations=0');return;
  }
  const baseline=load('build/production-phase3a/baseline.json'),approval=load('build/production-phase3a/approval.json');assert.equal(approval.artifactSha256,artifact.sourceSha256);assert.equal(approval.baselineSha256,hash(baseline));assert.deepEqual(approval.targets,NAMES);protectedSame(baseline,before,journal.updated);
  if(action==='update'){
   assert.equal(name,NAMES[journal.updated.length],'STOP: unexpected target/order or repeated update');assert.equal(before.legacy[name].versionId,baseline.legacy[name].versionId,'STOP: target changed');
   const fresh=await download(name,before.legacy[name],'immediate-before');assert.deepEqual(fresh,approval.currentSources[name],'STOP: current source changed');
   const d=await request(G+parent+'/functions:generateUploadUrl','POST',{});const u=uploadTarget(d.uploadUrl,baseline);uploadUrls.add(d.uploadUrl);
   const upload={action:'SIGNED_SOURCE_UPLOAD',function:name,at:new Date().toISOString(),status:'UNKNOWN',artifactZipSha256:artifact.zipSha256};journal.attempts.push(upload);persist();
   const zip=fs.readFileSync(path.join(DIR,'candidate.zip'));assert.equal(sha(zip),approval.zipSha256);
   const r=await fetch(u,{method:'PUT',redirect:'error',headers:{'Content-Type':'application/zip','x-goog-content-length-range':'0,104857600'},body:zip,signal:AbortSignal.timeout(45000)});
   assert(r.ok,'Source staging upload HTTP '+r.status);upload.status='CONFIRMED';persist();
   const current=await request(G+resource(name));assert.deepEqual(current,before.legacy[name],'STOP: target drift before PATCH');
   console.log(name+': applying exact sourceUploadUrl-only PATCH; no IAM/Secret/config changes');
   await waitOperation(await request(G+resource(name)+'?updateMask=sourceUploadUrl','PATCH',{name:resource(name),sourceUploadUrl:d.uploadUrl}));
   const installed=await request(G+resource(name));assertRuntime(name,installed);assert.notEqual(installed.versionId,baseline.legacy[name].versionId);assert.deepEqual(runtimeCore(installed),runtimeCore(baseline.legacy[name]));
   const actual=await download(name,installed,'installed');assert.deepEqual(actual.files,artifact.files,'STOP: installed source does not match approved artifact');assert.equal(actual.sourceSha256,artifact.sourceSha256);
   // Only include updated target after the complete source has been verified.
   journal.updated.push(name);journal.verified[name]=actual;
   const after=await snapshot();save('update-'+name+'-after',after);protectedSame(baseline,after,journal.updated);journal.status='VERIFIED_'+name;persist();console.log(name+': installed artifact SHA verified; other Functions and all protected resources unchanged');return;
  }
  assert.deepEqual(journal.updated,NAMES,'STOP: not all three updates verified');
  for(const n of NAMES){const actual=await download(n,before.legacy[n],'final');assert.deepEqual(actual.files,artifact.files);assert.deepEqual(actual,journal.verified[n],'STOP: verified function changed');}
  const after=await snapshot();save('postcheck-after',after);protectedSame(baseline,after,NAMES);journal.status='CONTROL_PLANE_PASS';journal.completedAt=new Date().toISOString();journal.protectedResourcesUnchanged=true;persist();
  console.log('Phase 3a post-check PASS: exactly three sources match fresh artifact; other 10 Functions/updateTime, Secrets/IAM/Rules/indexes/databases/queue/Scheduler/lifecycle unchanged');
 }catch(e){journal.status='STOPPED';journal.error=e.message;journal.partialSuccess=journal.attempts.some(a=>a.status==='UNKNOWN'||a.action==='SOURCE_PATCH'&&a.status==='CONFIRMED');persist();console.error('STOP Phase 3a: '+e.message+'; partialSuccess='+journal.partialSuccess+'; no automatic retry/rollback');process.exitCode=1;}
}
module.exports={validate,runtimeCore,metadataCore,uploadTarget,sourceManifest,assertArtifact,protectedSame,NAMES,resource,G,parent,hash};
if(require.main===module)main(...process.argv.slice(2)).catch(e=>{console.error('STOP: '+e.message);process.exitCode=1});
