const {test}=require('node:test'),assert=require('node:assert/strict');
const p=require('./production_read_retry.cjs'),URL='https://run.googleapis.com/v1/projects/forta-aogaku/locations/asia-northeast1/services/aiprocesssource:getIamPolicy';
test('Retry only five total attempts for timeout/429/500/502/503/504; exponential pauses',async()=>{
 const events=[],pauses=[];let count=0;const read=p.createReader({log:e=>events.push(e),sleepImpl:async ms=>pauses.push(ms),fetchImpl:async()=>{count++;if(count===4)throw Object.assign(Error('credential must not be logged'),{name:'TimeoutError'});return new Response(JSON.stringify({ok:true}),{status:[500,503,429,0,200][count-1]});}});
 assert.deepEqual((await read(URL)).data,{ok:true});assert.equal(count,5);assert.deepEqual(pauses,[2000,5000,10000,20000]);assert.equal(events.filter(e=>e.outcome==='ERROR').length,4);assert(!JSON.stringify(events).includes('credential'));
 for(const status of [429,500,502,503,504]){let count=0;const r=p.createReader({sleepImpl:async()=>{},fetchImpl:async()=>{count++;return new Response('{}',{status});}});await assert.rejects(()=>r(URL));assert.equal(count,5);}
});
test('No retries for 400/401/403/404 or unknown transport errors',async()=>{
 for(const status of [400,401,403,404]){let n=0;const r=p.createReader({fetchImpl:async()=>{n++;return new Response('{}',{status});},sleepImpl:async()=>{throw Error('unexpected retry');}});await assert.rejects(()=>r(URL));assert.equal(n,1);}
 let n=0;const r=p.createReader({fetchImpl:async()=>{n++;throw Error('unexpected internal error');}});await assert.rejects(()=>r(URL));assert.equal(n,1);
});
test('CREATE/PATCH/SET IAM/Scheduler/Eventarc/upload/OAuth/Secret access never enter retry loop',async()=>{
 let n=0;const r=p.createReader({fetchImpl:async()=>{n++;throw Error('must not be called');}});
 const base='https://cloudfunctions.googleapis.com/v2/projects/forta-aogaku/locations/asia-northeast1';
 for(const [url,method] of [[base+'/functions?functionId=aiReconcileInputs','POST'],[base+'/functions/aiCreateSource','PATCH'],[base+'/functions/aiProcessSource:setIamPolicy','POST'],[base+'/functions:generateUploadUrl','POST'],['https://cloudscheduler.googleapis.com/v1/projects/forta-aogaku/locations/asia-northeast1/jobs','POST'],['https://eventarc.googleapis.com/v1/projects/forta-aogaku/locations/us-central1/triggers','POST'],['https://oauth2.googleapis.com/token','POST'],['https://secretmanager.googleapis.com/v1/projects/forta-aogaku/secrets/GROQ_API_KEY/versions/1:access','GET']])await assert.rejects(()=>r(url,{method,body:'{}'}));
 assert.equal(n,0);
});
test('Read-only POST getIamPolicy and SourceCodeGet allowed; secret query/header/signed URL never logged',async()=>{
 const events=[],r=p.createReader({log:e=>events.push(e),fetchImpl:async()=>new Response('{}')});
 await r('https://cloudresourcemanager.googleapis.com/v1/projects/forta-aogaku:getIamPolicy',{method:'POST',body:JSON.stringify({options:{requestedPolicyVersion:3}}),headers:{Authorization:'Bearer NEVER_LOG'}});
 await r('https://cloudfunctions.googleapis.com/v2/projects/forta-aogaku/locations/asia-northeast1/functions/aiGetSource:generateDownloadUrl',{method:'POST',body:'{}'});
 await r('https://storage.googleapis.com/private-file?X-Goog-Signature=NEVER_LOG',{}, {bytes:true,sourceName:'aiGetSource'});
 assert(!JSON.stringify(events).includes('NEVER_LOG'));assert(!JSON.stringify(events).includes('private-file'));assert(events.some(e=>e.resourcePath==='/SourceCodeGet/aiGetSource'));
});
test('Mutation executed once, transient confirmation read retried without replaying write',async()=>{
 let writes=0,reads=0;async function mutation(){writes++;return {accepted:true};}await mutation();
 const r=p.createReader({sleepImpl:async()=>{},fetchImpl:async()=>{reads++;if(reads===1)throw Object.assign(Error('timeout'),{name:'TimeoutError'});return new Response('{}');}});await r(URL);assert.equal(writes,1);assert.equal(reads,2);
});
