const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
const p=require('./deploy_production_phase4_completion.cjs'),p1=require('./provision_production_phase1.cjs'),{hash}=require('./deploy_production_phase3a.cjs');
const P='forta-aogaku',R='asia-northeast1',SA='aogaku-ai-runtime@'+P+'.iam.gserviceaccount.com',G='https://cloudfunctions.googleapis.com/v2/',parent=`projects/${P}/locations/${R}`,source={bucket:'gcf-v2-uploads-505828754933-asia-northeast1',object:'fresh.zip'},c={apply:true,applyAction:'create',created:[],sources:new Set([hash(source)])};
test('Only two absent Functions can be created; successful ten immutable',()=>{
 assert.equal(p.EXISTING_TEN.length,10);assert.deepEqual(p.NAMES,['aiReconcileInputs','aiRejectLateUpload']);
 for(const n of p.NAMES)p.validate(G+parent+'/functions?functionId='+n,'POST',p.payload(n,source),c);
 for(const n of p.EXISTING_TEN){assert.throws(()=>p.validate(G+parent+'/functions?functionId='+n,'POST',p.payload(n,source),c));for(const m of ['PATCH','DELETE'])assert.throws(()=>p.validate(G+parent+'/functions/'+n,m,{},c));}
});
test('Worker IAM action allows only exact Function metadata role, never worker Run or project bindings',()=>{
 const url=G+parent+'/functions/aiProcessSource:setIamPolicy',before={etag:'fresh',version:3,bindings:[]},allowed=[{member:'serviceAccount:'+SA,roles:['projects/'+P+'/roles/aogakuAIFunctionMetadata']}],body={policy:p1.merge(before,allowed)},ctx={apply:true,applyAction:'workeriam',created:[],iamWrite:{url,before,allowed,function:'aiProcessSource'}};
 p.validate(url,'POST',body,ctx);assert.throws(()=>p.validate(url,'POST',body,{...ctx,applyAction:'create'}));
 for(const u of ['https://run.googleapis.com/v1/'+parent+'/services/aiprocesssource:setIamPolicy','https://cloudresourcemanager.googleapis.com/v1/projects/'+P+':setIamPolicy'])assert.throws(()=>p.validate(u,'POST',body,{...ctx,iamWrite:{...ctx.iamWrite,url:u}}));
 const bad=structuredClone(body);bad.policy.bindings.push({role:'roles/run.invoker',members:['allUsers']});assert.throws(()=>p.validate(url,'POST',bad,ctx));
});
test('Existing23 IAM baseline permits only one exact worker Function binding; worker Run stays immutable',()=>{
 const b={metadata:{functions:[],readAt:'before'},iam:{aiProcessSource:{etag:'run',bindings:[{role:'roles/run.invoker',members:['serviceAccount:'+SA]}]},aiProcessSourceFunctionIAM:{etag:'function',bindings:[]}},keys:{},secrets:{},functions:[],resources:{apis:[],serviceAccounts:[],queue:{state:'PAUSED'},scheduler:{data:{}},eventarc:{data:{}}}},a=structuredClone(b);
 p.protectedSame(b,a,[]);a.iam.aiProcessSourceFunctionIAM=p1.merge(a.iam.aiProcessSourceFunctionIAM,[{member:'serviceAccount:'+SA,roles:['projects/'+P+'/roles/aogakuAIFunctionMetadata']}]);a.iam.aiProcessSourceFunctionIAM.etag='updated';p.protectedSame(b,a,[],true);assert.throws(()=>p.protectedSame(b,a,[],false));a.iam.aiProcessSource.etag='changed';assert.throws(()=>p.protectedSame(b,a,[],true));
});
test('Public invoker, Secret payload, resume and source substitution remain prohibited',()=>{
 const u='https://secretmanager.googleapis.com/v1/projects/'+P+'/secrets/GROQ_API_KEY/versions/1:access';assert.throws(()=>p.validate(u,'GET',undefined,{extraReads:new Set([u])}));
 for(const u of ['https://cloudscheduler.googleapis.com/v1/'+p.JOB+':resume','https://cloudtasks.googleapis.com/v2/'+parent+'/queues/aiProcessSource:resume'])assert.throws(()=>p.validate(u,'POST',{},c));
 const n=p.NAMES[0],b=p.payload(n,source);b.serviceConfig.environmentVariables.AI_INPUT_ALLOWED_UIDS='["uid"]';assert.throws(()=>p.validate(G+parent+'/functions?functionId='+n,'POST',b,c));
});
test('New independent journal/fresh23 approval preserves both old STOPPED journals and verifies zero Scheduler attempts',()=>{
 const s=fs.readFileSync(__dirname+'/deploy_production_phase4_completion.cjs','utf8');assert(s.includes('build/production-phase4-completion'));assert(s.includes('before.functions.length,23'));assert(s.includes("j.status='STOPPED'"));assert(s.includes('Scheduler attempted execution'));assert(!s.includes('retry('));
 for(const [d,count] of [['production-phase4',4],['production-phase4-resume',6]]){const j=JSON.parse(fs.readFileSync(__dirname+'/../build/'+d+'/execution.json'));assert.equal(j.status,'STOPPED');assert.equal(j.created.length,count);}
});
