// Execute the byte-identical recovered history against local Firestore/Storage.
// Providers/signing/FCM transports are replaced; no cloud, keys, or production data.
const {test,before,after}=require('node:test'),assert=require('node:assert/strict');
const {readFileSync}=require('node:fs'),{createHash}=require('node:crypto');
const admin=require('firebase-admin');
const enabled=!!process.env.FIRESTORE_EMULATOR_HOST&&!!process.env.STORAGE_EMULATOR_HOST;
let api,app,db,bucket,fetchOriginal,filePrototype,signOriginal,credential,tokenOriginal;
let providerMode='ok',calls=[];
const raw='社会契約と自由について授業で説明しました。';
before(()=>{
 if(!enabled)return;
 process.env.FIREBASE_CONFIG=JSON.stringify({projectId:'demo-aogaku-input',storageBucket:'demo-aogaku-input.appspot.com'});
 process.env.OPENAI_API_KEY='emulator-placeholder';process.env.GROQ_API_KEY='emulator-placeholder';
 credential=admin.credential.applicationDefault();tokenOriginal=credential.getAccessToken;
 credential.getAccessToken=async()=>({access_token:'emulator-only',expires_in:3600});
 api=require('../lib-recovered/04cfb4a');app=admin.app();db=admin.firestore();bucket=admin.storage().bucket();
 filePrototype=Object.getPrototypeOf(bucket.file('probe'));signOriginal=filePrototype.getSignedUrl;
 filePrototype.getSignedUrl=async function(){assert(this.name.startsWith('users/recovered-'));return ['https://legacy-emulator.invalid/'+encodeURIComponent(this.name)];};
 fetchOriginal=global.fetch;
 global.fetch=async(url,options)=>{
  if(String(url)==='https://api.openai.com/v1/chat/completions'){
   const body=JSON.parse(options.body);calls.push({provider:'openai',body});
   if(providerMode==='fail')return new Response('{}',{status:503});
   const text=body.temperature===0?raw:body.temperature===0.2?'保存した会話の要約':'授業記録に基づく回答';
   return new Response(JSON.stringify({choices:[{message:{content:text}}]}),{status:200});
  }
  if(String(url)==='https://api.groq.com/openai/v1/audio/transcriptions'){
   calls.push({provider:'groq',model:options.body.get('model')});
   if(providerMode==='fail')return new Response('{}',{status:503});
   const text=providerMode==='empty'?'':raw;
   return new Response(JSON.stringify({text,segments:[{text,start:0,end:10,avg_logprob:-0.2,no_speech_prob:0.01,compression_ratio:1}]}),{status:200});
  }
  const u=new URL(url);
  if(u.protocol!=='http:'||!['127.0.0.1','localhost','[::1]'].includes(u.hostname))throw Error('Recovered regression attempted real cloud transport');
  return fetchOriginal(url,options);
 };
});
after(async()=>{if(fetchOriginal)global.fetch=fetchOriginal;if(filePrototype)filePrototype.getSignedUrl=signOriginal;if(credential)credential.getAccessToken=tokenOriginal;delete process.env.OPENAI_API_KEY;delete process.env.GROQ_API_KEY;if(app)await app.delete();});
const call=(name,uid,data)=>api[name].run(data,{auth:uid?{uid,token:{}}:undefined});
async function quota(uid){const s=await db.collection(`privateUsage/${uid}/counters`).get();return s.docs.reduce((n,d)=>n+(d.get('count')||0),0);}
test('recovered source provenance: immutable historic file, not claimed as deployed production source',()=>{
 const p=require('../recovered/provenance.json');assert.equal(p.productionVersionVerified,false);assert.equal(p.deployable,false);
 assert.equal(createHash('sha256').update(readFileSync(require.resolve('../recovered/04cfb4a/index.ts'))).digest('hex'),p.sha256);
 assert.deepEqual(p.missing,['onAuthUserDelete','preDeleteCleanup','deleteAccountServerSide']);
});
test('recovered old AI/ASR: unauthenticated and invalid content/path rejected',{skip:!enabled},async()=>{
 await assert.rejects(call('askCourseAI',null,{prompt:'質問',transcript:'資料'}),e=>e.code==='unauthenticated');
 await assert.rejects(call('askCourseAI','recovered-ask',{prompt:'質問'}),e=>e.code==='invalid-argument');
 await assert.rejects(call('transcribeLectureAudio',null,{}),e=>e.code==='unauthenticated');
 await assert.rejects(call('transcribeLectureAudio','recovered-asr',{storagePath:'users/other/transcriptionUploads/a.m4a',durationSeconds:10}),e=>e.code==='invalid-argument');
});
test('recovered askCourseAI: answer, prior history, rolling summary, quota and AI input isolation',{skip:!enabled},async()=>{
 providerMode='ok';calls=[];const uid='recovered-ask',key='historic-course';
 for(let i=0;i<20;i++)await db.doc(`users/${uid}/courseChats/${key}/messages/${String(i).padStart(3,'0')}`).set({role:i%2?'assistant':'user',content:'旧会話'+i,createdAt:admin.firestore.Timestamp.fromMillis(i+1)});
 await db.doc('aiSources/recovered-independent').set({ownerUserId:uid,status:'ready',courseOfferingId:'2026:00004',activeRun:'kept'});
 const result=await call('askCourseAI',uid,{prompt:'授業の要約',transcript:'社会契約の根拠',courseKey:key});
 assert.equal(result.text,'授業記録に基づく回答');assert.equal(result.remainingGenerationsToday,9);
 assert(calls[0].body.messages.some(x=>x.content==='旧会話19'));
 assert.equal((await db.collection(`users/${uid}/courseChats/${key}/messages`).get()).size,22);
 const summary=await db.doc(`users/${uid}/courseChats/${key}`).get();assert.equal(summary.get('summary'),'保存した会話の要約');assert.equal(summary.get('summarizedMessageCount'),12);
 assert.equal((await db.doc('aiSources/recovered-independent').get()).get('activeRun'),'kept');
 assert.equal(await quota(uid),1);
});
test('recovered askCourseAI: provider failure refunds quota and does not write a new turn',{skip:!enabled},async()=>{
 providerMode='fail';const uid='recovered-ask';
 await assert.rejects(call('askCourseAI',uid,{prompt:'質問',transcript:'資料',courseKey:'historic-course'}),e=>e.code==='internal');
 assert.equal(await quota(uid),1);assert.equal((await db.collection(`users/${uid}/courseChats/historic-course/messages`).get()).size,22);
});
test('recovered transcription: owned temporary audio, Groq/cleanup, quota and raw deletion',{skip:!enabled},async()=>{
 providerMode='ok';calls=[];const uid='recovered-asr',path=`users/${uid}/transcriptionUploads/a.m4a`;
 await bucket.file(path).save('synthetic audio');
 const r=await call('transcribeLectureAudio',uid,{storagePath:path,durationSeconds:10,contextPrompt:'社会契約'});
 assert.equal(r.rawTranscript,raw);assert.equal(r.text,raw);assert.equal(r.remainingTranscriptionsThisMonth,9);assert.equal(r.model,'whisper-large-v3-turbo');
 assert(calls.some(x=>x.provider==='groq'));assert.equal((await bucket.file(path).exists())[0],false);assert.equal(await quota(uid),1);
});
test('recovered transcription: failed provider refunds quota and still deletes originals',{skip:!enabled},async()=>{
 providerMode='fail';delete process.env.OPENAI_API_KEY;const uid='recovered-asr',path=`users/${uid}/transcriptionUploads/failure.m4a`;
 await bucket.file(path).save('synthetic failure audio');
 await assert.rejects(call('transcribeLectureAudio',uid,{storagePath:path,durationSeconds:10}),e=>e.code==='resource-exhausted');
 assert.equal((await bucket.file(path).exists())[0],false);assert.equal(await quota(uid),1);process.env.OPENAI_API_KEY='emulator-placeholder';
});
