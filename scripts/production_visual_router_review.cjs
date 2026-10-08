#!/usr/bin/env node
// OFFLINE ONLY: a new schema5 artifact never replaces/authorizes the old Qwen rollout.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto'),{execFileSync}=require('node:child_process');
const prior=require('./production_recognition_review.cjs'),ROOT=path.resolve(__dirname,'..'),DIR=path.join(ROOT,'build/production-visual-router-review');
function contract(){
 const ai=fs.readFileSync(path.join(ROOT,'functions/src/ai/index.ts'),'utf8'),visual=fs.readFileSync(path.join(ROOT,'functions/src/ai/visualExtraction.ts'),'utf8');
 assert(ai.includes('schemaVersion: 5'));assert(ai.includes('inputCapabilities: AUTO_CAPABILITIES'));assert(ai.includes('terminal.includes(s.status)'));assert(ai.includes('reserveProviderCall'));assert(ai.includes('extractAutoImage'));assert(ai.includes('extractAutoPDF'));
 assert(visual.includes('assertImageExtraction(ai)'));assert(visual.includes('assertAutoExtraction(value'));assert.equal(require(path.join(ROOT,'functions/lib/ai/pricing')).RECOGNITION_PRICING.image.model,'qwen/qwen3.8-27b');
 const caps=require(path.join(ROOT,'functions/lib/ai/visualRouter')).AUTO_CAPABILITIES;assert.equal(caps.image.pipelineVersion,'image-auto-v1');assert.equal(caps.pdf.pipelineVersion,'pdf-auto-v1');assert.equal(caps.image.fallback,false);assert.equal(caps.pdf.fallback,false);return caps;
}
function prepare(){
 assert.equal(execFileSync('git',['branch','--show-current'],{cwd:ROOT,encoding:'utf8'}).trim(),'codex/ai-recognition-comparison-lab');assert(!fs.existsSync(DIR),'Never overwrite an existing review');
 const target=JSON.parse(fs.readFileSync(path.join(ROOT,'Config/Production/target.json')));assert.equal(target.projectId,prior.TARGET.projectId);assert.equal(target.projectNumber,prior.TARGET.projectNumber);assert.equal(target.bucket,prior.TARGET.bucket);assert.equal(target.bundleId,prior.TARGET.bundleId);assert.equal(target.aiDatabaseId,'aogaku-ai');
 const caps=contract(),pkgdir=path.join(DIR,'package');fs.mkdirSync(pkgdir,{recursive:true,mode:0o700});fs.cpSync(path.join(ROOT,'functions/lib/ai'),path.join(pkgdir,'lib/ai'),{recursive:true});
 const entry='const admin=require("firebase-admin"),ai=require("./ai");if(!admin.apps.length)admin.initializeApp();\n'+prior.FUNCTIONS.map(n=>`exports.${n}=ai.${n};`).join('\n')+'\n';fs.writeFileSync(path.join(pkgdir,'lib/visual-router-production.js'),entry);
 const pkg=JSON.parse(fs.readFileSync(path.join(ROOT,'functions/package.json')));pkg.main='lib/visual-router-production.js';pkg.scripts={};delete pkg.devDependencies;fs.writeFileSync(path.join(pkgdir,'package.json'),JSON.stringify(pkg,null,2));fs.copyFileSync(path.join(ROOT,'functions/package-lock.json'),path.join(pkgdir,'package-lock.json'));
 const files=prior.inventory(pkgdir),sourceManifestSha256=crypto.createHash('sha256').update(JSON.stringify(files)).digest('hex');
 const value={status:'ROUTER_REVIEW_READY_AWAITING_APPROVAL',productionDeploymentAuthorized:false,livePreflightCompleted:false,target:prior.TARGET,functions:prior.FUNCTIONS,updateOrder:prior.ORDER,sourceManifestSha256,files,capabilities:caps,environmentUpdateAuthorized:false,iamUpdateAuthorized:false,secretChangeAuthorized:false,rulesChangeAuthorized:false,existingSourcesReprocessingAuthorized:false,pilotAllowlistMustBePreserved:true,queuePauseDrainAndRestoreRequiresApproval:true,oldApprovalReusable:false};fs.writeFileSync(path.join(DIR,'review.json'),JSON.stringify(value,null,2),{mode:0o600});console.log(JSON.stringify({status:value.status,functions:value.functions.length,sourceManifestSha256,productionMutations:0}));return value;
}
module.exports={contract,prepare,DIR};if(require.main===module){assert.deepEqual(process.argv.slice(2),['prepare']);prepare();}
