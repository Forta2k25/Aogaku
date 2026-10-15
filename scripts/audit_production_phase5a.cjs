#!/usr/bin/env node
// Read-only final audit; preserve preflight evidence and verify installed files.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const c=require('./production_phase5a_common.cjs'),reads=require('./production_read_retry.cjs'),p3a=require('./deploy_production_phase3a.cjs');
async function main(){
 const j=c.load('execution'),e=c.load('e2e');assert.equal(j.status,'QUEUE_RUNNING');assert(j.queueResumed);assert.deepEqual(j.configured,c.CONFIGURED);assert.deepEqual(j.public,c.CALLABLES);
 assert.equal(c.load('gates').status,'PASS');assert.equal(e.status,'PERMISSIONS_PASS');assert.equal(c.load('outsider-registry').status,'DELETED');
 assert.equal(c.load('outsider-cleanup-proof').status,'PASS');
 assert(e.results.length===5&&e.results.every(x=>x.status==='PASS'));assert.equal(e.duplicateRequest.status,'PASS');assert.equal(e.interruptedUpload.status,'PASS');assert.equal(e.permissions.status,'PASS');
 const b=c.load('baseline'),before=await c.snapshot();c.protectedState(b,before,j);c.save('final/before',before);
 const proof={status:'STARTED',phase:'5a',sourceChecks:[],runRevisionChecks:[],privateProbes:[],allowedUIDCount:1,allowedUIDHash:c.hash(c.operator().allowedUIDs[0]),sharing:false,queue:'RUNNING',scheduler:'PAUSED',phase5bStarted:false};
 for(const f of before.functions){
  const n=f.name.split('/').pop(),gen1=f.environment==='GEN_1',api=gen1?'https://cloudfunctions.googleapis.com/v1/':c.G;
  const full=gen1?await c.read(api+f.name):await c.read(c.G+f.name);
  const d=await c.read(api+f.name+':generateDownloadUrl','POST',gen1?{versionId:full.versionId}:{}),u=new URL(d.downloadUrl);
  assert(u.protocol==='https:'&&(u.hostname==='storage.googleapis.com'||u.hostname.endsWith('.storage.googleapis.com'))&&!u.username&&!u.password&&!u.port);
  const {data:bytes}=await reads.read(u,{}, {bytes:true,sourceName:'phase5a_final_'+n});assert(bytes.length<=100*1024*1024);
  const out=path.join(c.DIR,'final',n+'-source.zip');fs.writeFileSync(out,bytes,{mode:0o600});
  const files=p3a.sourceManifest(out),expected=p3a.sourceManifest(path.join(c.DIR,'preflight',n+'-source.zip'));assert.deepEqual(files,expected,'Installed source changed '+n);
  assert.deepEqual(c.p3b.safeMetadata(await c.read(c.G+f.name)),f,'Function changed during source audit '+n);
  if(c.ALL.includes(n)){
   assert.equal(p3a.hash(files),c.SHA);assert.equal(full.state,'ACTIVE');assert.equal(full.buildConfig.runtime,'nodejs22');assert.equal(full.serviceConfig.serviceAccountEmail,c.SA);
   assert.equal(full.serviceConfig.environmentVariables.AI_FIRESTORE_DATABASE_ID,c.DB);assert.equal(full.serviceConfig.environmentVariables.AI_SHARING_ENABLED,'false');
   assert.equal(full.serviceConfig.environmentVariables.AI_INPUT_ALLOWED_UIDS,JSON.stringify(c.CONFIGURED.includes(n)?c.operator().allowedUIDs:[]));
   const run=await c.read('https://run.googleapis.com/v1/'+full.serviceConfig.service),template=run.spec.template.spec;assert.equal(template.serviceAccountName,c.SA);assert(run.status.conditions.some(x=>x.type==='Ready'&&x.status==='True'));assert.equal(run.status.latestReadyRevisionName,full.serviceConfig.revision);assert(run.metadata.annotations?.['run.googleapis.com/invoker-iam-disabled']!=='true');
   const env=Object.fromEntries(template.containers[0].env.filter(x=>x.value!==undefined).map(x=>[x.name,x.value]));assert.equal(env.AI_FIRESTORE_DATABASE_ID,c.DB);assert.equal(env.AI_SHARING_ENABLED,'false');assert.equal(env.AI_INPUT_ALLOWED_UIDS,full.serviceConfig.environmentVariables.AI_INPUT_ALLOWED_UIDS);proof.runRevisionChecks.push({function:n,ready:true,serviceAccountMatches:true,envMatches:true,invokerIAMEnforced:true});
   if(!c.CALLABLES.includes(n))for(const url of [full.serviceConfig.uri,`https://${c.R}-${c.P}.cloudfunctions.net/${n}`]){
    const {response}=await reads.read(url,{}, {discard:true,allowStatuses:[401,403]});assert([401,403].includes(response.status));proof.privateProbes.push({function:n,httpStatus:response.status});
   }
  }
  proof.sourceChecks.push({function:n,sourceSha256:p3a.hash(files),installedFilesUnchanged:true,legacy:!c.ALL.includes(n)});c.save('final/result',proof);console.log(n+': final installed full source unchanged PASS');
 }
 const after=await c.snapshot();c.protectedState(b,after,j);c.save('final/after',after);assert.deepEqual([...after.functions].sort((x,y)=>x.name.localeCompare(y.name)),[...before.functions].sort((x,y)=>x.name.localeCompare(y.name)),'Functions changed during final audit');
 assert(after.resources.scheduler.data.jobs.every(x=>x.state==='PAUSED'&&!x.lastAttemptTime));assert.equal(proof.sourceChecks.length,25);assert.equal(proof.sourceChecks.filter(x=>x.legacy).length,13);assert.equal(proof.runRevisionChecks.length,12);assert.equal(proof.privateProbes.length,6);
 proof.status='PHASE5A_COMPLETE';proof.inputs=e.results;proof.duplicate=e.duplicateRequest;proof.uploadRetry=e.interruptedUpload;proof.directAccess=e.permissions;proof.namedDefaultSeparation=true;proof.protectedResourcesUnchanged=true;proof.completedAt=new Date().toISOString();proof.deferred=['Deletion admission race','Delayed worker refusal after deletion','Storage finalize late upload deletion','Scheduler reconcile','Long recording','Provider failures','Quota limits','Sharing/general availability'];c.save('final/result',proof);
 console.log('PHASE5A_COMPLETE: four live inputs, OCR/ASR/evidence/retrieval, duplicate/upload retry, single UID, private background, protected resources unchanged; no Phase5b');
}
if(require.main===module)main().catch(e=>{c.save('final/error',{status:'AUDIT_FAILED',error:c.masked(e.message),mutationCount:0});console.error('STOP final audit: '+c.masked(e.message));process.exitCode=1;});
