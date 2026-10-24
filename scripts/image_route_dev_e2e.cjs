#!/usr/bin/env node
// Dev-only fresh image route regression. No existing fixtures are overwritten or replayed.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict'),{execFileSync}=require('node:child_process');
const c=require('./dev_cloud.cjs'),P=c.PROJECT,D='aogaku-ai';
const output=path.join(c.ROOT,'build/image-route-dev-e2e'),registry=path.join(output,'registry.json');
const state={projectId:P,run:crypto.randomUUID(),sources:[],results:[]};
function save(){fs.writeFileSync(registry,JSON.stringify(state,null,2),{mode:0o600});}
async function snapshot(){
 c.guard();const project=await c.request(`https://cloudresourcemanager.googleapis.com/v1/projects/${P}`);assert.equal(project.projectNumber,c.NUMBER);
 const urls={functions:`https://cloudfunctions.googleapis.com/v2/projects/${P}/locations/-/functions`,database:`https://firestore.googleapis.com/v1/projects/${P}/databases/${D}`,bucket:`https://storage.googleapis.com/storage/v1/b/${c.BUCKET}`,queue:`https://cloudtasks.googleapis.com/v2/projects/${P}/locations/${c.REGION}/queues/aiProcessSource`};
 const value={project:{projectId:P,projectNumber:c.NUMBER}};for(const[k,url]of Object.entries(urls))value[k]=await c.request(url);
 fs.writeFileSync(path.join(c.ROOT,'build/detection-dev-before.json'),JSON.stringify(value,null,2),{mode:0o600});console.log('PASS Dev-only fresh deploy snapshot');
}
async function main(){
 if(process.argv[2]==='snapshot')return snapshot();assert.equal(process.argv.length,2);c.guard();assert(!fs.existsSync(registry),'Fresh registry required; never replay billable images');
 fs.mkdirSync(output,{recursive:true,mode:0o700});save();
 execFileSync('swift',['scripts/image_route_assets.swift',output,state.run],{cwd:c.ROOT,stdio:'pipe'});
 const key=execFileSync('python3',['-c','import plistlib;print(plistlib.load(open("Config/Firebase/Development/GoogleService-Info.plist","rb"))["API_KEY"])'],{cwd:c.ROOT,encoding:'utf8'}).trim();
 const r=await fetch('https://identitytoolkit.googleapis.com/v1/accounts:signUp?key='+encodeURIComponent(key),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({returnSecureToken:true})});assert(r.ok,'DEV_AUTH_'+r.status);const user=await r.json();
 const claims=JSON.parse(Buffer.from(user.idToken.split('.')[1],'base64url'));assert.equal(claims.aud,P);assert.equal(claims.iss,'https://securetoken.google.com/'+P);state.user={uid:user.localId,idToken:user.idToken,refreshToken:user.refreshToken};save();
 async function call(name,data){assert(['aiListSources','aiCreateSource','aiCompleteSource','aiGetSource','aiGetEvidence','aiRetrieveContext'].includes(name));c.guard();const r=await fetch(`https://${c.REGION}-${P}.cloudfunctions.net/${name}`,{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+user.idToken},body:JSON.stringify({data}),signal:AbortSignal.timeout(150000)});const v=await r.json();assert(r.ok,'DEV_CALL_'+name+'_'+r.status);return v.result;}
 // Reuse only catalog context from previous verified Dev fixture; no previous tokens or sources.
 const old=JSON.parse(fs.readFileSync(path.join(c.ROOT,'build/detection-dev-e2e/registry.json')));assert.equal(old.projectId,P);const context=old.context;
 const capability=(await call('aiListSources',{context})).inputCapabilities?.image;assert.deepEqual(capability,{provider:'groq',model:'qwen/qwen3.8-27b',method:'multimodal_ai',pipelineVersion:'image-ai-v2',fallback:false});
 state.context=context;save();
 for(let i=1;i<=2;i++){
  const bytes=fs.readFileSync(path.join(output,`image-${i}.jpg`)),sha=crypto.createHash('sha256').update(bytes).digest('hex');assert(!state.sources.some(s=>s.sha===sha));
  const source=await call('aiCreateSource',{clientRequestId:state.run+'-'+i,type:'image',title:'Synthetic Qwen route '+i,mime:'image/jpeg',size:bytes.length,context});assert.equal(source.sourceType,'image');assert.equal(source.pipelineVersion,'image-ai-v2');
  state.sources.push({sourceId:source.sourceId,sha});save();const u=new URL(source.upload.url);assert(u.hostname==='storage.googleapis.com'&&u.pathname.startsWith('/'+c.BUCKET+'/'));const upload=await fetch(u,{method:'PUT',headers:source.upload.headers,body:bytes});assert.equal(upload.status,200);
  await call('aiCompleteSource',{sourceId:source.sourceId});let ready;const end=Date.now()+300000;
  while(Date.now()<end){ready=await call('aiGetSource',{sourceId:source.sourceId});if(ready.status==='ready')break;assert(!['failed','partial_ready'].includes(ready.status),'DEV_PROCESSING_'+ready.error?.code);await new Promise(r=>setTimeout(r,3000));}
  assert.equal(ready.status,'ready');const m=ready.recognition;assert.equal(m.provider,'groq');assert.equal(m.model,'qwen/qwen3.8-27b');assert.equal(m.method,'multimodal_ai');assert.equal(m.pipelineVersion,'image-ai-v2');assert(m.totalTokens>0&&m.inputTokens>0&&m.outputTokens>0);assert(Math.abs(m.estimatedCostUSD-(m.inputTokens*.8+m.outputTokens*4)/1e6)<1e-12);
  const items=[];let after;do{const page=await call('aiGetEvidence',{sourceId:source.sourceId,...(after?{after}:{})});assert.equal(page.activeVersion,ready.activeVersion);assert.equal(page.recognition.model,m.model);items.push(...page.items);after=page.nextCursor;}while(after);assert(items.length&&items.every(x=>x.method==='multimodal_ai'));assert(items.every(x=>!['vision_ocr','apple_ocr'].includes(x.method)));
  const retrieved=await call('aiRetrieveContext',{courseOfferingId:ready.courseOfferingId,purpose:'lecture_summary',maxCharacters:30000});assert(retrieved.items.some(x=>x.sourceId===source.sourceId));
  const named=await c.request(`https://firestore.googleapis.com/v1/projects/${P}/databases/${D}/documents/aiSources/${source.sourceId}`);assert.equal(named.fields.recognition.mapValue.fields.model.stringValue,m.model);
  await assert.rejects(c.request(`https://firestore.googleapis.com/v1/projects/${P}/databases/(default)/documents/aiSources/${source.sourceId}`),e=>e.httpStatus===404);
  fs.writeFileSync(path.join(output,`result-${i}.json`),JSON.stringify({source:ready,items},null,2),{mode:0o600});state.results.push({image:i,chunks:items.length,recognition:m,status:'PASS'});save();console.log(JSON.stringify({image:i,chunks:items.length,recognition:m,status:'PASS'}));
 }
 const uiResults=[1,2].map(i=>{const v=JSON.parse(fs.readFileSync(path.join(output,`result-${i}.json`)));return {status:v.source.status,pipelineVersion:v.source.pipelineVersion,recognition:v.source.recognition,processingMs:v.source.processingMs,items:v.items.map(({chunkId,text,method,unitIndex,locator})=>({chunkId,text,method,unitIndex,locator}))};});
 fs.mkdirSync(path.join(c.ROOT,'AogakuTests/DevFixtures'),{recursive:true});fs.writeFileSync(path.join(c.ROOT,'AogakuTests/DevFixtures/image-route-dev-results.json'),JSON.stringify(uiResults),{mode:0o600});
 state.status='IMAGE_ROUTE_DEV_E2E_PASS';save();console.log(state.status);
}
main().catch(e=>{console.error('STOP '+e.name+' (see private Dev evidence; no mutation replay)');process.exitCode=1});
