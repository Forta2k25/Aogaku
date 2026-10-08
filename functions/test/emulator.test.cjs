const {test,before,after}=require('node:test');
const assert=require('node:assert/strict');
const admin=require('firebase-admin');
const enabled=!!process.env.FIRESTORE_EMULATOR_HOST && !!process.env.STORAGE_EMULATOR_HOST;
process.env.AI_SHARING_ENABLED='true';
const deletedUsers=new Set();
let originalGetUser, originalDeleteTask;
let recognitionStatus=200, imageRequests=0, audioRequests=0;
let originalVisionOCR;
let app,db,legacyDb,api,taskPrototype,originalEnqueue,originalFetch,credential,originalToken;
before(()=>{
  if(!enabled)return;
  const vision=require('@google-cloud/vision').ImageAnnotatorClient.prototype;
  originalVisionOCR=vision.documentTextDetection;
  vision.documentTextDetection=async()=>{
    const p=require('../../scripts/visual_router_fixtures.cjs').image('plain').probe;
    return [{fullTextAnnotation:{text:p.text,pages:[{width:800,height:1000,blocks:[{boundingBox:{vertices:[{x:50,y:50},{x:760,y:50},{x:760,y:700},{x:50,y:700}]},paragraphs:[{words:p.words.map(b=>({confidence:.98,boundingBox:{vertices:[{x:b.x*800,y:b.y*1000},{x:(b.x+b.w)*800,y:b.y*1000},{x:(b.x+b.w)*800,y:(b.y+b.h)*1000},{x:b.x*800,y:(b.y+b.h)*1000}]},symbols:[{text:'x'}]}))}]}]}]}}];
  };
  credential=admin.credential.applicationDefault();originalToken=credential.getAccessToken;
  credential.getAccessToken=async()=>({access_token:'emulator-only',expires_in:3600});
  app=admin.initializeApp({projectId:'demo-aogaku-input',storageBucket:'demo-aogaku-input.appspot.com',credential});
  // Stub the new worker metadata transport as well as Tasks; never ask ADC or real cloud APIs.
  originalFetch=global.fetch;
  global.fetch=async(url,options)=>{
    const name='projects/demo-aogaku-input/locations/asia-northeast1/functions/aiProcessSource';
    if(String(url)===`https://cloudfunctions.googleapis.com/v2/${name}`) {
      assert.equal(options.headers.Authorization,'Bearer emulator-only');
      return new Response(JSON.stringify({name,serviceConfig:{uri:'https://emulator-worker.a.run.app'}}),{status:200});
    }
    if(String(url)==='https://secretmanager.googleapis.com/v1/projects/demo-aogaku-input/secrets/GROQ_API_KEY/versions/latest:access')return new Response(JSON.stringify({payload:{data:Buffer.from('synthetic-test-only').toString('base64')}}));
    if(String(url)==='https://api.groq.com/openai/v1/models')return new Response(JSON.stringify({data:[{id:'qwen/qwen3.8-27b',active:true}]}));
    if(String(url)==='https://api.groq.com/openai/v1/chat/completions') {
      imageRequests++;const body=JSON.parse(options.body);assert.equal(body.model,'qwen/qwen3.8-27b');assert(body.messages[0].content[1].image_url.url.startsWith('data:image/png;base64,'));
      return new Response(JSON.stringify({model:body.model,usage:{prompt_tokens:2940,completion_tokens:417,total_tokens:3357},choices:[{finish_reason:'stop',message:{content:JSON.stringify({finalText:'親から子へ特徴が遺伝する。'+ '階層を説明する。'.repeat(200)})}}]}),{status:recognitionStatus});
    }
    if(String(url)==='https://api.groq.com/openai/v1/audio/transcriptions') {
      audioRequests++;assert.equal(options.body.get('model'),'whisper-large-v3-turbo');return new Response(JSON.stringify({duration:1,segments:[{start:0,end:1,text:'カントを学ぶ講義。',no_speech_prob:0}]}));
    }
    const u=new URL(url);
    if(u.protocol!=='http:' || !['127.0.0.1','localhost','[::1]'].includes(u.hostname))throw Error('Emulator test attempted a non-local network request');
    return originalFetch(url,options);
  };
  originalGetUser=admin.auth().getUser;admin.auth().getUser=async uid=>{if(deletedUsers.has(uid))throw Object.assign(Error("deleted"),{code:"auth/user-not-found"});return {uid,disabled:false};};
  db=require('firebase-admin/firestore').getFirestore(app,'aogaku-ai'); legacyDb=require('firebase-admin/firestore').getFirestore(app,'(default)'); api=require('../lib/ai');
  // Replace transport only: acceptance, transactions and worker logic remain real.
  taskPrototype=Object.getPrototypeOf(require('firebase-admin/functions').getFunctions().taskQueue('aiProcessSource'));
  originalDeleteTask=taskPrototype.delete;taskPrototype.delete=async()=>{};
  originalEnqueue=taskPrototype.enqueue; taskPrototype.enqueue=async()=>{};
});
after(async()=>{if(originalVisionOCR)require('@google-cloud/vision').ImageAnnotatorClient.prototype.documentTextDetection=originalVisionOCR;if(app)admin.auth().getUser=originalGetUser;if(taskPrototype)taskPrototype.delete=originalDeleteTask;if(taskPrototype)taskPrototype.enqueue=originalEnqueue;if(originalFetch)global.fetch=originalFetch;if(credential)credential.getAccessToken=originalToken;if(app)await app.delete()});
const call=(name,uid,data)=>api[name].run({auth:uid?{uid,token:{}}:undefined,data});
async function seed(id,owner,visibility='private',course='course-a') {
  const source={sourceId:id,sourceVersion:1,ownerUserId:owner,courseOfferingId:course,lectureId:'lecture-a',dayID:20730,
    sourceType:'note',title:'資料',mime:'text/plain',status:'ready',knowledgeVisibility:visibility,rawVisibility:'private',
    activeRun:'run-a',createdAt:Date.now(),updatedAt:Date.now(),attempts:0};
  await db.doc(`aiSources/${id}`).set(source);
  await db.doc(`aiSources/${id}/runs/run-a/chunks/000000`).set({chunkId:'000000',text:'社会思想とカントの解説',locator:{pageNumber:1},flags:[],method:'note'});
  return source;
}
test('emulator: unauthenticated callable is rejected',{skip:!enabled},async()=>{
  await assert.rejects(call('aiRetrieveContext',null,{courseOfferingId:'course-a',query:'カント'}),e=>e.code==='unauthenticated');
});
test('emulator: private/shared/other-course evidence and revocation',{skip:!enabled},async()=>{
  await seed('s-private','alice');await seed('s-shared','alice','course');await seed('s-other','alice','course','course-b');
  const request={courseOfferingId:'course-a',query:'カント',purpose:'question'};
  assert.equal((await call('aiRetrieveContext','bob',request)).items.length,0);
  await db.doc('aiCourseOfferings/course-a/memberships/bob').set({status:'verified',active:true});
  let r=await call('aiRetrieveContext','bob',request);
  assert.deepEqual(r.items.map(i=>i.sourceId),['s-shared']);
  assert.equal((await call('aiGetEvidence','bob',{sourceId:'s-shared'})).items.length,1);
  await assert.rejects(call('aiGetEvidence','bob',{sourceId:'s-private'}),e=>e.code==='not-found');
  await call('aiUpdateSource','alice',{sourceId:'s-shared',knowledgeVisibility:'private'});
  assert.equal((await call('aiRetrieveContext','bob',request)).items.length,0);
  await assert.rejects(call('aiGetEvidence','bob',{sourceId:'s-shared'}),e=>e.code==='not-found');
  await assert.rejects(call('aiUpdateSource','bob',{sourceId:'s-private',knowledgeVisibility:'course'}),e=>e.code==='permission-denied');
});
test('emulator: durable acceptance is idempotent and scoped to year/account',{skip:!enabled},async()=>{
  await legacyDb.doc('classes/00004').set({class_name:'試験用授業',teacher_name:'教員A',url:'https://example.test/?YR=2026'});
  const request={clientRequestId:'note-receipt',type:'note',title:'授業メモ',mime:'text/plain',text:'テストの資料',
    context:{localCourseUUID:'11111111-1111-4111-8111-111111111111',classDocId:'00004',year:2026,semester:'fall',dayID:20730,syllabusUrl:'https://example.test/?YR=2026',courseName:'試験用授業',teacherName:'教員A'}};
  const first=await call('aiCreateSource','accept-owner',request);
  const second=await call('aiCreateSource','accept-owner',request);
  assert.equal(first.sourceId,second.sourceId);assert.equal(first.lectureId,second.lectureId);
  await assert.rejects(call('aiCreateSource','accept-owner',{...request,text:'変更した資料'}),e=>e.message==='REQUEST_CONFLICT');
  const bob=await call('aiCreateSource','accept-bob',request);
  assert.notEqual(first.sourceId,bob.sourceId);assert.equal(first.courseOfferingId,bob.courseOfferingId);
  await legacyDb.doc('classes/00004').set({class_name:'翌年度の別授業',url:'https://example.test/?YR=2027'});
  const otherYear=await call('aiCreateSource','accept-owner',{...request,clientRequestId:'next-year',context:{...request.context,year:2027,syllabusUrl:'https://example.test/?YR=2027',courseName:'翌年度の別授業'}});
  assert.equal(first.courseOfferingId,'2026:00004');assert.equal(otherYear.courseOfferingId,'2027:00004');
  const frozen=await call('aiGetSource','accept-owner',{sourceId:first.sourceId});
  assert.deepEqual(frozen.courseSnapshot,first.courseSnapshot);
  assert.equal((await call('aiCreateSource','accept-owner',request)).courseOfferingId,'2026:00004');
  assert.equal((await db.doc('aiCourseOfferings/2026:00004').get()).get('courseName'),'試験用授業');
  const listed=await call('aiListSources','accept-owner',{context:request.context,onlyLecture:true});
  assert.equal(listed.courseOfferingId,first.courseOfferingId);assert.deepEqual(listed.items.map(i=>i.sourceId),[first.sourceId]);
  await call('aiDeleteSource','accept-owner',{sourceId:first.sourceId});
  await assert.rejects(call('aiCreateSource','accept-owner',request),e=>e.message==='SOURCE_DELETED');
});
test('emulator: users cannot self-authorize course sharing',{skip:!enabled},async()=>{
  await seed('s-share-attempt','charlie');
  await assert.rejects(call('aiUpdateSource','charlie',{sourceId:'s-share-attempt',knowledgeVisibility:'course'}),e=>e.message==='MEMBERSHIP_NOT_VERIFIED');
});
test('emulator: complete note worker, repeat delivery, retrieval and cascade deletion',{skip:!enabled},async()=>{
  const source=await seed('s-worker','worker-owner');
  await db.doc('aiSources/s-worker').set({...source,status:'queued',activeRun:null,noteText:'社会思想の授業でカントについて学んだ。',storagePath:'ai-inputs/aogaku-ai/worker-owner/s-worker/original'});
  await api.aiProcessSource.run({data:{databaseId:'aogaku-ai',sourceId:'s-worker'}});
  const first=(await db.doc('aiSources/s-worker').get()).data();
  assert.equal(first.status,'ready');assert.ok(first.activeRun);
  await api.aiProcessSource.run({data:{databaseId:'aogaku-ai',sourceId:'s-worker'}});
  assert.equal((await db.doc('aiSources/s-worker').get()).get('activeRun'),first.activeRun);
  const r=await call('aiRetrieveContext','worker-owner',{courseOfferingId:'course-a',query:'カント'});
  assert.equal(r.items.length,1);assert.equal(r.items[0].sourceId,'s-worker');
  await call('aiDeleteSource','worker-owner',{sourceId:'s-worker'});
  await api.aiProcessSource.run({data:{databaseId:'aogaku-ai',sourceId:'s-worker'}});
  assert.equal((await db.doc('aiSources/s-worker').get()).get('status'),'deleted');
  assert.equal((await db.doc(`aiSources/s-worker/runs/${first.activeRun}`).collection('chunks').get()).size,0);
  assert.equal((await call('aiRetrieveContext','worker-owner',{courseOfferingId:'course-a',query:'カント'})).items.length,0);
});
test('emulator: direct unauthenticated Firestore reads cannot bypass API',{skip:!enabled},async()=>{
  const base=`http://${process.env.FIRESTORE_EMULATOR_HOST}/v1/projects/demo-aogaku-input/databases/aogaku-ai/documents`;
  const r=await fetch(`${base}/aiSources/s-private`);
  assert.equal(r.status,403);
});

