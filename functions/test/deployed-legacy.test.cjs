// Verified deployed sources + proposed adapters; real local database/storage, stub transports only.
const {test,before,after}=require('node:test'),assert=require('node:assert/strict');
const fs=require('fs'),path=require('path'),crypto=require('crypto'),admin=require('firebase-admin');
const enabled=!!process.env.FIRESTORE_EMULATOR_HOST&&!!process.env.STORAGE_EMULATOR_HOST;
let original,originalAccount,adapted,account,ai,db,aidb,bucket,app,fetchOriginal,credential,tokenOriginal,fp,signOriginal,tp,deleteTaskOriginal,getUserOriginal,deleteUserOriginal,sendOriginal;
const deleted=new Set(),cancelled=[],notifications=[];let mode='ok',onProvider,calls=[];
const raw='社会契約と自由について授業で説明しました。';
before(()=>{
 if(!enabled)return;process.env.FIREBASE_CONFIG=JSON.stringify({projectId:'demo-aogaku-input',storageBucket:'demo-aogaku-input.appspot.com'});
 process.env.OPENAI_API_KEY='emulator-placeholder';process.env.GROQ_API_KEY='emulator-placeholder';process.env.AI_SHARING_ENABLED='false';
 credential=admin.credential.applicationDefault();tokenOriginal=credential.getAccessToken;credential.getAccessToken=async()=>({access_token:'emulator-only',expires_in:3600});
 original=require('../recovered/deployed/12ed370d671b/lib/index.js');app=admin.app();db=require('firebase-admin/firestore').getFirestore(app,'(default)');aidb=require('firebase-admin/firestore').getFirestore(app,'aogaku-ai');bucket=admin.storage().bucket();
 ai=require('../lib/ai');adapted=require('../lib/legacy-ai');account=require('../lib/account-deletion-entry');
 // SDK5 deployed root import maps to the explicit SDK6 v1 compatibility entry only in memory.
 const Module=require('module'),file=path.resolve(__dirname,'../recovered/deployed/aad2425fe638/index.js');
 const moduleCopy=new Module(file,module);moduleCopy.filename=file;moduleCopy.paths=Module._nodeModulePaths(path.dirname(file));moduleCopy._compile(fs.readFileSync(file,'utf8').replace("require('firebase-functions')","require('firebase-functions/v1')"),file);originalAccount=moduleCopy.exports;
 getUserOriginal=admin.auth().getUser;deleteUserOriginal=admin.auth().deleteUser;
 admin.auth().getUser=async uid=>{if(deleted.has(uid))throw Object.assign(Error('deleted'),{code:'auth/user-not-found'});return {uid,disabled:false};};admin.auth().deleteUser=async uid=>{deleted.add(uid);};
 fp=Object.getPrototypeOf(bucket.file('probe'));signOriginal=fp.getSignedUrl;fp.getSignedUrl=async function(){assert(this.name.startsWith('users/deployed-'));return ['https://emulator.invalid/'+encodeURIComponent(this.name)];};
 tp=Object.getPrototypeOf(require('firebase-admin/functions').getFunctions().taskQueue('aiProcessSource'));deleteTaskOriginal=tp.delete;tp.delete=async id=>cancelled.push(id);
 sendOriginal=admin.messaging().sendEachForMulticast;admin.messaging().sendEachForMulticast=async req=>{notifications.push(req);return {responses:req.tokens.map(()=>({success:true})),successCount:req.tokens.length,failureCount:0};};
 fetchOriginal=global.fetch;global.fetch=async(url,options)=>{
  if(String(url)==='https://api.openai.com/v1/chat/completions'){const body=JSON.parse(options.body);calls.push(body);if(onProvider){const f=onProvider;onProvider=null;await f();}if(mode==='fail')return new Response('{}',{status:503});return new Response(JSON.stringify({choices:[{message:{content:body.temperature===0?raw:'授業記録に基づく回答'}}]}));}
  if(String(url)==='https://api.groq.com/openai/v1/audio/transcriptions'){if(onProvider){const f=onProvider;onProvider=null;await f();}if(mode==='fail')return new Response('{}',{status:503});return new Response(JSON.stringify({text:raw,segments:[{text:raw,start:0,end:10,avg_logprob:-0.2,no_speech_prob:0.01,compression_ratio:1}]}));}
  const u=new URL(url);if(u.protocol!=='http:'||!['127.0.0.1','localhost','[::1]'].includes(u.hostname))throw Error('Real cloud transport forbidden in regression');return fetchOriginal(url,options);
 };
});
after(async()=>{if(fetchOriginal)global.fetch=fetchOriginal;if(fp)fp.getSignedUrl=signOriginal;if(tp)tp.delete=deleteTaskOriginal;if(app){admin.auth().getUser=getUserOriginal;admin.auth().deleteUser=deleteUserOriginal;admin.messaging().sendEachForMulticast=sendOriginal;await app.delete();}if(credential)credential.getAccessToken=tokenOriginal;});
const oldCall=(api,name,uid,data)=>api[name].run(data,{auth:{uid,token:{auth_time:Math.floor(Date.now()/1000)}}});
const delCall=(name,uid,data={},age=0)=>account[name].run({data,auth:{uid,token:{auth_time:Math.floor(Date.now()/1000)-age}}});
async function count(uid){return (await db.collection(`privateUsage/${uid}/counters`).get()).docs.reduce((n,d)=>n+(d.get('count')||0),0);}
async function seed(uid){
 await db.doc(`users/${uid}`).set({idLower:uid});await db.doc(`usernames/${uid}`).set({uid});
 await db.doc(`users/${uid}/courseChats/c/messages/m`).set({content:'old conversation'});await db.doc(`users/${uid}/lectureNotes/c/nested/n`).set({text:'old note'});
 await db.doc(`users/deployed-other/friends/${uid}`).set({friendUid:uid});await db.doc(`users/deployed-other/friends/kept`).set({friendUid:'kept'});
 await aidb.doc(`aiSources/${uid}`).set({sourceId:uid,ownerUserId:uid,status:'queued',storagePath:`ai-inputs/aogaku-ai/${uid}/${uid}/original`,courseOfferingId:'2026:00004'});
 await aidb.doc(`aiSources/${uid}/runs/r/chunks/c`).set({text:'evidence'});await aidb.doc(`aiSources/${uid}/jobs/${uid}-task`).set({taskId:uid+'-task'});
 await aidb.doc(`aiUsage/${uid}/periods/day`).set({count:1});await db.doc(`privateUsage/${uid}/counters/month`).set({count:1});
 for(const p of [`ai-inputs/aogaku-ai/${uid}/${uid}/original`,`ai-derived/aogaku-ai/${uid}/${uid}/page`,`avatars/${uid}.jpg`,`users/${uid}/transcriptionUploads/old.m4a`])await bucket.file(p).save('synthetic');
}
async function absent(uid){
 assert.equal((await aidb.doc(`aiSources/${uid}`).get()).get('status'),'deleted');assert.equal((await aidb.collection(`aiSources/${uid}/runs/r/chunks`).get()).size,0);assert.equal((await aidb.collection(`aiSources/${uid}/jobs`).get()).size,0);assert(cancelled.includes(uid+'-task'));assert.equal((await aidb.collection(`aiUsage/${uid}/periods`).get()).size,0);
 assert.equal((await bucket.getFiles({prefix:`ai-inputs/aogaku-ai/${uid}/`}))[0].length,0);assert.equal((await bucket.getFiles({prefix:`ai-derived/aogaku-ai/${uid}/`}))[0].length,0);
 assert((await db.doc('users/deployed-other/friends/kept').get()).exists);
}
test('deployed provenance: all nine functions recovered, code hash exact, verified runtime version',()=>{
 const p=require('../recovered/deployed/provenance.json');assert.equal(p.records.length,9);assert.equal(p.cloudWrites,0);
 for(const r of p.records){assert.equal(r.productionVersionVerified,true);const code=fs.readFileSync(path.resolve(__dirname,'../..',r.sourceDirectory,r.main));assert.equal(crypto.createHash('sha256').update(code).digest('hex'),r.codeSha256);}
});
test('deployed old AI: original/adapted answer and quota contract match; deployed version does not persist history',{skip:!enabled},async()=>{
 mode='ok';for(const [api,uid]of [[original,'deployed-orig-ask'],[adapted,'deployed-new-ask']]){calls=[];const r=await oldCall(api,'askCourseAI',uid,{prompt:'要約してください',transcript:raw,courseKey:'ignored'});assert.deepEqual(r,{text:'授業記録に基づく回答',remainingGenerationsToday:9});assert.equal(calls[0].model,'gpt-4o-mini');assert.equal(calls[0].messages.length,2);assert.equal((await db.collection(`users/${uid}/courseChats`).get()).size,0);assert.equal(await count(uid),1);
 mode='fail';await assert.rejects(oldCall(api,'askCourseAI',uid,{prompt:'質問',transcript:raw}),e=>e.code==='internal');assert.equal(await count(uid),1);mode='ok';}
});
test('deployed old transcription: original/adapted Groq quality, cleanup, return values and refund match',{skip:!enabled},async()=>{
 for(const [api,uid]of [[original,'deployed-orig-asr'],[adapted,'deployed-new-asr']]){mode='ok';let p=`users/${uid}/transcriptionUploads/a.m4a`;await bucket.file(p).save('synthetic');const r=await oldCall(api,'transcribeLectureAudio',uid,{storagePath:p,durationSeconds:10});assert.equal(r.rawTranscript,raw);assert.equal(r.text,raw);assert.equal(r.remainingTranscriptionsThisMonth,9);assert.equal(r.model,'whisper-large-v3-turbo');assert.equal((await bucket.file(p).exists())[0],false);
 mode='fail';delete process.env.OPENAI_API_KEY;p=`users/${uid}/transcriptionUploads/f.m4a`;await bucket.file(p).save('synthetic');await assert.rejects(oldCall(api,'transcribeLectureAudio',uid,{storagePath:p,durationSeconds:10}),e=>e.code==='resource-exhausted');assert.equal(await count(uid),1);assert.equal((await bucket.file(p).exists())[0],false);process.env.OPENAI_API_KEY='emulator-placeholder';}
 mode='ok';
});
test('deployed friend functions: request/accept/duplicate/cancel remain identical',{skip:!enabled},async()=>{
 for(const [api,suffix]of [[original,'orig'],[adapted,'new']]){notifications.length=0;const from='deployed-friend-from-'+suffix,to='deployed-friend-to-'+suffix;for(const uid of [from,to]){await db.doc(`users/${uid}`).set({name:uid});await db.doc(`users/${uid}/fcmTokens/fictional`).set({});}
 await api.onIncomingRequest.run({},{params:{targetUid:to,fromUid:from}});assert.equal(notifications[0].data.screen,'friend_requests');await db.doc(`users/${from}/friends/${to}`).set({friendUid:to});await api.onFriendshipCreated.run({},{params:{uid:from,friendUid:to}});assert.equal(notifications[1].data.screen,'friends_list');await api.onIncomingRequestDeleted.run({},{params:{uid:from,fromUid:to}});await api.onFriendshipCreated.run({},{params:{uid:from,friendUid:to}});await api.onIncomingRequestDeleted.run({},{params:{uid:from,fromUid:'cancelled'}});assert.equal(notifications.length,2);}
});
test('formal deletion: preDelete rejects stale/other account; fresh auth blocks all AI before Auth deletion',{skip:!enabled},async()=>{
 const uid='deployed-predelete';await seed(uid);await assert.rejects(delCall('preDeleteCleanup',uid,{uid:'other'}),e=>e.code==='permission-denied');await assert.rejects(delCall('preDeleteCleanup',uid,{},600),e=>e.code==='failed-precondition');assert.equal((await aidb.doc(`aiInputOwners/${uid}`).get()).exists,false);
 assert.deepEqual(await delCall('preDeleteCleanup',uid),{ok:true,aiAccountDeletionVersion:1});assert.equal(deleted.has(uid),false);await absent(uid);
 await assert.rejects(ai.aiRetrieveContext.run({auth:{uid},data:{courseOfferingId:'2026:00004',query:'資料'}}),e=>e.message==='ACCOUNT_DELETED');
 await assert.rejects(oldCall(adapted,'askCourseAI',uid,{prompt:'質問',transcript:raw}),e=>e.message==='ACCOUNT_DELETED');
 await account.onAuthUserDelete.run({uid});assert.equal((await db.collection(`privateUsage/${uid}/counters`).get()).size,0);assert.equal((await db.collection(`users/${uid}/courseChats/c/messages`).get()).size,0);assert.equal((await bucket.getFiles({prefix:`users/${uid}/transcriptionUploads/`}))[0].length,0);
});
test('formal deletion: server side + direct Auth trigger preserve legacy cleanup and erase nested AI/usage',{skip:!enabled},async()=>{
 for(const [uid,server]of [['deployed-server-delete',true],['deployed-trigger-delete',false]]){await seed(uid);if(server){assert.deepEqual(await delCall('deleteAccountServerSide',uid),{ok:true});assert(deleted.has(uid));}else{deleted.add(uid);await account.onAuthUserDelete.run({uid});}await absent(uid);assert.equal((await db.collection(`privateUsage/${uid}/counters`).get()).size,0);assert.equal((await db.collection(`users/${uid}/lectureNotes/c/nested`).get()).size,0);assert.equal((await db.doc(`usernames/${uid}`).get()).exists,false);assert.equal((await bucket.file(`avatars/${uid}.jpg`).exists())[0],false);}
});
test('deletion callback finishes all pages and missing-parent memberships without Scheduler',{skip:!enabled},async()=>{
 const uid='deployed-complete-pages',other='deployed-pages-control';
 for(let i=0;i<26;i++){
  const id=uid+'-'+String(i).padStart(2,'0');
  await aidb.doc(`aiSources/${id}`).set({sourceId:id,ownerUserId:uid,status:'queued',noteText:'private'});
  await aidb.doc(`aiSources/${id}/runs/r/chunks/c`).set({text:'private'});
 }
 for(let i=0;i<101;i++)await aidb.doc(`aiCourseOfferings/missing-${i}/memberships/${uid}`).set({userId:uid});
 await aidb.doc(`aiCourseOfferings/missing-control/memberships/${other}`).set({userId:other});
 await aidb.doc(`aiUsage/${uid}/periods/day`).set({count:26});
 await db.doc(`privateUsage/${uid}/counters/day`).set({count:26});
 await aidb.doc('aiMaintenance/accountSweep').set({after:uid,unrelated:'keep'});
 for(const root of ['ai-inputs','ai-derived']){
  await bucket.file(`${root}/aogaku-ai/${uid}/orphan/payload`).save('private');
  await bucket.file(`${root}/aogaku-ai/${other}/keep/payload`).save('keep');
 }
 await delCall('preDeleteCleanup',uid);
 assert.equal((await aidb.doc(`aiInputOwners/${uid}`).get()).get('state'),'deleted');
 assert.equal((await db.doc(`accountDeletionFences/${uid}`).get()).get('state'),'deleted');
 assert.equal((await aidb.collectionGroup('memberships').where('userId','==',uid).get()).size,0);
 assert((await aidb.doc(`aiCourseOfferings/missing-control/memberships/${other}`).get()).exists);
 assert.equal((await aidb.doc('aiMaintenance/accountSweep').get()).get('after'),null);
 assert.equal((await aidb.doc('aiMaintenance/accountSweep').get()).get('unrelated'),'keep');
 assert.equal(await count(uid),0);
 for(const root of ['ai-inputs','ai-derived']){
  assert.equal((await bucket.getFiles({prefix:`${root}/aogaku-ai/${uid}/`}))[0].length,0);
  assert((await bucket.file(`${root}/aogaku-ai/${other}/keep/payload`).exists())[0]);
 }
 for(const d of (await aidb.collection('aiSources').where('ownerUserId','==',uid).get()).docs){
  assert.deepEqual(Object.keys(d.data()).sort(),['ownerUserId','sourceId','status','updatedAt']);
  assert.equal((await d.ref.collection('runs').get()).size,0);
 }
 await aidb.doc('aiMaintenance/accountSweep').set({after:other,unrelated:'keep'});
 await account.onAuthUserDelete.run({uid});
 assert.equal((await aidb.doc('aiMaintenance/accountSweep').get()).get('after'),other);
});
test('in-flight old AI failure/refund after deletion cannot recreate quota/usage/user tree',{skip:!enabled},async()=>{
 const uid='deployed-ask-race';mode='fail';onProvider=async()=>{await delCall('deleteAccountServerSide',uid);};await assert.rejects(oldCall(adapted,'askCourseAI',uid,{prompt:'質問',transcript:raw}),e=>e.code==='internal');assert.equal(await count(uid),0);assert.equal((await db.doc(`privateUsage/${uid}`).get()).exists,false);mode='ok';
});
test('in-flight old transcription failure/refund after deletion cannot recreate quota/raw/usage',{skip:!enabled},async()=>{
 const uid='deployed-asr-race',p=`users/${uid}/transcriptionUploads/a.m4a`;await bucket.file(p).save('synthetic');mode='fail';delete process.env.OPENAI_API_KEY;onProvider=async()=>{await delCall('deleteAccountServerSide',uid);};await assert.rejects(oldCall(adapted,'transcribeLectureAudio',uid,{storagePath:p,durationSeconds:10}),e=>e.code==='resource-exhausted');assert.equal(await count(uid),0);assert.equal((await bucket.file(p).exists())[0],false);assert.equal((await db.doc(`privateUsage/${uid}`).get()).exists,false);mode='ok';process.env.OPENAI_API_KEY='emulator-placeholder';
});

