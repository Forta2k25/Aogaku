// Preload for the installed Firebase CLI. Never use --force.
// Approve only the idempotent AI Storage retry policy; all deletions/unsafe replacements abort.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
function install(lib,project){
 assert(['forta-aogaku','forta-aogaku-dev'].includes(project));
 assert.equal(require(path.join(lib,'../package.json')).version,'14.17.0','Firebase CLI upgrade requires guard revalidation');
 const prompts=require(path.join(lib,'deploy/functions/prompts.js'));
 const backend=require(path.join(lib,'deploy/functions/backend.js'));
 const originalUnsafe=prompts.promptForUnsafeMigration;
 prompts.promptForFunctionDeletion=async list=>{if(list.length)throw Error('STOP: function deletion proposal automatically rejected');return true;};
 prompts.promptForUnsafeMigration=async(updates,options)=>{if(updates.some(x=>x.unsafe))throw Error('STOP: unsafe function replacement automatically rejected');return originalUnsafe(updates,{...options,force:false,nonInteractive:true});};
 prompts.promptForFailurePolicies=async(options,want)=>{
  assert.equal(options.project,project);assert(!options.force);
  const retry=backend.allEndpoints(want).filter(e=>backend.isEventTriggered(e)&&e.eventTrigger.retry);
  for(const e of retry){assert.equal(e.id,'aiRejectLateUpload');assert.equal(e.project,project);assert.equal(e.region,'asia-northeast1');assert.equal(e.eventTrigger.eventFilters.bucket,project+'.firebasestorage.app');}
  // This policy is part of the reviewed artifact; no prompt about deletion is accepted.
  if(retry.length)console.log('AI finalize retry policy allowed; deletion/replacement guards remain active.');
 };
 if(project==='forta-aogaku'){
  const tasks=require(path.join(lib,'gcp/cloudtasks.js')),fromEndpoint=tasks.queueFromEndpoint;
  const queueName='projects/forta-aogaku/locations/asia-northeast1/queues/aiProcessSource';
  tasks.queueFromEndpoint=e=>{const q=fromEndpoint(e);assert.equal(q.name,queueName);delete q.state;return q;};
  // Queue.state is output-only: create/patch cannot pause it. Explicit pause and GET proof.
  const {Client}=require(path.join(lib,'apiv2.js'));
  const taskClient=new Client({urlPrefix:require(path.join(lib,'api.js')).cloudTasksOrigin(),auth:true,apiVersion:'v2'});
  tasks.upsertQueue=async queue=>{
   assert.equal(queue.name,queueName);const body={...queue};delete body.state;
   let existing;
   try{existing=await tasks.getQueue(queueName);}catch(err){if(err?.context?.response?.statusCode!==404)throw err;}
   if(existing){assert.equal(existing.state,'PAUSED','STOP: production queue must already be paused before deploy');await tasks.updateQueue(body);}
   else await tasks.createQueue(body);
   await taskClient.post(queueName+':pause',{});
   assert.equal((await tasks.getQueue(queueName)).state,'PAUSED','STOP: explicit production queue pause not confirmed');
   return !existing;
  };
  tasks.purgeQueue=async()=>{throw Error('STOP: production queue purge forbidden');};
  tasks.deleteQueue=async()=>{throw Error('STOP: production queue deletion forbidden');};
  const {FirestoreApi}=require(path.join(lib,'firestore/api.js'));
  const proto=FirestoreApi.prototype,originalDeploy=proto.deploy;
  proto.deploy=async function(options,indexes,fields,database='(default)'){
   assert.equal(options.project,project);assert(!options.force);assert.equal(database,'(default)');
   const existing=await this.listIndexes(project,database),overrides=await this.listFieldOverrides(project,database);
   const spec=this.upgradeOldSpec({indexes,fieldOverrides:fields});this.validateSpec(spec);
   if(existing.some(i=>!spec.indexes.some(s=>this.indexMatchesSpec(i,s,'STANDARD'))))throw Error('STOP: live index deletion proposal');
   if(overrides.some(f=>!spec.fieldOverrides.some(s=>this.fieldMatchesSpec(f,s))))throw Error('STOP: fieldOverride change/deletion proposal');
   return originalDeploy.call(this,{...options,force:false,nonInteractive:true},indexes,fields,database);
  };
  proto.createDatabase=async()=>{throw Error('STOP: production database recreation forbidden');};
  proto.deleteIndex=async()=>{throw Error('STOP: index deletion forbidden');};
  proto.deleteField=async()=>{throw Error('STOP: fieldOverride deletion forbidden');};
  proto.patchField=async()=>{throw Error('STOP: fieldOverride replacement forbidden');};
 }
 return prompts;
}
function boot(){
 const args=process.argv,idx=args.indexOf('--project');if(idx<0)throw Error('STOP: explicit project required');
 const project=args[idx+1];if(args.includes('--force')||!args.includes('deploy'))throw Error('STOP: only guarded deploy without force');
 if(project==='forta-aogaku'){
  const session=process.env.AOGAKU_PRODUCTION_SESSION;if(!session)throw Error('STOP: production approval missing');
  const receipt=JSON.parse(fs.readFileSync(session));assert.equal(receipt.target.projectId,project);assert.equal(receipt.gates.retryPolicyReviewed,true);
 } else {assert.equal(project,'forta-aogaku-dev');assert.equal(process.env.AOGAKU_DEV_RETRY_APPROVED,'true');}
 const lib=process.env.FIREBASE_TOOLS_LIB||path.dirname(path.dirname(fs.realpathSync(args[1])));
 install(lib,project);
}
module.exports={install};
if(process.env.AOGAKU_FIREBASE_PROMPT_PRELOAD==='true')boot();
