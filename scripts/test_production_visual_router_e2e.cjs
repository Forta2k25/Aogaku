const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
const read=name=>fs.readFileSync(__dirname+'/'+name,'utf8');
test('Synthetic Router E2E publishes exactly the selected text through every stored/API boundary',()=>{
 const {reconstruct}=require('./production_visual_router_e2e.cjs'),{chunksFor}=require('../functions/lib/ai/domain');
 const text='Observation → Question → Hypothesis → Experiment → Conclusion → Result。'+ '補足😀'.repeat(500);
 assert.equal(reconstruct(chunksFor([{text,method:'multimodal_ai',locator:{pageNumber:3},flags:[]}])),text);
 assert.throws(()=>reconstruct([{chunkId:'00001',text:'broken',locator:{startChar:7,endChar:13}}]));
 const code=read('production_visual_router_e2e.cjs');for(const contract of ['reconstruct(selectedChunks),unit.text','reconstruct(selected),unit.text','reconstruct(selectedRetrieved),unit.text','Invented closing edge','native.text.trim()','UPLOAD_INCOMPLETE','No fixture replay','defaultUsageBefore'])assert(code.includes(contract));
});
test('Production Router test operators cannot change rollout flags/IAM/secrets or reprocess old sources',()=>{
 for(const file of ['production_visual_router_e2e.cjs','production_visual_router_auth.cjs','production_visual_router_domain_gates.cjs']){
  const code=read(file);for(const forbidden of [':setIamPolicy',':resume',':pause',':access','firebase deploy','AI_INPUT_ALLOWED_UIDS='])assert(!code.includes(forbidden),file+' contains '+forbidden);
 }
 const auth=read('production_visual_router_auth.cjs');assert(auth.includes("consent.maximumAccounts,1"));assert(auth.includes('Signup replay forbidden'));assert(auth.includes('uidHash'));assert(auth.includes('pilotUntouched:true'));
 const gate=read('production_visual_router_domain_gates.cjs');assert(gate.includes('NETWORK_FORBIDDEN'));assert(gate.includes('assert.deepEqual(source.files,artifact.files)'));assert(gate.includes('exactProductionEnvironment:true'));
});
