const {test}=require('node:test'),assert=require('node:assert/strict');
const dev=require('./dev_cloud.cjs'),review=require('./visual_latency_review.cjs');
test('latency rollout is an unapproved four-function source-only plan, no new IAM/index/settings',()=>{
 const p=review.plan();assert.equal(p.productionDeploymentAuthorized,false);assert.deepEqual(p.functions,['aiProcessSource','aiCompleteSource','aiGetSource','aiGetEvidence']);assert.equal(p.updateMask,'buildConfig.source');assert.equal(p.additionalIAM,false);assert.equal(p.additionalIndexes,false);assert.equal(p.settingsChanges,false);
});
test('Dev latency tools cannot access production resources or Secret payloads',()=>{
 for(const url of ['https://cloudfunctions.googleapis.com/v2/projects/forta-aogaku/locations/asia-northeast1/functions/aiProcessSource','https://cloudtasks.googleapis.com/v2/projects/forta-aogaku/locations/asia-northeast1/queues/aiProcessSource','https://storage.googleapis.com/storage/v1/b/forta-aogaku.firebasestorage.app','https://firestore.googleapis.com/v1/projects/forta-aogaku/databases/aogaku-ai','https://secretmanager.googleapis.com/v1/projects/forta-aogaku-dev/secrets/GROQ_API_KEY/versions/1:access'])assert.throws(()=>dev.assertURL(url));
 dev.assertURL('https://cloudfunctions.googleapis.com/v2/projects/forta-aogaku-dev/locations/asia-northeast1/functions/aiProcessSource');
 assert.throws(()=>dev.assertURL('https://logging.googleapis.com/v2/entries:list',{resourceNames:['projects/forta-aogaku']}));
});

test('production rollout imports audited policy check and only permits four source patches',()=>{
 const d=require('./deploy_production_visual_router.cjs'),l=require('./deploy_production_visual_latency.cjs'),c=require('./production_phase5a_common.cjs');
 assert.equal(typeof d.policyChecks,'function');assert.deepEqual(l.ORDER,review.FUNCTIONS);
 for(const n of l.ORDER)l.validateMutation('https://cloudfunctions.googleapis.com/v2/'+c.parent+'/functions/'+n+'?updateMask=buildConfig.source','PATCH',{name:c.parent+'/functions/'+n,buildConfig:{source:{storageSource:{bucket:'reviewed',object:'reviewed'}}}},'source',n);
 assert.throws(()=>l.validateMutation('https://cloudfunctions.googleapis.com/v2/'+c.parent+'/functions/aiCreateSource?updateMask=buildConfig.source','PATCH',{},'source','aiCreateSource'));
 assert.throws(()=>l.validateMutation('https://cloudfunctions.googleapis.com/v2/'+c.parent+'/functions/aiProcessSource?updateMask=serviceConfig.environmentVariables','PATCH',{},'source','aiProcessSource'));
 assert.throws(()=>l.delta({'original.js':'a'},{}));
 const before={'original.js':'a'},after={...before};for(const m of l.MODULES)after[m]='changed';assert.equal(l.delta(before,after).length,5);after['unreviewed.js']='b';assert.throws(()=>l.delta(before,after));
});
