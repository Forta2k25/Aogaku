#!/usr/bin/env node
// Read-only final audit. Never clears or resumes the stopped mutation journal.
// The approved Storage trigger creates one notification and advances bucket
// metageneration; accept precisely that verified side effect, no settings drift.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto'),{execFileSync}=require('node:child_process');
const phase=require('./deploy_production_phase4_completion.cjs'),cloud=require('./production_cloud_phase4_retry.cjs'),reads=require('./production_read_retry.cjs'),p1=require('./provision_production_phase1.cjs'),p3a=require('./deploy_production_phase3a.cjs'),p3b=require('./deploy_production_phase3b.cjs');
const ROOT=path.resolve(__dirname,'..'),INPUT=path.join(ROOT,'build/production-phase4-completion'),DIR=path.join(ROOT,'build/production-phase4-completion-audit-final');
const P='forta-aogaku',R='asia-northeast1',B=P+'.firebasestorage.app',SA='aogaku-ai-runtime@'+P+'.iam.gserviceaccount.com',G='https://cloudfunctions.googleapis.com/v2/';
const {hash,sourceManifest}=p3a,load=n=>JSON.parse(fs.readFileSync(path.join(INPUT,n+'.json')));
function eventarcCore(trigger){return {...trigger,eventFilters:[...trigger.eventFilters].sort((a,b)=>a.attribute.localeCompare(b.attribute)||a.value.localeCompare(b.value))};}
function notificationBoundary(before,after,f,trigger,notifications){
 assert.equal(before.name,B);assert.equal(after.name,B);assert.equal(before.location,'US-CENTRAL1');
 assert.equal(BigInt(after.metageneration),BigInt(before.metageneration)+1n,'Unexpected bucket metadata generation delta');
 const stable=x=>Object.fromEntries(Object.entries(x).filter(([k])=>k!=='metageneration'));
 assert.deepEqual(stable(after),stable(before),'Bucket settings drift');
 assert.equal(f.name,`projects/${P}/locations/${R}/functions/aiRejectLateUpload`);
 assert.equal(trigger.name,f.eventTrigger.trigger);assert(trigger.name.startsWith(`projects/${P}/locations/us-central1/triggers/airejectlateupload-`));
 assert.equal(trigger.serviceAccount,SA);assert.equal(trigger.labels?.['goog-managed-by'],'cloudfunctions');
 assert.deepEqual([...trigger.eventFilters].sort((a,b)=>a.attribute.localeCompare(b.attribute)),[{attribute:'bucket',value:B},{attribute:'type',value:'google.cloud.storage.object.v1.finalized'}]);
 if(trigger.destination.cloudFunction)assert.deepEqual(trigger.destination,{cloudFunction:f.name});
 else assert.deepEqual(trigger.destination,{cloudRun:{service:f.serviceConfig.service.split('/').pop(),region:R}});
 assert(!Object.values(trigger.conditions||{}).some(c=>c.code&&c.code!=='OK'));
 assert.equal(trigger.transport.pubsub.topic,f.eventTrigger.pubsubTopic);
 assert.equal(notifications.items?.length,1,'Unexpected notification inventory');assert(!notifications.nextPageToken);
 const n=notifications.items[0],triggerId=trigger.name.split('/').pop();
 assert.equal(n.id,`eventarc-${P}-us-central1-${triggerId}`);
 assert.equal(n.topic,'//pubsub.googleapis.com/'+trigger.transport.pubsub.topic);
 assert.equal(n.payload_format,'JSON_API_V1');assert.deepEqual(n.event_types,['OBJECT_FINALIZE']);
 assert(!n.object_name_prefix&&!n.custom_attributes,'Unexpected notification filter/attributes');
 return {classification:'APPROVED_EVENTARC_NOTIFICATION_SIDE_EFFECT',before:before.metageneration,after:after.metageneration,notificationId:n.id,topic:trigger.transport.pubsub.topic,settingsUnchanged:true,destination:trigger.destination,documentation:'https://docs.cloud.google.com/storage/docs/pubsub-notifications'};
}
function protectedWithNotification(baseline,current,f,trigger,notifications){
 const proof=notificationBoundary(baseline.metadata.bucket,current.metadata.bucket,f,trigger,notifications);
 const policyCore=x=>Object.fromEntries(Object.entries(x).filter(([k])=>k!=='etag'));
 assert.deepEqual(policyCore(current.iam.bucket),policyCore(baseline.iam.bucket),'Bucket IAM binding/condition/version drift');
 // Exact observed validators for this preserved 3 -> 4 notification transition.
 // No IAM membership, condition, version, resource or other field may differ.
 assert.equal(baseline.metadata.bucket.metageneration,'3');assert.equal(current.metadata.bucket.metageneration,'4');
 assert.equal(baseline.iam.bucket.etag,'CAM=');assert.equal(current.iam.bucket.etag,'CAQ=');
 proof.bucketIAM={bindingsUnchanged:true,beforeEtag:baseline.iam.bucket.etag,afterEtag:current.iam.bucket.etag};
 // Comparison-only copy; raw original baseline and STOPPED journal stay intact.
 const compared=structuredClone(current);compared.metadata.bucket.metageneration=baseline.metadata.bucket.metageneration;compared.iam.bucket.etag=baseline.iam.bucket.etag;
 phase.protectedSame(baseline,compared,phase.NAMES,true);return proof;
}
async function main(){
 fs.mkdirSync(DIR,{recursive:true,mode:0o700});fs.chmodSync(DIR,0o700);
 const save=(n,x)=>{const f=path.join(DIR,n+'.json');fs.writeFileSync(f,JSON.stringify(p3b.safeMetadata(x),null,2)+'\n',{mode:0o600});fs.chmodSync(f,0o600);};
 const journalBytes=fs.readFileSync(path.join(INPUT,'execution.json')),baselineBytes=fs.readFileSync(path.join(INPUT,'baseline.json'));
 const journal=load('execution'),baseline=load('baseline'),artifact=load('artifact'),approval=load('approval');
 assert.equal(journal.status,'STOPPED');assert.deepEqual(journal.created,phase.NAMES);assert(journal.workerIAMVerified);
 assert(journal.error.includes('protected metadata drift bucket'));assert(journal.attempts.every(x=>x.status==='CONFIRMED'));
 for(const n of phase.NAMES){const op=load(n+'-operation');assert(op.done&&!op.error);assert.deepEqual(journal.verified[n].files,artifact.files);}
 assert.equal(artifact.sourceSha256,'34ef21c5a5f3816693809465c1e79ef2a762119db9686e3ed186130a146cf0a8');
 assert.equal(artifact.sourceSha256,hash(sourceManifest(path.join(INPUT,'candidate.zip'))));
 assert.equal(artifact.wrapperSha256,crypto.createHash('sha256').update(fs.readFileSync(path.join(ROOT,'scripts/deploy_production_phase4_completion.cjs'))).digest('hex'));
 assert.equal(approval.baselineSha256,hash(baseline));assert.equal(approval.artifactSha256,artifact.sourceSha256);
 for(const [f,h]of Object.entries(artifact.dependencies))assert.equal(crypto.createHash('sha256').update(fs.readFileSync(path.join(ROOT,f))).digest('hex'),h);
 execFileSync('python3',['scripts/firebase_production.py','check','--project',P],{cwd:ROOT,stdio:'pipe'});
 const exact=new Set([cloud.urls.functions,G+`projects/${P}/locations/${R}/functions/aiProcessSource:getIamPolicy?options.requestedPolicyVersion=3`,`https://storage.googleapis.com/storage/v1/b/${B}/notificationConfigs`,...Object.values(p1.policies).map(p=>p.get)]);
 async function request(url,method='GET',body){
  assert(exact.has(url),'Read not allowlisted');reads.assertRead(url,method,body===undefined?undefined:JSON.stringify(body));
  const {data}=await reads.read(url,{method,headers:{Authorization:'Bearer '+await cloud.oauth(),'Content-Type':'application/json'},...(body===undefined?{}:{body:JSON.stringify(body)})});assert(!data.nextPageToken);return data;
 }
 const legacy=baseline.functions.filter(f=>!phase.EXISTING_TEN.includes(f.name.split('/').pop())).map(f=>f.name.split('/').pop());assert.equal(legacy.length,13);
 async function snapshot(){
  const metadata=await cloud.inspect();execFileSync('python3',['-c','import sys;sys.path.insert(0,"scripts");import firebase_production as p;s=p.load("build/production-live.json");p.live_check(s);p.require_named_ready(s,True,True)'],{cwd:ROOT,stdio:'pipe'});
  await cloud.resourcesMetadata();const resources=JSON.parse(fs.readFileSync(path.join(ROOT,'build/production-resources-live.json'))).records;assert(Object.values(resources).every(x=>x.httpStatus===200));
  const functions=(await request(cloud.urls.functions)).functions||[],iam={},keys={},secrets={};
  for(const [k,p]of Object.entries(p1.policies))iam[k]=await request(p.get,p.getMethod||'GET',p.getMethod==='POST'?{options:{requestedPolicyVersion:3}}:undefined);
  for(const s of ['GROQ_API_KEY','OPENAI_API_KEY','IMPORT_API_KEY']){const base=`https://secretmanager.googleapis.com/v1/projects/${P}/secrets/${s}`;for(const u of [base,base+'/versions?pageSize=100',base+':getIamPolicy?options.requestedPolicyVersion=3'])exact.add(u);secrets[s]={metadata:await request(base),versions:await request(base+'/versions?pageSize=100')};iam[s]=await request(base+':getIamPolicy?options.requestedPolicyVersion=3');}
  for(const f of functions.filter(f=>legacy.includes(f.name.split('/').pop())||phase.EXISTING_TEN.includes(f.name.split('/').pop()))){const url=f.environment==='GEN_1'?'https://cloudfunctions.googleapis.com/v1/'+f.name+':getIamPolicy':'https://run.googleapis.com/v1/'+f.serviceConfig.service+':getIamPolicy';exact.add(url);iam[f.name.split('/').pop()]=await request(url);}
  iam.aiProcessSourceFunctionIAM=await request(G+`projects/${P}/locations/${R}/functions/aiProcessSource:getIamPolicy?options.requestedPolicyVersion=3`);
  for(const sa of [SA,`aogaku-ai-account-deletion@${P}.iam.gserviceaccount.com`]){const u=`https://iam.googleapis.com/v1/projects/${P}/serviceAccounts/${sa}/keys?keyTypes=USER_MANAGED`;exact.add(u);keys[sa]=await request(u);assert(!(keys[sa].keys||[]).length);}
  return p3b.safeMetadata({metadata,resources,functions,iam,keys,secrets});
 }
 const before=await snapshot();save('fresh-before',before);assert.equal(before.functions.length,25);
 const storageFunction=before.functions.find(f=>f.name.endsWith('/aiRejectLateUpload')),eventURL='https://eventarc.googleapis.com/v1/'+storageFunction.eventTrigger.trigger;exact.add(eventURL);
 const trigger=await request(eventURL),notifications=await request(`https://storage.googleapis.com/storage/v1/b/${B}/notificationConfigs`);
 const sideEffect=protectedWithNotification(baseline,before,storageFunction,trigger,notifications);save('notification-proof',sideEffect);save('eventarc',trigger);save('notifications',notifications);
 const proof={status:'STARTED',phase:4,cloudMutations:0,authFixturesCreated:0,functions:{},legacyFunctionsUnchanged:[],anonymousProbes:[],notificationSideEffect:sideEffect,queueState:before.resources.queue.data.state,phase5Authorized:false};
 const oldSources=load('legacy-sources');
 for(const f of before.functions){
  const n=f.name.split('/').pop(),base=f.environment==='GEN_1'?'https://cloudfunctions.googleapis.com/v1/':G,metaURL=base+f.name;exact.add(metaURL);const full=f.environment==='GEN_1'?await request(metaURL):f;
  const downloadURL=base+f.name+':generateDownloadUrl';exact.add(downloadURL);const d=await request(downloadURL,'POST',f.environment==='GEN_1'?{versionId:full.versionId}:{}),u=new URL(d.downloadUrl);assert(u.protocol==='https:'&&(u.hostname==='storage.googleapis.com'||u.hostname.endsWith('.storage.googleapis.com'))&&!u.username&&!u.password&&!u.port);
  const {data:bytes}=await reads.read(u,{}, {bytes:true,sourceName:n});assert(bytes.length<=100*1024*1024);const zip=path.join(DIR,n+'-source.zip');fs.writeFileSync(zip,bytes,{mode:0o600});const files=sourceManifest(zip),sourceSha256=hash(files);
  const currentURL=G+f.name;exact.add(currentURL);const current=await request(currentURL);assert.deepEqual(p3b.safeMetadata(current),f,'Function changed during source audit');
  if(!phase.ALL_NAMES.includes(n)){assert.deepEqual({sourceSha256,files,updateTime:f.updateTime},oldSources[n]);proof.legacyFunctionsUnchanged.push(n);save('closed-live',proof);console.log(n+': legacy full source/metadata unchanged PASS');continue;}
  assert.deepEqual(files,artifact.files);assert.equal(current.state,'ACTIVE');assert.equal(current.environment,'GEN_2');assert.equal(current.buildConfig.runtime,'nodejs22');assert.equal(current.buildConfig.entryPoint,n);assert.equal(current.serviceConfig.serviceAccountEmail,SA);assert.equal(current.labels['firebase-functions-codebase'],'aogaku-ai');
  for(const [k,v]of Object.entries(phase.env()))assert.equal(current.serviceConfig.environmentVariables[k],v);assert(!(current.serviceConfig.secretEnvironmentVariables||[]).length);
  const expected=phase.payload(n,{bucket:'CHECK_ONLY',object:'CHECK_ONLY'}).serviceConfig;for(const k of ['availableMemory','availableCpu','timeoutSeconds','maxInstanceCount','maxInstanceRequestConcurrency'])assert.equal(current.serviceConfig[k],expected[k]);assert.equal(current.serviceConfig.minInstanceCount||0,expected.minInstanceCount||0);
  assert(current.name.startsWith(`projects/${P}/locations/${R}/functions/`));
  if(n==='aiRejectLateUpload'){assert.equal(current.eventTrigger.triggerRegion,'us-central1');assert.equal(current.eventTrigger.eventType,'google.cloud.storage.object.v1.finalized');assert.deepEqual(current.eventTrigger.eventFilters,[{attribute:'bucket',value:B}]);assert.equal(current.eventTrigger.serviceAccountEmail,SA);}else assert(!current.eventTrigger);
  const runURL='https://run.googleapis.com/v1/'+current.serviceConfig.service;exact.add(runURL);exact.add(runURL+':getIamPolicy');const run=await request(runURL),iam=await request(runURL+':getIamPolicy');assert(run.metadata?.annotations?.['run.googleapis.com/invoker-iam-disabled']!=='true');assert(!(iam.bindings||[]).some(b=>b.members.some(m=>['allUsers','allAuthenticatedUsers'].includes(m))));
  if(phase.NAMES.includes(n))assert.deepEqual(iam,load(n+'-run-iam').after,'New resource IAM changed');
  if(['aiProcessSource',...phase.NAMES].includes(n))assert((iam.bindings||[]).some(b=>b.role==='roles/run.invoker'&&b.members.includes('serviceAccount:'+SA)));
  proof.functions[n]={state:'ACTIVE',runtime:'nodejs22',region:R,serviceAccount:SA,sourceSha256,updateTime:current.updateTime,databaseId:'aogaku-ai',allowedUIDs:[],sharing:false,publicInvoker:false,trigger:n==='aiRejectLateUpload'?'Storage finalized / Eventarc':n==='aiReconcileInputs'?'Scheduler HTTPS':n==='aiProcessSource'?'Tasks HTTPS':'Callable HTTPS'};
  for(const endpoint of [current.serviceConfig.uri,`https://${R}-${P}.cloudfunctions.net/${n}`]){const {response}=await reads.read(endpoint,{}, {discard:true,allowStatuses:[401,403]});assert([401,403].includes(response.status));proof.anonymousProbes.push({function:n,endpointType:endpoint===current.serviceConfig.uri?'Cloud Run':'cloudfunctions.net',method:'GET',httpStatus:response.status,denied:true});}
  save('closed-live',proof);console.log(n+': ACTIVE/full manifest/private/empty cohort/anonymous denied PASS');
 }
 const after=await snapshot();save('fresh-after',after);const afterF=after.functions.find(f=>f.name===storageFunction.name),afterTrigger=await request(eventURL),afterNotifications=await request(`https://storage.googleapis.com/storage/v1/b/${B}/notificationConfigs`);protectedWithNotification(baseline,after,afterF,afterTrigger,afterNotifications);
 for(const f of before.functions)assert.deepEqual(after.functions.find(x=>x.name===f.name),f,'Function changed during final audit');assert.deepEqual(eventarcCore(afterTrigger),eventarcCore(trigger));assert.deepEqual(afterNotifications,notifications);
 assert.equal(after.resources.queue.data.state,'PAUSED');const jobs=after.resources.scheduler.data.jobs;assert.equal(jobs.length,1);const job=jobs[0];assert.equal(job.name,phase.JOB);assert.equal(job.state,'PAUSED');assert(!job.lastAttemptTime);assert.equal(job.schedule,'every 15 minutes');assert.equal(job.httpTarget.oidcToken.serviceAccountEmail,SA);const scheduled=after.functions.find(f=>f.name.endsWith('/aiReconcileInputs'));assert.equal(job.httpTarget.uri.replace(/\/$/,''),scheduled.serviceConfig.uri.replace(/\/$/,''));assert.equal(job.httpTarget.oidcToken.audience,scheduled.serviceConfig.uri);
 assert.equal(Object.keys(proof.functions).length,12);assert.equal(proof.legacyFunctionsUnchanged.length,13);assert.equal(proof.anonymousProbes.length,24);
 assert.deepEqual(fs.readFileSync(path.join(INPUT,'execution.json')),journalBytes);assert.deepEqual(fs.readFileSync(path.join(INPUT,'baseline.json')),baselineBytes);
 proof.status='PHASE4_COMPLETE';proof.schedulerState='PAUSED';proof.schedulerLastAttemptTime=null;proof.protectedResourcesUnchanged=true;proof.unexpectedDrift=false;proof.stoppedJournalPreserved=true;proof.phase4Blockers=[];proof.phase5ReadinessBlockers=[];proof.phase5Conditions=['Separate approval','One confirmed internal UID in private config','Separately approved nine callable HTTP IAM ingress plus mandatory Firebase Auth/one UID','Separately approved queue and Scheduler resume','Deferred deletion/admission, delayed-worker and late-upload production E2E'];proof.completedAt=new Date().toISOString();save('closed-live',proof);
 console.log('PHASE4_COMPLETE: 12 ACTIVE; 24 anonymous denials; all13 legacy/protected settings unchanged. Approved Eventarc notification metadata effect verified; STOPPED journal preserved. No further production mutation; no Phase5.');
}
module.exports={notificationBoundary,protectedWithNotification,eventarcCore};
if(require.main===module)main().catch(e=>{fs.mkdirSync(DIR,{recursive:true,mode:0o700});fs.writeFileSync(path.join(DIR,'audit-error.json'),JSON.stringify({status:'AUDIT_FAILED',error:e.message,cloudMutations:0})+'\n',{mode:0o600});console.error(e.message);process.exitCode=1;});