test('deployed account handlers: baseline legacy cross-links/avatars/usernames/Auth contracts preserved by adapter',{skip:!enabled},async()=>{
 const uid='deployed-baseline-delete';await seed(uid);assert.deepEqual(await originalAccount.preDeleteCleanup.run({data:{uid},auth:{uid,token:{}}}),{ok:true});assert.equal((await db.doc(`users/deployed-other/friends/${uid}`).get()).exists,false);assert.equal((await bucket.file(`avatars/${uid}.jpg`).exists())[0],false);assert.equal((await db.doc(`usernames/${uid}`).get()).exists,false);
 await originalAccount.onAuthUserDelete.run({uid});assert.equal((await db.doc(`users/${uid}`).get()).exists,false);
 // Baseline leaves AI sources intact: this is the precise new helper responsibility.
 assert.equal((await aidb.doc(`aiSources/${uid}`).get()).get('status'),'queued');
 assert.deepEqual(await delCall('deleteAccountServerSide',uid),{ok:true});await absent(uid);assert.equal(await count(uid),0);
});

test('deployed reaction paper: original/adapted output/shared quota contract; late failure cannot regenerate quota',{skip:!enabled},async()=>{
 mode='ok';for(const [api,uid]of [[original,'deployed-orig-paper'],[adapted,'deployed-new-paper']]){const r=await oldCall(api,'generateReactionPaper',uid,{transcript:raw,targetLength:400});assert.deepEqual(r,{text:'授業記録に基づく回答',remainingGenerationsToday:9});assert.equal(await count(uid),1);}
 const uid='deployed-paper-race';mode='fail';onProvider=async()=>{await delCall('deleteAccountServerSide',uid);};await assert.rejects(oldCall(adapted,'generateReactionPaper',uid,{transcript:raw}),e=>e.code==='internal');assert.equal(await count(uid),0);mode='ok';
});

