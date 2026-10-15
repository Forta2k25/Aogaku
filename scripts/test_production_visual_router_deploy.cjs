const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
const d=require('./deploy_production_visual_router.cjs'),p=require('./production_recognition_review.cjs');
test('Visual Router migration has fresh evidence, exact ten targets, no replay/IAM/env mutation',()=>{
 const code=fs.readFileSync(__dirname+'/deploy_production_visual_router.cjs','utf8');
 assert(code.includes("build/production-visual-router-20261009"));assert(code.includes('final-protected-audit.json'));assert(code.includes('Fresh baseline must not overwrite evidence'));
 assert(code.includes('Mutation replay forbidden'));assert(code.includes('updateMask=buildConfig.source'));assert(!code.includes(':setIamPolicy'));assert(!code.includes('updateMask=serviceConfig'));assert(!code.includes('versions/latest:access'));
 assert(code.includes('v.contract()'));assert(code.includes('pausedReview=v.prepare()'));assert(code.includes('assertQueueDrained(q)'));
 assert(code.includes('j.status=\'STOPPED\''));assert(code.includes('queue is not auto-restored'));assert(code.includes('p.ORDER[j.updated.length]'));
 assert.equal(p.FUNCTIONS.length,10);assert.equal(p.ORDER.at(-1),'aiListSources');assert.equal(p.ORDER[0],'aiProcessSource');
});
test('Absent/malformed/active queue stats cannot authorize deployment',()=>{
 d.assertQueueDrained({name:'projects/forta-aogaku/locations/asia-northeast1/queues/aiProcessSource',state:'PAUSED',stats:{}});
 assert.throws(()=>d.assertQueueDrained({state:'PAUSED',stats:{}}));
});
