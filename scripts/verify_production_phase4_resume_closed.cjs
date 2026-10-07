#!/usr/bin/env node
// Final Phase4 read-only rejection audit. No Auth fixtures or user data writes.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const phase=require('./deploy_production_phase4_resume.cjs'),p3b=require('./deploy_production_phase3b.cjs');
const ROOT=path.resolve(__dirname,'..'),DIR=path.join(ROOT,'build/production-phase4-resume'),P='forta-aogaku',R='asia-northeast1',G='https://cloudfunctions.googleapis.com/v2/';
const load=n=>JSON.parse(fs.readFileSync(path.join(DIR,n+'.json'))),save=x=>{const f=path.join(DIR,'closed-live.json');fs.writeFileSync(f,JSON.stringify(p3b.safeMetadata(x),null,2)+'\n',{mode:0o600});fs.chmodSync(f,0o600);};
async function main(){
 const j=load('execution'),post=load('postcheck'),audit=load('audit-before');assert.equal(j.status,'CONTROL_PLANE_PASS');assert.equal(post.status,'CONTROL_PLANE_PASS');assert.deepEqual(j.created,phase.NAMES);assert.equal(load('stop-audit').status,'PROTECTED_STATE_UNCHANGED');
 phase.protectedSame(load('baseline'),audit,j.created);assert.equal(audit.functions.length,25);
 const lib='/Users/shum/anaconda3/lib/node_modules/firebase-tools/lib',account=require(lib+'/auth.js').getGlobalDefaultAccount(),api=require(lib+'/api.js');
 const t=await fetch('https://oauth2.googleapis.com/token',{method:'POST',body:new URLSearchParams({client_id:api.clientId(),client_secret:api.clientSecret(),refresh_token:account.tokens.refresh_token,grant_type:'refresh_token'}),signal:AbortSignal.timeout(45000)});const d=await t.json();assert(t.ok&&d.access_token,'OAuth refresh failed');const token=d.access_token;
 const reads=new Set(['https://cloudresourcemanager.googleapis.com/v1/projects/'+P,...phase.ALL_NAMES.flatMap(n=>{const f=audit.functions.find(f=>f.name.endsWith('/'+n));return [G+f.name,'https://run.googleapis.com/v1/'+f.serviceConfig.service,'https://run.googleapis.com/v1/'+f.serviceConfig.service+':getIamPolicy'];})]);
 async function read(u){assert(reads.has(u));const r=await fetch(u,{redirect:'error',headers:{Authorization:'Bearer '+token},signal:AbortSignal.timeout(45000)});if(!r.ok)throw Error('STOP: HTTP '+r.status+' GET '+new URL(u).hostname+new URL(u).pathname);return r.json();}
 const project=await read('https://cloudresourcemanager.googleapis.com/v1/projects/'+P);assert.equal(project.projectId,P);assert.equal(project.projectNumber,'505828754933');
 const proof={status:'STARTED',phase:'4-resume',cloudMutations:0,authFixturesCreated:0,functions:{},anonymousProbes:[],firebaseAndDevAuthenticationBoundary:'IAM-enforced private Run services; no valid production/Dev user token acquired or live token probe performed',queueState:audit.resources.queue.data.state,schedulerState:audit.resources.scheduler.data.jobs[0].state,phase5Authorized:false};save(proof);
 for(const n of phase.ALL_NAMES){
  const expected=audit.functions.find(f=>f.name.endsWith('/'+n)),f=await read(G+expected.name);assert.deepEqual(p3b.safeMetadata(f),expected,'STOP: Function changed during final rejection audit');assert.equal(f.state,'ACTIVE');assert.equal(f.buildConfig.runtime,'nodejs22');
  for(const [k,v]of Object.entries(phase.env()))assert.equal(f.serviceConfig.environmentVariables[k],v);
  const run=await read('https://run.googleapis.com/v1/'+f.serviceConfig.service);assert(run.metadata?.annotations?.['run.googleapis.com/invoker-iam-disabled']!=='true');
  const iam=await read('https://run.googleapis.com/v1/'+f.serviceConfig.service+':getIamPolicy');assert(!(iam.bindings||[]).some(b=>(b.members||[]).some(m=>['allUsers','allAuthenticatedUsers'].includes(m))));
  assert.equal(post.legacySources[n].sourceSha256,post.sourceSha256);assert.equal(post.legacySources[n].updateTime,f.updateTime);
  proof.functions[n]={state:'ACTIVE',environment:'GEN_2',runtime:'nodejs22',region:R,serviceAccount:f.serviceConfig.serviceAccountEmail,sourceSha256:post.sourceSha256,updateTime:f.updateTime,publicInvoker:false,invokerIAMDisabled:false,allowedUIDs:[],sharing:false,databaseId:'aogaku-ai'};
  for(const endpoint of [f.serviceConfig.uri,`https://${R}-${P}.cloudfunctions.net/${n}`]){
   const r=await fetch(endpoint,{method:'POST',redirect:'error',headers:{'Content-Type':'application/json'},body:JSON.stringify({data:{}}),signal:AbortSignal.timeout(45000)});assert([401,403].includes(r.status),'STOP: anonymous admission HTTP '+r.status+' '+n);proof.anonymousProbes.push({function:n,endpointType:endpoint===f.serviceConfig.uri?'Cloud Run':'cloudfunctions.net',httpStatus:r.status,denied:true});
  }
  save(proof);console.log(n+': ACTIVE / exact full source / private IAM / empty cohort / anonymous denied PASS');
 }
 assert.equal(proof.queueState,'PAUSED');assert.equal(proof.schedulerState,'PAUSED');proof.status='PHASE4_COMPLETE';proof.phase4Blockers=[];proof.phase5Conditions=['Separate approval','One confirmed internal UID stored only in private config','Separately approved nine callable public HTTP ingress guarded by mandatory Firebase Auth and exact one UID','Separately approved queue/Scheduler resume','Phase3b deferred deletion/admission, delayed-worker and late-upload integration E2E'];save(proof);
 console.log('Phase4 COMPLETE: all twelve private, closed, source verified; 24 anonymous probes denied. No Phase5 action.');
}
if(require.main===module)main().catch(e=>{const j=load('execution');j.status='STOPPED';j.partialSuccess=j.created.length>0;j.error=e.message;fs.writeFileSync(path.join(DIR,'execution.json'),JSON.stringify(p3b.safeMetadata(j),null,2)+'\n',{mode:0o600});console.error(e.message);process.exitCode=1;});