const uuidA='33333333-3333-4333-8333-333333333333',uuidB='44444444-4444-4444-8444-444444444444';
const makeRequest=(receipt,ctx={})=>({clientRequestId:receipt,type:'note',title:'資料',mime:'text/plain',text:'カントの授業資料',context:{localCourseUUID:uuidA,year:2026,semester:'fall',dayID:20730,courseName:'授業A',teacherName:'教員A',...ctx}});
async function processNote(source){await api.aiProcessSource.run({data:{databaseId:'aogaku-ai',sourceId:source.sourceId}});return call('aiGetSource','identity-owner',{sourceId:source.sourceId});}
test('emulator: missing docID courses, no-year unresolved, UUID/account isolation and explicit canonical link',{skip:!enabled},async()=>{
  await legacyDb.doc('classes/00008').set({class_name:'確認済み授業',teacher_name:'確認済み教員',url:'https://example.test/?YR=2026'});
  const a=await processNote(await call('aiCreateSource','identity-owner',makeRequest('uuid-a',{localCourseId:'#####'})));
  const b=await processNote(await call('aiCreateSource','identity-owner',makeRequest('uuid-b',{localCourseId:'#####',localCourseUUID:uuidB})));
  const unresolved=await processNote(await call('aiCreateSource','identity-owner',makeRequest('uuid-unresolved',{year:undefined,localCourseUUID:'55555555-5555-4555-8555-555555555555'})));
  assert.notEqual(a.courseOfferingId,b.courseOfferingId);assert.equal(unresolved.courseSnapshot.year,null);assert.equal(unresolved.courseSnapshot.resolution,'unresolved');
  assert.equal((await call('aiRetrieveContext','identity-owner',{courseOfferingId:a.courseOfferingId,query:'カント'})).items.length,1);
  const anotherOwner=await call('aiCreateSource','identity-bob',makeRequest('uuid-a'));
  assert.notEqual(a.courseOfferingId,anotherOwner.courseOfferingId);
  await db.doc(`aiCourseOfferings/${a.courseOfferingId}/memberships/identity-owner`).set({status:'verified',active:true});
  await assert.rejects(call('aiUpdateSource','identity-owner',{sourceId:a.sourceId,knowledgeVisibility:'course'}),e=>e.message==='OFFERING_UNRESOLVED');
  await assert.rejects(call('aiLinkSourceOffering','identity-bob',{sourceId:a.sourceId,classDocId:'00008'}),e=>e.code==='permission-denied');
  const original=a.courseSnapshot;
  const linked=await call('aiLinkSourceOffering','identity-owner',{sourceId:a.sourceId,classDocId:'00008'});
  assert.equal(linked.sourceId,a.sourceId);assert.equal(linked.courseOfferingId,'2026:00008');assert.deepEqual(linked.courseSnapshot,original);
  assert.equal(linked.canonicalSnapshot.courseName,'確認済み授業');assert.equal(linked.knowledgeVisibility,'private');
  assert.equal((await call('aiRetrieveContext','identity-owner',{courseOfferingId:'2026:00008',query:'カント'})).items.length,1);
  assert.equal((await call('aiRetrieveContext','identity-owner',{courseOfferingId:b.courseOfferingId,query:'カント'})).items.length,1);
  // A later catalog overwrite does not remap sources, lists, snapshots or duplicate receipts.
  await legacyDb.doc('classes/00008').set({class_name:'翌年の授業',teacher_name:'翌年の教員',url:'https://example.test/?YR=2027'});
  assert.deepEqual((await call('aiLinkSourceOffering','identity-owner',{sourceId:a.sourceId,classDocId:'00008'})).canonicalSnapshot,linked.canonicalSnapshot);
  const fetched=await call('aiGetSource','identity-owner',{sourceId:a.sourceId});assert.deepEqual(fetched.canonicalSnapshot,linked.canonicalSnapshot);
  assert.equal((await call('aiCreateSource','identity-owner',makeRequest('uuid-a',{localCourseId:'#####'}))).courseOfferingId,'2026:00008');
  await assert.rejects(call('aiLinkSourceOffering','identity-owner',{sourceId:b.sourceId,classDocId:'00008'}),e=>e.message==='CLASS_YEAR_MISMATCH');
  await assert.rejects(call('aiCreateSource','identity-owner',makeRequest('stale-missing-url',{classDocId:'00008'})),e=>e.message==='CLASS_YEAR_MISMATCH');
});
test('emulator: legacy accepted receipt survives missing catalog without reinterpretation',{skip:!enabled},async()=>{
  const {validateCreate,hash}=require('../lib/ai/domain');
  const data={clientRequestId:'legacy-receipt',type:'note',title:'以前のメモ',mime:'text/plain',text:'以前の内容',context:{localCourseId:'#####',classDocId:'old-dev-class',year:2026,semester:'fall',dayID:20730}};
  const sourceId=hash('legacy-owner',data.clientRequestId);
  await seed(sourceId,'legacy-owner');
  await db.doc(`aiSources/${sourceId}`).update({fingerprint:hash(validateCreate(data)),courseOfferingId:'legacy-hashed-offering'});
  const accepted=await call('aiCreateSource','legacy-owner',data);
  assert.equal(accepted.courseOfferingId,'legacy-hashed-offering');assert.equal(accepted.courseSnapshot,null);
  await assert.rejects(call('aiCreateSource','legacy-owner',{...data,clientRequestId:'new-legacy-receipt'}),e=>e.message==='INVALID_CLASS');
});

