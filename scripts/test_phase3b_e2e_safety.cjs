const {test}=require('node:test'),assert=require('node:assert/strict');
const p=require('./production_phase3b_e2e.cjs');
const jwt=c=>'header.'+Buffer.from(JSON.stringify(c)).toString('base64url')+'.signature';
test('Production E2E JWT guard refuses Dev, other issuer, and other synthetic UID',()=>{
 const c={aud:'forta-aogaku',iss:'https://securetoken.google.com/forta-aogaku',sub:'fresh-synthetic'};
 p.jwt(jwt(c),'fresh-synthetic');
 for(const x of [{...c,aud:'forta-aogaku-dev'},{...c,iss:'https://securetoken.google.com/forta-aogaku-dev'},{...c,sub:'unregistered'}])assert.throws(()=>p.jwt(jwt(x),'fresh-synthetic'));
});
test('Production E2E fixture encoding preserves supported scalar and nested fields',()=>{
 for(const x of [null,'synthetic',true,3,{state:'deleted',count:0}])assert.deepEqual(p.decode(p.field(x)),x);
});
test('Stopped fixture cleanup refuses an unrelated UID, path, database or Task',()=>{
 const {validateRegistry}=require('./cleanup_phase3b_stopped_fixtures.cjs');
 const uid='syntheticAccountUid1234567890',other='syntheticControlUid123456789',run='synthetic-run';
 const reg={uids:[uid,other],paths:[{database:'aogaku-ai',path:'aiInputOwners/'+uid,uid}],objects:[{path:'ai-inputs/aogaku-ai/'+uid+'/orphan/original',uid}],tasks:[]};
 validateRegistry(reg,run);
 for(const bad of [
  {...reg,uids:[uid,uid]},
  {...reg,paths:[{database:'aogaku-ai',path:'aiInputOwners/unrelated',uid}]},
  {...reg,paths:[{database:'other',path:'aiInputOwners/'+uid,uid}]},
  {...reg,objects:[{path:'avatars/unrelated.jpg',uid}]},
  {...reg,tasks:[{id:'unrelated-task',uid}]}
 ])assert.throws(()=>validateRegistry(bad,run));
});
test('Installed slim deletion verification is scoped to its recorded mode and group',()=>{
 const {isPhase3bSlim}=require('./verify_legacy_install.cjs'),receipt={groups:{deletion:{mode:'phase3b-runtime-db-correction'}}};
 assert.equal(isPhase3bSlim('candidate','deletion',receipt),true);
 for(const [mode,group,r]of [['candidate','quota',receipt],['rollback-before-pilot','deletion',receipt],['candidate','deletion',{groups:{}}]])assert.equal(isPhase3bSlim(mode,group,r),false);
});
test('Stopped Auth fixture identity uses exact Firebase canonical email casing',()=>{
 const {expectedFixtureEmail}=require('./cleanup_phase3b_stopped_fixtures.cjs');
 assert.equal(expectedFixtureEmail('preDeleteCleanup','synthetic-run'),'ai-phase3b-predeletecleanup-synthetic-run@example.test');
 assert.notEqual(expectedFixtureEmail('preDeleteCleanup','synthetic-run'),expectedFixtureEmail('control','synthetic-run'));
 assert.notEqual(expectedFixtureEmail('preDeleteCleanup','synthetic-run'),expectedFixtureEmail('preDeleteCleanup','different-run'));
});
