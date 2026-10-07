const {test}=require('node:test'),assert=require('node:assert/strict'),{spawnSync}=require('node:child_process');
const p=require('./deploy_production_phase4.cjs'),P='forta-aogaku',R='asia-northeast1',SA='aogaku-ai-runtime@'+P+'.iam.gserviceaccount.com';
const G='https://cloudfunctions.googleapis.com/v2/',parent=`projects/${P}/locations/${R}`,source={bucket:'gcf-v2-uploads-505828754933-asia-northeast1',object:'fresh.zip'};
test('Exact AI12 payloads preserve empty cohort, named DB, SA; no public policy or Secret value',()=>{
 for(const n of p.NAMES){const body=p.payload(n,source);assert.equal(body.name,parent+'/functions/'+n);assert.equal(body.environment,'GEN_2');assert.equal(body.buildConfig.runtime,'nodejs22');assert.equal(body.serviceConfig.serviceAccountEmail,SA);assert.equal(body.serviceConfig.environmentVariables.AI_INPUT_ALLOWED_UIDS,'[]');assert.equal(body.serviceConfig.environmentVariables.AI_FIRESTORE_DATABASE_ID,'aogaku-ai');assert.equal(body.serviceConfig.environmentVariables.AI_SHARING_ENABLED,'false');assert.equal(body.labels['firebase-functions-codebase'],'aogaku-ai');assert(!JSON.stringify(body).includes('allUsers'));assert(!body.serviceConfig.secretEnvironmentVariables);}
 const event=p.payload('aiRejectLateUpload',source).eventTrigger;assert.equal(event.triggerRegion,'us-central1');assert.deepEqual(event.eventFilters,[{attribute:'bucket',value:P+'.firebasestorage.app'}]);assert.equal(event.serviceAccountEmail,SA);
});
test('Mutation guard rejects legacy replacement, PATCH, DELETE, API/IAM expansion, rotation and resume',()=>{
 for(const [url,method,body]of [[G+parent+'/functions?functionId=askCourseAI','POST',{}],[G+parent+'/functions/aiCreateSource','PATCH',{}],[G+parent+'/functions/aiCreateSource','DELETE'],['https://cloudresourcemanager.googleapis.com/v1/projects/'+P+':setIamPolicy','POST',{policy:{}}],['https://secretmanager.googleapis.com/v1/projects/'+P+'/secrets/GROQ_API_KEY:addVersion','POST',{}],['https://cloudscheduler.googleapis.com/v1/'+p.JOB+':resume','POST',{}],['https://cloudtasks.googleapis.com/v2/projects/'+P+'/locations/'+R+'/queues/aiProcessSource:resume','POST',{}]])assert.throws(()=>p.validate(url,method,body,{apply:true,created:[]}));
});
test('Create requires exact allowlist, exact payload, newly-issued source and absent target',()=>{
 const n=p.NAMES[0],body=p.payload(n,source),context={apply:true,created:[],sources:new Set([require('./deploy_production_phase3a.cjs').hash(source)])};
 p.validate(G+parent+'/functions?functionId='+n,'POST',body,context);
 assert.throws(()=>p.validate(G+parent+'/functions?functionId='+n,'POST',body,{...context,created:[n]}));
 assert.throws(()=>p.validate(G+parent+'/functions?functionId='+n,'POST',body,{...context,sources:new Set()}));
 const bad=structuredClone(body);bad.serviceConfig.environmentVariables.AI_INPUT_ALLOWED_UIDS='["everyone"]';assert.throws(()=>p.validate(G+parent+'/functions?functionId='+n,'POST',bad,context));
});
test('Resource IAM only permits additive exact runtime identity and rejects public invoker',()=>{
 const url='https://run.googleapis.com/v1/projects/'+P+'/locations/'+R+'/services/aiprocesssource:setIamPolicy',before={etag:'current',version:3,bindings:[]},allowed=[{member:'serviceAccount:'+SA,roles:['roles/run.invoker']}],context={apply:true,created:['aiProcessSource'],iamWrite:{url,before,allowed,function:'aiProcessSource'}};
 const policy=require('./provision_production_phase1.cjs').merge(before,allowed);p.validate(url,'POST',{policy},context);
 assert.throws(()=>p.validate(url,'POST',{policy:{...policy,bindings:[{role:'roles/run.invoker',members:['allUsers']}]}},context));
 assert.throws(()=>p.validate(url,'POST',{policy}, {...context,created:[]}));
});
test('Exact installed package is closed before any Firestore/Auth/provider I/O; background is inert',()=>{
 const code=`global.fetch=async()=>{throw Error('REAL_NETWORK_FORBIDDEN')};const assert=require('node:assert/strict'),api=require('./build/production-functions');(async()=>{for(const n of ${JSON.stringify(p.NAMES.slice(0,9))}){await assert.rejects(()=>api[n].run({data:{},auth:{uid:'ordinary-authenticated'}}),e=>e.message==='AI_INPUT_NOT_ENABLED');await assert.rejects(()=>api[n].run({data:{}}),e=>e.code==='unauthenticated');}await assert.rejects(()=>api.aiProcessSource.run({data:{databaseId:'aogaku-ai',sourceId:'a'.repeat(64)}}),e=>e.message==='AI_INPUT_NOT_ENABLED');await api.aiReconcileInputs.run({});for(const name of ['avatars/existing.jpg','users/existing/audio.m4a','ai-derived/aogaku-ai/u/s/x','ai-inputs/other-db/u/s/original'])await api.aiRejectLateUpload.run({data:{name,bucket:'forta-aogaku.firebasestorage.app'}});console.log('CLOSED_NO_IO_PASS')})().catch(e=>{console.error(e);process.exitCode=1});`;
 const r=spawnSync(process.execPath,['-e',code],{cwd:require('node:path').resolve(__dirname,'..'),env:{...process.env,...p.env()},encoding:'utf8'});assert.equal(r.status,0,r.stderr);assert(r.stdout.includes('CLOSED_NO_IO_PASS'));
});
test('Exact package rejects every explicit invalid DB ID and accepts absent/fixed named ID',()=>{
 for(const [v,ok]of [[undefined,true],['aogaku-ai',true],['',false],['(default)',false],['other-db',false]]){const env={...process.env,...p.env()};delete env.AI_FIRESTORE_DATABASE_ID;if(v!==undefined)env.AI_FIRESTORE_DATABASE_ID=v;const r=spawnSync(process.execPath,['-e',"try{console.log(require('./build/production-functions/lib/ai/databases.js').aiDatabaseId())}catch(e){console.error(e.message);process.exitCode=1}"],{cwd:require('node:path').resolve(__dirname,'..'),env,encoding:'utf8'});assert.equal(r.status,ok?0:1);assert.equal(ok?r.stdout.trim():r.stderr.trim(),ok?'aogaku-ai':'AI_DATABASE_MISMATCH');}
});
