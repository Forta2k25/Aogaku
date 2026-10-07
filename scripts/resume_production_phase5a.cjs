#!/usr/bin/env node
// Fresh read-only resume preflight. Preserve prior stop evidence; no cloud write.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const c=require('./production_phase5a_common.cjs'),p3a=require('./deploy_production_phase3a.cjs'),reads=require('./production_read_retry.cjs'),guard=require('./production_phase5a_revision_guard.cjs');
async function main(){
 const j=c.load('execution'),b=c.load('baseline');assert.equal(j.status,'STOPPED');assert.equal(j.attempts.length,1);assert.equal(j.attempts[0].status,'CONFIRMED');assert(j.attempts[0].resource.endsWith('/aiCreateSource?updateMask=serviceConfig.environmentVariables'));assert.equal(j.configured.length,0);assert.equal(j.public.length,0);assert.equal(j.queueResumed,false);
 assert(!fs.existsSync(path.join(c.DIR,'resume-preflight/approval.json')),'Resume preflight already completed; do not replace its baseline');
 for(const n of ['baseline','approval','execution']){const dst=path.join(c.DIR,'resume-preflight/original',n+'.json');fs.mkdirSync(path.dirname(dst),{recursive:true,mode:0o700});assert(!fs.existsSync(dst));fs.copyFileSync(path.join(c.DIR,n+'.json'),dst);fs.chmodSync(dst,0o600);}
 const a=await c.snapshot();c.save('resume-preflight/before',a);const sourceChecks=[];
 let first;
 for(const f of a.functions){
  const n=f.name.split('/').pop(),gen1=f.environment==='GEN_1',api=gen1?'https://cloudfunctions.googleapis.com/v1/':c.G,full=await c.read(api+f.name);
  const d=await c.read(api+f.name+':generateDownloadUrl','POST',gen1?{versionId:full.versionId}:{}),u=new URL(d.downloadUrl);assert(u.protocol==='https:'&&(u.hostname==='storage.googleapis.com'||u.hostname.endsWith('.storage.googleapis.com'))&&!u.username&&!u.password&&!u.port);
  const {data:bytes}=await reads.read(u,{}, {bytes:true,sourceName:'phase5a_resume_'+n});assert(bytes.length<=100*1024*1024);const zip=path.join(c.DIR,'resume-preflight',n+'-source.zip');fs.writeFileSync(zip,bytes,{mode:0o600});const files=p3a.sourceManifest(zip);assert.deepEqual(files,p3a.sourceManifest(path.join(c.DIR,'preflight',n+'-source.zip')));
  assert.deepEqual(c.p3b.safeMetadata(await c.read(c.G+f.name)),f,'Function changed during fresh source audit '+n);
  if(c.ALL.includes(n)){
   assert.equal(p3a.hash(files),c.SHA);assert.equal(full.state,'ACTIVE');assert.equal(full.buildConfig.runtime,'nodejs22');assert.equal(full.serviceConfig.serviceAccountEmail,c.SA);assert.equal(full.serviceConfig.environmentVariables.AI_FIRESTORE_DATABASE_ID,c.DB);assert.equal(full.serviceConfig.environmentVariables.AI_SHARING_ENABLED,'false');assert.equal(full.serviceConfig.environmentVariables.AI_INPUT_ALLOWED_UIDS,JSON.stringify(n==='aiCreateSource'?c.operator().allowedUIDs:[]));
   assert(!(a.runIAM[n].bindings||[]).some(x=>x.members.some(m=>['allUsers','allAuthenticatedUsers'].includes(m))));
   if(n==='aiCreateSource'){
    const old=b.functions.find(x=>x.name===f.name);assert.equal(c.metadataHash({...full.serviceConfig.environmentVariables,AI_INPUT_ALLOWED_UIDS:'[]'}),old.serviceConfig.environmentVariables.sha256);
    const revision=guard.assertRevision(old,f,f.serviceConfig.environmentVariables,p3a.hash(files));first={updateTime:f.updateTime,environmentSha256:c.metadataHash(full.serviceConfig.environmentVariables),...revision};
   }
  }
  sourceChecks.push({function:n,sourceSha256:p3a.hash(files),fullSourceUnchanged:true});c.save('resume-preflight/sources',{checks:sourceChecks});console.log(n+': fresh resume source/metadata PASS');
 }
 assert(first);const resumed={...j,status:'CONFIGURED_PRIVATE',configured:['aiCreateSource'],configProof:{aiCreateSource:first},priorStopPreserved:true,resumedAt:new Date().toISOString()};delete resumed.error;
 c.protectedState(b,a,resumed);assert.equal(sourceChecks.length,25);assert(a.resources.scheduler.data.jobs.every(x=>x.state==='PAUSED'&&!x.lastAttemptTime));
 await c.auth('pilot');await c.auth('outsider');const after=await c.snapshot();c.protectedState(b,after,resumed);assert.deepEqual([...after.functions].sort((x,y)=>x.name.localeCompare(y.name)),[...a.functions].sort((x,y)=>x.name.localeCompare(y.name)));c.save('resume-preflight/after',after);
 const dependencies=Object.fromEntries(['scripts/production_phase5a_common.cjs','scripts/production_phase5a_revision_guard.cjs','scripts/production_read_retry.cjs'].map(n=>[n,require('node:crypto').createHash('sha256').update(fs.readFileSync(path.join(c.ROOT,n))).digest('hex')]));
 const approval={phase:'5a',at:new Date().toISOString(),authority:'Human explicitly approved Phase5a remaining work with revised full-source revision guard; aiCreateSource must never be re-PATCHed.',baselineSha256:c.hash(after),sourceSha256:c.SHA,allowedUIDCount:1,allowedUIDHash:c.hash(c.operator().allowedUIDs[0]),configuredFunctions:c.CONFIGURED,alreadyConfigured:['aiCreateSource'],remaining:c.CONFIGURED.slice(1),publicCallableFunctions:c.CALLABLES,wrapperSha256:require('node:crypto').createHash('sha256').update(fs.readFileSync(path.join(c.ROOT,'scripts/deploy_production_phase5a.cjs'))).digest('hex'),dependencies,sourceUpdatesAuthorized:false,schedulerResumeAuthorized:false,phase5bAuthorized:false};
 c.save('resume-preflight/approval',approval);c.save('resume-preflight/result',{status:'PHASE5A_RESUME_PREFLIGHT_PASS',sourceChecks:25,cloudMutations:0,alreadyConfigured:['aiCreateSource'],protectedResourcesUnchanged:true,queue:'PAUSED',scheduler:'PAUSED',sharing:false});c.save('baseline',after);c.save('approval',approval);c.save('execution',resumed);
 console.log('PHASE5A_RESUME_PREFLIGHT_PASS; current state is fresh baseline; aiCreateSource adopted without PATCH; previous stop/baseline/approval preserved; mutations=0');
}
if(require.main===module)main().catch(e=>{c.save('resume-preflight/error',{status:'FAILED',error:c.masked(e.message),cloudMutations:0});console.error('STOP resume preflight: '+c.masked(e.message));process.exitCode=1;});
