#!/usr/bin/env node
// Read-only Dev post-deploy checks. Source download URL exists only in memory.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict'),{execFileSync}=require('node:child_process'),c=require('./dev_cloud.cjs');
(async()=>{
 c.guard();const before=JSON.parse(fs.readFileSync(path.join(c.ROOT,'build/detection-dev-before.json')));assert.equal(before.project.projectId,c.PROJECT);
 const base=`https://cloudfunctions.googleapis.com/v2/projects/${c.PROJECT}/locations/${c.REGION}/functions`;
 const after=await c.request(`https://cloudfunctions.googleapis.com/v2/projects/${c.PROJECT}/locations/-/functions`);
 assert.equal(after.functions.length,before.functions.functions.length);const targets=['aiListSources','aiProcessSource'];
 const proof={project:c.PROJECT,targets,unchangedFunctions:0,installedSourceFiles:{}};
 for(const old of before.functions.functions){const f=after.functions.find(x=>x.name===old.name);assert(f);const n=f.name.split('/').at(-1);
  if(!targets.includes(n)){assert.deepEqual(f,old);proof.unchangedFunctions++;continue;}
  assert.equal(f.state,'ACTIVE');assert.equal(f.buildConfig.runtime,old.buildConfig.runtime);assert.equal(f.serviceConfig.serviceAccountEmail,old.serviceConfig.serviceAccountEmail);const oldEnv={...old.serviceConfig.environmentVariables},newEnv={...f.serviceConfig.environmentVariables};
  // Firebase CLI omits this generated HTTP marker; Functions Framework's default is http.
  if(n==='aiListSources'&&oldEnv.FUNCTION_SIGNATURE_TYPE==='http'&&newEnv.FUNCTION_SIGNATURE_TYPE===undefined){delete oldEnv.FUNCTION_SIGNATURE_TYPE;proof.generatedHTTPMarkerRemoved=true;}
  assert.deepEqual(newEnv,oldEnv);assert.deepEqual(f.eventTrigger,old.eventTrigger);assert.deepEqual(f.serviceConfig.secretEnvironmentVariables,old.serviceConfig.secretEnvironmentVariables);
  assert.equal(f.serviceConfig.environmentVariables.AI_FIRESTORE_DATABASE_ID,'aogaku-ai');assert.equal(f.serviceConfig.environmentVariables.AI_SHARING_ENABLED,'false');
  const source=await c.request(base+'/'+n+':generateDownloadUrl','POST',{});const u=new URL(source.downloadUrl);assert(u.protocol==='https:'&&(u.hostname==='storage.googleapis.com'||u.hostname.endsWith('.storage.googleapis.com')));
  const download=await fetch(u,{signal:AbortSignal.timeout(90000)});assert(download.ok,'DEV_SOURCE_DOWNLOAD');const file=path.join(c.ROOT,'build',`image-route-${n}-source.zip`);fs.writeFileSync(file,Buffer.from(await download.arrayBuffer()),{mode:0o600});
  const checked=['src/ai/index.ts','src/ai/extractors.ts','src/ai/recognition.ts','src/ai/pricing.ts','lib/ai/index.js','lib/ai/extractors.js','lib/ai/recognition.js','lib/ai/pricing.js'];
  for(const name of checked){const installed=execFileSync('unzip',['-p',file,name],{maxBuffer:1024**2});const expected=fs.readFileSync(path.join(c.ROOT,'functions',name));assert(installed.equals(expected),'DEV_SOURCE_MISMATCH '+name);}
  proof.installedSourceFiles[n]=checked.length;
 }
 const queue=await c.request(`https://cloudtasks.googleapis.com/v2/projects/${c.PROJECT}/locations/${c.REGION}/queues/aiProcessSource`);assert.equal(queue.state,before.queue.state);proof.queue=queue.state;
 const bucket=await c.request(`https://storage.googleapis.com/storage/v1/b/${c.BUCKET}`);assert.deepEqual(bucket.lifecycle,before.bucket.lifecycle);proof.lifecycleUnchanged=true;
 fs.writeFileSync(path.join(c.ROOT,'build/image-route-dev-audit.json'),JSON.stringify(proof,null,2),{mode:0o600});console.log(JSON.stringify(proof));
})().catch(e=>{console.error('STOP Dev audit '+e.name+' (no mutation replay)');console.error(String(e.stack).split('\n').filter(x=>/^\s+at /.test(x)).slice(0,3).join('\n'));process.exitCode=1});
