const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),d=require('./deploy_production_recognition.cjs'),reads=require('./production_read_retry.cjs');
const q='projects/forta-aogaku/locations/asia-northeast1/queues/aiProcessSource';
test('Queue stats read uses documented v2beta3 mask, never unsupported v2 mask or IAM mutation',()=>{
 assert.equal(d.queueStatsURL(),'https://cloudtasks.googleapis.com/v2beta3/'+q+'?readMask=name,state,stats');assert(reads.eligible(d.queueStatsURL()));assert(!reads.eligible(d.queueStatsURL(),'PATCH','{}'));assert(!reads.eligible(d.queueStatsURL().split('?')[0]+':resume','POST','{}'));
});
test('Pause/drain is fail-closed for active workers, wrong queue, missing stats and malformed count',()=>{
 d.assertQueueDrained({name:q,state:'PAUSED',stats:{}});d.assertQueueDrained({name:q,state:'PAUSED',stats:{concurrentDispatchesCount:'0'}});
 for(const v of [{name:q,state:'RUNNING',stats:{}},{name:q,state:'PAUSED'},{name:q.replace('forta-aogaku','forta-aogaku-dev'),state:'PAUSED',stats:{}},...['1','-1','NaN'].map(n=>({name:q,state:'PAUSED',stats:{concurrentDispatchesCount:n}}))])assert.throws(()=>d.assertQueueDrained(v));
});
// Optional read-only replay of private operator evidence; never require it in a clean clone.
const privateEvidenceAvailable=['safe-stop-queue-stats','execution'].every(n=>fs.existsSync(d.PREVIOUS_DIR+'/'+n+'.json'));
test('Fixed GET succeeds against exact live paused queue; stopped journal contains no Function PATCH',{skip:!privateEvidenceAvailable},()=>{
 const prior=n=>JSON.parse(fs.readFileSync(d.PREVIOUS_DIR+'/'+n+'.json'));const x=prior('safe-stop-queue-stats');d.assertQueueDrained(x);const j=prior('execution');assert.equal(j.status,'STOPPED');assert.equal(j.updated.length,0);assert.deepEqual(j.attempts.map(x=>({kind:x.kind,status:x.status,httpStatus:x.httpStatus})),[{kind:'pause',status:'CONFIRMED',httpStatus:200}]);
 assert(!fs.readFileSync(__dirname+'/deploy_production_recognition.cjs','utf8').includes(':setIamPolicy'));
});
