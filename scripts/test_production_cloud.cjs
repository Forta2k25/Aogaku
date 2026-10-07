const {test}=require('node:test');const assert=require('node:assert/strict');
const {assertRead,urls}=require('./production_cloud.cjs');
test('production read-only endpoints accept metadata only',()=>{for(const url of Object.values(urls))assert.doesNotThrow(()=>assertRead(url,url===urls.projectIAM?'POST':'GET'));});
test('production writes, data reads, credentials, other projects rejected',()=>{
 for(const method of ['POST','PUT','PATCH','DELETE'])assert.throws(()=>assertRead(urls.project,method));
 for(const url of [urls.secret+'/versions/latest:access',urls.bucket+'/o?alt=media',urls.project.replace('forta-aogaku','forta-aogaku-dev'),'https://asia-northeast1-forta-aogaku.cloudfunctions.net/askCourseAI','https://firestore.googleapis.com/v1/projects/forta-aogaku/databases/(default)/documents/users','https://oauth2.googleapis.com/token','https://storage.googleapis.com/storage/v1/b/forta-aogaku.firebasestorage.app.attacker'])assert.throws(()=>assertRead(url));
});
