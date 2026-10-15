const {test}=require('node:test'),assert=require('node:assert/strict');
const p=require('./deploy_production_phase3b.cjs');
test('Phase3b permits exact PATCH only to the selected existing deletion Function',()=>{
 for(const n of p.NAMES){const source=n==='onAuthUserDelete'?'issued':{bucket:'staging',object:'issued.zip'},c={apply:true,name:n,sources:new Set([require('./deploy_production_phase3a.cjs').hash(source)])};
 const url=(n==='onAuthUserDelete'?p.G1:p.G2)+p.resource(n)+'?updateMask='+p.mask(n),body=p.patch(n,source);
 p.validate(url,'PATCH',body,c);p.validate((n==='onAuthUserDelete'?p.G1:p.G2)+p.parent+'/functions:generateUploadUrl','POST',{},c);
 assert.throws(()=>p.validate(url,'PATCH',body,{...c,apply:false}));assert.throws(()=>p.validate(url,'PATCH',{...body,labels:{}},c));assert.throws(()=>p.validate(url,'PATCH',p.patch(n,'unissued'),c));
 assert.throws(()=>p.validate(url+',serviceConfig.serviceAccountEmail','PATCH',body,c));
 }
});
test('Phase3b denies all other Functions and any API/IAM/Secret/Rules/index/lifecycle/queue mutation',()=>{
 const c={apply:true,name:'preDeleteCleanup',sources:new Set()};
 for(const n of ['askCourseAI','transcribeLectureAudio','generateReactionPaper','aiCreateSource','aiProcessSource','deleteAccountServerSide'])
 for(const method of ['POST','PATCH','DELETE'])assert.throws(()=>p.validate(p.G2+p.resource(n),'PATCH',{},c));
 for(const url of ['https://secretmanager.googleapis.com/v1/projects/forta-aogaku/secrets/GROQ_API_KEY/versions/1:access','https://secretmanager.googleapis.com/v1/projects/forta-aogaku/secrets/GROQ_API_KEY:addVersion','https://cloudresourcemanager.googleapis.com/v1/projects/forta-aogaku:setIamPolicy','https://firebaserules.googleapis.com/v1/projects/forta-aogaku/releases/cloud.firestore','https://serviceusage.googleapis.com/v1/projects/505828754933/services:batchEnable','https://storage.googleapis.com/storage/v1/b/forta-aogaku.firebasestorage.app','https://firestore.googleapis.com/v1/projects/forta-aogaku/databases/aogaku-ai/collectionGroups/aiSources/indexes','https://cloudtasks.googleapis.com/v2/projects/forta-aogaku/locations/asia-northeast1/queues/aiProcessSource:resume'])
 for(const method of ['POST','PATCH','PUT','DELETE'])assert.throws(()=>p.validate(url,method,{},c));
 assert.throws(()=>p.validate('https://secretmanager.googleapis.com/v1/projects/forta-aogaku/secrets/GROQ_API_KEY/versions/1:access','GET',undefined,c));
 assert.throws(()=>p.validate(p.G2+p.resource('preDeleteCleanup').replace('forta-aogaku','forta-aogaku-dev')+'?updateMask='+p.mask('preDeleteCleanup'),'PATCH',{},c));
});
test('Phase3b artifact exports only three deletion handlers, no providers or worker exports',()=>{
 const a=p.artifact(),api=require('../build/production-phase3b/candidate');assert.deepEqual(Object.keys(api).sort(),[...p.NAMES].sort());assert.equal(Object.keys(a.files).length,8);assert(a.runtimeSAPreserved&&a.secretBindingsPreserved);assert.equal(a.phase4Exports,false);
});
test('Phase3b generated staging URL must match exact returned Gen2 storageSource and production project/region',()=>{
 const b='gcf-v2-uploads-505828754933.asia-northeast1.cloudfunctions.appspot.com',d={uploadUrl:'https://storage.googleapis.com/'+b+'/issued.zip?sig=local-test',storageSource:{bucket:b,object:'issued.zip'}};
 p.uploadTarget('preDeleteCleanup',d,{});
 for(const bad of [{...d,uploadUrl:d.uploadUrl.replace('storage.googleapis.com','evil.example')},{...d,storageSource:{bucket:'other',object:'issued.zip'}},{...d,uploadUrl:d.uploadUrl.replace('505828754933','1064661805206'),storageSource:{bucket:b.replace('505828754933','1064661805206'),object:'issued.zip'}},{...d,storageSource:{bucket:b,object:'unissued.zip'}}])assert.throws(()=>p.uploadTarget('preDeleteCleanup',bad,{}));
});
test('Phase3b compares all persistent database fields while preserving output-only retention metadata in evidence',()=>{
 const d={name:'projects/forta-aogaku/databases/aogaku-ai',updateTime:'unchanged',locationId:'asia-northeast1',type:'FIRESTORE_NATIVE',deleteProtectionState:'DELETE_PROTECTION_ENABLED',earliestVersionTime:'2026-10-06T22:00:00Z',etag:'a'};
 assert.deepEqual(p.metadataCore('aiDatabase',d),p.metadataCore('aiDatabase',{...d,earliestVersionTime:'2026-10-06T23:00:00Z',etag:'b'}));
 for(const k of ['name','updateTime','locationId','type','deleteProtectionState'])assert.notDeepEqual(p.metadataCore('aiDatabase',d),p.metadataCore('aiDatabase',{...d,[k]:'drift'}));
 assert.throws(()=>p.metadataCore('aiDatabase',{...d,earliestVersionTime:'invalid'}));
});
test('Phase3b signed upload headers follow v1/v2 contracts and never attach OAuth credentials',()=>{
 for(const n of ['preDeleteCleanup','deleteAccountServerSide'])assert.deepEqual(p.uploadHeaders(n),{'Content-Type':'application/zip'});
 assert.deepEqual(p.uploadHeaders('onAuthUserDelete'),{'Content-Type':'application/zip','x-goog-content-length-range':'0,104857600'});
 for(const n of p.NAMES)assert(!Object.keys(p.uploadHeaders(n)).some(k=>k.toLowerCase()==='authorization'));
 assert.throws(()=>p.uploadHeaders('aiProcessSource'));
});
test('Phase3b persisted metadata redacts signed URLs and credentials and remains idempotent',()=>{
 const raw={sourceUploadUrl:'https://storage.googleapis.com/uploads-123.asia-northeast1.cloudfunctions.appspot.com/issued.zip?GoogleAccessId=test&Signature=private',environmentVariables:{PRIVATE_VALUE:'must-not-persist'},downloadUrl:'https://storage.googleapis.com/test/obj?X-Goog-Signature=private',credential:'private',idToken:'private'};
 const safe=p.safeMetadata(raw),text=JSON.stringify(safe);assert(!text.includes('private'));assert(!text.includes('must-not-persist'));assert(!text.includes('https://'));assert.equal(safe.sourceUploadBucket,'uploads-123.asia-northeast1.cloudfunctions.appspot.com');assert.deepEqual(p.safeMetadata(safe),safe);
});
