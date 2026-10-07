// Production reads only. All mutation verbs/actions are excluded from retry.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const RETRY_STATUS=new Set([429,500,502,503,504]),BACKOFF_MS=[2000,5000,10000,20000];
const HOSTS=new Set(['cloudfunctions.googleapis.com','run.googleapis.com','cloudresourcemanager.googleapis.com','firestore.googleapis.com','firebaserules.googleapis.com','firebase.googleapis.com','storage.googleapis.com','iam.googleapis.com','cloudtasks.googleapis.com','cloudscheduler.googleapis.com','eventarc.googleapis.com','serviceusage.googleapis.com','secretmanager.googleapis.com']);
function assertRead(url,method='GET',body){
 const u=new URL(url);assert.equal(u.protocol,'https:');assert(!u.username&&!u.password);assert(!u.pathname.endsWith(':access'),'Secret payload forbidden');
 assert(HOSTS.has(u.hostname)||u.hostname.endsWith('.storage.googleapis.com')||/^[a-z0-9-]+\.a\.run\.app$/.test(u.hostname)||u.hostname==='asia-northeast1-forta-aogaku.cloudfunctions.net','Read service not allowlisted');
 if(method==='GET')return;
 assert.equal(method,'POST','Mutation retry forbidden');
 if(u.pathname.endsWith(':getIamPolicy')){assert(['cloudresourcemanager.googleapis.com','cloudtasks.googleapis.com','iam.googleapis.com'].includes(u.hostname));assert.deepEqual(JSON.parse(body),{options:{requestedPolicyVersion:3}});return;}
 assert.equal(u.hostname,'cloudfunctions.googleapis.com');assert(u.pathname.endsWith(':generateDownloadUrl'),'Mutation retry forbidden');const x=JSON.parse(body);assert(Object.keys(x).length===0||(Object.keys(x).length===1&&/^\d+$/.test(String(x.versionId))));
}
function eligible(url,method='GET',body){try{assertRead(url,method,body);return true;}catch{return false;}}
function createReader({fetchImpl=global.fetch,sleepImpl=ms=>new Promise(r=>setTimeout(r,ms)),log=()=>{},maxAttempts=5,timeoutMs=45000}={}){
 assert.equal(maxAttempts,5);
 return async function read(url,options={},settings={}){
  const method=options.method||'GET';assertRead(url,method,options.body);const u=new URL(url);let resourcePath=u.pathname;
  if(settings.sourceName){assert(/^[A-Za-z0-9_-]+$/.test(settings.sourceName));resourcePath='/SourceCodeGet/'+settings.sourceName;}
  const base={service:u.hostname,method,resourcePath};
  for(let attempt=1;attempt<=maxAttempts;attempt++){
   log({...base,attempt,outcome:'START',at:new Date().toISOString()});
   let record;
   try{
    const response=await fetchImpl(url,{...options,redirect:'error',signal:AbortSignal.timeout(timeoutMs)});
    if(!response.ok&&!(settings.allowStatuses||[]).includes(response.status)){
     await response.body?.cancel().catch(()=>{});const e=Error('READ_HTTP_ERROR');e.httpStatus=response.status;throw e;
    }
    const data=settings.discard?(await response.arrayBuffer(),null):settings.bytes?Buffer.from(await response.arrayBuffer()):await response.json();
    log({...base,attempt,outcome:'SUCCESS',httpStatus:response.status,at:new Date().toISOString()});return {response,data};
   }catch(e){
    const timeout=['TimeoutError','AbortError'].includes(e.name)||e.code==='UND_ERR_CONNECT_TIMEOUT'||e.cause?.code==='UND_ERR_CONNECT_TIMEOUT'||e.code==='ETIMEDOUT'||e.cause?.code==='ETIMEDOUT';
    const retry=timeout||RETRY_STATUS.has(e.httpStatus);record={...base,attempt,outcome:'ERROR',errorKind:timeout?'TIMEOUT':e.httpStatus?'HTTP_ERROR':'OTHER_ERROR',...(e.httpStatus?{httpStatus:e.httpStatus}:{}),willRetry:retry&&attempt<maxAttempts,at:new Date().toISOString()};log(record);
    if(!record.willRetry){const error=Error('Read exhausted/failed: '+JSON.stringify(record));error.readRecord=record;throw error;}
   }
   await sleepImpl(BACKOFF_MS[attempt-1]);
  }
 };
}
const DIR=path.resolve(__dirname,'../build/production-phase4-retry');
function safeLog(record){fs.mkdirSync(DIR,{recursive:true,mode:0o700});const f=path.join(DIR,'read-events.jsonl');fs.appendFileSync(f,JSON.stringify(record)+'\n',{mode:0o600});fs.chmodSync(f,0o600);if(record.outcome==='ERROR')console.log('Read attempt '+record.attempt+' '+record.service+' '+record.method+' '+record.resourcePath+' '+record.errorKind+(record.httpStatus?' HTTP'+record.httpStatus:'')+(record.willRetry?' -> bounded retry':' -> stop'));}
module.exports={assertRead,eligible,createReader,BACKOFF_MS,RETRY_STATUS,read:createReader({log:safeLog})};
