const {test,before,after}=require('node:test'),assert=require('node:assert/strict'),admin=require('firebase-admin');
const enabled=!!process.env.FIRESTORE_EMULATOR_HOST&&!!process.env.STORAGE_EMULATOR_HOST;
let rollback,candidate,app,credential,originalToken,originalGetUser,originalFetch;
before(()=>{if(!enabled)return;process.env.FIREBASE_CONFIG=JSON.stringify({projectId:'demo-aogaku-input',storageBucket:'demo-aogaku-input.appspot.com'});process.env.OPENAI_API_KEY='emulator-placeholder';credential=admin.credential.applicationDefault();originalToken=credential.getAccessToken;credential.getAccessToken=async()=>({access_token:'emulator-only',expires_in:3600});rollback=require('../../build/production-legacy-rollback-before-pilot');app=admin.app();candidate=require('../../build/production-legacy-candidate');originalGetUser=admin.auth().getUser;admin.auth().getUser=async uid=>({uid,disabled:false});originalFetch=global.fetch;global.fetch=async(url,opts)=>{if(String(url)==='https://api.openai.com/v1/chat/completions')return new Response(JSON.stringify({choices:[{message:{content:'compatible answer'}}]}));const u=new URL(url);if(u.protocol!=='http:'||!['127.0.0.1','localhost','[::1]'].includes(u.hostname))throw Error('Real cloud disabled');return originalFetch(url,opts);};});
after(async()=>{if(originalFetch)global.fetch=originalFetch;if(app){admin.auth().getUser=originalGetUser;await app.delete();}if(credential)credential.getAccessToken=originalToken;});
test('Exact Phase3b artifact without param injection cleans named data, fences default quota and is idempotent',{skip:!enabled},async()=>{
 const saved=process.env.AI_FIRESTORE_DATABASE_ID;
 delete process.env.AI_FIRESTORE_DATABASE_ID;
 try {
  const api=require('../../build/production-phase3b/candidate'),{getFirestore}=require('firebase-admin/firestore');
  const named=getFirestore(app,'aogaku-ai'),legacy=getFirestore(app,'(default)'),uid='exact-phase3b-no-env';
  await named.doc('aiSources/'+uid).set({sourceId:uid,ownerUserId:uid,status:'awaiting_upload',noteText:'private'});
  await named.doc('aiSources/'+uid+'/runs/r/chunks/c').set({text:'private'});
  await named.doc('aiUsage/'+uid+'/periods/day').set({count:2});
  await legacy.doc('privateUsage/'+uid+'/counters/month').set({count:2});
  await legacy.doc('aiSources/'+uid).set({legacySentinel:true});
  const req={data:{},auth:{uid,token:{auth_time:Math.floor(Date.now()/1000)}}};
  for(let i=0;i<2;i++)assert.deepEqual(await api.preDeleteCleanup.run(req),{ok:true,aiAccountDeletionVersion:1});
  assert.equal((await named.doc('aiInputOwners/'+uid).get()).get('state'),'deleted');
  assert.equal((await legacy.doc('accountDeletionFences/'+uid).get()).get('state'),'deleted');
  assert.equal((await named.doc('aiSources/'+uid).get()).get('noteText'),undefined);
  assert.equal((await named.doc('aiSources/'+uid+'/runs/r/chunks/c').get()).exists,false);
  assert.equal((await named.collection('aiUsage/'+uid+'/periods').get()).size,0);
  assert.equal((await legacy.collection('privateUsage/'+uid+'/counters').get()).size,0);
  assert.equal((await legacy.doc('aiSources/'+uid).get()).get('legacySentinel'),true);
 } finally {if(saved===undefined)delete process.env.AI_FIRESTORE_DATABASE_ID;else process.env.AI_FIRESTORE_DATABASE_ID=saved;}
});
test('built Node22 rollback/candidate artifacts preserve old AI and preDelete contracts',{skip:!enabled},async()=>{
 for(const [api,uid]of [[rollback,'artifact-rollback'],[candidate,'artifact-candidate']]){
  const result=await api.askCourseAI.run({prompt:'質問',transcript:'資料'},{auth:{uid,token:{}}});assert.deepEqual(result,{text:'compatible answer',remainingGenerationsToday:9});
  const cleanup=await api.preDeleteCleanup.run({data:{uid},auth:{uid,token:{auth_time:Math.floor(Date.now()/1000)}}});assert.equal(cleanup.ok,true);assert.equal(cleanup.aiAccountDeletionVersion,api===candidate?1:undefined);
  const marker=await require('firebase-admin/firestore').getFirestore(app,'aogaku-ai').doc('aiInputOwners/'+uid).get();assert.equal(marker.exists,api===candidate);
 }
});

