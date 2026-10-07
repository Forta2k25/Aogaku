#!/usr/bin/env node
// Production metadata only. This module intentionally has no cloud mutation API.
const fs=require('node:fs'),path=require('node:path');
const reads=require('./production_read_retry.cjs');let cachedToken,tokenAt=0;
const ROOT=path.resolve(__dirname,'..');
const P='forta-aogaku',N='505828754933',B='forta-aogaku.firebasestorage.app';
const urls={project:`https://cloudresourcemanager.googleapis.com/v1/projects/${P}`,
 aiDatabase:`https://firestore.googleapis.com/v1/projects/${P}/databases/aogaku-ai`,
 aiFields:`https://firestore.googleapis.com/v1/projects/${P}/databases/aogaku-ai/collectionGroups/-/fields?filter=indexConfig.usesAncestorConfig=false OR ttlConfig:*`,
 aiIndexes:`https://firestore.googleapis.com/v1/projects/${P}/databases/aogaku-ai/collectionGroups/-/indexes`,
 database:`https://firestore.googleapis.com/v1/projects/${P}/databases/(default)`,
 bucket:`https://storage.googleapis.com/storage/v1/b/${B}`,
 indexes:`https://firestore.googleapis.com/v1/projects/${P}/databases/(default)/collectionGroups/-/indexes`,
 fields:`https://firestore.googleapis.com/v1/projects/${P}/databases/(default)/collectionGroups/-/fields?filter=indexConfig.usesAncestorConfig=false OR ttlConfig:*`,
 functions:`https://cloudfunctions.googleapis.com/v2/projects/${P}/locations/-/functions`,
 releases:`https://firebaserules.googleapis.com/v1/projects/${P}/releases?pageSize=100`,
 apps:`https://firebase.googleapis.com/v1beta1/projects/${P}/iosApps?pageSize=100`,
 bucketIAM:`https://storage.googleapis.com/storage/v1/b/${B}/iam?optionsRequestedPolicyVersion=3`,
 defaultACL:`https://storage.googleapis.com/storage/v1/b/${B}/defaultObjectAcl`,
 projectIAM:`https://cloudresourcemanager.googleapis.com/v1/projects/${P}:getIamPolicy`,
 secretLatest:`https://secretmanager.googleapis.com/v1/projects/${P}/secrets/GROQ_API_KEY/versions/latest`,
 secret:`https://secretmanager.googleapis.com/v1/projects/${P}/secrets/GROQ_API_KEY`};
