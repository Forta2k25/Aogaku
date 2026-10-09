#!/usr/bin/env node
// No cloud writes/provider calls. Live env remains in memory, never printed or committed.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),{spawnSync}=require('node:child_process');
const d=require('./deploy_production_visual_router.cjs'),p=require('./production_recognition_review.cjs'),c=require('./production_phase5a_common.cjs');
async function main(){
 assert.equal(d.load('execution').status,'COHORT_AUDIT_PASS');const artifact=d.artifact(),live=await d.rawFunctions();
 for(const name of p.FUNCTIONS){const f=live.find(x=>x.name.endsWith('/'+name)),source=await d.source(f,'domain');assert.deepEqual(source.files,artifact.files);}
 const dir=path.join(require('./production_visual_router_review.cjs').DIR,'package');let count=0;
 for(const name of p.CALLABLES){
  const f=live.find(x=>x.name.endsWith('/'+name)),env=f.serviceConfig.environmentVariables;
  const code=`global.fetch=async()=>{throw Error('NETWORK_FORBIDDEN')};const assert=require('node:assert/strict'),api=require('./lib/visual-router-production');(async()=>{await assert.rejects(api[${JSON.stringify(name)}].run({auth:{uid:'SYNTHETIC_NONPILOT_DOMAIN_ONLY'},data:null}),e=>e.message==='AI_INPUT_NOT_ENABLED');console.log('PASS')})().catch(e=>{console.error(e.name);process.exit(1)});`;
  const result=spawnSync(process.execPath,['-e',code],{cwd:dir,env:{...process.env,NODE_PATH:path.join(c.ROOT,'functions/node_modules'),GCLOUD_PROJECT:c.P,FIREBASE_CONFIG:JSON.stringify({projectId:c.P,storageBucket:c.B}),...env},encoding:'utf8'});
  assert.equal(result.status,0,'Installed nonpilot domain gate '+name+' failed');assert(result.stdout.includes('PASS'));count++;
 }
 d.save('installed-nonpilot-domain-gates',{status:'PASS',count,exactProductionEnvironment:true,sourceManifestVerifiedForAllTen:true});console.log('9/9 installed full-source/live-env nonpilot gates PASS; no network inside handlers');
}
if(require.main===module)main().catch(e=>{console.error('SAFE STOP domain '+e.name);process.exitCode=1});
