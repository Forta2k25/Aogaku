const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const p=require('./deploy_production_phase4_resume.cjs'),{hash}=require('./deploy_production_phase3a.cjs');
const P='forta-aogaku',R='asia-northeast1',parent=`projects/${P}/locations/${R}`,G='https://cloudfunctions.googleapis.com/v2/',source={bucket:'gcf-v2-uploads-505828754933-asia-northeast1',object:'fresh.zip'},c={apply:true,created:[],sources:new Set([hash(source)])};
test('Resume CREATE allowlist is remaining eight; successful four cannot be recreated, patched or deleted',()=>{
 assert.equal(p.NAMES.length,8);assert.equal(p.FIRST_FOUR.length,4);
 for(const n of p.NAMES)p.validate(G+parent+'/functions?functionId='+n,'POST',p.payload(n,source),c);
 for(const n of p.FIRST_FOUR){assert.throws(()=>p.validate(G+parent+'/functions?functionId='+n,'POST',p.payload(n,source),c));for(const method of ['PATCH','DELETE'])assert.throws(()=>p.validate(G+parent+'/functions/'+n,method,{},c));}
});
test('Remaining creates still reject duplicate targets, stale/unissued staging and nonclosed payloads',()=>{
 const n=p.NAMES[0],url=G+parent+'/functions?functionId='+n,b=p.payload(n,source);
 assert.throws(()=>p.validate(url,'POST',b,{...c,created:[n]}));assert.throws(()=>p.validate(url,'POST',b,{...c,sources:new Set()}));
 const bad=structuredClone(b);bad.serviceConfig.environmentVariables.AI_INPUT_ALLOWED_UIDS='["uid"]';assert.throws(()=>p.validate(url,'POST',bad,c));
});
test('Secret payload, public ingress, project IAM and resume mutations are forbidden',()=>{
 assert.throws(()=>p.validate('https://secretmanager.googleapis.com/v1/projects/'+P+'/secrets/GROQ_API_KEY/versions/1:access','GET',undefined,{extraReads:new Set(['https://secretmanager.googleapis.com/v1/projects/'+P+'/secrets/GROQ_API_KEY/versions/1:access'])}));
 for(const u of ['https://cloudresourcemanager.googleapis.com/v1/projects/'+P+':setIamPolicy','https://cloudscheduler.googleapis.com/v1/'+p.JOB+':resume','https://cloudtasks.googleapis.com/v2/'+parent+'/queues/aiProcessSource:resume'])assert.throws(()=>p.validate(u,'POST',{},c));
});
test('Protected baseline includes all seventeen, their IAM and sources/updateTimes; first four cannot drift',()=>{
 const b={metadata:{readAt:'old',functions:[],namedDatabase:{name:'aogaku-ai',etag:'old',earliestVersionTime:'old'}},functions:[...Array(13)].map((_,i)=>({name:parent+'/functions/old'+i,updateTime:'fixed'})).concat(p.FIRST_FOUR.map(n=>({name:parent+'/functions/'+n,updateTime:'fixed'}))),iam:{firstFour:'private'},keys:{},secrets:{},resources:{apis:[],serviceAccounts:[],queue:{data:{state:'PAUSED'}},scheduler:{data:{}},eventarc:{data:{}}}};
 const a=structuredClone(b);a.functions.push({name:parent+'/functions/'+p.NAMES[0],updateTime:'new'});p.protectedSame(b,a,[p.NAMES[0]]);
 a.functions[13].updateTime='changed';assert.throws(()=>p.protectedSame(b,a,[p.NAMES[0]]));a.functions[13].updateTime='fixed';a.iam.firstFour='public';assert.throws(()=>p.protectedSame(b,a,[p.NAMES[0]]));
});
test('Independent execution directory and fresh seventeen-source approval; read errors stop without CREATE retries',()=>{
 const s=fs.readFileSync(path.join(__dirname,'deploy_production_phase4_resume.cjs'),'utf8');
 assert(s.includes('build/production-phase4-resume'));assert(s.includes('before.functions.length,17'));assert(s.includes("j.status='STOPPED'"));assert(s.includes('individual sequential allowlist order'));assert(!s.includes('retry('));assert(s.includes("new URL(url).pathname"));assert(s.includes('approvedAt:new Date().toISOString()'));
 const old=JSON.parse(fs.readFileSync(path.resolve(__dirname,'../build/production-phase4/execution.json')));assert.equal(old.status,'STOPPED');assert.equal(old.created.length,4);
});
