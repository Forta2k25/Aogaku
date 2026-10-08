#!/usr/bin/env node
// Dev-only, comparison-only: no DB, Storage, ingestion, queue, account creation or deletion.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const ROOT=path.resolve(__dirname,'..'),D=path.join(ROOT,'build/recognition-lab-dev'),P='forta-aogaku-dev';
async function main(){
 assert(process.argv.length<=3&&[undefined,'--resume-failed'].includes(process.argv[2]));
 const operator=JSON.parse(fs.readFileSync(path.join(D,'credentials.json'))),config=JSON.parse(fs.readFileSync(path.join(ROOT,'Config/firebase-development.json')));
 assert.equal(operator.projectId,P);assert.equal(config.projectId,P);assert.equal(config.projectNumber,'1064661805206');
 const key=operator.clientAPIKey;assert(typeof key==='string');
 const login=await fetch('https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key='+encodeURIComponent(key),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email:operator.email,password:operator.password,returnSecureToken:true}),signal:AbortSignal.timeout(30000)});
 assert(login.ok,'Dev authentication failed HTTP '+login.status);const auth=await login.json();assert.equal(auth.localId,operator.uid);assert(auth.idToken);
 const endpoint='https://asia-northeast1-'+P+'.cloudfunctions.net/recognitionLabRun';
 async function call(data,token=auth.idToken){const r=await fetch(endpoint,{method:'POST',headers:{'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{})},body:JSON.stringify({data}),signal:AbortSignal.timeout(185000)});if(!r.headers.get('content-type')?.includes('application/json')){await r.body?.cancel();throw Error('LAB_HTTP_'+r.status+'_NON_JSON');}const v=await r.json();if(!r.ok)throw Error(v.error?.message||'LAB_HTTP_'+r.status);return v.result??v.data;}
 const prior=process.argv[2]==='--resume-failed'?JSON.parse(fs.readFileSync(path.join(D,'result.json'))):null;
 const report=prior||{project:P,comparisonOnly:true,noPersistence:true,checks:[],images:{}};assert.equal(report.project,P);report.capabilities=await call({kind:'capabilities'});
 if(prior){fs.copyFileSync(path.join(D,'result.json'),path.join(D,'previous-result-'+Date.now()+'.json'));report.retest={reason:'Explicit failed-fixture recheck after instruct-mode token budget fix',previousFailures:report.checks.filter(x=>x.status==='FAIL').length};}
 const save=()=>fs.writeFileSync(path.join(D,'result.json'),JSON.stringify(report,null,2),{mode:0o600});save();
 try {await call({kind:'capabilities'},null);throw Error('Anonymous accepted');}catch(e){assert.equal(e.message,'LAB_AUTH_REQUIRED');if(!report.checks.some(x=>x.name==='anonymous'))report.checks.push({name:'anonymous',status:'PASS'});}
 const files=['slide','handwriting','arrow','enclosure','diagram'];let lastVisionAt=0;
 for(const name of files){const bytes=fs.readFileSync(path.join(D,name+'.jpg'));report.images[name]||={};for(const mode of ['vision_ocr','vision_llm','vision_ocr_llm']){
   if(prior&&report.checks.some(x=>x.name===name+'/'+mode&&x.status==='PASS'))continue;
   if(mode!=='vision_ocr'){const remaining=60000-(Date.now()-lastVisionAt);if(remaining>0){console.log('Pacing next independent vision comparison for account token budget');await new Promise(resolve=>setTimeout(resolve,remaining));}lastVisionAt=Date.now();}
   const result=await call({kind:'image',mime:'image/jpeg',mode,base64:bytes.toString('base64')});report.images[name][mode]=result;
   assert(result.results.length===(mode==='vision_ocr_llm'?2:1));const errors=result.results.map(x=>x.error).filter(Boolean);const status=errors.length?'FAIL':'PASS';
   if(!errors.length)assert(result.finalEvidenceText.trim());if(mode==='vision_ocr_llm'&&!result.results[0].error)assert.equal(result.ocrTextProvidedToAI,result.results[0].rawText);
   report.checks=report.checks.filter(x=>x.name!==name+'/'+mode);report.checks.push({name:name+'/'+mode,status,errors});save();console.log(status+' image '+name+'/'+mode+(errors.length?' '+errors.join(','):''));
 }}
 if(!prior||!report.checks.some(x=>x.name==='groq audio timestamps'&&x.status==='PASS')){const audio=await call({kind:'audio',mime:'audio/wav',mode:'groq_asr',base64:fs.readFileSync(path.join(D,'speech.wav')).toString('base64')});report.audio=audio;if(!audio.results[0].error){assert(audio.results[0].rawText.trim());assert(JSON.parse(audio.results[0].structuredResult).segments.length);}report.checks=report.checks.filter(x=>x.name!=='groq audio timestamps');report.checks.push({name:'groq audio timestamps',status:audio.results[0].error?'FAIL':'PASS',error:audio.results[0].error});save();}
 // Provider output is evidence for manual quality comparison, never silently an accuracy PASS.
 report.status=report.checks.every(x=>x.status==='PASS')?'DEV_TRANSPORT_E2E_PASS':'DEV_TRANSPORT_E2E_PARTIAL';save();console.log(JSON.stringify({status:report.status,imageCalls:15,audioCalls:1,model:report.capabilities.imageModel,checks:report.checks.length}));if(report.status.endsWith('PARTIAL'))process.exitCode=1;
}
main().catch(e=>{const safe=String(e.message).replace(/https?:\/\/\S+/g,'[URL]');console.error('STOP: '+safe);process.exitCode=1;});
