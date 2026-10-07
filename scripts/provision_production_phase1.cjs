#!/usr/bin/env node
// Only user-authorized Phase 1. No Functions, Rules, indexes, objects, Auth or Secret versions mutation.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto'),{execFileSync}=require('node:child_process');
const ROOT=path.resolve(__dirname,'..'),P='forta-aogaku',N='505828754933',B=P+'.firebasestorage.app',R='asia-northeast1';
const load=p=>JSON.parse(fs.readFileSync(path.join(ROOT,p))),plan=load('Config/Production/iam.plan.json');
const AI=plan.serviceAccount,DEL=plan.accountDeletionRuntime.serviceAccount,Q=`projects/${P}/locations/${R}/queues/aiProcessSource`;
const APIs=['cloudtasks.googleapis.com','cloudscheduler.googleapis.com','vision.googleapis.com'];
const roles={...plan.customRoles,...plan.accountDeletionRuntime.customRoles};
const agents=plan.managedServiceAgents;
const serviceForAgent={'cloudtasks':'cloudtasks.googleapis.com','cloudscheduler':'cloudscheduler.googleapis.com','eventarc':'eventarc.googleapis.com','pubsub':'pubsub.googleapis.com','cloudfunctions':'cloudfunctions.googleapis.com'};
const policies={
 project:{get:`https://cloudresourcemanager.googleapis.com/v1/projects/${P}:getIamPolicy`,set:`https://cloudresourcemanager.googleapis.com/v1/projects/${P}:setIamPolicy`,getMethod:'POST'},
 bucket:{get:`https://storage.googleapis.com/storage/v1/b/${B}/iam?optionsRequestedPolicyVersion=3`,set:`https://storage.googleapis.com/storage/v1/b/${B}/iam`,setMethod:'PUT'},
 secret:{get:`https://secretmanager.googleapis.com/v1/projects/${P}/secrets/GROQ_API_KEY:getIamPolicy?options.requestedPolicyVersion=3`,set:`https://secretmanager.googleapis.com/v1/projects/${P}/secrets/GROQ_API_KEY:setIamPolicy`},
 self:{get:`https://iam.googleapis.com/v1/projects/${P}/serviceAccounts/${AI}:getIamPolicy`,set:`https://iam.googleapis.com/v1/projects/${P}/serviceAccounts/${AI}:setIamPolicy`,getMethod:'POST'},
 queue:{get:`https://cloudtasks.googleapis.com/v2/${Q}:getIamPolicy`,set:`https://cloudtasks.googleapis.com/v2/${Q}:setIamPolicy`,getMethod:'POST'}
};
function bindingKey(b){return JSON.stringify({role:b.role,condition:b.condition||null});}
function preserved(before,after){for(const b of before.bindings||[]){const a=(after.bindings||[]).find(x=>bindingKey(x)===bindingKey(b));assert(a&&b.members.every(m=>a.members.includes(m)),'STOP: pre-existing IAM binding removed');}}
function merge(policy,bindings){const out=structuredClone(policy);out.bindings||=[];for(const {member,roles:list} of bindings)for(const role of list){assert(!['roles/owner','roles/editor'].includes(role));let b=out.bindings.find(b=>b.role===role&&!b.condition);if(!b){b={role,members:[]};out.bindings.push(b);}if(!b.members.includes(member))b.members.push(member);}preserved(policy,out);return out;}
function agentConfirmed(policy,agent){return (policy.bindings||[]).some(b=>b.role===agent.role&&!b.condition&&b.members.includes('serviceAccount:'+agent.serviceAccount));}
function policyCore(p){return {version:p.version||1,auditConfigs:p.auditConfigs||[],bindings:(p.bindings||[]).map(b=>({...b,members:[...b.members].sort()})).sort((a,b)=>bindingKey(a).localeCompare(bindingKey(b)))};}
function noUnplannedAdditions(before,after,allowed){preserved(before,after);preserved(after,merge(before,allowed));}
const SAURL=email=>`https://iam.googleapis.com/v1/projects/${P}/serviceAccounts/${email}`;
function assertRequest(url,method='GET',body,context={}){
 const reads=new Set([
 `https://cloudresourcemanager.googleapis.com/v1/projects/${P}`,`https://storage.googleapis.com/storage/v1/b/${B}`,`https://firebase.googleapis.com/v1beta1/projects/${P}/iosApps?pageSize=100`,
 `https://serviceusage.googleapis.com/v1/projects/${N}/services?filter=state:ENABLED&pageSize=200`,
 `https://cloudfunctions.googleapis.com/v2/projects/${P}/locations/-/functions`,
 `https://secretmanager.googleapis.com/v1/projects/${P}/secrets/GROQ_API_KEY/versions?pageSize=100`,
 `https://storage.googleapis.com/storage/v1/projects/${P}/serviceAccount`,`https://cloudtasks.googleapis.com/v2/${Q}`,
 ...[AI,DEL,...agents.map(a=>a.serviceAccount)].map(SAURL),...Object.keys(roles).map(id=>`https://iam.googleapis.com/v1/projects/${P}/roles/${id}`)
 ,...[AI,DEL].map(email=>SAURL(email)+'/keys?keyTypes=USER_MANAGED')
 ]);
 if(method==='GET'&&(reads.has(url)||Object.values(policies).some(p=>p.get===url&&p.getMethod!=='POST')))return;
 if(method==='POST'&&Object.values(policies).some(p=>p.get===url&&p.getMethod==='POST')){assert.deepEqual(body,{options:{requestedPolicyVersion:3}});return;}
 if(method==='GET'&&context.operationNames?.has(url))return;
 assert.equal(context.apply,true,'STOP: Phase 1 mutation not authorized');
 if(context.resume){
  assert(!url.endsWith('/services:batchEnable')&&!url.endsWith('/serviceAccounts')&&!url.endsWith('/roles'),'STOP: resume cannot recreate/change APIs, runtime SAs or custom roles');
  if(url.endsWith(':generateServiceIdentity'))assert(['eventarc.googleapis.com','pubsub.googleapis.com'].some(s=>url===`https://serviceusage.googleapis.com/v1beta1/projects/${N}/services/${s}:generateServiceIdentity`),'STOP: retain existing Tasks/Scheduler/Functions agents');
 }
 if(method==='POST'&&url===`https://serviceusage.googleapis.com/v1/projects/${N}/services:batchEnable`){assert.deepEqual(Object.keys(body),['serviceIds']);assert(body.serviceIds.length>0&&body.serviceIds.every(s=>APIs.includes(s)));return;}
 if(method==='POST'&&Object.values(serviceForAgent).some(s=>url===`https://serviceusage.googleapis.com/v1beta1/projects/${N}/services/${s}:generateServiceIdentity`)){assert.deepEqual(body,{});return;}
 if(method==='POST'&&url===`https://iam.googleapis.com/v1/projects/${P}/serviceAccounts`){assert(['aogaku-ai-runtime','aogaku-ai-account-deletion'].includes(body.accountId));assert.deepEqual(Object.keys(body).sort(),['accountId','serviceAccount']);assert.deepEqual(Object.keys(body.serviceAccount),['displayName']);return;}
 if(method==='POST'&&url===`https://iam.googleapis.com/v1/projects/${P}/roles`){assert(roles[body.roleId]);assert.deepEqual(body.role.includedPermissions,roles[body.roleId]);assert.deepEqual(Object.keys(body).sort(),['role','roleId']);assert.deepEqual(Object.keys(body.role).sort(),['includedPermissions','stage','title']);assert.equal(body.role.stage,'GA');return;}
 const policy=Object.values(policies).find(p=>p.set===url&&(p.setMethod||'POST')===method);
 if(policy){const wanted=method==='PUT'?body:body.policy;assert(wanted.etag,'STOP: IAM etag required');assert(context.beforePolicy);preserved(context.beforePolicy,wanted);assert.deepEqual(wanted,merge(context.beforePolicy,context.allowedBindings));return;}
 if(method==='POST'&&url===`https://cloudtasks.googleapis.com/v2/projects/${P}/locations/${R}/queues`){assert.deepEqual(body,load('Config/Production/queue.create.json'));assert(!('state' in body));return;}
 if(method==='POST'&&url===`https://cloudtasks.googleapis.com/v2/${Q}:pause`){assert.deepEqual(body,{});return;}
 throw Error('STOP: operation outside authorized Phase 1');
}
function privateWrite(dir,name,data){const file=path.join(dir,name);fs.writeFileSync(file,JSON.stringify(data,null,2)+'\n',{mode:0o600});fs.chmodSync(file,0o600);}
async function runner(action){
 assert(['preflight','apply','postcheck','audit','resume-preflight','resume'].includes(action));
 const resume=action.startsWith('resume');
 execFileSync('python3',['scripts/firebase_production.py','check','--project',P],{cwd:ROOT,stdio:'pipe'});
 assert.equal(plan.projectId,P);assert.equal(AI,`aogaku-ai-runtime@${P}.iam.gserviceaccount.com`);assert.equal(DEL,`aogaku-ai-account-deletion@${P}.iam.gserviceaccount.com`);
 const dir=path.join(ROOT,resume?'build/production-phase1-resume':'build/production-phase1');fs.mkdirSync(dir,{recursive:true,mode:0o700});fs.chmodSync(dir,0o700);
 const report={phase:1,projectId:P,startedAt:new Date().toISOString(),operations:[],attempts:[],status:'STARTED',partialSuccess:false};
 const persist=()=>privateWrite(dir,action==='audit'?'audit-execution.json':'execution.json',report);persist();
 let token;
 async function bearer(){if(token)return token;const lib='/Users/shum/anaconda3/lib/node_modules/firebase-tools/lib',account=require(lib+'/auth.js').getGlobalDefaultAccount(),api=require(lib+'/api.js');assert(account?.tokens?.refresh_token);const r=await fetch('https://oauth2.googleapis.com/token',{method:'POST',body:new URLSearchParams({client_id:api.clientId(),client_secret:api.clientSecret(),refresh_token:account.tokens.refresh_token,grant_type:'refresh_token'})});const d=await r.json();assert(r.ok&&d.access_token,'OAuth refresh failed');token=d.access_token;return token;}
 const operations=new Set();
 async function request(url,method='GET',body,context={}){
  assertRequest(url,method,body,{...context,apply:action==='apply'||action==='resume',resume,operationNames:operations});
  const isWrite=method!=='GET'&&!Object.values(policies).some(p=>p.get===url);
  const attempt=isWrite?{method,url,bodySha256:crypto.createHash('sha256').update(JSON.stringify(body)).digest('hex'),status:'UNKNOWN',at:new Date().toISOString()}:null;
  if(attempt){report.attempts.push(attempt);persist();}
  const r=await fetch(url,{method,redirect:'error',headers:{Authorization:'Bearer '+await bearer(),'Content-Type':'application/json'},...(body===undefined?{}:{body:JSON.stringify(body)}),signal:AbortSignal.timeout(45000)});const d=await r.json().catch(()=>({}));
  if(!r.ok){if(attempt){attempt.status='HTTP_ERROR';attempt.httpStatus=r.status;persist();}const err=Error(`HTTP ${r.status} ${new URL(url).hostname} ${d.error?.status||''}`);err.httpStatus=r.status;throw err;}
  if(attempt){attempt.status='CONFIRMED';persist();}
  if(isWrite){report.operations.push({method,url,bodySha256:crypto.createHash('sha256').update(JSON.stringify(body)).digest('hex'),at:new Date().toISOString()});persist();}
  if(d.nextPageToken)throw Error('STOP: unexpected pagination');return d;
 }
 const getPolicy=key=>{const p=policies[key];return request(p.get,p.getMethod||'GET',p.getMethod==='POST'?{options:{requestedPolicyVersion:3}}:undefined);};
 async function identity(){const project=await request(`https://cloudresourcemanager.googleapis.com/v1/projects/${P}`),bucket=await request(`https://storage.googleapis.com/storage/v1/b/${B}`),apps=await request(`https://firebase.googleapis.com/v1beta1/projects/${P}/iosApps?pageSize=100`);assert.equal(project.projectId,P);assert.equal(project.projectNumber,N);assert.equal(project.lifecycleState,'ACTIVE');assert.equal(bucket.name,B);assert.equal(bucket.location,'US-CENTRAL1');assert(apps.apps.some(a=>a.bundleId==='com.forta2k25.Aogaku'&&a.state==='ACTIVE'));return {projectId:P,projectNumber:N,bucket:B,bundleId:'com.forta2k25.Aogaku'};}
 async function operation(d){if(d.done){assert(!d.error,JSON.stringify(d.error));return d;}assert(d.name);const url=(d.name.startsWith('operations/')?'https://serviceusage.googleapis.com/v1/':'https://serviceusage.googleapis.com/v1beta1/')+d.name;operations.add(url);for(let i=0;i<60;i++){await new Promise(r=>setTimeout(r,2000));const x=await request(url);if(x.done){assert(!x.error,JSON.stringify(x.error));return x;}}throw Error('STOP: service operation timeout; no automatic repeat');}
 async function maybeGet(url){try{return await request(url);}catch(e){if(e.httpStatus===404)return null;throw e;}}
 async function snapshot(){const id=await identity();const data={identity:id,apis:await request(`https://serviceusage.googleapis.com/v1/projects/${N}/services?filter=state:ENABLED&pageSize=200`),project:await getPolicy('project'),bucket:await getPolicy('bucket'),secret:await getPolicy('secret'),versions:await request(`https://secretmanager.googleapis.com/v1/projects/${P}/secrets/GROQ_API_KEY/versions?pageSize=100`),functions:await request(`https://cloudfunctions.googleapis.com/v2/projects/${P}/locations/-/functions`)};data.functions=(data.functions.functions||[]).map(f=>({name:f.name,updateTime:f.updateTime,environment:f.environment}));return data;}
 const runtimeBindings=plan.additiveBindings.filter(b=>!b.scope.includes('/services/')&&!b.scope.includes('/functions/'));
 const deletionBindings=plan.accountDeletionRuntime.additiveBindings.map(b=>({...b,member:'serviceAccount:'+DEL}));
 const byScope=scope=>[...runtimeBindings,...deletionBindings].filter(b=>b.scope===scope);
 const projectBindings=()=>[...byScope('projects/'+P),...agents.map(a=>({member:'serviceAccount:'+a.serviceAccount,roles:[a.role]}))];
 let baselinePolicies={};
 async function bind(key,bindings){const before=await getPolicy(key);if(resume&&baselinePolicies[key])noUnplannedAdditions(baselinePolicies[key],before,bindings);const desired=merge(before,bindings);if(JSON.stringify(before)!==JSON.stringify(desired)){await identity();const p=policies[key];await request(p.set,p.setMethod||'POST',p.setMethod==='PUT'?desired:{policy:desired},{beforePolicy:before,allowedBindings:bindings});}const after=await getPolicy(key);preserved(before,after);preserved(desired,after);noUnplannedAdditions(before,after,bindings);privateWrite(dir,'policy-'+key+'-after.json',after);}
 try{
  const before=['postcheck','audit'].includes(action)?load('build/production-phase1/before.json'):await snapshot();
  if(!['postcheck','audit'].includes(action))privateWrite(dir,'before.json',before);
  if(resume){
   const previous=load('build/production-phase1/after.json');
   for(const k of ['project','bucket','secret'])assert.deepEqual(policyCore(before[k]),policyCore(previous[k]),'STOP: unexpected IAM drift since partial-success audit: '+k);
   assert.deepEqual(before.versions,previous.versions,'STOP: Secret version drift');assert.deepEqual(before.functions,previous.functions,'STOP: Function drift');
   assert(APIs.every(s=>before.apis.services.some(a=>a.config.name===s)),'STOP: completed API is no longer enabled');
   const resources={serviceAccounts:[],customRoles:[],keys:{}};
   for(const email of [AI,DEL]){const a=await request(SAURL(email));assert.equal(a.email,email);assert.equal(a.projectId,P);assert(a.uniqueId&&!a.disabled);resources.serviceAccounts.push(a);const keys=await request(SAURL(email)+'/keys?keyTypes=USER_MANAGED');assert.equal((keys.keys||[]).length,0,'STOP: unexpected user-managed SA key');resources.keys[email]=keys;}
   for(const [id,permissions] of Object.entries(roles)){const a=await request(`https://iam.googleapis.com/v1/projects/${P}/roles/${id}`);assert.equal(a.name,`projects/${P}/roles/${id}`);assert.equal(a.stage,'GA');assert(!a.deleted);assert.deepEqual([...a.includedPermissions].sort(),[...permissions].sort());resources.customRoles.push(a);}
   // Verify the already automatic bindings; never generate these identities again.
   for(const a of agents.filter(a=>/cloudtasks|cloudscheduler|gcf-admin/.test(a.serviceAccount)))assert(agentConfirmed(before.project,a),'STOP: completed managed-agent binding drift');
   assert(!await maybeGet(`https://cloudtasks.googleapis.com/v2/${Q}`),'STOP: unexpected existing queue; do not adopt/pause/replace');
   baselinePolicies={project:before.project,bucket:before.bucket,secret:before.secret,self:await getPolicy('self')};
   privateWrite(dir,'resources-before.json',resources);
   if(action==='resume-preflight'){report.status='RESUME_PREFLIGHT_PASS';report.identity=before.identity;report.resourceRecreationForbidden=true;report.queueAbsent=true;persist();console.log(JSON.stringify({status:report.status,identity:report.identity,completedResourcesVerified:true,existingIAMUnchanged:true,queueAbsent:true,mutations:0}));return;}
  }
  if(action==='preflight'){report.status='PREFLIGHT_PASS';report.identity=before.identity;persist();console.log(JSON.stringify({status:report.status,identity:report.identity,missingAPIs:APIs.filter(s=>!before.apis.services.some(a=>a.config.name===s))}));return;}
  if(action==='apply'){
   // Detect names owned by another change before enabling any API or creating resources.
   for(const email of [AI,DEL])assert(!await maybeGet(SAURL(email)),'STOP: service account name collision; no changes started');
   for(const id of Object.keys(roles))assert(!await maybeGet(`https://iam.googleapis.com/v1/projects/${P}/roles/${id}`),'STOP: custom role name collision; no changes started');
   await identity();const missing=APIs.filter(s=>!before.apis.services.some(a=>a.config.name===s));if(missing.length)await operation(await request(`https://serviceusage.googleapis.com/v1/projects/${N}/services:batchEnable`,'POST',{serviceIds:missing}));
   // Names must be absent. Do not adopt unrelated existing SAs/roles/queues silently.
   for(const [email,id] of [[AI,'aogaku-ai-runtime'],[DEL,'aogaku-ai-account-deletion']]){const old=await maybeGet(SAURL(email));assert(!old,'STOP: service account name collision; review before retry');await identity();await request(`https://iam.googleapis.com/v1/projects/${P}/serviceAccounts`,'POST',{accountId:id,serviceAccount:{displayName:id==='aogaku-ai-runtime'?'Aogaku private AI runtime':'Aogaku account deletion only'}});const sa=await request(SAURL(email));assert.equal(sa.email,email);assert.equal(sa.projectId,P);}
   for(const [roleId,permissions] of Object.entries(roles)){assert(!await maybeGet(`https://iam.googleapis.com/v1/projects/${P}/roles/${roleId}`),'STOP: custom role name collision');await identity();await request(`https://iam.googleapis.com/v1/projects/${P}/roles`,'POST',{roleId,role:{title:roleId,stage:'GA',includedPermissions:permissions}});}
   // Google-managed agents need not be readable through customer-project IAM SA GET.
   // Existing exact serviceAgent bindings are checked in project IAM; missing identities
   // use project-number-scoped Service Usage and its returned exact email, never SA keys.
   for(const agent of agents){
    if(agentConfirmed(await getPolicy('project'),agent))continue;
    const service=Object.entries(serviceForAgent).find(([k])=>agent.serviceAccount.includes(k))?.[1]||(agent.serviceAccount.includes('gcf-admin')?'cloudfunctions.googleapis.com':null);assert(service);await identity();
    const op=await operation(await request(`https://serviceusage.googleapis.com/v1beta1/projects/${N}/services/${service}:generateServiceIdentity`,'POST',{}));
    assert.equal(op.response?.email,agent.serviceAccount,'STOP: returned managed identity mismatch');
    privateWrite(dir,'identity-'+service+'.json',{service,email:op.response.email});
   }
   const storage=await request(`https://storage.googleapis.com/storage/v1/projects/${P}/serviceAccount`);assert.equal(storage.email_address,`service-${N}@gs-project-accounts.iam.gserviceaccount.com`);
   await bind('project',projectBindings());await bind('bucket',byScope('buckets/'+B));await bind('secret',byScope(`projects/${P}/secrets/GROQ_API_KEY`));await bind('self',byScope(`projects/${P}/serviceAccounts/${AI}`));
   assert(!await maybeGet(`https://cloudtasks.googleapis.com/v2/${Q}`),'STOP: existing queue ownership needs explicit review');await identity();await request(`https://cloudtasks.googleapis.com/v2/projects/${P}/locations/${R}/queues`,'POST',load('Config/Production/queue.create.json'));
   // Immediately pause the newly-created empty queue, before any other mutation.
   await request(`https://cloudtasks.googleapis.com/v2/${Q}:pause`,'POST',{});assert.equal((await request(`https://cloudtasks.googleapis.com/v2/${Q}`)).state,'PAUSED');
   await bind('queue',byScope(Q));
  }
  if(action==='resume'){
   for(const agent of agents){
    if(agentConfirmed(await getPolicy('project'),agent))continue;
    const service=Object.entries(serviceForAgent).find(([k])=>agent.serviceAccount.includes(k))?.[1];assert(['eventarc.googleapis.com','pubsub.googleapis.com'].includes(service));
    assert(before.apis.services.some(a=>a.config.name===service),'STOP: managed-agent API not enabled; do not enable automatically');await identity();
    const op=await operation(await request(`https://serviceusage.googleapis.com/v1beta1/projects/${N}/services/${service}:generateServiceIdentity`,'POST',{}));assert.equal(op.response?.email,agent.serviceAccount,'STOP: managed identity mismatch');privateWrite(dir,'identity-'+service+'.json',{service,email:op.response.email});
   }
   const storage=await request(`https://storage.googleapis.com/storage/v1/projects/${P}/serviceAccount`);assert.equal(storage.email_address,`service-${N}@gs-project-accounts.iam.gserviceaccount.com`);
   await bind('project',projectBindings());await bind('bucket',byScope('buckets/'+B));await bind('secret',byScope(`projects/${P}/secrets/GROQ_API_KEY`));await bind('self',byScope(`projects/${P}/serviceAccounts/${AI}`));
   assert(!await maybeGet(`https://cloudtasks.googleapis.com/v2/${Q}`),'STOP: queue appeared during setup');await identity();await request(`https://cloudtasks.googleapis.com/v2/projects/${P}/locations/${R}/queues`,'POST',load('Config/Production/queue.create.json'));
   await request(`https://cloudtasks.googleapis.com/v2/${Q}:pause`,'POST',{});assert.equal((await request(`https://cloudtasks.googleapis.com/v2/${Q}`)).state,'PAUSED');
   await bind('queue',byScope(Q));
  }
  const after=await snapshot();privateWrite(dir,'after.json',after);
  for(const k of ['project','bucket','secret'])preserved(before[k],after[k]);assert.deepEqual(after.versions,before.versions,'STOP: Secret versions changed');assert.deepEqual(after.functions,before.functions,'STOP: Functions changed');
  if(action==='audit'){
   const sas=[];for(const email of [AI,DEL]){const a=await maybeGet(SAURL(email));sas.push({email,exists:!!a,enabled:!!a&&!a.disabled});}
   const custom=[];for(const [id,permissions] of Object.entries(roles)){const a=await maybeGet(`https://iam.googleapis.com/v1/projects/${P}/roles/${id}`);custom.push({id,exists:!!a,permissionsMatch:!!a&&JSON.stringify([...a.includedPermissions].sort())===JSON.stringify([...permissions].sort())});}
   const queue=await maybeGet(`https://cloudtasks.googleapis.com/v2/${Q}`),expected={project:projectBindings(),bucket:byScope('buckets/'+B),secret:byScope(`projects/${P}/secrets/GROQ_API_KEY`),self:byScope(`projects/${P}/serviceAccounts/${AI}`),queue:byScope(Q)},missing=[];
   for(const [key,list] of Object.entries(expected)){if(key==='queue'&&!queue){missing.push({scope:key,resourceMissing:true});continue;}const policy=await getPolicy(key);for(const b of list)for(const role of b.roles)if(!(policy.bindings||[]).some(x=>x.role===role&&!x.condition&&x.members.includes(b.member)))missing.push({scope:key,member:b.member,role});}
   const saved=load('build/production-phase1/execution.json');
   report.status='PARTIAL_SUCCESS_AUDITED';report.partialSuccess=saved.partialSuccess;report.previousError=saved.error;report.apiStates=APIs.map(name=>({name,enabled:after.apis.services.some(s=>s.config.name===name)}));report.serviceAccounts=sas;report.customRoles=custom;report.missingBindings=missing;report.secretVersionsUnchanged=true;report.existingIAMRetained=true;report.functionsUnchanged=true;report.queue=queue?{exists:true,state:queue.state}:{exists:false};report.phase2Ready=false;report.mutations=0;persist();console.log(JSON.stringify({status:report.status,phase2Ready:false,apis:report.apiStates,serviceAccounts:sas,customRoles:custom,missingBindings:missing.length,secretVersionsUnchanged:true,existingIAMRetained:true,functionsUnchanged:true,queue:report.queue,mutations:0}));return;
  }
  assert(APIs.every(s=>after.apis.services.some(a=>a.config.name===s)));
  const allBindings={project:projectBindings(),bucket:byScope('buckets/'+B),secret:byScope(`projects/${P}/secrets/GROQ_API_KEY`),self:byScope(`projects/${P}/serviceAccounts/${AI}`),queue:byScope(Q)};
  for(const [key,list] of Object.entries(allBindings)){const live=await getPolicy(key);preserved(merge({bindings:[]},list),live);}
  for(const [roleId,permissions] of Object.entries(roles)){const role=await request(`https://iam.googleapis.com/v1/projects/${P}/roles/${roleId}`);assert.equal(role.stage,'GA');assert.deepEqual([...role.includedPermissions].sort(),[...permissions].sort());assert(!role.deleted);}
  for(const email of [AI,DEL]){const a=await request(SAURL(email));assert.equal(a.email,email);assert.equal(a.projectId,P);assert(!a.disabled);}
  const queue=await request(`https://cloudtasks.googleapis.com/v2/${Q}`),expectedQueue=load('Config/Production/queue.create.json');assert.equal(queue.name,Q);assert.equal(queue.state,'PAUSED');for(const [k,v] of Object.entries(expectedQueue.rateLimits))assert.equal(queue.rateLimits[k],v);for(const [k,v] of Object.entries(expectedQueue.retryConfig))assert.equal(queue.retryConfig[k],v);
  if(resume){
   const originals=load('build/production-phase1-resume/resources-before.json');
   for(const a of originals.serviceAccounts){assert.deepEqual(await request(SAURL(a.email)),a,'STOP: created SA changed');assert.deepEqual(await request(SAURL(a.email)+'/keys?keyTypes=USER_MANAGED'),originals.keys[a.email],'STOP: SA keys changed');}
   for(const a of originals.customRoles)assert.deepEqual(await request('https://iam.googleapis.com/v1/'+a.name),a,'STOP: custom role changed');
   for(const k of ['project','bucket','secret'])noUnplannedAdditions(before[k],after[k],k==='project'?projectBindings():byScope(k==='bucket'?'buckets/'+B:`projects/${P}/secrets/GROQ_API_KEY`));
   report.completedResourcesRetained=true;report.userManagedSAKeyCount=0;
  }
  report.status='PASS';report.identity=after.identity;report.secretVersionsUnchanged=true;report.existingIAMRetained=true;report.functionsUnchanged=true;report.queueState=queue.state;report.queue={name:queue.name,state:queue.state,rateLimits:queue.rateLimits,retryConfig:queue.retryConfig};report.apis=APIs;report.createdServiceAccounts=resume?[]:[AI,DEL];report.verifiedServiceAccounts=[AI,DEL];report.deferredResourceBindings=plan.additiveBindings.filter(b=>b.scope.includes('/services/')||b.scope.includes('/functions/'));report.completedAt=new Date().toISOString();persist();console.log(JSON.stringify({status:report.status,phase:1,mutations:report.operations.length,secretVersionsUnchanged:true,existingIAMRetained:true,functionsUnchanged:true,queueState:queue.state,phase2Ready:true}));
 }catch(e){report.status='STOPPED';report.partialSuccess=report.operations.length>0||report.attempts.some(a=>a.status==='UNKNOWN');report.error=e.message;persist();console.error(JSON.stringify({status:report.status,partialSuccess:report.partialSuccess,mutations:report.operations.length,error:e.message}));throw e;}
}
module.exports={assertRequest,merge,preserved,agentConfirmed,policyCore,noUnplannedAdditions,policies,runner};
if(require.main===module)runner(process.argv[2]).catch(()=>{process.exitCode=1});
