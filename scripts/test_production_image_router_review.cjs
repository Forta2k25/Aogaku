const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
const r=require('./production_image_router_review.cjs'),p=require('./production_recognition_review.cjs');
test('image-only production candidate changes exactly two modules; no contract/provider/entrypoint changes',()=>{
 const before={'package.json':'a','lib/ai/visualExtraction.js':'a','lib/ai/visualRouter.js':'a','lib/ai/recognition.js':'a','lib/ai/index.js':'a'},after={...before,'lib/ai/visualExtraction.js':'b','lib/ai/visualRouter.js':'b'};assert.deepEqual(r.assertModuleDelta(before,after),[...r.MODULES]);
 for(const bad of [{...after,'lib/ai/recognition.js':'b'},{...after,'package.json':'b'},{...after,'lib/ai/index.js':'b'},{...after,'new.js':'x'},{...before}])assert.throws(()=>r.assertModuleDelta(before,bad));
});
test('one-worker offline plan never authorizes mutation, ten-function update or changing safety flags',()=>{
 const plan={productionDeploymentAuthorized:false,target:p.TARGET,functions:['aiProcessSource'],changedModules:[...r.MODULES],updateMask:'buildConfig.source',environmentUpdateAuthorized:false,iamUpdateAuthorized:false,oldSourceReprocessingAuthorized:false,queuePauseDrainRestoreRequiresApproval:true,sharing:false,schedulerState:'PAUSED',originalQueueState:'RUNNING',pipelineVersion:'image-auto-v1',pdfPipelineVersion:'pdf-auto-v1',model:'qwen/qwen3.8-27b',allowlistCount:2};assert.doesNotThrow(()=>r.validatePlan(plan));
 for(const change of [{productionDeploymentAuthorized:true},{functions:p.FUNCTIONS},{environmentUpdateAuthorized:true},{iamUpdateAuthorized:true},{sharing:true},{schedulerState:'ENABLED'},{pipelineVersion:'image-ai-v2'},{model:'other'},{target:{...p.TARGET,projectId:'forta-aogaku-dev'}}])assert.throws(()=>r.validatePlan({...plan,...change}));
 const code=fs.readFileSync(__dirname+'/production_image_router_review.cjs','utf8');for(const forbidden of ['fetch(',':setIamPolicy',':generateUploadUrl',':pause',':resume','firebase deploy'])assert(!code.includes(forbidden));
});
