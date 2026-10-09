const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
const {joinChunks}=require('./evidence_adoption_dev.cjs');
test('exact Evidence reconstruction removes overlap, never drops relations or page text',()=>{
 const text='Observation → Question → Hypothesis → Experiment → Conclusion → Result。'+ '続き😀'.repeat(500);
 const {chunksFor}=require('../functions/lib/ai/domain');
 const chunks=chunksFor([{text,method:'multimodal_ai',locator:{pageNumber:4},flags:[]}]);
 assert.equal(joinChunks(chunks.reverse()),text);assert(chunks.every(x=>x.locator.pageNumber===4));
 assert.throws(()=>joinChunks([{chunkId:'000001',text:'missing',locator:{startChar:1300,endChar:1307}}]));
});
test('Dev course-PDF operator never deploys, changes config, or silently re-creates billed source',()=>{
 const code=fs.readFileSync(__dirname+'/evidence_adoption_dev.cjs','utf8');
 for(const action of [':setIamPolicy',':pause',':resume','generateUploadUrl','firebase deploy',':access','forta-aogaku.cloudfunctions.net'])assert(!code.includes(action));
 assert(code.includes('Never recreate billed fixture'));assert(code.includes('--approve-provider-retry'));
 assert(code.includes('assert.deepEqual(afterSnapshot.functions'));assert(code.includes('assert.equal(joinChunks(retrieved),checkpoint.unit.text'));
 assert(code.includes('fs.writeFileSync(path.join(c.ROOT,\'AogakuTests/DevFixtures/'));assert(!code.includes('aiUpdateSource'));
});
