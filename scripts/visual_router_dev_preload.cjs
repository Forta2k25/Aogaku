// The existing Dev queue is deliberately frozen during the contract cohort.
// Firebase CLI's generic updater includes output-only Queue.state; never apply it.
const assert=require('node:assert/strict'),path=require('node:path'),fs=require('node:fs');
if(process.env.AOGAKU_VISUAL_ROUTER_DEV==='true'){
 const args=process.argv;assert.equal(args[args.indexOf('--project')+1],'forta-aogaku-dev');assert(!args.includes('--force'));
 const lib=process.env.FIREBASE_TOOLS_LIB||path.dirname(path.dirname(fs.realpathSync(args[1]))),tasks=require(path.join(lib,'gcp/cloudtasks.js'));
 tasks.upsertQueue=async desired=>{
  assert.equal(desired.name,'projects/forta-aogaku-dev/locations/asia-northeast1/queues/aiProcessSource');
  const live=await tasks.getQueue(desired.name);assert.equal(live.state,'PAUSED');
  for(const [key,values]of Object.entries({rateLimits:desired.rateLimits,retryConfig:desired.retryConfig}))for(const [k,v]of Object.entries(values))if(v!==null&&v!==undefined)assert.deepEqual(live[key][k],v,'Unexpected Dev queue config drift');
  console.log('Existing Dev worker queue/config preserved PAUSED; no queue PATCH');return false;
 };
 tasks.purgeQueue=tasks.deleteQueue=async()=>{throw Error('Dev Router queue deletion/purge forbidden');};
}
