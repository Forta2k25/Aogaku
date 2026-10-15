const {test,before,after}=require('node:test'),assert=require('node:assert/strict');
const admin=require('firebase-admin');
const {AI_DOCUMENT_PATHS}=require('../lib/ai/schema');
const enabled=!!process.env.FIRESTORE_EMULATOR_HOST&&!!process.env.STORAGE_EMULATOR_HOST;
let app,db,aidb;const project='demo-aogaku-input',bucket=project+'.appspot.com';
before(()=>{if(enabled){const credential=admin.credential.applicationDefault();credential.getAccessToken=async()=>({access_token:'emulator-only',expires_in:3600});app=admin.initializeApp({projectId:project,storageBucket:bucket,credential});db=require('firebase-admin/firestore').getFirestore(app,'(default)');aidb=require('firebase-admin/firestore').getFirestore(app,'aogaku-ai');}});
after(async()=>{if(app)await app.delete();});
function token(uid){return Buffer.from(JSON.stringify({alg:'none',typ:'JWT'})).toString('base64url')+'.'+Buffer.from(JSON.stringify({sub:uid,user_id:uid,aud:project,iss:`https://securetoken.google.com/${project}`,iat:Math.floor(Date.now()/1000),exp:Math.floor(Date.now()/1000)+3600,auth_time:Math.floor(Date.now()/1000),firebase:{sign_in_provider:'custom'}})).toString('base64url')+'.';}
const url=(path,database='(default)')=>`http://${process.env.FIRESTORE_EMULATOR_HOST}/v1/projects/${project}/databases/${database}/documents/${path}`;
async function firestore(path,uid,method='GET',fields,database='(default)'){return fetch(url(path,database),{method,headers:{...(uid?{Authorization:'Bearer '+token(uid)}:{}),'Content-Type':'application/json'},...(fields?{body:JSON.stringify({fields})}:{})});}
const str=x=>({stringValue:x});
test('production Rules regression: public catalog/search, reviews, career, circles',{skip:!enabled},async()=>{
 for(const path of ['classes/99101','circle/reg-circle','careerListings/reg-career']){await db.doc(path).set({name:'fictional'});assert.equal((await firestore(path)).status,200);assert.equal((await firestore(path,'reg-owner','PATCH',{name:str('changed')})).status,403);}
 assert.equal((await firestore('classes/99101/entries/reg-owner','reg-owner','PATCH',{review:str('review')})).status,200);
 assert.equal((await firestore('classes/99101/entries/reg-owner')).status,200);
 assert.equal((await firestore('classes/99101/entries/reg-owner','reg-outsider','PATCH',{review:str('bad')})).status,403);
 assert.equal((await firestore('classReviews/99101/entries/reg-owner','reg-owner','PATCH',{review:str('review')})).status,200);
 assert.equal((await firestore('classReviews/99101/entries/reg-owner')).status,200);
 assert.equal((await firestore('classReviews/99101/entries/reg-owner','reg-outsider','PATCH',{review:str('bad')})).status,403);
 assert.equal((await firestore('classReviews/99101/entries')).status,200);
});
test('production Rules regression: public entries collectionGroup query remains allowed',{skip:!enabled},async()=>{
 await db.doc('classReviews/99102/entries/reg-group-review').set({review:'fictional'});
 const query={structuredQuery:{from:[{collectionId:'entries',allDescendants:true}],limit:10}};
 const response=await fetch(url('').replace(/\/$/,':runQuery'),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(query)});
 assert.equal(response.status,200,'legacy public collectionGroup query changed');
});
test('production Rules regression: lectureNotes, timetable, fcmTokens, friends requests',{skip:!enabled},async()=>{
 await db.doc('users/reg-owner').set({id:'regowner'});await db.doc('users/reg-outsider').set({id:'outsider'});
 assert.equal((await firestore('users/reg-owner')).status,200);
 for(const path of ['users/reg-owner/lectureNotes/reg-note','users/reg-owner/fcmTokens/reg-token','users/reg-owner/timetable/2026-fall']){
  assert.equal((await firestore(path,'reg-owner','PATCH',{text:str('mine')})).status,200);
  assert.equal((await firestore(path,'reg-owner')).status,200);
  assert.equal((await firestore(path,'reg-outsider')).status,403);
  assert.equal((await firestore(path,'reg-outsider','PATCH',{text:str('bad')})).status,403);
 }
 await db.doc('users/reg-owner/friends/reg-friend').set({friendUid:'reg-friend'});
 assert.equal((await firestore('users/reg-owner/timetable/2026-fall','reg-friend')).status,200);
 assert.equal((await firestore('users/reg-owner/friends/reg-friend','reg-owner')).status,200);
 assert.equal((await firestore('users/reg-owner/friends/reg-friend','reg-outsider')).status,403);
 // request.time cannot be forged: Firestore commit REQUEST_TIME transform.
 const commit=`http://${process.env.FIRESTORE_EMULATOR_HOST}/v1/projects/${project}/databases/(default)/documents:commit`;
 const req={writes:[{update:{name:`projects/${project}/databases/(default)/documents/users/reg-outsider/requestsIncoming/reg-owner`,fields:{senderUid:str('reg-owner'),status:str('pending')}},updateTransforms:[{fieldPath:'createdAt',setToServerValue:'REQUEST_TIME'}]}]};
 assert.equal((await fetch(commit,{method:'POST',headers:{Authorization:'Bearer '+token('reg-owner'),'Content-Type':'application/json'},body:JSON.stringify(req)})).status,200);
 assert.equal((await firestore('users/reg-outsider/requestsIncoming/reg-owner','reg-outsider')).status,200);
 assert.equal((await firestore('users/reg-outsider/requestsIncoming/reg-owner','reg-friend')).status,403);
});
test('production Rules regression: every registered AI schema path remains client-denied',{skip:!enabled},async()=>{
 for(const template of AI_DOCUMENT_PATHS){
  const path=template.replace(/\{[^}]+\}/g,'reg-owner');
  await aidb.doc(path).set({ownerUserId:'reg-owner'});
  for(const uid of [null,'reg-owner','reg-outsider']){
   assert.equal((await firestore(path,uid,'GET',undefined,'aogaku-ai')).status,403,`schema read: ${path}`);
   assert.equal((await firestore(path,uid,'PATCH',{state:str('verified')},'aogaku-ai')).status,403,`schema write: ${path}`);
   assert.equal((await firestore(path,uid,'DELETE',undefined,'aogaku-ai')).status,403,`schema delete: ${path}`);
  }
 }
});
// These paths are malicious probes, not AI fixtures/schema. Retain this strict
// assertion: renaming canonical collections cannot enforce arbitrary path deny.
test('production security boundary: arbitrary AI nested entries must not bypass deny through review wildcard',{skip:!enabled},async()=>{
 const violations=[];
 for(const root of ['aiSources','aiCourseOfferings','aiUsage','aiInputOwners','aiMaintenance']){
  const path=`${root}/reg-ai/entries/reg-owner`;
  // Client creates the unsupported path itself. No Admin seeding needed.
  const created=(await firestore(path,'reg-owner','PATCH',{text:str('bypass')},'aogaku-ai')).status;
  if(created!==403)violations.push({path,operation:'client create',status:created});
  for(const uid of [null,'reg-owner','reg-outsider']){
   const status=(await firestore(path,uid,'GET',undefined,'aogaku-ai')).status;
   if(status!==403)violations.push({path,operation:'read',uid,status});
  }
 }
 assert.deepEqual(violations,[],'schema naming cannot restrict client-created entries paths');
});
async function storage(name,uid,method='POST'){
 const base=`${process.env.STORAGE_EMULATOR_HOST.startsWith("http")?process.env.STORAGE_EMULATOR_HOST:"http://"+process.env.STORAGE_EMULATOR_HOST}/v0/b/${bucket}/o`;
 return fetch(method==='POST'?base+'?uploadType=media&name='+encodeURIComponent(name):base+'/'+encodeURIComponent(name)+'?alt=media',{method,headers:{...(uid?{Authorization:'Bearer '+token(uid)}:{}),'Content-Type':'image/jpeg'},...(method==='POST'?{body:Buffer.from('fixture')}:{})});
}
test('production Storage regression: avatars unchanged, AI direct uploads/downloads denied',{skip:!enabled},async()=>{
 assert.equal((await storage('avatars/reg-owner.jpg','reg-owner')).status,200);
 assert.equal((await storage('avatars/reg-owner.jpg','reg-friend','GET')).status,200);
 assert.equal((await storage('avatars/reg-owner.jpg',null,'GET')).status,403);
 assert.equal((await storage('avatars/reg-owner.jpg','reg-outsider')).status,403);
 for(const name of ['ai-inputs/aogaku-ai/reg-owner/raw/original','ai-derived/aogaku-ai/reg-owner/raw/extraction.json']){await admin.storage().bucket().file(name).save('fixture');assert.equal((await storage(name,'reg-owner')).status,403);assert.equal((await storage(name,'reg-owner','GET')).status,403);}
});
