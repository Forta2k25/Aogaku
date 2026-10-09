#!/usr/bin/env node
// Explicitly approved recognition migration. Existing ten resources: source-only PATCH.
// No IAM/env/Secret/Rules updates, automatic mutation retry, CREATE/DELETE or rollback.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),{execFileSync}=require('node:child_process');
const p=require('./production_recognition_review.cjs'),c=require('./production_phase5a_common.cjs'),reads=require('./production_read_retry.cjs'),p3=require('./deploy_production_phase3a.cjs');
const PREVIOUS_DIR=path.join(c.ROOT,'build/production-recognition-deploy-20261008-resume1'),DIR=path.join(c.ROOT,'build/production-visual-router-20261009'),v=require('./production_visual_router_review.cjs'),PACKAGE=path.join(v.DIR,'package'),G='https://cloudfunctions.googleapis.com/v2/',Q='https://cloudtasks.googleapis.com/v2/'+c.Q;
const hash=x=>require('node:crypto').createHash('sha256').update(JSON.stringify(x)).digest('hex');
const save=(n,x)=>{fs.mkdirSync(DIR,{recursive:true,mode:0o700});fs.writeFileSync(path.join(DIR,n+'.json'),JSON.stringify(x,null,2)+'\n',{mode:0o600});};
const load=n=>JSON.parse(fs.readFileSync(path.join(DIR,n+'.json'))),fn=n=>G+c.parent+'/functions/'+n;
const read=async(u,m='GET',b,opts={})=>{const {data}=await reads.read(u,{method:m,headers:{Authorization:'Bearer '+await c.cloud.oauth(),'Content-Type':'application/json'},...(b===undefined?{}:{body:JSON.stringify(b)})},opts);assert(!data?.nextPageToken||opts.boundedPage,'Unexpected pagination');return data;};
async function pilotAuth(live){
 const dest=path.join(DIR,'pilot-auth.private.json');
 if(!fs.existsSync(dest)){const prior=path.join(PREVIOUS_DIR,'pilot-auth.private.json');assert(fs.existsSync(prior),'Existing pilot login missing: operator login needed');fs.copyFileSync(prior,dest);fs.chmodSync(dest,0o600);}
 let a=JSON.parse(fs.readFileSync(dest));assert.equal(a.projectId,c.P);
 if(a.expiresAt*1000<Date.now()+120000){const r=await fetch('https://securetoken.googleapis.com/v1/token?key='+encodeURIComponent(c.apiKey()),{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({grant_type:'refresh_token',refresh_token:a.refreshToken}),signal:AbortSignal.timeout(45000)});assert(r.ok,'Existing pilot refresh HTTP '+r.status);const d=await r.json();a={idToken:d.id_token,refreshToken:d.refresh_token,expiresAt:Date.now()/1000+Number(d.expires_in),projectId:c.P};save('pilot-auth.private',a);}
 const claims=c.jwt(a.idToken);const allowed=JSON.parse(live.find(f=>f.name.endsWith('/aiCreateSource')).serviceConfig.environmentVariables.AI_INPUT_ALLOWED_UIDS);assert(allowed.includes(claims.sub),'Authenticated pilot not in live allowlist');return {uid:claims.sub,token:a.idToken};
}
function artifact(){const a=JSON.parse(fs.readFileSync(path.join(v.DIR,'review.json')));assert.equal(a.sourceManifestSha256,hash(p.inventory(PACKAGE)));assert.deepEqual(a.functions,p.FUNCTIONS);v.contract();return a;}
async function batchReads(jobs){
 const out={};for(let i=0;i<jobs.length;i+=4){const results=await Promise.allSettled(jobs.slice(i,i+4).map(async([key,job])=>[key,await job()]));for(const r of results){if(r.status==='rejected')throw r.reason;out[r.value[0]]=r.value[1];}}return out;
}
async function snapshot(){
 // Bounded parallelism only for independent, read-only metadata. No mutation here.
 await c.cloud.oauth();const pair=await Promise.allSettled([c.cloud.inspect(),c.cloud.resourcesMetadata()]);for(const r of pair)if(r.status==='rejected')throw r.reason;const metadata=pair[0].value;
 execFileSync('python3',['-c','import sys;sys.path.insert(0,"scripts");import firebase_production as p;s=p.load("build/production-live.json");p.live_check(s);p.require_named_ready(s,True,True)'],{cwd:c.ROOT,stdio:'pipe'});
 const resources=JSON.parse(fs.readFileSync(path.join(c.ROOT,'build/production-resources-live.json'))).records;assert(Object.values(resources).every(x=>x.httpStatus===200));
 const functions=await rawFunctions(),iamJobs=[],secretJobs=[],keyJobs=[];
 for(const[k,v]of Object.entries(c.p1.policies))iamJobs.push([k,()=>read(v.get,v.getMethod||'GET',v.getMethod==='POST'?{options:{requestedPolicyVersion:3}}:undefined)]);
 for(const key of ['GROQ_API_KEY','OPENAI_API_KEY','IMPORT_API_KEY']){const u=`https://secretmanager.googleapis.com/v1/projects/${c.P}/secrets/${key}`;secretJobs.push([key,async()=>{const x=await Promise.allSettled([read(u),read(u+'/versions?pageSize=100')]);for(const r of x)if(r.status==='rejected')throw r.reason;return {metadata:x[0].value,versions:x[1].value};}]);iamJobs.push([key,()=>read(u+':getIamPolicy?options.requestedPolicyVersion=3')]);}
 const fnJobs=functions.map(f=>[f.name.split('/').at(-1),()=>read('https://cloudfunctions.googleapis.com/'+(f.environment==='GEN_1'?'v1/':'v2/')+f.name+':getIamPolicy'+(f.environment==='GEN_1'?'':'?options.requestedPolicyVersion=3'))]);
 for(const sa of [c.SA,`aogaku-ai-account-deletion@${c.P}.iam.gserviceaccount.com`])keyJobs.push([sa,async()=>{const v=await read(`https://iam.googleapis.com/v1/projects/${c.P}/serviceAccounts/${sa}/keys?keyTypes=USER_MANAGED`);assert(!(v.keys||[]).length);return v;}]);
 const iam=await batchReads(iamJobs),secrets=await batchReads(secretJobs),functionIAM=await batchReads(fnJobs),keys=await batchReads(keyJobs),runIAM=await batchReads(functions.map(f=>[f.name.split('/').at(-1),()=>f.environment==='GEN_1'?functionIAM[f.name.split('/').at(-1)]:read('https://run.googleapis.com/v1/'+f.serviceConfig.service+':getIamPolicy')]));
 return c.p3b.safeMetadata({metadata,resources,functions,iam,functionIAM,runIAM,secrets,keys});
}
function protectedCheck(b,a,j){
 assert.equal(a.functions.length,25);for(const k of Object.keys(b.metadata).filter(k=>!['readAt','functions'].includes(k)))assert.deepEqual(c.p3b.metadataCore(k,a.metadata[k]),c.p3b.metadataCore(k,b.metadata[k]),'Protected metadata drift: '+k);
 for(const k of ['iam','functionIAM','runIAM','secrets','keys'])assert.deepEqual(a[k],b[k],'Protected '+k+' drift');
 for(const k of ['apis','serviceAccounts','scheduler'])assert.deepEqual(a.resources[k],b.resources[k],'Protected '+k+' drift');
 const ec=require('./audit_production_phase4_complete.cjs').eventarcCore;assert.deepEqual(a.resources.eventarc.data.triggers.map(ec),b.resources.eventarc.data.triggers.map(ec),'Eventarc drift');
 const qa=structuredClone(a.resources.queue),qb=structuredClone(b.resources.queue);assert.equal(qa.data.state,j.resumed?'RUNNING':j.paused?'PAUSED':'RUNNING');qa.data.state=qb.data.state;assert.deepEqual(qa,qb,'Queue configuration drift');
 for(const f of b.functions){const n=f.name.split('/').at(-1),cur=a.functions.find(x=>x.name===f.name);assert(cur);assert.deepEqual(cur,j.after[n]||f,'Unexpected Function drift: '+n);}
}
async function source(f,label){
 const n=f.name.split('/').at(-1),gen1=f.environment==='GEN_1',base='https://cloudfunctions.googleapis.com/'+(gen1?'v1/':'v2/');
 let body={};if(gen1){const old=await read(base+f.name);body={versionId:old.versionId};}
 const d=await read(base+f.name+':generateDownloadUrl','POST',body),u=new URL(d.downloadUrl);assert(u.protocol==='https:'&&(u.hostname==='storage.googleapis.com'||u.hostname.endsWith('.storage.googleapis.com'))&&!u.username&&!u.password&&!u.port);
 const {data:bytes}=await reads.read(u,{}, {bytes:true,sourceName:'recognition_'+n});assert(bytes.length<100*1024*1024);const file=path.join(DIR,'sources',label+'-'+n+'.zip');fs.mkdirSync(path.dirname(file),{recursive:true,mode:0o700});fs.writeFileSync(file,bytes,{mode:0o600});
 assert.deepEqual(await read(G+f.name),f,'Source changed during read: '+n);const files=p3.sourceManifest(file);return {files,sha256:hash(files),zipSha256:p.sha? p.sha(bytes):require('node:crypto').createHash('sha256').update(bytes).digest('hex')};
}
async function rawFunctions(){const a=(await read(c.cloud.urls.functions)).functions||[];assert.equal(a.length,25);return a;}
function policyChecks(s,live,expectedQueueState){
 p.cohort(live.filter(f=>p.FUNCTIONS.includes(f.name.split('/').at(-1))));assert.equal(s.resources.queue.data.state,expectedQueueState);assert(s.resources.scheduler.data.jobs?.length);assert(s.resources.scheduler.data.jobs.every(x=>x.state==='PAUSED'));
 for(const n of p.CALLABLES){const f=live.find(f=>f.name.endsWith('/'+n));assert.equal(f.serviceConfig.ingressSettings,'ALLOW_ALL');assert((s.runIAM[n].bindings||[]).some(b=>b.role==='roles/run.invoker'&&b.members.includes('allUsers')));}
 for(const n of ['aiProcessSource','aiReconcileInputs','aiRejectLateUpload'])assert(!(s.runIAM[n].bindings||[]).some(b=>b.members.some(v=>['allUsers','allAuthenticatedUsers'].includes(v))));
}
function queueStatsURL(){return Q.replace('/v2/','/v2beta3/')+'?readMask=name,state,stats';}
function assertQueueDrained(q){
 assert.equal(q.name,c.Q);assert.equal(q.state,'PAUSED');assert(q.stats&&typeof q.stats==='object','Queue stats required for worker drain');
 // Proto JSON omits scalar zero fields; an omitted count in present stats means zero.
 const count=Number(q.stats.concurrentDispatchesCount??0);assert(Number.isInteger(count)&&count>=0,'Invalid queue dispatch count');assert.equal(count,0,'In-flight task dispatches remain');
}
async function busy(){
 const q=await read(queueStatsURL());assertQueueDrained(q);
 // Read all sources without content: leases/status only. Refuse any active/expired nonterminal lease.
 // Use REST GETs with field masks; never an implicit Admin default or data mutation.
 let page,active=0,count=0;do{const url=`https://firestore.googleapis.com/v1/projects/${c.P}/databases/${c.DB}/documents/aiSources?pageSize=100&mask.fieldPaths=status&mask.fieldPaths=leaseToken&mask.fieldPaths=leaseUntil`+(page?'&pageToken='+encodeURIComponent(page):'');const v=await read(url,'GET',undefined,{boundedPage:true});for(const d of v.documents||[]){count++;const f=d.fields||{};if(['extracting','indexing'].includes(f.status?.stringValue)||f.leaseToken?.stringValue||Number(f.leaseUntil?.integerValue||f.leaseUntil?.doubleValue||0)>Date.now())active++;}page=v.nextPageToken;}while(page);
 assert.equal(active,0,'Active source leases remain; no deploy');save('drain',{at:new Date().toISOString(),concurrentDispatches:0,activeSourceLeases:0,scannedSources:count});return 0;
}
async function main(action,name){assert(['preflight','pause','update','audit','resume'].includes(action));if(action==='update')assert(p.FUNCTIONS.includes(name));else assert(!name);const a=artifact();
 fs.mkdirSync(DIR,{recursive:true,mode:0o700});let j=fs.existsSync(path.join(DIR,'execution.json'))?load('execution'):{status:'STARTED',attempts:[],updated:[],after:{},paused:false,resumed:false};assert(j.status!=='STOPPED','Prior stop requires explicit user review');const persist=()=>save('execution',j);
 async function mutation(url,method,body,kind){
 assert(!j.attempts.some(x=>x.kind===kind&&x.name===(name||null)),'Mutation replay forbidden');assert(method==='POST'||method==='PATCH');
 const allowed=kind==='pause'&&url===Q+':pause'||kind==='resume'&&url===Q+':resume'||kind==='staging'&&url===G+c.parent+'/functions:generateUploadUrl'||kind==='source'&&url===fn(name)+'?updateMask=buildConfig.source';assert(allowed,'Mutation outside allowlist');
 const ev={kind,name:name||null,at:new Date().toISOString(),status:'UNKNOWN'};j.attempts.push(ev);persist();const r=await fetch(url,{method,redirect:'error',headers:{Authorization:'Bearer '+await c.cloud.oauth(),'Content-Type':'application/json'},body:JSON.stringify(body),signal:AbortSignal.timeout(45000)});const d=await r.json().catch(()=>({}));ev.httpStatus=r.status;ev.status=r.ok?'CONFIRMED':'HTTP_ERROR';persist();assert(r.ok,kind+' HTTP '+r.status);return d;
 }
 try{
 if(action==='preflight'){
  assert(!fs.existsSync(path.join(DIR,'baseline.json')),'Fresh baseline must not overwrite evidence');const s=await snapshot(),raw=await rawFunctions();policyChecks(s,raw,'RUNNING');
  const priorFinal=JSON.parse(fs.readFileSync(path.join(PREVIOUS_DIR,'final-protected-audit.json'))),priorJournal=JSON.parse(fs.readFileSync(path.join(PREVIOUS_DIR,'execution.json')));assert(priorJournal.resumed);protectedCheck(priorFinal,s,{paused:false,resumed:true,after:{}});
  save('baseline',s);save('baseline-functions.private',raw);const co=p.cohort(raw.filter(f=>p.FUNCTIONS.includes(f.name.split('/').at(-1))));await pilotAuth(raw);
  const sources={};for(let i=0;i<raw.length;i+=3){const results=await Promise.allSettled(raw.slice(i,i+3).map(async f=>[f.name.split('/').at(-1),await source(f,'before')]));for(const r of results){if(r.status==='rejected')throw r.reason;sources[r.value[0]]=r.value[1];}console.log('Fresh full source '+Math.min(i+3,raw.length)+'/25');}
  for(const[n,x]of Object.entries(sources)){const old=path.join(PREVIOUS_DIR,'sources','final-'+n+'.zip');assert(fs.existsSync(old));assert.deepEqual(x.files,p3.sourceManifest(old),'Source drift since prior successful migration: '+n);}save('baseline-sources',sources);
  assert.deepEqual(await rawFunctions(),raw,'Functions changed during preflight');protectedCheck(s,await snapshot(),j);
  save('approval',{at:new Date().toISOString(),humanDeploymentApproved:true,originalQueueState:'RUNNING',functions:p.FUNCTIONS,manifestSha256:a.sourceManifestSha256,baselineHash:c.hash(s),cohort:co,sourceOnly:true,queuePauseAndResumeApproved:true,iamEnvSecretChangesApproved:false,phase5bAuthorized:false});
  execFileSync('python3',['-c','import os,zipfile,sys; root=sys.argv[1]; z=zipfile.ZipFile(sys.argv[2],"w",zipfile.ZIP_DEFLATED); [(z.write(os.path.join(d,n),os.path.relpath(os.path.join(d,n),root))) for d,_,ns in os.walk(root) for n in sorted(ns)];z.close()',PACKAGE,path.join(DIR,'candidate.zip')]);assert.deepEqual(p3.sourceManifest(path.join(DIR,'candidate.zip')),a.files);
  j.status='PREFLIGHT_PASS';persist();console.log('PREFLIGHT PASS: fresh 25 sources and protected state; pilot count '+co.allowedUIDCount+'; mutation=0');return;
 }
 const b=load('baseline'),approval=load('approval');assert.equal(approval.baselineHash,c.hash(b));assert.equal(approval.manifestSha256,a.sourceManifestSha256);assert.equal(approval.humanDeploymentApproved,true);
 if(action==='pause'){
  assert.equal(j.status,'PREFLIGHT_PASS');const fresh=await snapshot();protectedCheck(b,fresh,j);assert.equal(fresh.resources.queue.data.state,'RUNNING');await mutation(Q+':pause','POST',{},'pause');j.paused=true;persist();assert.equal((await read(Q)).state,'PAUSED');await new Promise(r=>setTimeout(r,15000));await busy();const archive=path.join(DIR,'before','pre-pause-review');assert(!fs.existsSync(archive));fs.renameSync(v.DIR,archive);const pausedReview=v.prepare();assert.equal(pausedReview.sourceManifestSha256,a.sourceManifestSha256);save('paused-artifact',{at:new Date().toISOString(),manifestSha256:pausedReview.sourceManifestSha256});j.status='QUEUE_PAUSED_DRAINED';persist();console.log('Queue PAUSED, concurrent dispatches=0 and active source leases=0');return;
 }
 if(action==='update'){
  assert(j.paused&&!j.resumed);assert.equal(p.ORDER[j.updated.length],name);const start=Date.now(),s=await snapshot();protectedCheck(b,s,j);const raw=await rawFunctions();p.cohort(raw.filter(f=>p.FUNCTIONS.includes(f.name.split('/').at(-1))));await busy();
  const before=await read(fn(name));assert.deepEqual(c.p3b.safeMetadata(before),b.functions.find(f=>f.name===before.name));assert.deepEqual((await source(before,'immediate')).files,load('baseline-sources')[name].files);
  const issued=await mutation(G+c.parent+'/functions:generateUploadUrl','POST',{},'staging');const u=new URL(issued.uploadUrl);assert(u.protocol==='https:'&&u.hostname==='storage.googleapis.com'&&!u.username&&!u.password&&!u.port);assert(issued.storageSource.bucket.includes(c.N)&&issued.storageSource.bucket.includes(c.R));assert(decodeURIComponent(u.pathname).startsWith('/'+issued.storageSource.bucket+'/'));const bytes=fs.readFileSync(path.join(DIR,'candidate.zip'));
  const up={kind:'upload',name,at:new Date().toISOString(),status:'UNKNOWN'};j.attempts.push(up);persist();const r=await fetch(u,{method:'PUT',redirect:'error',headers:{'Content-Type':'application/zip'},body:bytes,signal:AbortSignal.timeout(45000)});up.httpStatus=r.status;up.status=r.ok?'CONFIRMED':'HTTP_ERROR';persist();assert(r.ok,'Gen2 source upload HTTP '+r.status);
  const url=fn(name)+'?updateMask=buildConfig.source',body={name:before.name,buildConfig:{source:{storageSource:issued.storageSource}}};p.validateSourcePatch(url,'PATCH',body,{approved:true,baselineAgeSeconds:(Date.now()-start)/1000,queuePaused:true,inflightWorkers:0,schedulerPaused:true,phase5bAuthorized:false,identity:p.TARGET,functions:p.FUNCTIONS,liveFunctions:raw.filter(f=>p.FUNCTIONS.includes(f.name.split('/').at(-1))),name,before,freshStorageSource:issued.storageSource,stagingUploaded:true,issuedStorageSourceHash:hash(issued.storageSource),approvedSourceManifestSha256:a.sourceManifestSha256,actualSourceManifestSha256:hash(p3.sourceManifest(path.join(DIR,'candidate.zip')))});
  assert.deepEqual(await read(fn(name)),before,'Target drift before PATCH');const op=await mutation(url,'PATCH',body,'source');assert(op.name.startsWith(c.parent+'/operations/'));let complete=false;
  for(let i=0;i<240;i++){const v=await read(G+op.name);save(name+'-operation',c.p3b.safeMetadata(v));if(v.done){assert(!v.error,'Source operation failed code '+v.error?.code);complete=true;break;}if(i%6===0)console.log(name+': build pending');await new Promise(r=>setTimeout(r,5000));}assert(complete,'Operation timeout; no PATCH retry');
  const after=await read(fn(name)),installed=await source(after,'installed');p.postCheck(before,after,installed.files,a.files);j.updated.push(name);j.after[name]=c.p3b.safeMetadata(after);save(name+'-proof',{beforeRevision:before.serviceConfig.revision,afterRevision:after.serviceConfig.revision,beforeUpdateTime:before.updateTime,afterUpdateTime:after.updateTime,beforeManifest:load('baseline-sources')[name].sha256,afterManifest:installed.sha256,sourceVerified:true,envUnchanged:true});persist();const latest=await snapshot();protectedCheck(b,latest,j);j.status='VERIFIED_'+name;persist();console.log(name+': source/runtime/env/IAM/protected state PASS ('+j.updated.length+'/10)');return;
 }
 assert.deepEqual(j.updated,p.ORDER);const s=await snapshot();protectedCheck(b,s,j);const raw=await rawFunctions();p.cohort(raw.filter(f=>p.FUNCTIONS.includes(f.name.split('/').at(-1))));
 for(const f of raw){const n=f.name.split('/').at(-1),v=await source(f,'final');assert.deepEqual(v.files,p.FUNCTIONS.includes(n)?a.files:load('baseline-sources')[n].files,'Final source mismatch '+n);}
 if(action==='audit'){assert(!j.resumed);j.status='COHORT_AUDIT_PASS';save('cohort-audit',s);persist();console.log('10/10 ACTIVE full-source cohort and other15 unchanged; queue PAUSED, Scheduler PAUSED, sharing OFF');return;}
 assert.equal(j.status,'COHORT_AUDIT_PASS');assert(!j.resumed);const gates=load('auth-gates');assert.equal(gates.status,'PASS');assert.equal(gates.checks.length,27);const domain=load('installed-nonpilot-domain-gates');assert.equal(domain.status,'PASS');assert.equal(domain.count,9);assert.equal(domain.exactProductionEnvironment,true);assert.equal(domain.sourceManifestVerifiedForAllTen,true);await mutation(Q+':resume','POST',{},'resume');j.resumed=true;persist();assert.equal((await read(Q)).state,'RUNNING');const final=await snapshot();protectedCheck(b,final,j);save('resumed-audit',final);j.status='DEPLOY_COMPLETE_E2E_PENDING';persist();console.log('Queue RUNNING restored; ten sources verified, protected state unchanged');
 }catch(e){j.status='STOPPED';j.safeError=/^[A-Za-z0-9 :_./()=-]{1,200}$/.test(e.message)?e.message:e.name;j.partialSuccess=j.attempts.some(x=>['source','pause','resume'].includes(x.kind)&&['CONFIRMED','UNKNOWN'].includes(x.status));persist();console.error('SAFE STOP: '+j.safeError+'; mutations are not retried, queue is not auto-restored');process.exitCode=1;}
}
module.exports={PREVIOUS_DIR,DIR,read,source,load,save,protectedCheck,artifact,pilotAuth,rawFunctions,snapshot,queueStatsURL,assertQueueDrained};if(require.main===module)main(...process.argv.slice(2)).catch(e=>{console.error('SAFE STOP '+e.name);process.exitCode=1});
