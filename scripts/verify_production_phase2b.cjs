#!/usr/bin/env node
// No administrative data writes. Read-only public entries query projects only
// __name__; unauthenticated probes are sent only after exact live deny checks.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const ROOT=path.resolve(__dirname,'..'),P='forta-aogaku',B=P+'.firebasestorage.app',DB='aogaku-ai',DIR=path.join(ROOT,'build/production-phase2b-named');
async function main(){
 const journal=JSON.parse(fs.readFileSync(path.join(DIR,'execution.json')));assert.equal(journal.status,'CONTROL_PLANE_PASS');assert(!journal.partialSuccess);
 const live=await require('./production_cloud.cjs').inspect();
 assert.equal(live.projectId,P);assert.equal(live.projectNumber,'505828754933');assert.equal(live.bucket.name,B);assert(live.apps.apps.some(a=>a.bundleId==='com.forta2k25.Aogaku'&&a.state==='ACTIVE'));
 const named=fs.readFileSync(path.join(ROOT,'Config/AI/firestore.rules'),'utf8');assert.equal(live.aiRules.content,named);
 assert.equal(live.rules.firestore.content,fs.readFileSync(path.join(ROOT,'Config/Production/baseline.firestore.rules'),'utf8'));
 assert.equal(live.rules.storage.content,fs.readFileSync(path.join(ROOT,'Config/Production/storage.rules'),'utf8'));
 const id='phase2b-deny-'+crypto.randomUUID(),root=`https://firestore.googleapis.com/v1/projects/${P}/databases/`,base=root+'(default)/documents';
 const evidence={projectId:P,database:DB,readAt:new Date().toISOString(),rulesExact:true,namedClientChecks:[],storageClientChecks:[],noAdministrativeDataWrites:true,noAuthChanges:true};
 const query=await fetch(base+':runQuery',{method:'POST',redirect:'error',headers:{'Content-Type':'application/json'},body:JSON.stringify({structuredQuery:{select:{fields:[{fieldPath:'__name__'}]},from:[{collectionId:'entries',allDescendants:true}],limit:1}}),signal:AbortSignal.timeout(45000)});
 assert.equal(query.status,200,'legacy anonymous entries query changed');const data=await query.json();
 evidence.legacyQuery={status:query.status,projection:'__name__ only',limit:1};
 const doc=(Array.isArray(data)?data:[]).find(x=>x.document)?.document;
 if(doc){assert(doc.name.startsWith(`projects/${P}/databases/(default)/documents/`));assert(!Object.keys(doc.fields||{}).length,'query exposed unexpected content');
  // Historical class/review IDs can contain '#'. Encode every resource segment
  // so the name never becomes a URL fragment or a different document path.
  const encodedName=doc.name.split('/').map(encodeURIComponent).join('/');
  const r=await fetch('https://firestore.googleapis.com/v1/'+encodedName+'?mask.fieldPaths=phase2bUnrequested_'+id.replaceAll('-',''),{redirect:'error',signal:AbortSignal.timeout(45000)});assert.equal(r.status,200,'anonymous existing entries read changed');await r.arrayBuffer();evidence.legacyAnonymousRead={status:200,contentNotStored:true};}
 else evidence.legacyAnonymousRead={status:'NO_QUERY_RESULTS',rulesVerified:true};
 const {AI_DOCUMENT_PATHS}=require('../functions/lib/ai/schema');
 for(const template of [...AI_DOCUMENT_PATHS,'aiSources/{sourceId}/entries/{uid}']){
  const sourcePath=template.replace(/\{[^}]+\}/g,id),url=root+DB+'/documents/'+sourcePath;
  for(const method of ['GET','PATCH']){const r=await fetch(url,{method,redirect:'error',headers:{'Content-Type':'application/json'},...(method==='PATCH'?{body:JSON.stringify({fields:{phase2bDeniedProbe:{stringValue:'synthetic'}}})}:{}),signal:AbortSignal.timeout(45000)});assert.equal(r.status,403,'named client access must deny: '+template+' '+method);await r.arrayBuffer();evidence.namedClientChecks.push({template,method,status:r.status});}
 }
 const storageBase=`https://firebasestorage.googleapis.com/v0/b/${B}/o`;
 for(const prefix of ['ai-inputs','ai-derived']){const name=prefix+'/aogaku-ai/'+id+'/probe/original';for(const method of ['GET','POST']){const url=method==='GET'?storageBase+'/'+encodeURIComponent(name)+'?alt=media':storageBase+'?uploadType=media&name='+encodeURIComponent(name);const r=await fetch(url,{method,redirect:'error',headers:{'Content-Type':'application/octet-stream'},...(method==='POST'?{body:Buffer.from('denied synthetic probe')}:{}),signal:AbortSignal.timeout(45000)});assert.equal(r.status,403,'AI Storage client direct access must deny');await r.arrayBuffer();evidence.storageClientChecks.push({prefix,method,status:r.status});}}
 fs.writeFileSync(path.join(DIR,'client-postcheck.json'),JSON.stringify(evidence,null,2)+'\n',{mode:0o600});
 console.log(JSON.stringify({status:'PASS',legacyEntriesQuery:200,legacyEntriesRead:evidence.legacyAnonymousRead.status,namedClientReadWrite403:evidence.namedClientChecks.length,storageClientReadWrite403:evidence.storageClientChecks.length,defaultDataChanged:false,authChanged:false}));
}
if(require.main===module)main().catch(e=>{console.error(e.message);process.exitCode=1});