test('emulator: private feature flag blocks even verified memberships',{skip:!enabled},async()=>{
  await seed('s-flag','flag-owner','course','flag-course');
  await db.doc('aiCourseOfferings/flag-course/memberships/flag-member').set({status:'verified',active:true});
  process.env.AI_SHARING_ENABLED='false';
  try {
    assert.equal((await call('aiRetrieveContext','flag-member',{courseOfferingId:'flag-course',query:'カント'})).items.length,0);
    await assert.rejects(call('aiGetEvidence','flag-member',{sourceId:'s-flag'}),e=>e.message==='NOT_FOUND');
    await assert.rejects(call('aiUpdateSource','flag-owner',{sourceId:'s-flag',knowledgeVisibility:'course'}),e=>e.message==='SHARING_DISABLED');
    assert.equal((await call('aiGetSource','flag-owner',{sourceId:'s-flag'})).sharingEnabled,false);
    assert.equal((await call('aiGetEvidence','flag-owner',{sourceId:'s-flag'})).items.length,1);
    await call('aiUpdateSource','flag-owner',{sourceId:'s-flag',knowledgeVisibility:'private'});
  } finally {process.env.AI_SHARING_ENABLED='true';}
});
test('emulator: deleted Auth user blocks tokens; reconcile purges originals, derived, usage, jobs',{skip:!enabled},async()=>{
  const uid='deleted-account',req=makeRequest('deleted-account-note');
  const source=await call('aiCreateSource',uid,req);await api.aiProcessSource.run({data:{databaseId:'aogaku-ai',sourceId:source.sourceId}});
  const b=admin.storage().bucket();
  const raw=`ai-inputs/aogaku-ai/${uid}/${source.sourceId}/original`,derived=`ai-derived/aogaku-ai/${uid}/${source.sourceId}/extra.json`;
  await b.file(raw).save('original');await b.file(derived).save('derived');
  await db.doc(`aiSources/${source.sourceId}/jobs/pending-task`).set({taskId:'pending-task'});
  deletedUsers.add(uid);
  await assert.rejects(call('aiCreateSource',uid,makeRequest('after-delete')),e=>e.message==='ACCOUNT_DELETED');
  await assert.rejects(call('aiGetEvidence',uid,{sourceId:source.sourceId}),e=>e.message==='ACCOUNT_DELETED');
  await api.aiReconcileInputs.run({});
  const tomb=(await db.doc(`aiSources/${source.sourceId}`).get()).data();
  assert.deepEqual(Object.keys(tomb).sort(),['ownerUserId','sourceId','status','updatedAt']);assert.equal(tomb.status,'deleted');
  for(const key of [raw,derived])assert.equal((await b.file(key).exists())[0],false);
  assert.equal((await db.doc(`aiSources/${source.sourceId}`).collection('jobs').get()).size,0);
  assert.equal((await db.doc(`aiUsage/${uid}`).collection('periods').get()).size,0);
  assert.equal((await db.doc(`aiInputOwners/${uid}`).get()).get('state'),'deleted');
  await api.aiProcessSource.run({data:{databaseId:'aogaku-ai',sourceId:source.sourceId}});assert.equal((await db.doc(`aiSources/${source.sourceId}`).get()).get('status'),'deleted');
  await b.file(raw).save('late');const [metadata]=await b.file(raw).getMetadata();
  await api.aiRejectLateUpload.run({data:{name:raw,bucket:b.name,generation:metadata.generation}});
  assert.equal((await b.file(raw).exists())[0],false);
});
test('emulator: account deletion hook cancels processing before publication',{skip:!enabled},async()=>{
  const uid='hook-deletion',source=await call('aiCreateSource',uid,makeRequest('before-hook'));
  await api.beginAIAccountDeletion(uid);
  await api.aiProcessSource.run({data:{databaseId:'aogaku-ai',sourceId:source.sourceId}});
  assert.equal((await db.doc(`aiSources/${source.sourceId}`).get()).get('status'),'deleted');
  await assert.rejects(call('aiCreateSource',uid,makeRequest('after-hook')),e=>e.message==='ACCOUNT_DELETED');
});

