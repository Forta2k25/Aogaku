const {test,before,after}=require('node:test');
const assert=require('node:assert/strict');
const admin=require('firebase-admin');
const enabled=!!process.env.FIRESTORE_EMULATOR_HOST && !!process.env.STORAGE_EMULATOR_HOST;
let app,db,api,taskPrototype,originalEnqueue;
before(()=>{
  if(!enabled)return;
  app=admin.initializeApp({projectId:'demo-aogaku-input',storageBucket:'demo-aogaku-input.appspot.com'});
  db=admin.firestore(); api=require('../lib/ai');
  // Replace transport only: acceptance, transactions and worker logic remain real.
  taskPrototype=Object.getPrototypeOf(require('firebase-admin/functions').getFunctions().taskQueue('aiProcessSource'));
  originalEnqueue=taskPrototype.enqueue; taskPrototype.enqueue=async()=>{};
});
after(async()=>{if(taskPrototype)taskPrototype.enqueue=originalEnqueue;if(app)await app.delete()});
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
  await db.doc('classes/class-id').set({title:'試験用授業'});
  const request={clientRequestId:'note-receipt',type:'note',title:'授業メモ',mime:'text/plain',text:'テストの資料',
    context:{localCourseId:'local-class',classDocId:'class-id',year:2026,semester:'fall',dayID:20730}};
  const first=await call('aiCreateSource','accept-owner',request);
  const second=await call('aiCreateSource','accept-owner',request);
  assert.equal(first.sourceId,second.sourceId);assert.equal(first.lectureId,second.lectureId);
  await assert.rejects(call('aiCreateSource','accept-owner',{...request,text:'変更した資料'}),e=>e.message==='REQUEST_CONFLICT');
  const bob=await call('aiCreateSource','accept-bob',request);
  assert.notEqual(first.sourceId,bob.sourceId);assert.equal(first.courseOfferingId,bob.courseOfferingId);
  const otherYear=await call('aiCreateSource','accept-owner',{...request,clientRequestId:'next-year',context:{...request.context,year:2027}});
  assert.notEqual(first.courseOfferingId,otherYear.courseOfferingId);
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
  await db.doc('aiSources/s-worker').set({...source,status:'queued',activeRun:null,noteText:'社会思想の授業でカントについて学んだ。',storagePath:'ai-inputs/worker-owner/s-worker/original'});
  await api.aiProcessSource.run({data:{sourceId:'s-worker'}});
  const first=(await db.doc('aiSources/s-worker').get()).data();
  assert.equal(first.status,'ready');assert.ok(first.activeRun);
  await api.aiProcessSource.run({data:{sourceId:'s-worker'}});
  assert.equal((await db.doc('aiSources/s-worker').get()).get('activeRun'),first.activeRun);
  const r=await call('aiRetrieveContext','worker-owner',{courseOfferingId:'course-a',query:'カント'});
  assert.equal(r.items.length,1);assert.equal(r.items[0].sourceId,'s-worker');
  await call('aiDeleteSource','worker-owner',{sourceId:'s-worker'});
  await api.aiProcessSource.run({data:{sourceId:'s-worker'}});
  assert.equal((await db.doc('aiSources/s-worker').get()).get('status'),'deleted');
  assert.equal((await db.doc(`aiSources/s-worker/runs/${first.activeRun}`).collection('chunks').get()).size,0);
  assert.equal((await call('aiRetrieveContext','worker-owner',{courseOfferingId:'course-a',query:'カント'})).items.length,0);
});
test('emulator: direct unauthenticated Firestore reads cannot bypass API',{skip:!enabled},async()=>{
  const base=`http://${process.env.FIRESTORE_EMULATOR_HOST}/v1/projects/demo-aogaku-input/databases/(default)/documents`;
  const r=await fetch(`${base}/aiSources/s-private`);
  assert.equal(r.status,403);
});
