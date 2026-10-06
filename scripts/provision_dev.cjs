#!/usr/bin/env node
// Applies only additive, explicitly scoped Dev IAM bindings. No secret values or private keys.
const {PROJECT:P, NUMBER:N, BUCKET:B, REGION:R, request, guard} = require('./dev_cloud.cjs');
const SA = `aogaku-ai-runtime@${P}.iam.gserviceaccount.com`;
const MEMBER = `serviceAccount:${SA}`;
async function createIfAbsent(get, create, body) {
  try { return await request(get); }
  catch(e) { if(e.httpStatus!==404) throw e; }
  return request(create, 'POST', body);
}
async function bind(get, set, member, roles, method='POST', getMethod='GET') {
  const policy = await request(get, getMethod, getMethod==='POST' ? {options:{requestedPolicyVersion:3}} : undefined);
  policy.bindings ||= [];
  let changed=false;
  for(const role of roles) {
    let binding=policy.bindings.find(b=>b.role===role && !b.condition);
    if(!binding) { binding={role,members:[]};policy.bindings.push(binding); }
    if(!binding.members.includes(member)) { binding.members.push(member);changed=true; }
  }
  if(changed) await request(set, method, method==='PUT' ? policy : {policy});
  console.log(JSON.stringify({resource:new URL(set).pathname,member,roles,changed}));
}
async function provision() {
  guard();
  const project = await request(`https://cloudresourcemanager.googleapis.com/v1/projects/${P}`);
  if(project.projectId!==P || project.projectNumber!==N) throw Error('STOP: live Dev identity mismatch');
  await createIfAbsent(`https://iam.googleapis.com/v1/projects/${P}/serviceAccounts/${SA}`,
    `https://iam.googleapis.com/v1/projects/${P}/serviceAccounts`,{accountId:'aogaku-ai-runtime',serviceAccount:{displayName:'Aogaku AI Dev runtime'}});
  const storageAgent = await request(`https://storage.googleapis.com/storage/v1/projects/${P}/serviceAccount`);
  if(storageAgent.email_address !== `service-${N}@gs-project-accounts.iam.gserviceaccount.com`) throw Error('STOP: Storage service agent identity mismatch');
  const projectPolicy = `https://cloudresourcemanager.googleapis.com/v1/projects/${P}`;
  // Project getIamPolicy is POST, unlike service-account/secret policies.
  const policy = await request(`${projectPolicy}:getIamPolicy`,'POST',{options:{requestedPolicyVersion:3}});
  const roles=['roles/datastore.user','roles/cloudtasks.enqueuer','roles/serviceusage.serviceUsageConsumer','roles/cloudfunctions.viewer','roles/eventarc.eventReceiver'];
  policy.bindings ||= [];
  let changed=false;
  for(const [member,list] of [[MEMBER,roles],[`serviceAccount:service-${N}@gs-project-accounts.iam.gserviceaccount.com`,['roles/pubsub.publisher']]]) {
    for(const role of list) {
      let binding=policy.bindings.find(b=>b.role===role && !b.condition);
      if(!binding) {binding={role,members:[]};policy.bindings.push(binding);}
      if(!binding.members.includes(member)) {binding.members.push(member);changed=true;}
    }
  }
  if(changed) await request(`${projectPolicy}:setIamPolicy`,'POST',{policy});
  console.log(JSON.stringify({project:P,runtimeRoles:roles,storageAgentRole:'roles/pubsub.publisher',changed}));
  const self=`https://iam.googleapis.com/v1/projects/${P}/serviceAccounts/${SA}`;
  await bind(`${self}:getIamPolicy`,`${self}:setIamPolicy`,MEMBER,['roles/iam.serviceAccountUser','roles/iam.serviceAccountTokenCreator'],'POST','POST');
  await bind(`https://storage.googleapis.com/storage/v1/b/${B}/iam?optionsRequestedPolicyVersion=3`,
    `https://storage.googleapis.com/storage/v1/b/${B}/iam`,MEMBER,['roles/storage.objectAdmin'],'PUT');
  const secret=`https://secretmanager.googleapis.com/v1/projects/${P}/secrets/GROQ_API_KEY`;
  await createIfAbsent(secret,`https://secretmanager.googleapis.com/v1/projects/${P}/secrets?secretId=GROQ_API_KEY`,{replication:{automatic:{}}});
  await bind(`${secret}:getIamPolicy?options.requestedPolicyVersion=3`,`${secret}:setIamPolicy`,MEMBER,['roles/secretmanager.secretAccessor']);
  console.log('GROQ_API_KEY resource prepared; no secret version or key value was created.');
}
async function invokeBindings() {
  for(const name of ['aiProcessSource','aiRejectLateUpload','aiReconcileInputs']) {
    const func=await request(`https://cloudfunctions.googleapis.com/v2/projects/${P}/locations/${R}/functions/${name}`);
    if(!func.serviceConfig?.service?.startsWith(`projects/${P}/locations/${R}/services/`)) throw Error('STOP: service is outside Dev');
    const service=`https://run.googleapis.com/v2/${func.serviceConfig.service}`;
    await bind(`${service}:getIamPolicy?options.requestedPolicyVersion=3`,`${service}:setIamPolicy`,MEMBER,['roles/run.invoker']);
  }
}
if(require.main===module) (process.argv[2]==='runtime' ? provision() : process.argv[2]==='invoke' ? invokeBindings() : Promise.reject(Error('Usage: provision_dev.cjs runtime|invoke')))
  .catch(e=>{console.error(e.message);process.exitCode=1;});