test('emulator: production sharing stays OFF even with an enabled env flag',{skip:!enabled},()=>{
  const previous=process.env.GCLOUD_PROJECT;process.env.GCLOUD_PROJECT='forta-aogaku';
  try {assert.equal(api.sharingEnabled(),false);}
  finally {if(previous===undefined)delete process.env.GCLOUD_PROJECT;else process.env.GCLOUD_PROJECT=previous;}
});

test('emulator: production input requires explicit internal test UID, Dev unaffected',{skip:!enabled},()=>{
 const previous=process.env.GCLOUD_PROJECT;process.env.GCLOUD_PROJECT='forta-aogaku';
 process.env.AI_INPUT_ALLOWED_UIDS='';
 try {assert.equal(api.productionInputsAllowed('pilot-owner'),false);process.env.AI_INPUT_ALLOWED_UIDS=JSON.stringify(['pilot-owner']);assert.equal(api.productionInputsAllowed('pilot-owner'),true);assert.equal(api.productionInputsAllowed('other-owner'),false);}
 finally {delete process.env.AI_INPUT_ALLOWED_UIDS;if(previous===undefined)delete process.env.GCLOUD_PROJECT;else process.env.GCLOUD_PROJECT=previous;}
});

test('production pilot: every client callable rejects ordinary UID before any admission, even verified member',{skip:!enabled},async()=>{
 const previous=process.env.GCLOUD_PROJECT,prevUIDs=process.env.AI_INPUT_ALLOWED_UIDS;process.env.GCLOUD_PROJECT='forta-aogaku';process.env.AI_INPUT_ALLOWED_UIDS='["internal-pilot-only"]';
 try {
  await db.doc('aiCourseOfferings/2026:00004/memberships/ordinary-pilot-denied').set({status:'verified',active:true});
  for(const name of ['aiCreateSource','aiCompleteSource','aiGetSource','aiListSources','aiGetEvidence','aiRetrySource','aiUpdateSource','aiDeleteSource','aiRetrieveContext'])await assert.rejects(call(name,'ordinary-pilot-denied',{}),e=>e.message==='AI_INPUT_NOT_ENABLED');
  assert.equal((await db.doc('aiInputOwners/ordinary-pilot-denied').get()).exists,false);assert.equal((await db.collection('aiUsage/ordinary-pilot-denied/periods').get()).size,0);
  await seed('pilot-owned-source','internal-pilot-only','course','2026:00004');
  assert.equal((await call('aiGetSource','internal-pilot-only',{sourceId:'pilot-owned-source'})).sourceId,'pilot-owned-source');
  process.env.AI_INPUT_ALLOWED_UIDS='[]';await assert.rejects(call('aiGetSource','internal-pilot-only',{sourceId:'pilot-owned-source'}),e=>e.message==='AI_INPUT_NOT_ENABLED');
 } finally {if(previous===undefined)delete process.env.GCLOUD_PROJECT;else process.env.GCLOUD_PROJECT=previous;if(prevUIDs===undefined)delete process.env.AI_INPUT_ALLOWED_UIDS;else process.env.AI_INPUT_ALLOWED_UIDS=prevUIDs;}
});
test('production pilot: background worker does not process an owner excluded from cohort',{skip:!enabled},async()=>{
 const previous=process.env.GCLOUD_PROJECT,prevUIDs=process.env.AI_INPUT_ALLOWED_UIDS;process.env.GCLOUD_PROJECT='forta-aogaku';process.env.AI_INPUT_ALLOWED_UIDS='["internal-pilot-only"]';
 try {const id='ordinary-worker-denied';await seed(id,'ordinary-worker-denied');await db.doc('aiSources/'+id).update({status:'queued',activeRun:null,noteText:'not allowed'});await api.aiProcessSource.run({data:{databaseId:'aogaku-ai',sourceId:id}});const s=await db.doc('aiSources/'+id).get();assert.equal(s.get('status'),'queued');assert.equal(s.get('attempts'),0);assert.equal(s.get('leaseToken'),undefined);assert.equal((await db.collection('aiSources/'+id+'/runs').get()).size,0);}
 finally{if(previous===undefined)delete process.env.GCLOUD_PROJECT;else process.env.GCLOUD_PROJECT=previous;if(prevUIDs===undefined)delete process.env.AI_INPUT_ALLOWED_UIDS;else process.env.AI_INPUT_ALLOWED_UIDS=prevUIDs;}
});

