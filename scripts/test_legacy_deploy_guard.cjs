const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('fs'),path=require('path');
const lib='/Users/shum/anaconda3/lib/node_modules/firebase-tools/lib',install=require('./firebase_legacy_prompt_guard.cjs').install;
const metadata=JSON.parse(fs.readFileSync(path.join(__dirname,'../Config/Production/legacy-baseline.json')));
test('legacy quota guard pins original Secret versions; unknown names/secret changes disabled',async()=>{
 const sm=require(lib+'/gcp/secretManager.js'),original=sm.getSecretVersion;let read=[];sm.getSecretVersion=async(project,secret,version)=>{read.push({project,secret,version});return {versionId:version,state:'ENABLED'};};
 try {
  const receipt={target:{projectId:'forta-aogaku'},group:'quota',mode:'candidate',authorizeNamedUpdates:['askCourseAI','transcribeLectureAudio','generateReactionPaper']};const v=install(lib,receipt,metadata);
  const want={endpoints:{'asia-northeast1':{askCourseAI:{id:'askCourseAI',secretEnvironmentVariables:[{key:'OPENAI_API_KEY',secret:'OPENAI_API_KEY'}]}}}};
  await v.secretsAreValid('forta-aogaku',want);assert.deepEqual(read,[{project:'forta-aogaku',secret:'OPENAI_API_KEY',version:'1'}]);assert.equal(want.endpoints['asia-northeast1'].askCourseAI.secretEnvironmentVariables[0].version,'1');
  await assert.rejects(v.secretsAreValid('forta-aogaku-dev',want));want.endpoints['asia-northeast1'].askCourseAI.id='friendNotification';await assert.rejects(v.secretsAreValid('forta-aogaku',want));
  const tasks=require(lib+'/gcp/cloudtasks.js');await assert.rejects(tasks.purgeQueue('x'),/forbidden/);await assert.rejects(tasks.deleteQueue('x'),/forbidden/);
  const queue=tasks.queueFromEndpoint({project:'forta-aogaku',region:'asia-northeast1',id:'aiProcessSource',taskQueueTrigger:{}});assert(!('state' in queue));
 } finally {sm.getSecretVersion=original;}
});
test('production queue upsert uses explicit pause, rejects running queue and verifies paused state',async()=>{
 const tasks=require(lib+'/gcp/cloudtasks.js'),{Client}=require(lib+'/apiv2.js');
 const saved={get:tasks.getQueue,create:tasks.createQueue,update:tasks.updateQueue,post:Client.prototype.post};
 const name='projects/forta-aogaku/locations/asia-northeast1/queues/aiProcessSource';let exists=false,state='RUNNING',events=[];
 tasks.getQueue=async()=>{if(!exists)throw {context:{response:{statusCode:404}}};return {name,state};};
 tasks.createQueue=async b=>{assert(!('state' in b));exists=true;events.push('create');};
 tasks.updateQueue=async b=>{assert(!('state' in b));events.push('update');};
 Client.prototype.post=async p=>{assert.equal(p,name+':pause');events.push('pause');state='PAUSED';return {body:{}};};
 try{
  await assert.rejects(tasks.upsertQueue({name:name+'-other'}));
  assert.equal(await tasks.upsertQueue({name,state:'PAUSED'}),true);assert.deepEqual(events,['create','pause']);
  events=[];assert.equal(await tasks.upsertQueue({name}),false);assert.deepEqual(events,['update','pause']);
  state='RUNNING';events=[];await assert.rejects(tasks.upsertQueue({name}),/already be paused/);assert.deepEqual(events,[]);
  state='PAUSED';Client.prototype.post=async()=>{state='RUNNING';return {body:{}};};await assert.rejects(tasks.upsertQueue({name}),/pause not confirmed/);
 }finally{tasks.getQueue=saved.get;tasks.createQueue=saved.create;tasks.updateQueue=saved.update;Client.prototype.post=saved.post;}
});
