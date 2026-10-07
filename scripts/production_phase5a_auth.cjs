#!/usr/bin/env node
// One separately approved disposable non-allowed Auth account. Never allowlisted.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto'),c=require('./production_phase5a_common.cjs');
async function main(action){assert(['create-outsider','cleanup-outsider'].includes(action));assert.equal(c.load('preflight/closed-live').status,'PHASE5A_PREFLIGHT_PASS');
 if(action==='create-outsider'){
  assert.equal(c.load('execution').status,'BASELINE_PASS');await c.auth('pilot');assert(!fs.existsSync(path.join(c.DIR,'outsider-registry.json')),'STOP: no repeated signup');
  c.save('outsider-registry',{status:'SIGNUP_ATTEMPTED',attemptedAt:new Date().toISOString(),authority:'Human explicitly approved one disposable non-allowed Auth UID creation and cleanup',allowlisted:false,fixtureSourcesCreated:0});
  const email='phase5a-denied-'+crypto.randomUUID()+'@example.test',password=crypto.randomBytes(32).toString('base64url');
  const r=await fetch('https://identitytoolkit.googleapis.com/v1/accounts:signUp?key='+encodeURIComponent(c.apiKey()),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email,password,returnSecureToken:true}),signal:AbortSignal.timeout(45000)});assert(r.ok,'Disposable signup HTTP '+r.status);const d=await r.json();c.jwt(d.idToken,d.localId);assert.notEqual(d.localId,c.operator().allowedUIDs[0]);
  fs.writeFileSync(path.join(c.DIR,'outsider-auth.json'),JSON.stringify({idToken:d.idToken,refreshToken:d.refreshToken,expiresAt:Date.now()/1000+Number(d.expiresIn),projectId:c.P})+'\n',{mode:0o600});
  c.save('outsider-registry',{status:'CREATED',uidHash:c.hash(d.localId),createdAt:new Date().toISOString(),allowlisted:false,fixtureSourcesCreated:0});console.log('One disposable non-allowed Auth account created; UID masked; not allowlisted; no document/Storage fixture');return;
 }
 const reg=c.load('outsider-registry');assert.equal(reg.status,'CREATED');const a=await c.auth('outsider');assert.notEqual(a.uid,c.operator().allowedUIDs[0]);assert.equal(c.hash(a.uid),reg.uidHash);assert.equal(c.load('gates').status,'PASS');assert.equal(c.load('e2e').permissions.status,'PASS');
 const target=path.join(c.DIR,'outsider-cleanup-target.json');assert(!fs.existsSync(target));fs.writeFileSync(target,JSON.stringify({projectId:c.P,uid:a.uid,uidHash:reg.uidHash,pilotExcluded:true})+'\n',{mode:0o600});
 // Admin deletion of this registered disposable UID avoids requiring the
 // long-running test's client session to have a recent password sign-in.
 // No IAM extension; target project and localId are exact, not an inventory.
 reg.status='DELETE_ATTEMPTED';c.save('outsider-registry',reg);const r=await fetch(`https://identitytoolkit.googleapis.com/v1/projects/${c.P}/accounts:delete`,{method:'POST',redirect:'error',headers:{Authorization:'Bearer '+await c.cloud.oauth(),'Content-Type':'application/json'},body:JSON.stringify({localId:a.uid}),signal:AbortSignal.timeout(45000)});assert(r.ok,'Disposable cleanup HTTP '+r.status);reg.status='DELETED';reg.deletedAt=new Date().toISOString();c.save('outsider-registry',reg);fs.unlinkSync(path.join(c.DIR,'outsider-auth.json'));console.log('Only registered non-allowed disposable Auth account deleted; pilot untouched. Normal deletion handler may retain its minimal tombstones; no deletion-race E2E invoked.');
}
if(require.main===module)main(process.argv[2]).catch(e=>{console.error('STOP: '+c.masked(e.message));process.exitCode=1;});