test('named database: catalog comes only from default; AI transaction references stay in named',{skip:!enabled},async()=>{
 await legacyDb.doc('classes/00019').set({class_name:'default catalog',teacher_name:'Catalog teacher',url:'https://example.test/?YR=2026'});
 await db.doc('classes/00019').set({class_name:'wrong database decoy',url:'https://example.test/?YR=2027'});
 const original=db.runTransaction;let checked=0;
 db.runTransaction=function(fn,...args){return original.call(this,async tx=>{const get=tx.get.bind(tx);tx.get=(ref,...rest)=>{assert.equal(ref.firestore,db,'cross-database transaction read');checked++;return get(ref,...rest)};return fn(tx)},...args)};
 try {const source=await call('aiCreateSource','named-boundary-owner',makeRequest('named-boundary',{classDocId:'00019',courseName:undefined,teacherName:undefined}));assert.equal(source.courseOfferingId,'2026:00019');assert.equal(source.courseSnapshot.courseName,'default catalog');assert.equal(source.databaseId,'aogaku-ai');assert(checked>0);assert.equal((await legacyDb.doc('aiSources/'+source.sourceId).get()).exists,false);}
 finally {db.runTransaction=original;}
});
test('named database: old deliveries and unversioned Storage never mutate either source',{skip:!enabled},async()=>{
 const id='named-delivery-sentinel',uid='named-delivery-owner';
 await seed(id,uid);await db.doc('aiSources/'+id).update({status:'queued',activeRun:null,noteText:'new content'});
 const sentinel={status:'queued',noteText:'old retained content',ownerUserId:uid};await legacyDb.doc('aiSources/'+id).set(sentinel);
 for(const databaseId of [undefined,'(default)','wrong-db'])await api.aiProcessSource.run({data:{sourceId:id,databaseId}});
 assert.equal((await db.doc('aiSources/'+id).get()).get('status'),'queued');assert.deepEqual((await legacyDb.doc('aiSources/'+id).get()).data(),sentinel);
 const b=admin.storage().bucket(),old=`ai-inputs/${uid}/${'f'.repeat(64)}/original`;await b.file(old).save('old preserved');const [meta]=await b.file(old).getMetadata();await api.aiRejectLateUpload.run({data:{name:old,bucket:b.name,generation:meta.generation}});assert.equal((await b.file(old).exists())[0],true);
 await api.aiProcessSource.run({data:{sourceId:id,databaseId:'aogaku-ai'}});assert.equal((await db.doc('aiSources/'+id).get()).get('status'),'ready');assert.deepEqual((await legacyDb.doc('aiSources/'+id).get()).data(),sentinel);
});
test('named deletion: crash between database fences is fail closed and resumes idempotently',{skip:!enabled},async()=>{
 const uid='named-interrupted-delete';await db.doc('aiCourseOfferings/no-source-membership/memberships/'+uid).set({status:'verified',active:true,userId:uid});const source=await call('aiCreateSource',uid,makeRequest('named-delete'));
 const fence=legacyDb.doc('accountDeletionFences/'+uid),proto=Object.getPrototypeOf(fence),set=proto.set;let failed=false;
 proto.set=function(...args){if(this.path===fence.path&&!failed){failed=true;return Promise.reject(Error('simulated default fence outage'))}return set.apply(this,args)};
 try {await assert.rejects(api.beginAIAccountDeletion(uid),/simulated default fence outage/);}finally{proto.set=set}
 assert.equal((await db.doc('aiInputOwners/'+uid).get()).get('state'),'deleting');assert.equal((await fence.get()).exists,false);
 await assert.rejects(call('aiCreateSource',uid,makeRequest('after-crash')),e=>e.message==='ACCOUNT_DELETED');
 await api.continueAIAccountDeletion(uid);await api.continueAIAccountDeletion(uid);assert.equal((await db.doc('aiCourseOfferings/no-source-membership/memberships/'+uid).get()).exists,false);assert.equal((await fence.get()).get('state'),'deleted');assert.equal((await db.doc('aiSources/'+source.sourceId).get()).get('status'),'deleted');assert.equal((await db.collection('aiUsage/'+uid+'/periods').get()).size,0);
 await api.aiProcessSource.run({data:{sourceId:source.sourceId,databaseId:'aogaku-ai'}});assert.equal((await db.doc('aiSources/'+source.sourceId).get()).get('status'),'deleted');
});
test('named database: default deletion fence prevents admission without named owner; database misconfiguration fails closed',{skip:!enabled},async()=>{
 await legacyDb.doc('accountDeletionFences/default-fenced-owner').set({state:'deleted'});await assert.rejects(call('aiCreateSource','default-fenced-owner',makeRequest('default-fence')),e=>e.message==='ACCOUNT_DELETED');
 assert.equal((await db.doc('aiInputOwners/default-fenced-owner').get()).exists,false);
 const original=process.env.AI_FIRESTORE_DATABASE_ID;process.env.AI_FIRESTORE_DATABASE_ID='(default)';try{await assert.rejects(call('aiListSources','named-config-owner',{}),e=>e.message==='AI_DATABASE_MISMATCH');}finally{process.env.AI_FIRESTORE_DATABASE_ID=original}
});
test('named deletion: 101 orphan memberships resume without affecting another UID',{skip:!enabled},async()=>{
 const uid='orphan-paged-owner',batch=db.batch();for(let i=0;i<101;i++)batch.set(db.doc(`aiCourseOfferings/orphan-${i}/memberships/${uid}`),{userId:uid,status:'verified'});batch.set(db.doc('aiCourseOfferings/orphan-0/memberships/orphan-other'),{userId:'orphan-other',status:'verified'});await batch.commit();
 await api.beginAIAccountDeletion(uid);assert.equal((await db.doc('aiInputOwners/'+uid).get()).get('state'),'deleting');await api.continueAIAccountDeletion(uid);assert.equal((await db.doc('aiInputOwners/'+uid).get()).get('state'),'deleted');assert.equal((await db.collectionGroup('memberships').where('userId','==',uid).get()).size,0);assert.equal((await db.doc('aiCourseOfferings/orphan-0/memberships/orphan-other').get()).exists,true);
});