function assertRead(url,method='GET') {
 if(url===urls.projectIAM){if(method!=='POST')throw Error('STOP: getIamPolicy requires read-only POST');return;}
 if(method!=='GET')throw Error('STOP: production mutations prohibited');
 const u=new URL(url);
 const legacy=/^https:\/\/cloudfunctions\.googleapis\.com\/v2\/projects\/forta-aogaku\/locations\/asia-northeast1\/functions\/(?:preDeleteCleanup|deleteAccountServerSide|onAuthUserDelete|askCourseAI|transcribeLectureAudio|generateReactionPaper)$/;
 const resources=new Set([`https://serviceusage.googleapis.com/v1/projects/${N}/services?filter=state:ENABLED&pageSize=200`,`https://iam.googleapis.com/v1/projects/${P}/serviceAccounts`,`https://cloudtasks.googleapis.com/v2/projects/${P}/locations/asia-northeast1/queues/aiProcessSource`,`https://cloudscheduler.googleapis.com/v1/projects/${P}/locations/asia-northeast1/jobs`,`https://eventarc.googleapis.com/v1/projects/${P}/locations/us-central1/triggers`]);
 if(!resources.has(String(url)) && !legacy.test(String(url)) && !Object.values(urls).includes(String(url)) && !(u.origin==='https://firebaserules.googleapis.com' && new RegExp(`^/v1/projects/${P}/rulesets/[A-Za-z0-9-]+$`).test(u.pathname) && !u.search)) throw Error('STOP: metadata endpoint not allowlisted');
}
async function oauth(){if(cachedToken&&Date.now()-tokenAt<2700000)return cachedToken;
 const lib=process.env.FIREBASE_TOOLS_LIB||'/Users/shum/anaconda3/lib/node_modules/firebase-tools/lib';
 const account=require(path.join(lib,'auth.js')).getGlobalDefaultAccount();
 if(!account?.tokens?.refresh_token)throw Error('Firebase CLI reauthentication required');
 const api=require(path.join(lib,'api.js'));
 const r=await fetch('https://oauth2.googleapis.com/token',{method:'POST',body:new URLSearchParams({client_id:api.clientId(),client_secret:api.clientSecret(),refresh_token:account.tokens.refresh_token,grant_type:'refresh_token'}),signal:AbortSignal.timeout(45000)});
 const data=await r.json();if(!r.ok||!data.access_token)throw Error('OAuth refresh failed');cachedToken=data.access_token;tokenAt=Date.now();return cachedToken;
}
async function inspect(){
 const bearer=await oauth();
 const read=async url=>{const method=url===urls.projectIAM?'POST':'GET';assertRead(url,method);const {response:r,data:d}=await reads.read(url,{method,...(method==='POST'?{body:JSON.stringify({options:{requestedPolicyVersion:3}})}:{}),headers:{Authorization:`Bearer ${bearer}`,'Content-Type':'application/json'}},{allowStatuses:[urls.aiDatabase,urls.aiIndexes,urls.aiFields].includes(url)?[404]:[]});if(r.status===404&&[urls.aiDatabase,urls.aiIndexes,urls.aiFields].includes(url))return null;if(!r.ok)throw Error(`Metadata HTTP ${r.status}`);if(d.nextPageToken)throw Error('STOP: paginated inventory needs explicit review');return d;};
 const project=await read(urls.project);if(project.projectId!==P||project.projectNumber!==N||project.lifecycleState!=='ACTIVE')throw Error('STOP: live project identity mismatch');
 const out={readAt:new Date().toISOString(),projectId:P,projectNumber:N};
 for(const kind of ['database','aiDatabase','aiIndexes','aiFields','bucket','indexes','fields','functions','apps'])out[kind]=await read(urls[kind]);
 // Store no source URLs, env values, API keys or person/user records.
 out.database={name:out.database.name,locationId:out.database.locationId};
 out.bucket={name:out.bucket.name,location:out.bucket.location,metageneration:out.bucket.metageneration,lifecycle:out.bucket.lifecycle,softDeletePolicy:out.bucket.softDeletePolicy};
 out.functions.functions=(out.functions.functions||[]).map(f=>({name:f.name,environment:f.environment,state:f.state,labels:f.labels,region:f.name.split('/')[3]}));
 out.apps.apps=(out.apps.apps||[]).map(a=>({bundleId:a.bundleId,state:a.state}));
 const [bucketIAM,defaultACL,projectIAM]=await Promise.all([read(urls.bucketIAM),read(urls.defaultACL),read(urls.projectIAM)]);
 const hasPublic=policy=>(policy.bindings||[]).some(b=>(b.members||[]).some(m=>['allUsers','allAuthenticatedUsers'].includes(m)));
 out.storagePrivacy={publicBucketIAM:hasPublic(bucketIAM),publicProjectIAM:hasPublic(projectIAM),publicDefaultACL:(defaultACL.items||[]).some(a=>['allUsers','allAuthenticatedUsers'].includes(a.entity))};
 const release=await read(urls.releases);out.rules={};
 for(const kind of ['firestore','storage']){
  const found=(release.releases||[]).filter(r=>kind==='firestore'?r.name.endsWith('/cloud.firestore'):r.name.endsWith('/firebase.storage/'+B));
  if(found.length!==1)throw Error('STOP: active rule release unresolved');
  const d=await read('https://firebaserules.googleapis.com/v1/'+found[0].rulesetName);
  if(d.source?.files?.length!==1)throw Error('STOP: multi-file rules need explicit review');
  out.rules[kind]={...found[0],content:d.source.files[0].content};
 }
 const namedRelease=(release.releases||[]).filter(r=>r.name.endsWith('/cloud.firestore/aogaku-ai'));
 if(namedRelease.length>1)throw Error('Named Rules release ambiguous');
 out.aiRules=null;
 if(namedRelease.length){const d=await read('https://firebaserules.googleapis.com/v1/'+namedRelease[0].rulesetName);if(d.source?.files?.length!==1)throw Error('Named Rules source ambiguous');out.aiRules={...namedRelease[0],content:d.source.files[0].content};}
 // Resource metadata proves existence, without accessing any version/payload or rotating the key.
 const secret=await read(urls.secret),latest=await read(urls.secretLatest);out.secret={name:secret.name,latestVersion:latest.name,latestState:latest.state};
 const dir=path.join(ROOT,'build');fs.mkdirSync(dir,{recursive:true});const dest=path.join(dir,'production-live.json');fs.writeFileSync(dest,JSON.stringify(out,null,2),{mode:0o600});fs.chmodSync(dest,0o600);
 console.log('Production metadata read: identities/rules/indexes/functions/bucket/secret resource only; mutations=0.');
 return out;
}
async function legacyMetadata(){
 const bearer=await oauth(),read=async url=>{assertRead(url);const {data}=await reads.read(url,{headers:{Authorization:'Bearer '+bearer}});return data;};
 const project=await read(urls.project);if(project.projectId!==P||project.projectNumber!==N)throw Error('Project identity mismatch');
 const names=['preDeleteCleanup','deleteAccountServerSide','onAuthUserDelete','askCourseAI','transcribeLectureAudio','generateReactionPaper'],records=[];
 const dir=path.join(ROOT,'build/production-legacy-metadata');fs.mkdirSync(dir,{recursive:true,mode:0o700});fs.chmodSync(dir,0o700);
 for(const name of names){const f=await read(`https://cloudfunctions.googleapis.com/v2/projects/${P}/locations/asia-northeast1/functions/${name}`);if(f.name.split('/').pop()!==name)throw Error('Function identity mismatch');
  const raw=path.join(dir,name+'.private.json');fs.writeFileSync(raw,JSON.stringify(require('./deploy_production_phase3b.cjs').safeMetadata(f)),{mode:0o600});fs.chmodSync(raw,0o600);
  const b=f.buildConfig||{},s=f.serviceConfig||{};
  records.push({name,environment:f.environment,updateTime:f.updateTime,runtime:b.runtime,entryPoint:b.entryPoint,codebase:f.labels?.['firebase-functions-codebase']||'default',labels:f.labels||{},serviceAccount:s.serviceAccountEmail,availableMemory:s.availableMemory,availableCpu:s.availableCpu,timeoutSeconds:s.timeoutSeconds,maxInstanceCount:s.maxInstanceCount,minInstanceCount:s.minInstanceCount,ingressSettings:s.ingressSettings,secretBindings:s.secretEnvironmentVariables||[],environmentVariableKeys:Object.keys(s.environmentVariables||{}).sort(),eventTrigger:f.eventTrigger||null});
 }
 const dest=path.join(ROOT,'build/production-legacy-live.json');fs.writeFileSync(dest,JSON.stringify({projectId:P,projectNumber:N,readAt:new Date().toISOString(),records},null,2),{mode:0o600});fs.chmodSync(dest,0o600);
 console.log('Six legacy Function metadata snapshots saved privately; no environment values or payloads printed; writes=0.');
}
async function resourcesMetadata(){
 const bearer=await oauth(),read=async url=>{assertRead(url);const {response:r,data:d}=await reads.read(url,{headers:{Authorization:'Bearer '+bearer}});if(r.ok&&d.nextPageToken)throw Error('Paginated resources require review');return {httpStatus:r.status,data:d};};
 const project=await read(urls.project);if(project.data.projectId!==P||project.data.projectNumber!==N)throw Error('Project mismatch');
 const records={apis:await read(`https://serviceusage.googleapis.com/v1/projects/${N}/services?filter=state:ENABLED&pageSize=200`),serviceAccounts:await read(`https://iam.googleapis.com/v1/projects/${P}/serviceAccounts`),queue:await read(`https://cloudtasks.googleapis.com/v2/projects/${P}/locations/asia-northeast1/queues/aiProcessSource`),scheduler:await read(`https://cloudscheduler.googleapis.com/v1/projects/${P}/locations/asia-northeast1/jobs`),eventarc:await read(`https://eventarc.googleapis.com/v1/projects/${P}/locations/us-central1/triggers`)};
 const dest=path.join(ROOT,'build/production-resources-live.json');fs.writeFileSync(dest,JSON.stringify({projectId:P,projectNumber:N,readAt:new Date().toISOString(),records},null,2),{mode:0o600});fs.chmodSync(dest,0o600);console.log('API/SA/queue/scheduler/Eventarc metadata saved; mutations=0');
}
module.exports={assertRead,inspect,legacyMetadata,resourcesMetadata,urls,oauth};
if(require.main===module)(process.argv[2]==='legacy'?legacyMetadata():process.argv[2]==='resources'?resourcesMetadata():inspect()).catch(e=>{console.error(e.message);process.exitCode=1});