test('account cleanup resumes across 25-source pages and remains closed to late workers',{skip:!enabled},async()=>{
 const uid='deployed-paged-owner';await aidb.doc(`aiUsage/${uid}/periods/day`).set({count:30});
 for(let i=0;i<30;i++){const id='deployed-paged-'+String(i).padStart(2,'0');await aidb.doc(`aiSources/${id}`).set({sourceId:id,ownerUserId:uid,status:'ready',noteText:'sensitive',courseOfferingId:'2026:00004'});await aidb.doc(`aiSources/${id}/runs/r/chunks/c`).set({text:'sensitive'});}
 await ai.beginAIAccountDeletion(uid);assert.equal((await aidb.doc(`aiInputOwners/${uid}`).get()).get('state'),'deleting');
 await assert.rejects(ai.aiListSources.run({auth:{uid},data:{}}),e=>e.message==='ACCOUNT_DELETED');
 await ai.continueAIAccountDeletion(uid);assert.equal((await aidb.doc(`aiInputOwners/${uid}`).get()).get('state'),'deleted');assert.equal((await aidb.collection(`aiUsage/${uid}/periods`).get()).size,0);
 for(let i=0;i<30;i++){const id='deployed-paged-'+String(i).padStart(2,'0');await ai.aiProcessSource.run({data:{databaseId:'aogaku-ai',sourceId:id}});const s=await aidb.doc(`aiSources/${id}`).get();assert.equal(s.get('status'),'deleted');assert.equal(s.get('noteText'),undefined);assert.equal((await aidb.collection(`aiSources/${id}/runs/r/chunks`).get()).size,0);}
});