test('Phase3a slim artifact exports only the approved three callables and preserves answer contract',{skip:!enabled},async()=>{
 const api=require('../../build/production-phase3a/candidate');
 assert.deepEqual(Object.keys(api).sort(),['askCourseAI','generateReactionPaper','transcribeLectureAudio']);
 const result=await api.askCourseAI.run({prompt:'質問',transcript:'資料'},{auth:{uid:'slim-active',token:{}}});
 assert.deepEqual(result,{text:'compatible answer',remainingGenerationsToday:9});
 const db=require('firebase-admin/firestore').getFirestore(app,'aogaku-ai');
 assert.equal((await db.doc('aiInputOwners/slim-active').get()).exists,false);
 assert.equal((await db.collection('aiSources').where('ownerUserId','==','slim-active').get()).size,0);
});

test('Phase3a slim artifact denies all three callables after either database deletion fence without quota recreation',{skip:!enabled},async()=>{
 const api=require('../../build/production-phase3a/candidate'),{getFirestore}=require('firebase-admin/firestore');
 for(const database of ['(default)','aogaku-ai']){
  const uid=database==='(default)'?'slim-default-fenced':'slim-named-fenced';
  await getFirestore(app,database).doc((database==='(default)'?'accountDeletionFences/':'aiInputOwners/')+uid).set({state:'deleting'});
  await admin.storage().bucket().file(`users/${uid}/transcriptionUploads/a.m4a`).save('synthetic emulator fixture');
  for(const [name,data]of [['askCourseAI',{prompt:'質問',transcript:'資料'}],['generateReactionPaper',{transcript:'資料'}],['transcribeLectureAudio',{storagePath:`users/${uid}/transcriptionUploads/a.m4a`,durationSeconds:10}]]){
   await assert.rejects(api[name].run(data,{auth:{uid,token:{}}}),e=>e.code==='failed-precondition'&&e.message==='ACCOUNT_DELETED');
  }
  assert.equal((await getFirestore(app,'(default)').collection(`privateUsage/${uid}/counters`).get()).size,0);
 }
});

test('Phase3a missing Auth owner writes only default fence; named DB and legacy quota remain empty',{skip:!enabled},async()=>{
 const api=require('../../build/production-phase3a/candidate'),{getFirestore}=require('firebase-admin/firestore'),uid='slim-auth-missing';
 const saved=admin.auth().getUser;admin.auth().getUser=async()=>{throw Object.assign(Error('missing'),{code:'auth/user-not-found'});};
 try{await assert.rejects(api.askCourseAI.run({prompt:'質問',transcript:'資料'},{auth:{uid,token:{}}}),e=>e.code==='failed-precondition'&&e.message==='ACCOUNT_DELETED');}finally{admin.auth().getUser=saved;}
 assert.equal((await getFirestore(app,'(default)').doc('accountDeletionFences/'+uid).get()).get('state'),'deleting');
 assert.equal((await getFirestore(app,'aogaku-ai').doc('aiInputOwners/'+uid).get()).exists,false);
 assert.equal((await getFirestore(app,'(default)').collection(`privateUsage/${uid}/counters`).get()).size,0);
});