// Real named/default Firestore + Storage, real worker/chunks/quota; provider transport is mock-only.
async function recognitionSource(id,owner,type,bytes,mime){
 const source=await seed(id,owner);const path=`ai-inputs/aogaku-ai/${owner}/${id}/original`;
 await admin.storage().bucket().file(path).save(bytes,{contentType:mime});
 await db.doc(`aiSources/${id}`).set({...source,sourceType:type,mime,status:'queued',activeRun:null,attempts:0,storagePath:path,declaredSize:bytes.length,declaredDuration:2});return source;
}
test('recognition: AI-only image worker, real evidence overlap/usage/retrieval, old evidence and UID boundaries',{skip:!enabled},async()=>{
 const bytes=Buffer.from([137,80,78,71,13,10,26,10,0]);await recognitionSource('det-image','det-owner','image',bytes,'image/png');
 await api.aiProcessSource.run({data:{databaseId:'aogaku-ai',sourceId:'det-image'}});
 const source=await call('aiGetSource','det-owner',{sourceId:'det-image'});assert.equal(source.status,'ready');assert.equal(source.pipelineVersion,'image-ai-v2');assert.equal(source.recognition.totalTokens,3357);assert.equal((await call('aiListSources','det-owner',{courseOfferingId:source.courseOfferingId})).inputCapabilities.image.model,'qwen/qwen3.8-27b');assert(Math.abs(source.recognition.estimatedCostUSD-.00402)<1e-12);
 const evidence=await call('aiGetEvidence','det-owner',{sourceId:'det-image'});assert.equal(evidence.activeVersion,source.activeVersion);assert(evidence.items.length>1);assert(evidence.items.every(x=>x.method==='multimodal_ai'&&x.unitIndex===0));
 let text='',end=0;for(const item of evidence.items){text+=item.text.slice(Math.max(0,end-item.locator.startChar));end=item.locator.endChar;}assert.equal(text,'親から子へ特徴が遺伝する。'+'階層を説明する。'.repeat(200));
 const r=await call('aiRetrieveContext','det-owner',{courseOfferingId:'course-a',query:'遺伝'});assert(r.items.some(x=>x.sourceId==='det-image'));assert.equal((await legacyDb.doc('aiSources/det-image').get()).exists,false);
 await assert.rejects(call('aiGetEvidence','det-outsider',{sourceId:'det-image'}),e=>e.code==='not-found');
 await assert.rejects(call('aiGetSource','det-outsider',{sourceId:'det-image'}),e=>e.code==='permission-denied');
 const before=imageRequests;await api.aiProcessSource.run({data:{databaseId:'aogaku-ai',sourceId:'det-image'}});assert.equal(imageRequests,before,'ready images never reprocess');
 await seed('det-old-ocr','det-owner');await db.doc('aiSources/det-old-ocr/runs/run-a/chunks/000000').update({method:'vision_ocr'});assert.equal((await call('aiGetEvidence','det-owner',{sourceId:'det-old-ocr'})).items[0].method,'vision_ocr');
});
test('recognition: actual audio segmentation, Turbo only, timestamp/cost, original removed after ready',{skip:!enabled},async()=>{
 const {execFileSync}=require('node:child_process'),{mkdtempSync,readFileSync,rmSync}=require('node:fs'),{tmpdir}=require('node:os'),{join}=require('node:path');const dir=mkdtempSync(join(tmpdir(),'detection-audio-'));
 try{const path=join(dir,'test.m4a');execFileSync(require('ffmpeg-static'),['-nostdin','-y','-f','lavfi','-i','sine=frequency=440:duration=1','-c:a','aac',path],{stdio:'ignore'});await recognitionSource('det-audio','det-audio-owner','audio',readFileSync(path),'audio/mp4');
 await api.aiProcessSource.run({data:{databaseId:'aogaku-ai',sourceId:'det-audio'}});const source=await call('aiGetSource','det-audio-owner',{sourceId:'det-audio'});assert.equal(source.status,'ready');assert.equal(source.recognition.model,'whisper-large-v3-turbo');assert.equal(source.recognition.billedAudioSeconds,10);assert.equal(source.recognition.inputTokens,null);assert.equal(source.recognition.estimatedCostUSD,10/3600*.04);
 const ev=await call('aiGetEvidence','det-audio-owner',{sourceId:'det-audio'});assert.equal(ev.items[0].locator.startMs,0);assert.equal(ev.items[0].locator.endMs,1000);assert.equal((await admin.storage().bucket().file('ai-inputs/aogaku-ai/det-audio-owner/det-audio/original').exists())[0],false);assert.equal(audioRequests,1);
 }finally{rmSync(dir,{recursive:true,force:true});}
});
test('recognition: 429 and 503 stay retryable without OCR, manual retry succeeds; provider budget/rate/App Check fail closed',{skip:!enabled},async()=>{
 const bytes=Buffer.from([137,80,78,71,13,10,26,10,0]);await recognitionSource('det-retry','det-retry-owner','image',bytes,'image/png');
 for(const status of [429,503]){recognitionStatus=status;await assert.rejects(api.aiProcessSource.run({data:{databaseId:'aogaku-ai',sourceId:'det-retry'}}),e=>e.retryable);const s=(await db.doc('aiSources/det-retry').get()).data();assert.equal(s.status,'queued');assert.equal(s.activeRun,null);}
 recognitionStatus=200;await api.aiProcessSource.run({data:{databaseId:'aogaku-ai',sourceId:'det-retry'}});assert.equal((await call('aiGetSource','det-retry-owner',{sourceId:'det-retry'})).status,'ready');
 await recognitionSource('det-budget','det-budget-owner','image',bytes,'image/png');const day=new Date(Date.now()+9*3600000).toISOString().slice(0,10);await db.doc(`aiUsage/det-budget-owner/periods/day-${day}`).set({providerCalls:100});const previous=imageRequests;await api.aiProcessSource.run({data:{databaseId:'aogaku-ai',sourceId:'det-budget'}});assert.equal(imageRequests,previous);assert.equal((await db.doc('aiSources/det-budget').get()).get('error.code'),'PROVIDER_QUOTA_EXCEEDED');
 await db.doc('aiUsage/det-rate/periods/request-rate').set({slot:Math.floor(Date.now()/60000),count:120});await assert.rejects(call('aiListSources','det-rate',{context:{}}),e=>e.message==='RATE_LIMITED');
 process.env.AI_INPUT_ADMISSION_MODE='public';process.env.AI_INPUT_REQUIRE_APP_CHECK='true';
 try{await assert.rejects(call('aiListSources','det-public',{context:{}}),e=>e.message==='APP_CHECK_REQUIRED');assert.equal((await db.doc('aiUsage/det-public/periods/request-rate').get()).exists,false);const result=await api.aiGetSource.run({auth:{uid:'det-owner',token:{}},app:{appId:'synthetic-attested'},data:{sourceId:'det-image'}});assert.equal(result.sourceId,'det-image');}finally{process.env.AI_INPUT_ADMISSION_MODE='pilot';process.env.AI_INPUT_REQUIRE_APP_CHECK='false';}
});
test('recognition: existing daily count/bytes/weekly audio limits stay effective and deletion removes new counters',{skip:!enabled},async()=>{
 const day=new Date(Date.now()+9*3600000).toISOString().slice(0,10),{weekKey}=require('../lib/ai/domain');
 for(const [uid,values]of [['det-count-limit',{count:100}],['det-bytes-limit',{bytes:500*1024**2}]]){await db.doc(`aiUsage/${uid}/periods/day-${day}`).set(values);await assert.rejects(call('aiCreateSource',uid,makeRequest('limit-check')),e=>e.message==='QUOTA_EXCEEDED');}
 await db.doc(`aiUsage/det-seconds-limit/periods/week-${weekKey(new Date())}`).set({seconds:10800});
 await assert.rejects(call('aiCreateSource','det-seconds-limit',{...makeRequest('audio-limit'),type:'audio',mime:'audio/mp4',text:undefined,size:10,durationSeconds:1}),e=>e.message==='QUOTA_EXCEEDED');
 await api.beginAIAccountDeletion('det-retry-owner');
 assert.equal((await db.collection('aiUsage/det-retry-owner/periods').get()).size,0);await assert.rejects(call('aiListSources','det-retry-owner',{context:{}}),e=>e.message==='ACCOUNT_DELETED');assert.equal((await db.collection('aiUsage/det-retry-owner/periods').get()).size,0);
});

