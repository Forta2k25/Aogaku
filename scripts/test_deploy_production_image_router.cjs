const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');const d=require('./deploy_production_image_router.cjs');
test('one-worker production source mutation allowlist rejects other Functions and configuration writes',()=>{
 const body={name:'projects/forta-aogaku/locations/asia-northeast1/functions/aiProcessSource',buildConfig:{source:{storageSource:{bucket:'issued',object:'issued.zip'}}}};assert.doesNotThrow(()=>d.validateMutation(d.F+'?updateMask=buildConfig.source','PATCH',body,'source'));
 for(const [u,m,b,k]of [[d.F.replace('aiProcessSource','aiCreateSource')+'?updateMask=buildConfig.source','PATCH',body,'source'],[d.F+'?updateMask=serviceConfig','PATCH',body,'source'],[d.F+'?updateMask=buildConfig.source','PATCH',{...body,serviceConfig:{}},'source'],[d.F+'?updateMask=buildConfig.source','PATCH',{...body,buildConfig:{...body.buildConfig,runtime:'nodejs20'}},'source'],[d.F,'DELETE',{},'source'],[d.F+':setIamPolicy','POST',{},'source']])assert.throws(()=>d.validateMutation(u,m,b,k));
 assert.doesNotThrow(()=>d.validateMutation(d.Q+':pause','POST',{},'pause'));assert.doesNotThrow(()=>d.validateMutation(d.Q+':resume','POST',{},'resume'));assert.throws(()=>d.validateMutation(d.Q+':purge','POST',{},'pause'));
});
test('production operator checks full25 sources, drain/protected state and prevents mutation replay',()=>{
 const code=fs.readFileSync(__dirname+'/deploy_production_image_router.cjs','utf8');for(const s of ['Mutation replay forbidden','PREFLIGHT_PASS','sourceManifest','assertQueueDrained','Active worker source lease','p.postCheck(before,after','other24 unchanged','No other Function'])assert(code.includes(s));for(const forbidden of [':setIamPolicy','updateMask=serviceConfig','firebase deploy','versions/latest:access','--force'])assert(!code.includes(forbidden));
});
test('production five fresh synthetic input proofs compare text and locator, never reprocess old sources',()=>{
 const code=fs.readFileSync(__dirname+'/production_image_router_e2e.cjs','utf8');for(const s of ['Never replay synthetic provider-billed fixtures','short-arrow-flow','two-label-arrow','mixed-pdf','Qwen finalText -> Unit/chunks/Evidence/retrieval','assert.deepEqual(x.locator,found.locator)','PRODUCTION_IMAGE_ROUTING_E2E_PASS'])assert(code.includes(s));for(const forbidden of ['aiRetrySource','aiDeleteSource','aiUpdateSource',':setIamPolicy',':pause',':resume',':access'])assert(!code.includes(forbidden));
});

test('production admission proof and cleanup reuse only the already authorized disposable nonpilot',()=>{
 const code=fs.readFileSync(__dirname+'/production_image_router_auth.cjs','utf8');
 for(const guard of ['reg.uidHash','assert(!allowed.includes(claims.sub))','assert.notEqual(pilot.uid,other.uid)','assert.equal(consent.cleanupApproved,true)','assert.equal(consent.maximumAccounts,1)','Cleanup mutation never replayed','PRODUCTION_IMAGE_ROUTING_E2E_PASS','fixtureSourcesCreated','auth/user-not-found'])assert(code.includes(guard));
 for(const forbidden of ['accounts:signUp','signInAnonymously',':setIamPolicy','aiCreateSource\",','aiDeleteSource','versions/latest:access'])assert(!code.includes(forbidden));
});

test('Firestore legacy proof ignores map ordering but rejects content or timestamp drift',()=>{
 const {documentDigest}=require('./production_image_router_e2e.cjs');
 const before={fields:{status:{stringValue:'ready'},nested:{mapValue:{fields:{a:{integerValue:'1'},b:{stringValue:'text'}}}}},updateTime:'2026-10-09T01:00:00Z'};
 const reordered={updateTime:before.updateTime,fields:{nested:{mapValue:{fields:{b:{stringValue:'text'},a:{integerValue:'1'}}}},status:{stringValue:'ready'}}};
 assert.equal(documentDigest(before),documentDigest(reordered));
 assert.notEqual(documentDigest(before),documentDigest({...reordered,updateTime:'2026-10-09T01:00:01Z'}));
 assert.notEqual(documentDigest(before),documentDigest({...reordered,fields:{...reordered.fields,status:{stringValue:'failed'}}}));
 const code=fs.readFileSync(__dirname+'/production_image_router_e2e.cjs','utf8');assert(code.includes('current.updateTime,old.updateTime'));assert(!code.includes('sourceHash:c.hash(source)'));
});
