const {test}=require('node:test'),assert=require('node:assert/strict');
const p=require('./deploy_production_phase3a.cjs');
test('Phase3a permits only an issued source URL PATCH to one explicitly selected existing target',()=>{
 const url='https://storage.googleapis.com/gcf-upload-test/artifact?signature=local-test-only';
 for(const name of p.NAMES){const c={apply:true,name,uploadUrls:new Set([url])};
  p.validate(p.G+p.parent+'/functions:generateUploadUrl','POST',{},c);
  p.validate(p.G+p.resource(name)+'?updateMask=sourceUploadUrl','PATCH',{name:p.resource(name),sourceUploadUrl:url},c);
  assert.throws(()=>p.validate(p.G+p.resource(name)+'?updateMask=sourceUploadUrl,secretEnvironmentVariables','PATCH',{name:p.resource(name),sourceUploadUrl:url},c));
  assert.throws(()=>p.validate(p.G+p.resource(name)+'?updateMask=sourceUploadUrl','PATCH',{name:p.resource(name),sourceUploadUrl:url,labels:{}},c));
  assert.throws(()=>p.validate(p.G+p.resource(name)+'?updateMask=sourceUploadUrl','PATCH',{name:p.resource(name),sourceUploadUrl:'https://storage.googleapis.com/unissued'},c));
 }
});
test('Phase3a denies creation/deletion/full deploy, other functions and cross-project targets',()=>{
 const c={apply:true,name:'askCourseAI',uploadUrls:new Set(['issued'])};
 for(const url of [p.G+p.parent+'/functions',p.G+p.resource('preDeleteCleanup'),p.G+p.resource('deleteAccountServerSide'),p.G+p.resource('onAuthUserDelete'),p.G+p.resource('transcribeLectureAudio')+'?updateMask=sourceUploadUrl',p.G+p.resource('askCourseAI').replace('forta-aogaku','forta-aogaku-dev')+'?updateMask=sourceUploadUrl'])
  for(const method of ['POST','PATCH','DELETE'])assert.throws(()=>p.validate(url,method,{name:p.resource('askCourseAI'),sourceUploadUrl:'issued'},c));
 assert.throws(()=>p.validate(p.G+p.resource('askCourseAI')+'?updateMask=sourceUploadUrl','PATCH',{name:p.resource('askCourseAI'),sourceUploadUrl:'issued'},{...c,apply:false}));
});
test('Phase3a denies Secret payloads/versions, IAM/API/Rules/index/data/queue/Scheduler/lifecycle mutations',()=>{
 const c={apply:true,name:'askCourseAI',uploadUrls:new Set(['issued'])};
 for(const url of [
  'https://secretmanager.googleapis.com/v1/projects/forta-aogaku/secrets/GROQ_API_KEY/versions/1:access',
  'https://secretmanager.googleapis.com/v1/projects/forta-aogaku/secrets/GROQ_API_KEY:addVersion',
  'https://cloudresourcemanager.googleapis.com/v1/projects/forta-aogaku:setIamPolicy',
  'https://serviceusage.googleapis.com/v1/projects/505828754933/services:batchEnable',
  'https://firebaserules.googleapis.com/v1/projects/forta-aogaku/releases/cloud.firestore',
  'https://firestore.googleapis.com/v1/projects/forta-aogaku/databases/(default)/documents/users/u',
  'https://firestore.googleapis.com/v1/projects/forta-aogaku/databases/aogaku-ai/collectionGroups/aiSources/indexes',
  'https://storage.googleapis.com/storage/v1/b/forta-aogaku.firebasestorage.app',
  'https://cloudtasks.googleapis.com/v2/projects/forta-aogaku/locations/asia-northeast1/queues/aiProcessSource:resume',
  'https://cloudscheduler.googleapis.com/v1/projects/forta-aogaku/locations/asia-northeast1/jobs'
 ])for(const method of ['GET','POST','PUT','PATCH','DELETE']){
  if(method==='GET'&&['https://storage.googleapis.com/storage/v1/b/forta-aogaku.firebasestorage.app','https://cloudscheduler.googleapis.com/v1/projects/forta-aogaku/locations/asia-northeast1/jobs'].includes(url))continue;
  assert.throws(()=>p.validate(url,method,{},c),url+' '+method);
 }
});
test('Phase3a requires pinned artifact bytes, original dependency lock, five files and exact three exports',()=>{
 const a=p.assertArtifact();assert.equal(Object.keys(a.files).length,5);assert.deepEqual(a.names,p.NAMES);assert.equal(a.newDependencies,false);assert.equal(a.namedSourceWrites,false);
 const api=require('../build/production-phase3a/candidate');assert.deepEqual(Object.keys(api).sort(),[...p.NAMES].sort());
});
test('Phase3a ignores only the observed volatile named DB etag and rejects every actual database field change',()=>{
 const db={name:'projects/forta-aogaku/databases/aogaku-ai',uid:'same',locationId:'asia-northeast1',type:'FIRESTORE_NATIVE',deleteProtectionState:'DELETE_PROTECTION_ENABLED',updateTime:'unchanged',etag:'read-one'};
 assert.deepEqual(p.metadataCore('aiDatabase',db),p.metadataCore('aiDatabase',{...db,etag:'read-two'}));
 for(const k of Object.keys(db).filter(k=>k!=='etag'))assert.notDeepEqual(p.metadataCore('aiDatabase',db),p.metadataCore('aiDatabase',{...db,[k]:'drift'}));
 assert.deepEqual(p.metadataCore('bucket',db),db);
});
test('Phase3a signed upload must use the exact shared Gen1 staging bucket from fresh deployed metadata',()=>{
 const prefix='https://storage.googleapis.com/uploads-123.asia-northeast1.cloudfunctions.appspot.com/';
 const baseline={legacy:Object.fromEntries(p.NAMES.map(n=>[n,{sourceUploadUrl:prefix+'previous.zip'}]))};
 assert.equal(p.uploadTarget(prefix+'new.zip?signature=local-only',baseline).pathname.split('/')[1],'uploads-123.asia-northeast1.cloudfunctions.appspot.com');
 for(const url of [prefix.replace('123','456')+'new.zip',prefix.replace('asia-northeast1','us-central1')+'new.zip',prefix.replace('storage.googleapis.com','evil.example')+'new.zip',prefix.replace('https:','http:')+'new.zip',prefix+'../unknown/new.zip'])assert.throws(()=>p.uploadTarget(url,baseline));
});
