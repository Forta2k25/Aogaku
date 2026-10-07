#!/usr/bin/env node
// Explicit Phase 2b only. No default database mutation, Functions/IAM/Secret
// mutation, object writes, Auth mutation, queue/Scheduler change, or rollback.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto'),{execFileSync}=require('node:child_process');
const ROOT=path.resolve(__dirname,'..'),P='forta-aogaku',N='505828754933',B=P+'.firebasestorage.app',DB='aogaku-ai',REGION='asia-northeast1';
const DIR=path.join(ROOT,'build/production-phase2b-named');
const F=`https://firestore.googleapis.com/v1/projects/${P}/databases/`,RULES=`https://firebaserules.googleapis.com/v1/projects/${P}`;
const AI=`aogaku-ai-runtime@${P}.iam.gserviceaccount.com`,DEL=`aogaku-ai-account-deletion@${P}.iam.gserviceaccount.com`;
const phase1=require('./provision_production_phase1.cjs'),cloud=require('./production_cloud.cjs');
const load=p=>JSON.parse(fs.readFileSync(path.join(ROOT,p),'utf8'));
const namedRules=()=>fs.readFileSync(path.join(ROOT,'Config/AI/firestore.rules'),'utf8');
const storageRules=()=>fs.readFileSync(path.join(ROOT,'Config/Production/storage.rules'),'utf8');
const spec=load('Config/AI/firestore.indexes.json'),createBody=load('Config/Production/named-firestore.plan.json').body;
const indexBody={queryScope:spec.indexes[0].queryScope,fields:spec.indexes[0].fields};
const fieldBody={indexConfig:{indexes:spec.fieldOverrides[0].indexes.map(i=>({queryScope:i.queryScope,fields:[{fieldPath:'userId',...(i.order?{order:i.order}:{arrayConfig:i.arrayConfig})}]}))}};
const fieldURL=F+DB+'/collectionGroups/memberships/fields/userId';
const releaseName=kind=>`projects/${P}/releases/`+(kind==='named'?'cloud.firestore/'+DB:'firebase.storage/'+B);
function hash(x){return crypto.createHash('sha256').update(typeof x==='string'?x:JSON.stringify(x)).digest('hex');}
function save(name,x){const dest=path.join(DIR,name+'.json');fs.writeFileSync(dest,JSON.stringify(x,null,2)+'\n',{mode:0o600});fs.chmodSync(dest,0o600);}
function validateRequest(url,method='GET',body,context={}){
 const reads=new Set([F+DB,F+DB+'/collectionGroups/-/indexes',F+DB+'/collectionGroups/-/fields?filter=indexConfig.usesAncestorConfig=false OR ttlConfig:*',fieldURL,
  ...['named','storage'].map(k=>'https://firebaserules.googleapis.com/v1/'+releaseName(k)),
  ...Object.values(phase1.policies).map(p=>p.get),
  `https://secretmanager.googleapis.com/v1/projects/${P}/secrets/GROQ_API_KEY/versions?pageSize=100`,
  ...[AI,DEL].flatMap(a=>[`https://iam.googleapis.com/v1/projects/${P}/serviceAccounts/${a}`,`https://iam.googleapis.com/v1/projects/${P}/serviceAccounts/${a}/keys?keyTypes=USER_MANAGED`]),
  ...Object.keys({...load('Config/Production/iam.plan.json').customRoles,...load('Config/Production/iam.plan.json').accountDeletionRuntime.customRoles}).map(r=>`https://iam.googleapis.com/v1/projects/${P}/roles/${r}`)]);
 if(method==='GET'&&(reads.has(url)||context.operations?.has(url)))return;
 if(method==='POST'&&Object.values(phase1.policies).some(p=>p.get===url&&p.getMethod==='POST')){assert.deepEqual(body,{options:{requestedPolicyVersion:3}});return;}
 try{cloud.assertRead(url,method);return;}catch{}
 if(method==='POST'&&url===RULES+':test'){
  assert.deepEqual(Object.keys(body),['source']);assert.equal(body.source.files.length,1);
  assert([namedRules(),storageRules()].includes(body.source.files[0].content));return;
 }
 assert(context.apply===true,'STOP: Phase 2b write not authorized');
 if(method==='POST'&&url===F.slice(0,-1)+'?databaseId='+DB){assert.deepEqual(body,createBody);return;}
 if(method==='POST'&&url===F+DB+'/collectionGroups/aiSources/indexes'){assert.deepEqual(body,indexBody);return;}
 if(method==='PATCH'&&url===fieldURL+'?updateMask=indexConfig'){assert.deepEqual(body,fieldBody);return;}
 if(method==='POST'&&url===RULES+'/rulesets'){
  assert.deepEqual(Object.keys(body),['source']);assert.equal(body.source.files.length,1);
  assert([namedRules(),storageRules()].includes(body.source.files[0].content));assert.equal(body.source.files[0].name,'security.rules');return;
 }
 const release=method==='PATCH'?body?.release:body;
 if((method==='POST'&&url===RULES+'/releases')||(method==='PATCH'&&url===RULES+'/releases/firebase.storage/'+B)){
  assert(context.rulesetNames?.has(release?.rulesetName),'STOP: unreviewed ruleset');
  assert.deepEqual(Object.keys(release).sort(),['name','rulesetName']);
  assert.equal(release.name,releaseName(context.kind));assert(['named','storage'].includes(context.kind));
  if(method==='PATCH'){assert.equal(context.kind,'storage');assert.deepEqual(Object.keys(body),['release']);}
  return;
 }
 throw Error('STOP: operation outside named Phase 2b allowlist');
}
function assertNamed(db){assert.equal(db.name,`projects/${P}/databases/${DB}`);assert.equal(db.locationId,REGION);assert.equal(db.type,'FIRESTORE_NATIVE');assert.equal(db.deleteProtectionState,'DELETE_PROTECTION_ENABLED');}
function indexShape(i){return {queryScope:i.queryScope,fields:i.fields.filter(f=>f.fieldPath!=='__name__')};}
function assertIndex(indexes,ready=false){assert((indexes.indexes||[]).length<=1,'unexpected named composite index');for(const i of indexes.indexes||[]){assert(i.name.includes('/collectionGroups/aiSources/indexes/'));assert.deepEqual(indexShape(i),indexBody);assert(['CREATING','READY'].includes(i.state));if(ready)assert.equal(i.state,'READY');}if(ready)assert.equal(indexes.indexes.length,1);}
function fieldShape(f){return (f.indexConfig?.indexes||[]).map(i=>({queryScope:i.queryScope,fields:i.fields})).sort((a,b)=>JSON.stringify(a).localeCompare(JSON.stringify(b)));}
function assertField(f,ready=false){assert.equal(f.name,`projects/${P}/databases/${DB}/collectionGroups/memberships/fields/userId`);assert(!f.ttlConfig,'unexpected TTL');if(!f.indexConfig.usesAncestorConfig){assert.deepEqual(fieldShape(f),fieldShape(fieldBody),'membership index drift');if(ready)assert(f.indexConfig.indexes.every(i=>i.state==='READY'));}else assert(!ready,'membership override not provisioned');}
function protectedSame(before,after,storageUpdated=false){
 for(const k of ['projectId','projectNumber','database','bucket','indexes','fields','functions','apps','storagePrivacy','secret'])assert.deepEqual(after.metadata[k],before.metadata[k],'STOP: protected metadata drift: '+k);
 assert.deepEqual(after.metadata.rules.firestore,before.metadata.rules.firestore,'STOP: default Rules drift');
 if(!storageUpdated)assert.deepEqual(after.metadata.rules.storage,before.metadata.rules.storage,'STOP: Storage Rules drift');
 else assert.equal(after.metadata.rules.storage.content,storageRules());
 assert.deepEqual(after.resources,before.resources,'STOP: API/SA/queue/Scheduler/Eventarc drift');
 assert.deepEqual(after.protected,before.protected,'STOP: IAM/Secret versions/SA keys/Functions drift');
}
async function main(action){
 assert(['preflight','database','indexes','storage','postcheck'].includes(action));
 fs.mkdirSync(DIR,{recursive:true,mode:0o700});fs.chmodSync(DIR,0o700);
 execFileSync('python3',['scripts/firebase_production.py','check','--project',P],{cwd:ROOT,stdio:'pipe'});
 const journalPath=path.join(DIR,'execution.json');
 const journal=fs.existsSync(journalPath)?JSON.parse(fs.readFileSync(journalPath)): {phase:'2b',target:{projectId:P,projectNumber:N,bucket:B,bundleId:'com.forta2k25.Aogaku'},operations:[],attempts:[],status:'STARTED',partialSuccess:false};
 assert(!journal.partialSuccess&&journal.status!=='STOPPED','STOP: previous partial/error needs review, no automatic resume');
 const persist=()=>save('execution',journal);journal.action=action;persist();
 let bearer;const operations=new Set(),rulesetNames=new Set();
 async function token(){if(bearer)return bearer;const lib='/Users/shum/anaconda3/lib/node_modules/firebase-tools/lib',account=require(lib+'/auth.js').getGlobalDefaultAccount(),api=require(lib+'/api.js');assert(account?.tokens?.refresh_token);const r=await fetch('https://oauth2.googleapis.com/token',{method:'POST',body:new URLSearchParams({client_id:api.clientId(),client_secret:api.clientSecret(),refresh_token:account.tokens.refresh_token,grant_type:'refresh_token'})});const d=await r.json();assert(r.ok&&d.access_token,'OAuth refresh failed');return bearer=d.access_token;}
 async function request(url,method='GET',body,context={}){
  validateRequest(url,method,body,{apply:action!=='preflight'&&action!=='postcheck',operations,rulesetNames,...context});
  const readonly=method==='GET'||url.endsWith(':test')||Object.values(phase1.policies).some(p=>p.get===url);
  const attempt=readonly?null:{url,method,bodySha256:hash(body),status:'UNKNOWN',at:new Date().toISOString()};if(attempt){journal.attempts.push(attempt);persist();}
  const r=await fetch(url,{method,redirect:'error',headers:{Authorization:'Bearer '+await token(),'Content-Type':'application/json'},...(body===undefined?{}:{body:JSON.stringify(body)}),signal:AbortSignal.timeout(45000)});
  const d=await r.json().catch(()=>({}));if(!r.ok){if(attempt){attempt.status='HTTP_ERROR';attempt.httpStatus=r.status;persist();}const e=Error(`HTTP ${r.status} ${new URL(url).hostname} ${d.error?.status||''}`);e.httpStatus=r.status;throw e;}
  if(attempt){attempt.status='CONFIRMED';journal.operations.push({...attempt});persist();}
  assert(!d.nextPageToken,'STOP: unexpected pagination');return d;
 }
 async function maybe(url){try{return await request(url);}catch(e){if(e.httpStatus===404)return null;throw e;}}
 async function operation(d){assert(d.name?.startsWith(`projects/${P}/databases/${DB}/operations/`),'operation target mismatch');save('last-operation',d);if(d.done){assert(!d.error);return;}const url='https://firestore.googleapis.com/v1/'+d.name;operations.add(url);for(let i=0;i<180;i++){const current=await request(url);if(current.done){assert(!current.error,'STOP: operation failed');return;}await new Promise(r=>setTimeout(r,2000));}throw Error('STOP: operation wait timeout');}
 async function snapshot(){
  const metadata=await cloud.inspect();const protectedResources={};
  for(const [name,p]of Object.entries(phase1.policies))protectedResources['iam-'+name]=await request(p.get,p.getMethod||'GET',p.getMethod==='POST'?{options:{requestedPolicyVersion:3}}:undefined);
  protectedResources.versions=await request(`https://secretmanager.googleapis.com/v1/projects/${P}/secrets/GROQ_API_KEY/versions?pageSize=100`);
  const f=await request(cloud.urls.functions);protectedResources.functions=(f.functions||[]).map(x=>({name:x.name,updateTime:x.updateTime,state:x.state,environment:x.environment}));
  for(const a of [AI,DEL]){protectedResources[a]=await request(`https://iam.googleapis.com/v1/projects/${P}/serviceAccounts/${a}`);protectedResources[a+'-keys']=await request(`https://iam.googleapis.com/v1/projects/${P}/serviceAccounts/${a}/keys?keyTypes=USER_MANAGED`);}
  const plan=load('Config/Production/iam.plan.json');for(const [id,permissions]of Object.entries({...plan.customRoles,...plan.accountDeletionRuntime.customRoles})){const role=await request(`https://iam.googleapis.com/v1/projects/${P}/roles/${id}`);assert(!role.deleted&&role.stage==='GA');assert.deepEqual([...role.includedPermissions].sort(),[...permissions].sort());protectedResources[id]=role;}
  await cloud.resourcesMetadata();const resources=load('build/production-resources-live.json').records;
  for(const r of Object.values(resources))assert.equal(r.httpStatus,200);assert.equal(resources.queue.data.state,'PAUSED');
  return {metadata,resources,protected:protectedResources};
 }
 async function compile(kind){const content=kind==='named'?namedRules():storageRules();const d=await request(RULES+':test','POST',{source:{files:[{name:'security.rules',content}]}});assert(!(d.issues||[]).some(x=>x.severity==='ERROR'),'Rules compiler rejected');save(kind+'-compile',d);}
 async function installRules(kind,before){
  const content=kind==='named'?namedRules():storageRules(),releaseURL='https://firebaserules.googleapis.com/v1/'+releaseName(kind);
  const current=await maybe(releaseURL);
  if(kind==='named'&&current){const source=await request('https://firebaserules.googleapis.com/v1/'+current.rulesetName);assert.equal(source.source.files.length,1);assert.equal(source.source.files[0].content,content,'STOP: unexpected existing named Rules');return;}
  if(kind==='storage'){assert.deepEqual(current,before.metadata.rules.storage?Object.fromEntries(Object.entries(before.metadata.rules.storage).filter(([k])=>k!=='content')):null,'STOP: release changed before update');if(before.metadata.rules.storage.content===content)return;}
  await compile(kind);
  const created=await request(RULES+'/rulesets','POST',{source:{files:[{name:'security.rules',content}]}});assert(created.name.startsWith(`projects/${P}/rulesets/`));rulesetNames.add(created.name);save(kind+'-new-ruleset',created);
  // No create-on-error fallback. Recheck exact release immediately before update.
  assert.deepEqual(await maybe(releaseURL),current,'STOP: Rules release drift during compilation');
  const body={name:releaseName(kind),rulesetName:created.name};
  if(kind==='named')await request(RULES+'/releases','POST',body,{kind});else await request(releaseURL,'PATCH',{release:body},{kind});
  const installed=await request(releaseURL);assert.equal(installed.rulesetName,created.name);const actual=await request('https://firebaserules.googleapis.com/v1/'+installed.rulesetName);assert.equal(actual.source.files.length,1);assert.equal(actual.source.files[0].content,content);save(kind+'-installed',{...installed,content});
 }
 try{
  const before=await snapshot();save(action+'-before',before);
  execFileSync('python3',['-c',"import sys;sys.path.insert(0,'scripts');import firebase_production as p;s=p.load('build/production-live.json');p.live_check(s);assert len(p.normalized_indexes(s['indexes']))==4;assert p.normalized_indexes(s['indexes'])==p.normalized_indexes(p.load(p.CONF/'firestore.indexes.json'));assert len(p.normalized_fields(s['fields']))==8"],{cwd:ROOT,stdio:'pipe'});
  assert.equal(before.metadata.rules.firestore.content,fs.readFileSync(path.join(ROOT,'Config/Production/baseline.firestore.rules'),'utf8'));
  if(action==='preflight'){
   assert(!fs.existsSync(path.join(DIR,'baseline.json')),'STOP: baseline already exists');
   const previous=load('build/production-phase2/protected-resources-after-index.json');
   assert.deepEqual(before.protected.functions.map(({name,updateTime,state})=>({name,updateTime,state})),previous.functions,'STOP: Functions changed since Phase2a');
   assert.deepEqual(before.resources.scheduler.data,previous.scheduler,'STOP: Scheduler changed since Phase2a');
   for(const [key,old]of [['project',previous.projectIAM],['bucket',previous.bucketIAM],['secret',previous.secretIAM]])assert.deepEqual(phase1.policyCore(before.protected['iam-'+key]),phase1.policyCore(old),'STOP: Phase 1 IAM drift '+key);
   for(const key of ['self','queue'])assert.deepEqual(phase1.policyCore(before.protected['iam-'+key]),phase1.policyCore(load('build/production-phase1-resume/policy-'+key+'-after.json')),'STOP: Phase 1 IAM drift '+key);
   for(const a of [AI,DEL]){assert.equal(before.protected[a].email,a);assert(!before.protected[a].disabled);assert.equal((before.protected[a+'-keys'].keys||[]).length,0);assert((before.protected['iam-project'].bindings||[]).some(b=>b.role==='roles/datastore.user'&&!b.condition&&b.members.includes('serviceAccount:'+a)),'STOP: planned datastore role missing; scope review required');}
   for(const a of load('build/production-phase1-resume/resources-before.json').serviceAccounts){assert.equal(before.protected[a.email].uniqueId,a.uniqueId,'STOP: Phase1 SA identity/ownership changed');assert.equal(before.protected[a.email].projectId,P);}
   assert.deepEqual(before.protected.versions,load('build/production-phase1-resume/after.json').versions,'STOP: Secret version drift');
   assert.deepEqual(before.resources.queue.data,previous.queue,'STOP: Phase 1 queue drift');
   assert.equal(before.metadata.rules.storage.content,fs.readFileSync(path.join(ROOT,'Config/Production/baseline.storage.rules'),'utf8'));
   if(before.metadata.aiDatabase)assertNamed(before.metadata.aiDatabase);
   await compile('named');await compile('storage');save('baseline',before);journal.status='PREFLIGHT_PASS';journal.namedDatabaseAlreadyExists=!!before.metadata.aiDatabase;journal.iamChangesNeeded=false;persist();console.log('Phase 2b preflight PASS; default4/8 preserved; Phase1 IAM/keys/Secret/queue matched; named datastore access already exists; mutations=0');return;
  }
  const baseline=load('build/production-phase2b-named/baseline.json');protectedSame(baseline,before,journal.storageUpdated===true);
  if(action==='database'){
   assert(!journal.databaseReady,'STOP: database phase already completed');
   let db=await maybe(F+DB);if(!db){await operation(await request(F.slice(0,-1)+'?databaseId='+DB,'POST',createBody));db=await request(F+DB);}assertNamed(db);
   await installRules('named',before);journal.databaseReady=true;journal.status='DATABASE_CLOSED';persist();
  }
  if(action==='indexes'){
   assert(journal.databaseReady&&!journal.indexesReady);assertNamed(await request(F+DB));
   let indexes=await request(F+DB+'/collectionGroups/-/indexes');assertIndex(indexes);if(!(indexes.indexes||[]).length)await request(F+DB+'/collectionGroups/aiSources/indexes','POST',indexBody);
   let field=await request(fieldURL);assertField(field);if(field.indexConfig.usesAncestorConfig)await request(fieldURL+'?updateMask=indexConfig','PATCH',fieldBody);
   for(let i=0;i<240;i++){indexes=await request(F+DB+'/collectionGroups/-/indexes');field=await request(fieldURL);assertIndex(indexes);assertField(field);assert(['CREATING','READY'].includes(indexes.indexes[0]?.state));assert(field.indexConfig.indexes.every(i=>['CREATING','READY'].includes(i.state)));save('named-indexes',indexes);save('membership-field',field);if(indexes.indexes[0].state==='READY'&&field.indexConfig.indexes.every(i=>i.state==='READY'))break;if(i%12===0)console.log('Waiting for named index READY; queue remains PAUSED');assert(i<239,'STOP: index readiness timed out');await new Promise(r=>setTimeout(r,5000));}
   assertIndex(indexes,true);assertField(field,true);journal.indexesReady=true;journal.status='INDEXES_READY';persist();
  }
  if(action==='storage'){
   assert(journal.databaseReady&&journal.indexesReady&&!journal.storageUpdated);
   execFileSync('python3',['-c',"import sys;sys.path.insert(0,'scripts');import firebase_production as p;p.require_named_ready(p.load('build/production-live.json'),True,True)"],{cwd:ROOT,stdio:'pipe'});
   await installRules('storage',before);journal.storageUpdated=true;journal.status='STORAGE_READY';persist();
  }
  const after=await snapshot();save(action+'-after',after);protectedSame(baseline,after,journal.storageUpdated===true);
  if(action==='postcheck'){
   assert(journal.databaseReady&&journal.indexesReady&&journal.storageUpdated);
   execFileSync('python3',['-c',"import sys;sys.path.insert(0,'scripts');import firebase_production as p;p.require_named_ready(p.load('build/production-live.json'),True,True)"],{cwd:ROOT,stdio:'pipe'});
   journal.status='CONTROL_PLANE_PASS';journal.protectedResourcesUnchanged=true;journal.iamChanges=0;journal.completedAt=new Date().toISOString();
  }
  persist();console.log(JSON.stringify({phase:'2b',status:journal.status,operations:journal.operations.length,partialSuccess:false,queue:'PAUSED',defaultUnchanged:true,functionsUnchanged:true,secretVersionsUnchanged:true,iamChanges:0}));
 }catch(e){journal.status='STOPPED';journal.error=e.message;journal.partialSuccess=journal.operations.length>0||journal.attempts.some(a=>a.status==='UNKNOWN');persist();console.error(JSON.stringify({status:journal.status,partialSuccess:journal.partialSuccess,operations:journal.operations.length,error:e.message}));throw e;}
}
module.exports={validateRequest,assertNamed,indexBody,fieldBody,createBody,protectedSame,releaseName};
if(require.main===module)main(process.argv[2]).catch(()=>{process.exitCode=1});
