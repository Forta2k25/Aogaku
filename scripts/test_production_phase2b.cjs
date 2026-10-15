const {test}=require('node:test'),assert=require('node:assert/strict');
const p=require('./deploy_production_phase2b.cjs');
const F='https://firestore.googleapis.com/v1/projects/forta-aogaku/databases/';
test('Phase2b named Native Tokyo delete-protected target only',()=>{
 p.validateRequest(F.slice(0,-1)+'?databaseId=aogaku-ai','POST',p.createBody,{apply:true});
 for(const url of [F.slice(0,-1)+'?databaseId=(default)',F.replace('forta-aogaku','forta-aogaku-dev')])assert.throws(()=>p.validateRequest(url,'POST',p.createBody,{apply:true}));
 assert.throws(()=>p.validateRequest(F.slice(0,-1)+'?databaseId=aogaku-ai','POST',{...p.createBody,deleteProtectionState:'DELETE_PROTECTION_DISABLED'},{apply:true}));
 assert.throws(()=>p.validateRequest(F.slice(0,-1)+'?databaseId=aogaku-ai','POST',p.createBody));
});
test('Phase2b exact composite and membership additions, never default/deletion',()=>{
 p.validateRequest(F+'aogaku-ai/collectionGroups/aiSources/indexes','POST',p.indexBody,{apply:true});
 p.validateRequest(F+'aogaku-ai/collectionGroups/memberships/fields/userId?updateMask=indexConfig','PATCH',p.fieldBody,{apply:true});
 for(const [url,method,body]of [[F+'(default)/collectionGroups/aiSources/indexes','POST',p.indexBody],[F+'aogaku-ai/collectionGroups/other/indexes','POST',p.indexBody],[F+'aogaku-ai','DELETE',{}],[F+'aogaku-ai/documents/aiSources/probe','PATCH',{fields:{}}]])assert.throws(()=>p.validateRequest(url,method,body,{apply:true}));
});
test('Phase2b excludes Functions, IAM, payloads, Secret versions, queue, Scheduler, lifecycle',()=>{
 for(const [url,method]of [['https://cloudfunctions.googleapis.com/v2/projects/forta-aogaku/locations/asia-northeast1/functions','POST'],['https://cloudresourcemanager.googleapis.com/v1/projects/forta-aogaku:setIamPolicy','POST'],['https://secretmanager.googleapis.com/v1/projects/forta-aogaku/secrets/GROQ_API_KEY/versions/1:access','GET'],['https://secretmanager.googleapis.com/v1/projects/forta-aogaku/secrets/GROQ_API_KEY:addVersion','POST'],['https://cloudtasks.googleapis.com/v2/projects/forta-aogaku/locations/asia-northeast1/queues/aiProcessSource:resume','POST'],['https://storage.googleapis.com/storage/v1/b/forta-aogaku.firebasestorage.app','PATCH']])assert.throws(()=>p.validateRequest(url,method,{}, {apply:true}));
});
test('Phase2b deny-only ruleset, exact named/storage release, no default release',()=>{
 const fs=require('node:fs'),content=fs.readFileSync('Config/AI/firestore.rules','utf8');
 const rules='https://firebaserules.googleapis.com/v1/projects/forta-aogaku';
 p.validateRequest(rules+'/rulesets','POST',{source:{files:[{name:'security.rules',content}]}},{apply:true});
 assert.throws(()=>p.validateRequest(rules+'/rulesets','POST',{source:{files:[{name:'security.rules',content:'allow read, write: if true;'}]}},{apply:true}));
 const rulesetName='projects/forta-aogaku/rulesets/approved',ctx={apply:true,kind:'named',rulesetNames:new Set([rulesetName])};
 p.validateRequest(rules+'/releases','POST',{name:p.releaseName('named'),rulesetName},ctx);
 assert.throws(()=>p.validateRequest(rules+'/releases','POST',{name:'projects/forta-aogaku/releases/cloud.firestore',rulesetName},ctx));
 assert.throws(()=>p.validateRequest(rules+'/releases','POST',{name:p.releaseName('named'),rulesetName:'unapproved'},ctx));
});
test('Phase2b metadata rejects all protected/default drift',()=>{
 const before={metadata:{rules:{firestore:{content:'existing'},storage:{content:'existing'}}},resources:{queue:{state:'PAUSED'}},protected:{policy:{bindings:[]}}};
 p.protectedSame(before,structuredClone(before));
 for(const mutate of [x=>x.metadata.rules.firestore.content='changed',x=>x.resources.queue.state='RUNNING',x=>x.protected.policy.bindings.push({role:'new'})]){const after=structuredClone(before);mutate(after);assert.throws(()=>p.protectedSame(before,after));}
});
