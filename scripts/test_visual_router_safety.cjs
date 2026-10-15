const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
const {NAMES,protectedCheck,assertReferenceApproval,assertReferenceRun}=require('./visual_router_dev.cjs');
test('Router Dev cohort is exact ten; no legacy, scheduler, trigger, link or production target',()=>{
 assert.equal(NAMES.length,10);assert.equal(new Set(NAMES).size,10);assert(!NAMES.includes('aiReconcileInputs'));assert(!NAMES.includes('aiRejectLateUpload'));assert(!NAMES.includes('aiLinkSourceOffering'));
 const s=fs.readFileSync(__dirname+'/deploy_detection_dev.py','utf8');assert(s.includes("validate_approved() == 'forta-aogaku-dev'"));assert(s.includes("'--visual-router'"));assert(s.includes("'--only'"));
 const d=fs.readFileSync(__dirname+'/visual_router_dev.cjs','utf8');assert(!d.includes(':setIamPolicy'));assert(!d.includes('versions/latest:access'));assert(d.includes('build/visual-router-reference-dev'));assert(!d.includes('--include-reference'));
});
test('new Visual Router cannot reuse the previous AI-only production approval artifact',()=>{
 const old=require('./production_recognition_review.cjs');assert.throws(()=>old.verifyContract(),'Old schema4/image-ai-v2 review must reject Router schema5');
 const source=fs.readFileSync(__dirname+'/production_recognition_review.cjs','utf8');assert(source.includes("assert(i.includes('schemaVersion: 4'))"));assert(source.includes('Existing review cannot be overwritten'));
});
test('Dev post-check accepts only source revisions/generated HTTP metadata; admission/IAM/Secret/Rules drift rejects',()=>{
 const name='aiCreateSource',f={name:'projects/forta-aogaku-dev/locations/asia-northeast1/functions/'+name,state:'ACTIVE',buildConfig:{runtime:'nodejs22'},serviceConfig:{environmentVariables:{AI_FIRESTORE_DATABASE_ID:'aogaku-ai',AI_SHARING_ENABLED:'false',AI_INPUT_ALLOWED_UIDS:'[]'},serviceAccountEmail:'synthetic-runtime',ingressSettings:'ALLOW_ALL',secretEnvironmentVariables:[]}};
 const b={functions:{functions:[f]},database:{locationId:'asia-northeast1',earliestVersionTime:'before',etag:'before'},scheduler:{jobs:[{name:'synthetic-job',state:'PAUSED',scheduleTime:'before'}]},queue:{name:'synthetic-queue',rateLimits:{maxConcurrentDispatches:3},retryConfig:{maxAttempts:4}},rules:{rulesetName:'protected'},runIAM:{bindings:[]},secret:{versions:[1]}};
 const a=structuredClone(b);a.database.earliestVersionTime='after';a.database.etag='after';a.scheduler.jobs[0].scheduleTime='after';a.functions.functions[0].serviceConfig.environmentVariables.FUNCTION_SIGNATURE_TYPE='http';assert.doesNotThrow(()=>protectedCheck(b,a));
 for(const modify of [x=>x.functions.functions[0].serviceConfig.environmentVariables.AI_INPUT_ALLOWED_UIDS='["unauthorized"]',x=>x.functions.functions[0].serviceConfig.environmentVariables.AI_SHARING_ENABLED='true',x=>x.functions.functions[0].serviceConfig.environmentVariables.AI_FIRESTORE_DATABASE_ID='(default)',x=>x.secret.versions=[2],x=>x.rules.rulesetName='other',x=>x.scheduler.jobs[0].state='ENABLED',x=>x.runIAM.bindings=[{role:'roles/editor'}]]){const wrong=structuredClone(a);modify(wrong);assert.throws(()=>protectedCheck(b,wrong));}
});

test('real course PDF has separate consent and evidence; synthetic permission never implies provider submission',()=>{
 for(const args of [[],['--reference-only'],['--approve-reference-provider-send'],['--include-reference']])assert.throws(()=>assertReferenceApproval(args));
 assert.doesNotThrow(()=>assertReferenceApproval(['--reference-only','--approve-reference-provider-send']));
 const s=fs.readFileSync(__dirname+'/visual_router_dev.cjs','utf8');assert(s.includes("'build/visual-router-before/science.pdf'"));assert.doesNotThrow(()=>assertReferenceRun(false,false,[]));assert.throws(()=>assertReferenceRun(false,true,[]));assert.throws(()=>assertReferenceRun(true,true,["--reference-only"]));assert.throws(()=>assertReferenceRun(true,false,["--reference-only","--approve-reference-provider-send"]));assert.doesNotThrow(()=>assertReferenceRun(true,true,["--reference-only","--approve-reference-provider-send"]));assert(s.includes("visual-router-reference-dev-results.json"));
});

test('Eventarc filter order is irrelevant but bucket/type/destination drift remains forbidden',()=>{
 const f={name:'projects/forta-aogaku-dev/locations/asia-northeast1/functions/legacy',serviceConfig:{}};
 const b={functions:{functions:[f]},database:{},scheduler:{},queue:{},eventarc:{triggers:[{name:'test-trigger',eventFilters:[{attribute:'bucket',value:'dev-bucket'},{attribute:'type',value:'finalized'}],destination:{name:'protected'}}]}};
 const a=structuredClone(b);a.eventarc.triggers[0].eventFilters.reverse();assert.doesNotThrow(()=>protectedCheck(b,a));
 for(const mutate of [x=>x.eventarc.triggers[0].eventFilters[0].value='other',x=>x.eventarc.triggers[0].destination.name='other']){const wrong=structuredClone(a);mutate(wrong);assert.throws(()=>protectedCheck(b,wrong));}
});
