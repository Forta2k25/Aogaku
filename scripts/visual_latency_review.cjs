#!/usr/bin/env node
// Offline planning only; no cloud clients, credentials, network or mutations.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto'),{execFileSync}=require('node:child_process');
const ROOT=path.resolve(__dirname,'..'),BASE='b3a04d1d7d0cf47f76199c4b46b3451adc795dc5';
const FUNCTIONS=['aiProcessSource','aiCompleteSource','aiGetSource','aiGetEvidence'];
const MODULES=['lib/ai/index.js','lib/ai/visualExtraction.js','lib/ai/latency.js','lib/ai/localVisual.js','lib/ai/progressive.js'];
function plan(){assert.equal(execFileSync('git',['branch','--show-current'],{cwd:ROOT,encoding:'utf8'}).trim(),'codex/ai-recognition-comparison-lab');for(const file of ['recognition.ts','visualRouter.ts','pricing.ts']){
 const current=fs.readFileSync(path.join(ROOT,'functions/src/ai',file),'utf8'),before=execFileSync('git',['show',BASE+':functions/src/ai/'+file],{cwd:ROOT,encoding:'utf8'});
 // New diagnostics are type-only in Router/Pricing. Their decision/pricing implementation must remain byte-identical.
 const clean=s=>s.replace(/^  ocrProbeSkipped\?:.*\n/gm,'').replace(/^  latency\?:.*\n/gm,'');
 const sha=s=>crypto.createHash('sha256').update(s).digest('hex');assert.equal(sha(clean(current)),sha(clean(before)),file+' protected algorithm/model/prompt/pricing changed');
 }
 return {baseline:BASE,projectId:'forta-aogaku',productionDeploymentAuthorized:false,functions:FUNCTIONS,changedModules:MODULES,updateMask:'buildConfig.source',preserve:['source contracts and old OCR','live pilot allowlist','sharing OFF','Scheduler PAUSED','Rules','IAM','Secret','indexes','lifecycle'],queue:'fresh RUNNING snapshot -> pause/drain -> all four source and protected checks -> restore RUNNING',rollback:'only separate approval; archived four deployed ZIPs, source-only patches, same protected checks',settingsChanges:false,additionalIndexes:false,additionalIAM:false};}
module.exports={plan,FUNCTIONS,MODULES};if(require.main===module)console.log(JSON.stringify(plan(),null,2));
