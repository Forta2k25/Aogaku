#!/usr/bin/env node
// Phase 5a only: ten environment-only PATCHes, nine Run public invoker bindings,
// and one queue resume, gated by three-way live Auth rejection tests. No deploy.
const fs=require('node:fs'),assert=require('node:assert/strict'),path=require('node:path');
const c=require('./production_phase5a_common.cjs'),p3a=require('./deploy_production_phase3a.cjs'),reads=require('./production_read_retry.cjs'),revisionGuard=require('./production_phase5a_revision_guard.cjs');
function validate(url,method,body,ctx){
 const pilot=ctx.pilot,fn=ctx.name;assert.equal(pilot.length,1);assert(/^[A-Za-z0-9_-]{1,128}$/.test(pilot[0]));
 if(method==='PATCH'&&ctx.action==='configure'){
  assert(c.CONFIGURED.includes(fn));assert.equal(url,c.G+c.parent+'/functions/'+fn+'?updateMask=serviceConfig.environmentVariables');
  const wanted={...ctx.before.serviceConfig.environmentVariables,AI_INPUT_ALLOWED_UIDS:JSON.stringify(pilot)};
  assert.equal(wanted.AI_SHARING_ENABLED,'false');assert.equal(wanted.AI_FIRESTORE_DATABASE_ID,c.DB);
  assert.deepEqual(body,{name:ctx.before.name,serviceConfig:{environmentVariables:wanted}});return;
 }
 if(method==='POST'&&ctx.action==='public'){
  assert(c.CALLABLES.includes(fn));assert.equal(url,'https://run.googleapis.com/v1/'+ctx.before.serviceConfig.service+':setIamPolicy');assert(ctx.policy.etag);
  assert.deepEqual(body,{policy:c.p1.merge(ctx.policy,[{member:'allUsers',roles:['roles/run.invoker']}] )});return;
 }
 if(method==='POST'&&ctx.action==='resume'){assert.equal(url,'https://cloudtasks.googleapis.com/v2/'+c.Q+':resume');assert.deepEqual(body,{});assert(ctx.gatesPassed);return;}
 throw Error('STOP: outside Phase 5a exact mutation allowlist');
}
async function main(action,name){
 assert(['baseline','configure','public','gates','resume','audit'].includes(action));if(['configure','public'].includes(action))assert(name);else assert(!name);
 assert.equal(c.load('preflight/closed-live').status,'PHASE5A_PREFLIGHT_PASS');
 let j=fs.existsSync(path.join(c.DIR,'execution.json'))?c.load('execution'):{status:'STARTED',configured:[],public:[],configProof:{},attempts:[],queueResumed:false};assert(j.status!=='STOPPED');
 const persist=()=>c.save('execution',j),pilot=c.operator().allowedUIDs;
 async function mutation(url,method,body,ctx){validate(url,method,body,{...ctx,action,name,pilot});assert(!j.attempts.some(x=>x.resource===url&&x.method===method),'STOP: mutation cannot be replayed');const attempt={resource:url,method,bodySha256:c.hash(body),status:'UNKNOWN',at:new Date().toISOString()};j.attempts.push(attempt);persist();const r=await fetch(url,{method,redirect:'error',headers:{Authorization:'Bearer '+await c.cloud.oauth(),'Content-Type':'application/json'},body:JSON.stringify(body),signal:AbortSignal.timeout(45000)});const d=await r.json().catch(()=>({}));if(!r.ok){attempt.status='HTTP_ERROR';attempt.httpStatus=r.status;persist();throw Error('Mutation HTTP '+r.status);}attempt.status='CONFIRMED';persist();return d;}
 async function operation(d){assert(d.name.startsWith(c.parent+'/operations/'));for(let i=0;i<180;i++){const x=await c.read(c.G+d.name);c.save(name+'-operation',x);if(x.done){assert(!x.error,'STOP: config operation failed '+(x.error?.code||''));return;}if(i%6===0)console.log(name+': environment-only revision pending');await new Promise(r=>setTimeout(r,5000));}throw Error('STOP: operation timeout; no mutation replay');}
 const getfn=n=>c.read(c.G+c.parent+'/functions/'+n);
 async function installedSource(after){
  const d=await c.read(c.G+after.name+':generateDownloadUrl','POST',{}),u=new URL(d.downloadUrl);assert(u.protocol==='https:'&&(u.hostname==='storage.googleapis.com'||u.hostname.endsWith('.storage.googleapis.com'))&&!u.username&&!u.password&&!u.port);
  const {data:bytes}=await reads.read(u,{}, {bytes:true,sourceName:'phase5a_revision_'+name});assert(bytes.length<=100*1024*1024);const dir=path.join(c.DIR,'config-source');fs.mkdirSync(dir,{recursive:true,mode:0o700});const zip=path.join(dir,name+'.zip');fs.writeFileSync(zip,bytes,{mode:0o600});
  const files=p3a.sourceManifest(zip);assert.deepEqual(files,p3a.sourceManifest(path.join(c.DIR,'preflight',name+'-source.zip')));assert.equal(p3a.hash(files),c.SHA);assert.deepEqual(await getfn(name),after,'Function changed during installed-source verification');c.save('config-source/'+name,{files,sourceSha256:p3a.hash(files),fullManifestUnchanged:true});return p3a.hash(files);
 }
 try{
  if(action==='baseline'){
   assert(!fs.existsSync(path.join(c.DIR,'baseline.json')));const a=await c.snapshot(),previous=c.load('preflight/fresh-after');assert.equal(a.functions.length,25);
   for(const k of Object.keys(previous.metadata).filter(k=>!['readAt','functions'].includes(k)))assert.deepEqual(c.p3b.metadataCore(k,a.metadata[k]),c.p3b.metadataCore(k,previous.metadata[k]));assert.deepEqual([...a.functions].sort((x,y)=>x.name.localeCompare(y.name)),[...previous.functions].sort((x,y)=>x.name.localeCompare(y.name)));
   for(const k of Object.keys(previous.resources).filter(k=>k!=='eventarc'))assert.deepEqual(a.resources[k],previous.resources[k]);const core=require('./audit_production_phase4_complete.cjs').eventarcCore;assert.deepEqual(a.resources.eventarc.data.triggers.map(core),previous.resources.eventarc.data.triggers.map(core));
   for(const [k,v]of Object.entries(previous.iam)){const actual=k==='aiProcessSourceFunctionIAM'?a.functionIAM.aiProcessSource:(a.iam[k]||a.runIAM[k]);assert.deepEqual(actual,v);}
   for(const n of c.ALL){const f=await getfn(n);assert.equal(f.serviceConfig.environmentVariables.AI_INPUT_ALLOWED_UIDS,'[]');assert.equal(f.serviceConfig.environmentVariables.AI_SHARING_ENABLED,'false');assert.equal(f.serviceConfig.environmentVariables.AI_FIRESTORE_DATABASE_ID,c.DB);assert(!(a.runIAM[n].bindings||[]).some(b=>b.members.some(m=>['allUsers','allAuthenticatedUsers'].includes(m))));if(c.CALLABLES.includes(n))assert.equal(f.serviceConfig.ingressSettings,'ALLOW_ALL');}
   for(const n of ['aiReconcileInputs','aiRejectLateUpload'])assert.deepEqual(a.runIAM[n],JSON.parse(fs.readFileSync(path.join(c.ROOT,'build/production-phase4-completion/'+n+'-run-iam.json'))).after);
   assert.equal(a.resources.queue.data.state,'PAUSED');assert(a.resources.scheduler.data.jobs.every(x=>x.state==='PAUSED'&&!x.lastAttemptTime));c.save('baseline',a);c.save('approval',{phase:'5a',at:new Date().toISOString(),baselineSha256:c.hash(a),sourceSha256:c.SHA,allowedUIDCount:1,allowedUIDHash:c.hash(pilot[0]),configuredFunctions:c.CONFIGURED,publicCallableFunctions:c.CALLABLES,workerSchedulerEventarcPrivate:true,sourceUpdatesAuthorized:false,schedulerResumeAuthorized:false,phase5bAuthorized:false});j.status='BASELINE_PASS';persist();console.log('Fresh 25 Functions + all Function/Run IAM + closed protected-state baseline PASS; no production mutation');return;
  }
  const baseline=c.load('baseline');assert.equal(c.load('approval').baselineSha256,c.hash(baseline));assert.equal(c.load('approval').allowedUIDHash,c.hash(pilot[0]));
  const approval=c.load('approval');if(approval.wrapperSha256){assert.equal(require('node:crypto').createHash('sha256').update(fs.readFileSync(__filename)).digest('hex'),approval.wrapperSha256);for(const [file,sha]of Object.entries(approval.dependencies))assert.equal(require('node:crypto').createHash('sha256').update(fs.readFileSync(path.join(c.ROOT,file))).digest('hex'),sha);}
  if(action==='configure'){
   await c.auth('pilot');assert.equal(c.CONFIGURED[j.configured.length],name);assert(!j.configured.includes(name));
   const before=await getfn(name);assert.deepEqual(c.p3b.safeMetadata(before),baseline.functions.find(f=>f.name===before.name));assert.equal(before.serviceConfig.environmentVariables.AI_INPUT_ALLOWED_UIDS,'[]');
   const env={...before.serviceConfig.environmentVariables,AI_INPUT_ALLOWED_UIDS:JSON.stringify(pilot)},body={name:before.name,serviceConfig:{environmentVariables:env}};
   await operation(await mutation(c.G+before.name+'?updateMask=serviceConfig.environmentVariables','PATCH',body,{before}));const after=await getfn(name);const revision=revisionGuard.assertRevision(before,after,env,await installedSource(after));
   assert.deepEqual(await c.read('https://run.googleapis.com/v1/'+before.serviceConfig.service+':getIamPolicy'),baseline.runIAM[name]);assert.deepEqual(await c.read(c.G+before.name+':getIamPolicy?options.requestedPolicyVersion=3'),baseline.functionIAM[name]);
   j.configured.push(name);j.configProof[name]={updateTime:after.updateTime,environmentSha256:c.metadataHash(after.serviceConfig.environmentVariables),...revision};j.status='CONFIGURED_PRIVATE';persist();console.log(name+': one approved UID / named DB / sharing OFF / installed source/private IAM unchanged PASS');return;
  }
  if(action==='public'){
   assert.deepEqual(j.configured,c.CONFIGURED);assert.equal(c.CALLABLES[j.public.length],name);const before=await getfn(name);assert.equal(before.serviceConfig.environmentVariables.AI_INPUT_ALLOWED_UIDS,JSON.stringify(pilot));assert.equal(before.serviceConfig.environmentVariables.AI_SHARING_ENABLED,'false');assert.equal(before.serviceConfig.ingressSettings,'ALLOW_ALL');
   const url='https://run.googleapis.com/v1/'+before.serviceConfig.service,policy=await c.read(url+':getIamPolicy');assert.deepEqual(policy,baseline.runIAM[name]);const desired=c.p1.merge(policy,[{member:'allUsers',roles:['roles/run.invoker']}]);await mutation(url+':setIamPolicy','POST',{policy:desired},{before,policy});const after=await c.read(url+':getIamPolicy');c.p1.preserved(policy,after);assert.deepEqual(c.p1.policyCore(after),c.p1.policyCore(desired));assert.deepEqual(await getfn(name),before,'STOP: Run IAM changed Function metadata');c.save(name+'-public-iam',{resource:url,before:policy,after,scope:'one approved Callable Run service'});j.public.push(name);j.status='CALLABLE_PUBLIC_UID_GATED';persist();console.log(name+': resource-only HTTP public invoker; app Auth + single UID required PASS');return;
  }
  if(action==='gates'){
   assert.deepEqual(j.configured,c.CONFIGURED);assert.deepEqual(j.public,c.CALLABLES);const a=await c.snapshot();c.protectedState(baseline,a,j);c.save('ingress-before-gates',a);
   const pilotAuth=await c.auth('pilot'),outsider=await c.auth('outsider'),proof={status:'STARTED',allowedUIDCount:1,checks:[],queueState:'PAUSED',schedulerState:'PAUSED',fixtureWrites:0};
   for(const n of c.CALLABLES){for(const [role,token,expected]of [['anonymous',null,'UNAUTHENTICATED'],['nonAllowedUID',outsider.token,'AI_INPUT_NOT_ENABLED'],['approvedUID',pilotAuth.token,'INVALID_REQUEST']]){const r=await fetch(`https://${c.R}-${c.P}.cloudfunctions.net/${n}`,{method:'POST',headers:{'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{})},body:JSON.stringify({data:null}),signal:AbortSignal.timeout(45000)});const d=await r.json().catch(()=>({}));assert(!r.ok&&d.error);if(role==='anonymous')assert.equal(d.error.status,expected);else assert.equal(d.error.details?.code||d.error.message,expected);proof.checks.push({function:n,role,httpStatus:r.status,result:expected,admissionPassed:role==='approvedUID'});c.save('gates',proof);}
   }
   proof.status='PASS';proof.accountActivityCheckNotInvoked=true;proof.gateBeforeAnyDBStorageProviderIO=true;c.save('gates',proof);j.status='GATES_PASS';persist();console.log('27/27 live Auth gates PASS: anonymous denied, synthetic non-allowed denied, approved UID reaches validation; queue/Scheduler PAUSED');return;
  }
  if(action==='resume'){
   assert.equal(j.status,'GATES_PASS');assert.equal(c.load('gates').status,'PASS');assert(!j.queueResumed);const a=await c.snapshot();c.protectedState(baseline,a,j);assert.equal(a.resources.queue.data.state,'PAUSED');assert(a.resources.scheduler.data.jobs.every(x=>x.state==='PAUSED'));
   await mutation('https://cloudtasks.googleapis.com/v2/'+c.Q+':resume','POST',{}, {gatesPassed:true});const q=await c.read('https://cloudtasks.googleapis.com/v2/'+c.Q);assert.equal(q.state,'RUNNING');j.queueResumed=true;j.status='QUEUE_RUNNING';persist();c.save('queue-resumed',q);console.log('Only aiProcessSource queue RUNNING; Scheduler remains PAUSED');return;
  }
  const a=await c.snapshot();c.protectedState(baseline,a,j);c.save('audit',a);console.log('Phase5a protected-state audit PASS; no new mutation');
 }catch(e){j.status='STOPPED';j.error=c.masked(e.message);persist();console.error('STOP: '+c.masked(e.message));throw e;}
}
module.exports={validate,main};if(require.main===module)main(process.argv[2],process.argv[3]).catch(()=>process.exitCode=1);
