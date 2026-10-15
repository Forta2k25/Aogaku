#!/usr/bin/env node
// OFFLINE REVIEW ONLY. No cloud credentials, HTTP client, Firebase CLI deploy or mutation runner.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),{execFileSync}=require('node:child_process');
const ROOT=path.resolve(__dirname,'..');
const TARGET=Object.freeze({projectId:'forta-aogaku',projectNumber:'505828754933',bucket:'forta-aogaku.firebasestorage.app',bundleId:'com.forta2k25.Aogaku',databaseId:'aogaku-ai',region:'asia-northeast1',runtimeServiceAccount:'aogaku-ai-runtime@forta-aogaku.iam.gserviceaccount.com'});
const CALLABLES=Object.freeze(['aiCreateSource','aiCompleteSource','aiGetSource','aiListSources','aiGetEvidence','aiRetrySource','aiUpdateSource','aiDeleteSource','aiRetrieveContext']);
const FUNCTIONS=Object.freeze([...CALLABLES,'aiProcessSource']);
const ORDER=Object.freeze(['aiProcessSource','aiGetSource','aiGetEvidence','aiRetrieveContext','aiRetrySource','aiUpdateSource','aiDeleteSource','aiCompleteSource','aiCreateSource','aiListSources']);
const DIR=path.join(ROOT,'build/production-recognition-review'),PACKAGE=path.join(DIR,'package');
const sha=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');
const hash=x=>sha(Buffer.from(JSON.stringify(x)));
function names(values){assert.equal(values.length,10,'Exact ten Functions required');assert.deepEqual([...values].sort(),[...FUNCTIONS].sort());}
function cohort(functions){
 names(functions.map(f=>f.name.split('/').at(-1)));let allowed;
 for(const f of functions){
  const n=f.name.split('/').at(-1);assert.equal(f.name,`projects/${TARGET.projectId}/locations/${TARGET.region}/functions/${n}`);assert.equal(f.environment,'GEN_2');assert.equal(f.state,'ACTIVE');assert.equal(f.buildConfig.runtime,'nodejs22');assert.equal(f.serviceConfig.serviceAccountEmail,TARGET.runtimeServiceAccount);
  const env=f.serviceConfig.environmentVariables;assert.equal(env.AI_FIRESTORE_DATABASE_ID,TARGET.databaseId);assert.equal(env.AI_SHARING_ENABLED,'false');
  assert(env.AI_INPUT_ADMISSION_MODE===undefined||env.AI_INPUT_ADMISSION_MODE==='pilot','General admission forbidden');
  assert(env.AI_INPUT_REQUIRE_APP_CHECK===undefined||['false','true'].includes(env.AI_INPUT_REQUIRE_APP_CHECK),'Invalid App Check setting');
  const uids=JSON.parse(env.AI_INPUT_ALLOWED_UIDS);assert(Array.isArray(uids)&&uids.length>0&&new Set(uids).size===uids.length);assert(uids.every(v=>typeof v==='string'&&/^[A-Za-z0-9_-]{1,128}$/.test(v)),'Invalid/wildcard UID forbidden');
  if(allowed===undefined)allowed=env.AI_INPUT_ALLOWED_UIDS;else assert.equal(env.AI_INPUT_ALLOWED_UIDS,allowed,'Live cohort allowlists differ: stop, never repair automatically');
 }
 // Return a digest/count only. Never reconstruct deployment env from stale local UID files.
 return {allowedUIDCount:JSON.parse(allowed).length,allowedUIDDigest:sha(Buffer.from(allowed)),environmentUpdateAuthorized:false};
}
function validateIdentity(identity){assert.deepEqual(identity,TARGET,'Production ID/number/bucket/bundle/named DB/region/SA mismatch');}
function validateSourcePatch(url,method,body,context){
 // Pure future-deploy validator. There is intentionally no execution path in this file.
 assert(context.approved===true,'Review is not deployment approval');assert(context.baselineAgeSeconds>=0&&context.baselineAgeSeconds<=300);assert(context.queuePaused===true&&context.inflightWorkers===0,'Worker must be fully drained');
 assert(context.schedulerPaused===true);assert(context.phase5bAuthorized===false);validateIdentity(context.identity);names(context.functions);cohort(context.liveFunctions);
 const n=context.name;assert(FUNCTIONS.includes(n));assert.equal(context.before.name,`projects/${TARGET.projectId}/locations/${TARGET.region}/functions/${n}`);
 assert.equal(method,'PATCH');assert.equal(url,`https://cloudfunctions.googleapis.com/v2/${context.before.name}?updateMask=buildConfig.source`);
 assert.deepEqual(body,{name:context.before.name,buildConfig:{source:{storageSource:context.freshStorageSource}}});
 assert(context.freshStorageSource&&typeof context.freshStorageSource.bucket==='string'&&typeof context.freshStorageSource.object==='string');
 assert(context.freshStorageSource.bucket.includes(TARGET.projectNumber)&&context.freshStorageSource.bucket.includes(TARGET.region));assert(!context.freshStorageSource.object.includes('..'));
 // Gen2 staging responses can issue a storageSource without a generation.
 if(context.freshStorageSource.generation!==undefined)assert(String(context.freshStorageSource.generation).match(/^\d+$/));
 assert(context.stagingUploaded===true&&context.issuedStorageSourceHash===hash(context.freshStorageSource),'Unissued/unuploaded source forbidden');
 assert.equal(context.approvedSourceManifestSha256,context.actualSourceManifestSha256,'Fresh artifact mismatch');assert(/^[a-f0-9]{64}$/.test(context.approvedSourceManifestSha256));
}
function postCheck(before,after,installedManifest,expectedManifest){
 assert.deepEqual(installedManifest,expectedManifest,'FULL installed source, including lockfile, must match');
 assert.equal(after.state,'ACTIVE');assert.equal(after.name,before.name);
 const old=structuredClone(before),current=structuredClone(after);
 // Only source update/revision/build output references can change after verified full source.
 for(const key of ['build','source','sourceProvenance'])current.buildConfig[key]=old.buildConfig[key];
 current.updateTime=old.updateTime;current.serviceConfig.revision=old.serviceConfig.revision;
 // GCF may regenerate metadata describing the new build. No business settings are ignored.
 assert.deepEqual(current,old,'Unapproved Function metadata drift');
}
function inventory(dir){
 const files={};function visit(folder){for(const entry of fs.readdirSync(folder,{withFileTypes:true}).sort((a,b)=>a.name.localeCompare(b.name))){assert(!entry.isSymbolicLink(),'Symlinks are not part of source');const p=path.join(folder,entry.name);if(entry.isDirectory())visit(p);else{const name=path.relative(dir,p).replaceAll(path.sep,'/');assert(!/(^|\/)(?:\.env(?:\.|$)|node_modules|build|DevFixtures|GoogleService|credentials|.*\.local\.json)/.test(name),'Private/generated file in package');files[name]=sha(fs.readFileSync(p));}}}visit(dir);return Object.fromEntries(Object.entries(files).sort(([a],[b])=>a.localeCompare(b)));
}
function verifyContract(){
 const i=fs.readFileSync(path.join(ROOT,'functions/src/ai/index.ts'),'utf8'),x=fs.readFileSync(path.join(ROOT,'functions/src/ai/extractors.ts'),'utf8');
 assert(i.includes('schemaVersion: 4'));assert(i.includes('inputCapabilities: {image: IMAGE_PIPELINE}'));assert(i.includes('recognition: latest.recognition || null'));assert(i.includes('reserveProviderCall'));assert(i.includes('terminal.includes(s.status)'));
 assert(x.includes('assertImageExtraction(result)'));assert(!x.includes('documentTextDetection'));
 assert(x.includes('batchAnnotateFiles'),'PDF OCR must stay available');assert(!x.includes('whisper-large-v3"'),'No audio model fallback');
}
function prepare(){
 const branch=execFileSync('git',['branch','--show-current'],{cwd:ROOT,encoding:'utf8'}).trim();
 assert(['codex/ai-input-detection-results','codex/ai-recognition-comparison-lab'].includes(branch),'Recognition candidate requires an approved feature branch, never main');
 const target=JSON.parse(fs.readFileSync(path.join(ROOT,'Config/Production/target.json')));for(const[k,v]of Object.entries({projectId:TARGET.projectId,projectNumber:TARGET.projectNumber,bucket:TARGET.bucket,bundleId:TARGET.bundleId,aiDatabaseId:TARGET.databaseId}))assert.equal(target[k],v);
 // Do not read/output the plist's client API key, private config, tokens or live allowlist.
 const identity=JSON.parse(execFileSync('python3',['-c','import plistlib,json;d=plistlib.load(open("Aogaku/GoogleService-Info.plist","rb"));print(json.dumps({k:d[k] for k in ["PROJECT_ID","GCM_SENDER_ID","STORAGE_BUCKET","BUNDLE_ID"]}))'],{cwd:ROOT,encoding:'utf8'}));
 assert.deepEqual(identity,{PROJECT_ID:TARGET.projectId,GCM_SENDER_ID:TARGET.projectNumber,STORAGE_BUCKET:TARGET.bucket,BUNDLE_ID:TARGET.bundleId});
 const project=JSON.parse(execFileSync('plutil',['-convert','json','-o','-',path.join(ROOT,'Aogaku.xcodeproj/project.pbxproj')],{encoding:'utf8'})).objects;
 const app=Object.values(project).find(x=>x.isa==='PBXNativeTarget'&&x.name==='Aogaku');const configs=project[app.buildConfigurationList].buildConfigurations.map(k=>project[k]);assert.equal(configs.find(x=>x.name==='Release').buildSettings.PRODUCT_BUNDLE_IDENTIFIER,TARGET.bundleId);
 verifyContract();execFileSync('npm',['--prefix','functions','run','build'],{cwd:ROOT,stdio:'pipe'});
 // Preserve prior Phase4/5a evidence. Only this new isolated review directory is generated.
 assert(!fs.existsSync(path.join(DIR,'review.json')),'Existing review cannot be overwritten; archive deliberately before rebuilding');fs.mkdirSync(PACKAGE,{recursive:true,mode:0o700});
 fs.cpSync(path.join(ROOT,'functions/lib/ai'),path.join(PACKAGE,'lib/ai'),{recursive:true});
 const entry='// Reviewed ten-export production candidate. Existing deployed env/IAM are retained.\nconst admin=require("firebase-admin"),ai=require("./ai");if(!admin.apps.length)admin.initializeApp();\n'+FUNCTIONS.map(n=>`exports.${n}=ai.${n};`).join('\n')+'\n';fs.writeFileSync(path.join(PACKAGE,'lib/recognition-production.js'),entry);
 const pkg=JSON.parse(fs.readFileSync(path.join(ROOT,'functions/package.json')));pkg.name='aogaku-ai-recognition-review';pkg.main='lib/recognition-production.js';pkg.scripts={};delete pkg.devDependencies;fs.writeFileSync(path.join(PACKAGE,'package.json'),JSON.stringify(pkg,null,2)+'\n');fs.copyFileSync(path.join(ROOT,'functions/package-lock.json'),path.join(PACKAGE,'package-lock.json'));
 const script=`global.fetch=async()=>{throw Error('REVIEW_NETWORK_FORBIDDEN')};const a=require('node:assert/strict'),s=require(${JSON.stringify(path.join(ROOT,'functions/node_modules/firebase-functions/lib/runtime/loader.js'))});s.loadStack(process.cwd()).then(v=>{console.log(JSON.stringify(v))}).catch(e=>{console.error(e.name);process.exit(1)});`;
 const env={...process.env,NODE_PATH:path.join(ROOT,'functions/node_modules'),GCLOUD_PROJECT:TARGET.projectId,FIREBASE_CONFIG:JSON.stringify({projectId:TARGET.projectId,storageBucket:TARGET.bucket}),AI_FIRESTORE_DATABASE_ID:TARGET.databaseId,AI_RUNTIME_SERVICE_ACCOUNT:TARGET.runtimeServiceAccount,AI_INPUT_ALLOWED_UIDS:'[]',AI_SHARING_ENABLED:'false',AI_INPUT_ADMISSION_MODE:'pilot',AI_INPUT_REQUIRE_APP_CHECK:'false'};
 const stack=JSON.parse(execFileSync(process.execPath,['-e',script],{cwd:PACKAGE,env,encoding:'utf8'}));names(Object.keys(stack.endpoints));
 for(const[n,e]of Object.entries(stack.endpoints)){assert.deepEqual(e.region,[TARGET.region]);assert(e.serviceAccountEmail.includes('AI_RUNTIME_SERVICE_ACCOUNT'));assert(n==='aiProcessSource'?e.taskQueueTrigger:e.callableTrigger);}
 const files=inventory(PACKAGE),review={status:'REVIEW_READY_AWAITING_APPROVAL',reviewOnly:true,productionDeploymentAuthorized:false,livePreflightCompleted:false,target:TARGET,functions:FUNCTIONS,updateOrder:ORDER,sourceManifestSha256:hash(files),files,pipelines:{image:require(path.join(ROOT,'functions/lib/ai/pricing')).IMAGE_PIPELINE,audio:require(path.join(ROOT,'functions/lib/ai/pricing')).RECOGNITION_PRICING.audio},privateConfigEmbedded:false,liveEnvironmentPreservationRequired:true,newAppCheckEnforcementAuthorized:false,newAdmissionModeAuthorized:false,queuePauseAndRestoreNeedsApproval:true,secretRotationAuthorized:false};
 fs.writeFileSync(path.join(DIR,'review.json'),JSON.stringify(review,null,2)+'\n',{mode:0o600});fs.writeFileSync(path.join(DIR,'endpoints.json'),JSON.stringify(stack.endpoints,null,2)+'\n',{mode:0o600});console.log(JSON.stringify({status:review.status,functions:FUNCTIONS.length,sourceManifestSha256:review.sourceManifestSha256,productionMutations:0,livePreflightCompleted:false}));return review;
}
module.exports={validateIdentity,TARGET,CALLABLES,FUNCTIONS,ORDER,DIR,PACKAGE,names,cohort,validateSourcePatch,postCheck,inventory,verifyContract,prepare};
if(require.main===module){assert.deepEqual(process.argv.slice(2),['prepare'],'Only offline prepare is supported; deploy cannot run');prepare();}
