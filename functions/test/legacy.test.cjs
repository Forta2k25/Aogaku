const {test,before,after}=require('node:test'),assert=require('node:assert/strict');const admin=require('firebase-admin');
const enabled=!!process.env.FIRESTORE_EMULATOR_HOST;let api,app,send,originalSend,db;
before(()=>{if(!enabled)return;process.env.FIREBASE_CONFIG=JSON.stringify({projectId:'demo-aogaku-input',storageBucket:'demo-aogaku-input.appspot.com'});api=require('../lib/index');app=admin.app();db=admin.firestore();originalSend=admin.messaging().sendEachForMulticast;send=[];admin.messaging().sendEachForMulticast=async req=>{send.push(req);return {responses:req.tokens.map(()=>({success:true})),successCount:req.tokens.length,failureCount:0};};});
after(async()=>{if(app){admin.messaging().sendEachForMulticast=originalSend;await app.delete();}});
test('legacy friend notifications: request, accepted, duplicate suppression, cancellation',{skip:!enabled},async()=>{
 for(const uid of ['legacy-from','legacy-to']){await db.doc(`users/${uid}`).set({name:uid,id:uid});await db.doc(`users/${uid}/fcmTokens/fictional-token-${uid}`).set({});}
 const dummy={};await api.onIncomingRequest.run(dummy,{params:{targetUid:'legacy-to',fromUid:'legacy-from'}});
 assert.equal(send.length,1);assert.equal(send[0].notification.title,'友だち申請が届きました');
 await db.doc('users/legacy-from/friends/legacy-to').set({friendUid:'legacy-to'});
 await api.onFriendshipCreated.run(dummy,{params:{uid:'legacy-from',friendUid:'legacy-to'}});
 assert.equal(send.length,2);assert.equal(send[1].data.screen,'friends_list');
 await api.onFriendshipCreated.run(dummy,{params:{uid:'legacy-from',friendUid:'legacy-to'}});assert.equal(send.length,2);
 await api.onIncomingRequestDeleted.run(dummy,{params:{uid:'legacy-to',fromUid:'legacy-from'}});assert.equal(send.length,2);
 await api.onIncomingRequestDeleted.run(dummy,{params:{uid:'legacy-to',fromUid:'legacy-cancel'}});assert.equal(send.length,2);
});
