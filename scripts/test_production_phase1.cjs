const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {assertRequest,merge,preserved,agentConfirmed,policyCore,noUnplannedAdditions,policies}=require('./provision_production_phase1.cjs');
const P='forta-aogaku',N='505828754933',context={apply:true};
test('Phase 1 enables only explicitly approved APIs, with authorization required',()=>{
 const url=`https://serviceusage.googleapis.com/v1/projects/${N}/services:batchEnable`;
 assertRequest(url,'POST',{serviceIds:['vision.googleapis.com']},context);
 assert.throws(()=>assertRequest(url,'POST',{serviceIds:['vision.googleapis.com']}));
 assert.throws(()=>assertRequest(url,'POST',{serviceIds:['identitytoolkit.googleapis.com']},context));
 assert.throws(()=>assertRequest(url.replace(N,'1064661805206'),'POST',{serviceIds:['vision.googleapis.com']},context));
});
test('Phase 1 refuses deploy, Auth/data/object mutation, Secret rotation/payload and SA keys',()=>{
 for(const [url,method] of [
 [`https://cloudfunctions.googleapis.com/v2/projects/${P}/locations/asia-northeast1/functions`,'POST'],
 [`https://firestore.googleapis.com/v1/projects/${P}/databases/(default)/documents/users/test`,'PATCH'],
 [`https://storage.googleapis.com/storage/v1/b/${P}.firebasestorage.app/o/raw`,'DELETE'],
 [`https://secretmanager.googleapis.com/v1/projects/${P}/secrets/GROQ_API_KEY/versions/1:access`,'GET'],
 [`https://secretmanager.googleapis.com/v1/projects/${P}/secrets/GROQ_API_KEY:addVersion`,'POST'],
 [`https://iam.googleapis.com/v1/projects/${P}/serviceAccounts/aogaku-ai-runtime@${P}.iam.gserviceaccount.com/keys`,'POST'],
 [`https://cloudtasks.googleapis.com/v2/projects/${P}/locations/asia-northeast1/queues/aiProcessSource:resume`,'POST']
 ])assert.throws(()=>assertRequest(url,method,{},context));
});
test('IAM merge preserves conditional members and etag; removal and unplanned additions rejected',()=>{
 const before={etag:'fresh',version:3,bindings:[{role:'roles/viewer',members:['user:existing@example.test'],condition:{title:'old',expression:'true'}}]};
 const allowed=[{member:`serviceAccount:aogaku-ai-runtime@${P}.iam.gserviceaccount.com`,roles:['roles/datastore.user']}],desired=merge(before,allowed);
 assert.equal(desired.etag,before.etag);assert.deepEqual(before.bindings,desired.bindings.slice(0,1));
 assertRequest(policies.project.set,'POST',{policy:desired},{...context,beforePolicy:before,allowedBindings:allowed});
 const removed=structuredClone(desired);removed.bindings.shift();assert.throws(()=>preserved(before,removed));
 const broad=structuredClone(desired);broad.bindings.push({role:'roles/owner',members:[allowed[0].member]});assert.throws(()=>assertRequest(policies.project.set,'POST',{policy:broad},{...context,beforePolicy:before,allowedBindings:allowed}));
});
test('queue creation uses exact plan and explicit pause, never output-only state',()=>{
 const body=JSON.parse(fs.readFileSync(path.join(__dirname,'../Config/Production/queue.create.json'))),url=`https://cloudtasks.googleapis.com/v2/projects/${P}/locations/asia-northeast1/queues`;
 assertRequest(url,'POST',body,context);assertRequest('https://cloudtasks.googleapis.com/v2/'+body.name+':pause','POST',{},context);
 assert.throws(()=>assertRequest(url,'POST',{...body,state:'PAUSED'},context));
 assert.throws(()=>assertRequest('https://cloudtasks.googleapis.com/v2/'+body.name+':purge','POST',{},context));
});
test('only two named service accounts and exact custom-role permissions may be created',()=>{
 const base=`https://iam.googleapis.com/v1/projects/${P}`;
 assertRequest(base+'/serviceAccounts','POST',{accountId:'aogaku-ai-runtime',serviceAccount:{displayName:'AI'}},context);
 assert.throws(()=>assertRequest(base+'/serviceAccounts','POST',{accountId:'other',serviceAccount:{displayName:'other'}},context));
 assertRequest(base+'/roles','POST',{roleId:'aogakuAIAuthRead',role:{title:'AI read',stage:'GA',includedPermissions:['firebaseauth.users.get']}},context);
 assert.throws(()=>assertRequest(base+'/roles','POST',{roleId:'aogakuAIAuthRead',role:{title:'AI read',stage:'GA',includedPermissions:['firebaseauth.users.delete']}},context));
});
test('managed-agent proof requires exact project-number identity and serviceAgent role',()=>{
 const a={serviceAccount:`service-${N}@gcp-sa-cloudtasks.iam.gserviceaccount.com`,role:'roles/cloudtasks.serviceAgent'};
 assert(agentConfirmed({bindings:[{role:a.role,members:['serviceAccount:'+a.serviceAccount]}]},a));
 assert(!agentConfirmed({bindings:[{role:'roles/editor',members:['serviceAccount:'+a.serviceAccount]}]},a));
 assert(!agentConfirmed({bindings:[{role:a.role,members:['serviceAccount:other@example.test']}]},a));
});
test('resume refuses APIs/runtime SAs/custom role recreation and Tasks/Scheduler agent regeneration',()=>{
 const c={apply:true,resume:true};
 for(const [url,body] of [
 [`https://serviceusage.googleapis.com/v1/projects/${N}/services:batchEnable`,{serviceIds:['vision.googleapis.com']}],
 [`https://iam.googleapis.com/v1/projects/${P}/serviceAccounts`,{accountId:'aogaku-ai-runtime',serviceAccount:{displayName:'AI'}}],
 [`https://iam.googleapis.com/v1/projects/${P}/roles`,{roleId:'aogakuAIAuthRead',role:{title:'AI',stage:'GA',includedPermissions:['firebaseauth.users.get']}}],
 [`https://serviceusage.googleapis.com/v1beta1/projects/${N}/services/cloudtasks.googleapis.com:generateServiceIdentity`,{}],
 [`https://serviceusage.googleapis.com/v1beta1/projects/${N}/services/cloudscheduler.googleapis.com:generateServiceIdentity`,{}]
 ])assert.throws(()=>assertRequest(url,'POST',body,c));
 assertRequest(`https://serviceusage.googleapis.com/v1beta1/projects/${N}/services/eventarc.googleapis.com:generateServiceIdentity`,'POST',{},c);
});
test('drift proof accepts etag/member ordering changes, rejects removal and unrelated additions',()=>{
 const original={etag:'a',version:3,bindings:[{role:'roles/viewer',members:['user:b@example.test','user:a@example.test']}]},other=structuredClone(original);other.etag='b';other.bindings[0].members.reverse();assert.deepEqual(policyCore(original),policyCore(other));
 const allowed=[{member:`serviceAccount:aogaku-ai-runtime@${P}.iam.gserviceaccount.com`,roles:['roles/datastore.user']}];noUnplannedAdditions(original,merge(original,allowed),allowed);
 other.bindings.push({role:'roles/viewer',members:['user:unknown@example.test']});assert.throws(()=>noUnplannedAdditions(original,other,allowed));
 assert.throws(()=>noUnplannedAdditions(original,{bindings:[]},allowed));
});
