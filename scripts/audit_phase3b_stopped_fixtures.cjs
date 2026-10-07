#!/usr/bin/env node
// Read-only inventory of paths registered by this one stopped synthetic E2E.
// No Auth enumeration, cleanup, Function invocation, or cloud mutation.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const ROOT=path.resolve(__dirname,'..'),DIR=path.join(ROOT,'build/production-phase3b');
const P='forta-aogaku',N='505828754933',B=P+'.firebasestorage.app';
async function main(){
 const load=n=>JSON.parse(fs.readFileSync(path.join(DIR,n+'.json')));
 const e=load('e2e'),registry=load('fixture-registry');assert.equal(e.status,'STOPPED');assert.equal(e.results.length,0);assert.equal(e.realUsersUsed,0);
 const cloud=require('./production_cloud.cjs'),bearer=await cloudToken();
 async function read(url){const r=await fetch(url,{method:'GET',redirect:'error',headers:{Authorization:'Bearer '+bearer},signal:AbortSignal.timeout(45000)});if(r.status===404)return null;assert(r.ok,'Read-only fixture audit HTTP '+r.status);return r.json();}
 // OAuth refresh is authentication only; all resource operations are GET.
 async function cloudToken(){const lib='/Users/shum/anaconda3/lib/node_modules/firebase-tools/lib',a=require(lib+'/auth.js').getGlobalDefaultAccount(),api=require(lib+'/api.js');const r=await fetch('https://oauth2.googleapis.com/token',{method:'POST',body:new URLSearchParams({client_id:api.clientId(),client_secret:api.clientSecret(),refresh_token:a.tokens.refresh_token,grant_type:'refresh_token'}),signal:AbortSignal.timeout(45000)});const d=await r.json();assert(r.ok&&d.access_token);return d.access_token;}
 const project=await read(cloud.urls.project);assert.equal(project.projectId,P);assert.equal(project.projectNumber,N);assert.equal((await read(cloud.urls.bucket)).name,B);
 const queue=await read(`https://cloudtasks.googleapis.com/v2/projects/${P}/locations/asia-northeast1/queues/aiProcessSource`);assert.equal(queue.state,'PAUSED');
 const out={checkedAt:new Date().toISOString(),status:'READ_ONLY_STOP_AUDIT',runId:e.runId,registeredSyntheticUIDs:registry.uids.length,realUsersUsed:0,queueState:queue.state,resourceMutations:0,documents:{},objects:{registered:registry.objects.length,present:0,absent:0},tasks:{registered:registry.tasks.length,present:0,absent:0},markers:[],fixtureOwnershipMismatches:0};
 const {decode}=require('./production_phase3b_e2e.cjs');
 async function bounded(items,fn){let cursor=0;await Promise.all(Array.from({length:4},async()=>{while(cursor<items.length)await fn(items[cursor++]);}));}
 await bounded(registry.paths,async p=>{
  assert(registry.uids.includes(p.uid));assert(['(default)','aogaku-ai'].includes(p.database));assert(!p.path.includes('..'));
  const d=await read(`https://firestore.googleapis.com/v1/projects/${P}/databases/${p.database}/documents/${p.path}`);
  const s=out.documents[p.database]||=( {registered:0,present:0,absent:0} );s.registered++;s[d?'present':'absent']++;
  if(d){const fields=d.fields||{};if(fields.testRunId&&decode(fields.testRunId)!==e.runId)out.fixtureOwnershipMismatches++;if(p.path===`aiInputOwners/${p.uid}`||p.path===`accountDeletionFences/${p.uid}`)out.markers.push({database:p.database,path:p.path,state:fields.state?decode(fields.state):null});}
 });
 await bounded(registry.objects,async o=>{assert(registry.uids.includes(o.uid));const d=await read(`https://storage.googleapis.com/storage/v1/b/${B}/o/${encodeURIComponent(o.path)}`);out.objects[d?'present':'absent']++;});
 await bounded(registry.tasks,async t=>{assert(registry.uids.includes(t.uid));assert(/^[a-f0-9]{64}$/.test(t.id));const d=await read(`https://cloudtasks.googleapis.com/v2/${queue.name}/tasks/${t.id}`);out.tasks[d?'present':'absent']++;});
 assert.equal(out.fixtureOwnershipMismatches,0,'STOP: synthetic ownership mismatch');
 const file=path.join(DIR,'stopped-fixtures-audit.json');fs.writeFileSync(file,JSON.stringify(out,null,2)+'\n',{mode:0o600});fs.chmodSync(file,0o600);
 console.log(JSON.stringify({...out,markers:out.markers.map(m=>({database:m.database,state:m.state}))},null,2));
}
if(require.main===module)main().catch(e=>{console.error(e.message);process.exitCode=1;});
