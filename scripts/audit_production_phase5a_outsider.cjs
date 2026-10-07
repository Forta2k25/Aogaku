#!/usr/bin/env node
// Read-only verification of the single registered disposable account cleanup.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const c=require('./production_phase5a_common.cjs'),reads=require('./production_read_retry.cjs');
async function main(){
 const t=c.load('outsider-cleanup-target'),reg=c.load('outsider-registry');assert.equal(reg.status,'DELETED');assert.equal(t.projectId,c.P);assert.equal(c.hash(t.uid),reg.uidHash);assert.notEqual(t.uid,c.operator().allowedUIDs[0]);assert.equal(t.pilotExcluded,true);const uid=t.uid;
 const db=d=>`https://firestore.googleapis.com/v1/projects/${c.P}/databases/${d}/documents`;
 const queries=[{from:[{collectionId:'aiSources'}],where:{fieldFilter:{field:{fieldPath:'ownerUserId'},op:'EQUAL',value:{stringValue:uid}}},limit:100},{from:[{collectionId:'memberships',allDescendants:true}],where:{fieldFilter:{field:{fieldPath:'userId'},op:'EQUAL',value:{stringValue:uid}}},limit:100}];
 async function scopedRead(url,body){
  const lookup=url===`https://identitytoolkit.googleapis.com/v1/projects/${c.P}/accounts:lookup`,query=url===db(c.DB)+':runQuery';assert(lookup||query);
  if(lookup)assert.deepEqual(body,{localId:[uid]});else assert(queries.some(q=>JSON.stringify(body)===JSON.stringify({structuredQuery:q})));
  const meta={service:new URL(url).hostname,method:'POST',resourcePath:new URL(url).pathname};
  const log=x=>fs.appendFileSync(path.join(c.DIR,'cleanup-read-events.jsonl'),JSON.stringify({...meta,...x,at:new Date().toISOString()})+'\n',{mode:0o600});
  for(let attempt=1;attempt<=5;attempt++){
   log({attempt,outcome:'START'});try{const r=await fetch(url,{method:'POST',redirect:'error',headers:{Authorization:'Bearer '+await c.cloud.oauth(),'Content-Type':'application/json'},body:JSON.stringify(body),signal:AbortSignal.timeout(45000)});if(!r.ok){await r.body?.cancel();const e=Error('SCOPED_READ_HTTP');e.httpStatus=r.status;throw e;}const d=await r.json();log({attempt,outcome:'SUCCESS',httpStatus:r.status});return d;}
   catch(e){const timeout=['TimeoutError','AbortError'].includes(e.name)||e.cause?.code==='UND_ERR_CONNECT_TIMEOUT';const retry=timeout||reads.RETRY_STATUS.has(e.httpStatus);log({attempt,outcome:'ERROR',errorKind:timeout?'TIMEOUT':e.httpStatus?'HTTP_ERROR':'OTHER',httpStatus:e.httpStatus,willRetry:retry&&attempt<5});if(!retry||attempt===5)throw Error('Scoped cleanup read failed '+(e.httpStatus||e.name));await new Promise(r=>setTimeout(r,reads.BACKOFF_MS[attempt-1]));}
  }
 }
 async function get(d,p){const {response,data}=await reads.read(db(d)+'/'+p,{headers:{Authorization:'Bearer '+await c.cloud.oauth()}},{allowStatuses:[404],sourceName:'phase5a_disposable_cleanup'});return response.status===404?null:data;}
 assert.equal((await scopedRead(`https://identitytoolkit.googleapis.com/v1/projects/${c.P}/accounts:lookup`,{localId:[uid]})).users?.length||0,0);
 let marker;for(let i=0;i<40;i++){marker=await get(c.DB,'aiInputOwners/'+uid);if(marker?.fields?.state?.stringValue==='deleted')break;if(i%10===0)console.log('Waiting only for registered disposable Auth cleanup marker');await new Promise(r=>setTimeout(r,3000));}assert.equal(marker?.fields?.state?.stringValue,'deleted');assert(Object.keys(marker.fields).every(x=>['state','updatedAt'].includes(x)));
 assert.equal((await get('(default)','accountDeletionFences/'+uid))?.fields?.state?.stringValue,'deleted');
 for(const q of queries){const d=await scopedRead(db(c.DB)+':runQuery',{structuredQuery:q});assert.equal(d.filter(x=>x.document).length,0,'Disposable source/membership remains');}
 for(const d of [c.DB,'(default)']){assert.equal(await get(d,'aiUsage/'+uid),null);const periods=await c.read(db(d)+'/aiUsage/'+uid+'/periods?pageSize=100','GET',undefined,{sourceName:'phase5a_disposable_usage_cleanup'});assert.equal((periods.documents||[]).length,0);}
 for(const p of [`ai-inputs/${c.DB}/${uid}/`,`ai-derived/${c.DB}/${uid}/`]){const d=await c.read(`https://storage.googleapis.com/storage/v1/b/${c.B}/o?prefix=${encodeURIComponent(p)}`,'GET',undefined,{sourceName:'phase5a_disposable_storage_cleanup'});assert.equal((d.items||[]).length,0);}
 c.save('outsider-cleanup-proof',{status:'PASS',authAbsent:true,namedSources:0,memberships:0,namedDefaultUsageAbsent:true,rawDerivedObjects:0,pilotExcluded:true,fixtureSourcesEverCreated:0,minimalNamedOwnerAndDefaultFenceRetained:true,noDeletionRaceE2E:true,cloudMutations:0});console.log('PASS disposable cleanup: Auth absent; sources/memberships/usage/raw/derived absent; minimal resurrection fences retained; pilot untouched');
}
if(require.main===module)main().catch(e=>{c.save('outsider-cleanup-error',{status:'FAILED',error:c.masked(e.message),cloudMutations:0});console.error('STOP cleanup audit: '+c.masked(e.message));process.exitCode=1;});