// New source contract and routed worker are exercised against real local DB/Storage.
test('visual router: new receipts, native/OCR/AI evidence, retry and deletion boundaries',{skip:!enabled},async()=>{
 const fixture=require('../../scripts/visual_router_fixtures.cjs');
 const file=admin.storage().bucket().file('unused'),proto=Object.getPrototypeOf(file),signed=proto.getSignedUrl;
 proto.getSignedUrl=async()=>['http://localhost/synthetic-only'];
 try{
  for(const type of ['image','pdf']){const bytes=type==='image'?fixture.image('plain').bytes:fixture.pdf(['text']);const req={...makeRequest('router-receipt-'+type),type,mime:type==='image'?'image/png':'application/pdf',size:bytes.length,text:undefined};
   const source=await call('aiCreateSource','router-receipt-owner',req);assert.equal(source.pipelineVersion,type+'-auto-v1');assert.equal((await db.doc('aiSources/'+source.sourceId).get()).get('schemaVersion'),5);assert.equal((await call('aiCreateSource','router-receipt-owner',req)).sourceId,source.sourceId);
  }
 }finally{proto.getSignedUrl=signed;}
 for(const [id,type,bytes,routes]of [
  ['router-ocr','image',fixture.image('plain').bytes,['vision_ocr']],
  ['router-diagram','image',fixture.image('arrows').bytes,['multimodal_ai']],
  ['router-mixed','pdf',fixture.pdf(['text','scanned','diagram']),['native_text','vision_ocr','multimodal_ai']]]){
  await recognitionSource(id,'router-owner',type,bytes,type==='image'?'image/png':'application/pdf');await db.doc('aiSources/'+id).update({pipelineVersion:type+'-auto-v1',schemaVersion:5});
  await api.aiProcessSource.run({data:{databaseId:'aogaku-ai',sourceId:id}});const source=await call('aiGetSource','router-owner',{sourceId:id});assert.equal(source.status,'ready');assert.deepEqual(source.recognition.routing.pages.map(x=>x.route),routes);
  const all=[];let after;do{const page=await call('aiGetEvidence','router-owner',{sourceId:id,...(after?{after}:{})});all.push(...page.items);after=page.nextCursor;}while(after);assert.deepEqual([...new Set(all.map(x=>x.method))],routes);if(type==='pdf')assert.deepEqual([...new Set(all.map(x=>x.locator.pageNumber))],[1,2,3]);
  assert.equal((await legacyDb.doc('aiSources/'+id).get()).exists,false);assert((await call('aiRetrieveContext','router-owner',{courseOfferingId:'course-a',purpose:'lecture_summary'})).items.some(x=>x.sourceId===id));const old=imageRequests;await api.aiProcessSource.run({data:{databaseId:'aogaku-ai',sourceId:id}});assert.equal(imageRequests,old);
 }
 await recognitionSource('router-retry','router-retry-owner','image',fixture.image('arrows').bytes,'image/png');await db.doc('aiSources/router-retry').update({pipelineVersion:'image-auto-v1'});recognitionStatus=503;
 try{await assert.rejects(api.aiProcessSource.run({data:{databaseId:'aogaku-ai',sourceId:'router-retry'}}),e=>e.retryable);const s=(await db.doc('aiSources/router-retry').get()).data();assert.equal(s.status,'queued');assert.equal(s.activeRun,null);assert.equal(s.pipelineVersion,'image-auto-v1');assert.equal(s.recognition,undefined);}finally{recognitionStatus=200;}
 await api.aiProcessSource.run({data:{databaseId:'aogaku-ai',sourceId:'router-retry'}});assert.equal((await call('aiGetSource','router-retry-owner',{sourceId:'router-retry'})).status,'ready');await api.beginAIAccountDeletion('router-retry-owner');assert.equal((await db.collection('aiSources/router-retry/runs').get()).size,0);assert.equal((await db.collection('aiUsage/router-retry-owner/periods').get()).size,0);await api.aiProcessSource.run({data:{databaseId:'aogaku-ai',sourceId:'router-retry'}});assert.equal((await db.doc('aiSources/router-retry').get()).get('status'),'deleted');
});
