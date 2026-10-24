#!/usr/bin/env node
// Recognition Lab only: synthetic provider calls, no production API / data persistence / credential output.
const fs=require('node:fs'),path=require('node:path'),cp=require('node:child_process'),assert=require('node:assert/strict'),crypto=require('node:crypto');
process.env.FIREBASE_TOOLS_LIB ||= path.dirname(path.dirname(fs.realpathSync(cp.execFileSync('which',['firebase'],{encoding:'utf8'}).trim())));
const c=require('./dev_cloud.cjs'),D=path.join(c.ROOT,'build/recognition-lab-pricing'),oldD=path.join(c.ROOT,'build/recognition-lab-dev');
fs.mkdirSync(D,{recursive:true,mode:0o700});
const functionURL=`https://cloudfunctions.googleapis.com/v2/projects/${c.PROJECT}/locations/${c.REGION}/functions`;
const name=`projects/${c.PROJECT}/locations/${c.REGION}/functions/recognitionLabRun`;
const near=(a,b)=>assert(typeof a==='number'&&Math.abs(a-b)<1e-10,'Cost formula mismatch');
async function snapshot(){
 c.guard();const project=await c.request(`https://cloudresourcemanager.googleapis.com/v1/projects/${c.PROJECT}`);assert.equal(project.projectId,c.PROJECT);assert.equal(String(project.projectNumber),c.NUMBER);
 const endpoints={functions:functionURL,rules:`https://firebaserules.googleapis.com/v1/projects/${c.PROJECT}/releases`,indexes:`https://firestore.googleapis.com/v1/projects/${c.PROJECT}/databases/(default)/collectionGroups/-/indexes`,namedIndexes:`https://firestore.googleapis.com/v1/projects/${c.PROJECT}/databases/aogaku-ai/collectionGroups/-/indexes`,bucket:`https://storage.googleapis.com/storage/v1/b/${c.BUCKET}`,secretVersions:`https://secretmanager.googleapis.com/v1/projects/${c.PROJECT}/secrets/GROQ_API_KEY/versions`,functionIAM:`https://cloudfunctions.googleapis.com/v2/${name}:getIamPolicy`,runIAM:`https://run.googleapis.com/v2/projects/${c.PROJECT}/locations/${c.REGION}/services/recognitionlabrun:getIamPolicy`};
 const data=Object.fromEntries(await Promise.all(Object.entries(endpoints).map(async([key,url])=>[key,await c.request(url)])));
 for(const value of Object.values(data))assert(!value.nextPageToken,'Paginated inventory needs review');
 const f=data.functions.functions.find(x=>x.name===name);assert(f&&f.state==='ACTIVE');assert.equal(f.buildConfig.runtime,'nodejs22');assert.equal(f.serviceConfig.environmentVariables.RECOGNITION_LAB_ENABLED,'true');
 const cfg=JSON.parse(fs.readFileSync(path.join(c.ROOT,'Config/recognition-lab.local.json')));assert.deepEqual(JSON.parse(f.serviceConfig.environmentVariables.RECOGNITION_LAB_ALLOWED_UIDS),cfg.allowedUIDs);
 return data;
}
async function before(){const file=path.join(D,'before.json');assert(!fs.existsSync(file),'Never overwrite baseline');fs.writeFileSync(file,JSON.stringify(await snapshot(),null,2),{mode:0o600});console.log('PASS: fresh Dev pricing preflight; identity and live/private allowlist match.');}
async function after(){
 const before=JSON.parse(fs.readFileSync(path.join(D,'before.json'))),after=await snapshot();assert.equal(after.functions.functions.length,before.functions.functions.length);
 for(const f of before.functions.functions.filter(x=>x.name!==name))assert.deepEqual(after.functions.functions.find(x=>x.name===f.name),f,'Other Dev Function changed');
 for(const key of Object.keys(before).filter(x=>x!=='functions'))assert.deepEqual(after[key],before[key],'Protected Dev resource drift '+key);
 const a=before.functions.functions.find(x=>x.name===name),b=after.functions.functions.find(x=>x.name===name);
 assert.deepEqual(b.serviceConfig.environmentVariables,a.serviceConfig.environmentVariables);assert.equal(b.serviceConfig.serviceAccountEmail,a.serviceConfig.serviceAccountEmail);assert.deepEqual(b.serviceConfig.secretEnvironmentVariables,a.serviceConfig.secretEnvironmentVariables);assert.deepEqual(b.eventTrigger,a.eventTrigger);assert.equal(b.buildConfig.entryPoint,a.buildConfig.entryPoint);
 const d=await c.request(`https://cloudfunctions.googleapis.com/v2/${name}:generateDownloadUrl`,'POST',{}),u=new URL(d.downloadUrl);assert(u.protocol==='https:'&&(u.hostname==='storage.googleapis.com'||u.hostname.endsWith('.storage.googleapis.com')));
 const r=await fetch(u);assert(r.ok);const bytes=Buffer.from(await r.arrayBuffer());assert(bytes.length<100*1024*1024);
 const manifest=JSON.parse(cp.execFileSync('python3',['-c','import sys,zipfile,io,hashlib,json;z=zipfile.ZipFile(io.BytesIO(sys.stdin.buffer.read()));print(json.dumps({x.filename:hashlib.sha256(z.read(x)).hexdigest() for x in z.infolist() if not x.is_dir()}))'],{input:bytes,maxBuffer:20*1024*1024}));
 for(const file of ['src/pricing.ts','src/domain.ts','src/providers.ts','src/index.ts','lib/pricing.js','lib/domain.js','lib/providers.js','lib/index.js','package.json','package-lock.json'])assert.equal(manifest[file],crypto.createHash('sha256').update(fs.readFileSync(path.join(c.ROOT,'recognition-lab/functions',file))).digest('hex'),'Installed source mismatch '+file);
 fs.writeFileSync(path.join(D,'after.json'),JSON.stringify(after,null,2),{mode:0o600});console.log('PASS: Lab source matches; other Dev Functions, allowlist, IAM, Rules/indexes/bucket/Secret versions unchanged.');
}
async function e2e(){
 const operator=JSON.parse(fs.readFileSync(path.join(oldD,'credentials.json')));assert.equal(operator.projectId,c.PROJECT);
 const login=await fetch('https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key='+encodeURIComponent(operator.clientAPIKey),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email:operator.email,password:operator.password,returnSecureToken:true}),signal:AbortSignal.timeout(30000)});assert(login.ok,'Dev test login failed');const auth=await login.json();assert.equal(auth.localId,operator.uid);
 const endpoint=`https://${c.REGION}-${c.PROJECT}.cloudfunctions.net/recognitionLabRun`;
 async function call(data,token=auth.idToken){const r=await fetch(endpoint,{method:'POST',headers:{'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{})},body:JSON.stringify({data}),signal:AbortSignal.timeout(185000)});const v=await r.json();if(!r.ok)throw Error(v.error?.message||'LAB_HTTP_'+r.status);return v.result??v.data;}
 const prior=process.argv[3]==='--resume-failed'?JSON.parse(fs.readFileSync(path.join(D,'result.json'))):null;
 if(prior){assert.equal(prior.project,c.PROJECT);fs.copyFileSync(path.join(D,'result.json'),path.join(D,'previous-result-'+Date.now()+'.json'));}
 const report=prior||{project:c.PROJECT,syntheticOnly:true,noPersistence:true,checks:[],images:{}};
 const save=()=>fs.writeFileSync(path.join(D,'result.json'),JSON.stringify(report,null,2),{mode:0o600});
 try{await call({kind:'capabilities'},null);assert.fail('Anonymous accepted');}catch(e){assert.equal(e.message,'LAB_AUTH_REQUIRED');if(!report.checks.includes('anonymous denied'))report.checks.push('anonymous denied');}
 const bytes=fs.readFileSync(path.join(oldD,'arrow.jpg'));
 for(const mode of ['vision_ocr','vision_llm','vision_ocr_llm']){
  if(report.checks.includes(mode+' usage/cost PASS'))continue;
  if(prior&&mode==='vision_llm'){console.log('Explicit failed-call recheck after 60s pacing');await new Promise(r=>setTimeout(r,60000));}
  if(mode==='vision_ocr_llm'){console.log('Pacing independent AI call for token budget (60s)');await new Promise(r=>setTimeout(r,60000));}
  const result=await call({kind:'image',mode,mime:'image/jpeg',base64:bytes.toString('base64')});report.images[mode]=result;save();
  if(result.results.some(row=>row.error)){console.log('Provider error retained without invented usage/cost: '+result.results.map(row=>row.error).filter(Boolean).join(','));continue;}
  for(const row of result.results){assert.equal(row.error,null,'Provider error '+row.error);const cost=row.estimatedCost;assert(cost?.pricing);assert.equal(cost.pricing.currency,'USD');assert.equal(cost.pricing.pricingAsOf,'2026-10-08');
   if(row.provider==='groq'){assert(Number.isSafeInteger(row.usage?.promptTokens));assert(Number.isSafeInteger(row.usage?.completionTokens));assert(Number.isSafeInteger(row.usage?.totalTokens));near(cost.inputCostUSD,row.usage.promptTokens/1e6*cost.pricing.inputPrice);near(cost.outputCostUSD,row.usage.completionTokens/1e6*cost.pricing.outputPrice);near(cost.estimatedCostUSD,cost.inputCostUSD+cost.outputCostUSD);}
   else{assert.equal(cost.imageUnits,1);near(cost.estimatedCostUSD,0.0015);}
  }
  assert(result.totalProcessingMs>=0);report.checks.push(mode+' usage/cost PASS');save();console.log('PASS: '+mode+' usage/cost');
 }
 const audio=await call({kind:'audio',mode:'groq_asr',mime:'audio/wav',base64:fs.readFileSync(path.join(oldD,'speech.wav')).toString('base64')});report.audio=audio;save();const row=audio.results[0],cost=row.estimatedCost;assert.equal(row.error,null);assert.equal(cost.pricing.pricingUnit,'audio_hour');near(cost.billedAudioSeconds,Math.max(10,cost.audioDurationSeconds));near(cost.estimatedCostUSD,cost.billedAudioSeconds/3600*0.04);assert(JSON.parse(row.structuredResult).segments.length);report.checks.push('Groq audio duration/cost/timestamps PASS');report.status=['vision_ocr','vision_llm','vision_ocr_llm'].every(mode=>report.checks.includes(mode+' usage/cost PASS'))?'DEV_PRICING_E2E_PASS':'DEV_PRICING_E2E_PARTIAL';save();console.log(report.status+' '+report.checks.length+' checks');if(report.status.endsWith('PARTIAL'))process.exitCode=1;
}
(async()=>{assert(['before','after','e2e'].includes(process.argv[2]));assert(process.argv.length<=4&&[undefined,'--resume-failed'].includes(process.argv[3]));assert(!process.argv[3]||process.argv[2]==='e2e');c.guard();await ({before,after,e2e}[process.argv[2]])();})().catch(e=>{console.error('STOP: '+(e instanceof assert.AssertionError?'Verification failed; inspect private evidence':String(e.message).replace(/https?:\/\/\S+/g,'[URL]')));process.exitCode=1;});
