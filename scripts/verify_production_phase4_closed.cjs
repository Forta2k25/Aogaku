#!/usr/bin/env node
// Rejection probes only. Fresh disposable Auth identities, no AI data/allowlist/queue activation.
// Passwords, Firebase ID tokens and public app keys remain in memory, never in receipts.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict'),{execFileSync}=require('node:child_process');
const phase=require('./deploy_production_phase4.cjs'),ROOT=path.resolve(__dirname,'..'),DIR=path.join(ROOT,'build/production-phase4'),P='forta-aogaku',D='forta-aogaku-dev';
const proof={phase:'4',status:'STARTED',runId:crypto.randomBytes(12).toString('hex'),allowedUIDs:[],sharingEnabled:false,probes:[],syntheticAccounts:[],realUsersUsed:0};
const save=()=>{fs.writeFileSync(path.join(DIR,'closed-rejection.json'),JSON.stringify(proof,null,2)+'\n',{mode:0o600});fs.chmodSync(path.join(DIR,'closed-rejection.json'),0o600);};
function validateToken(token,project,uid){const x=JSON.parse(Buffer.from(token.split('.')[1],'base64url').toString('utf8'));assert.equal(x.aud,project);assert.equal(x.iss,'https://securetoken.google.com/'+project);assert.equal(x.sub,uid);assert(x.exp>Date.now()/1000);}
async function main(){
 assert(!fs.existsSync(path.join(DIR,'closed-rejection.json')),'STOP: preserve existing rejection evidence');
 const installed=JSON.parse(fs.readFileSync(path.join(DIR,'execution.json')));assert.equal(installed.status,'CONTROL_PLANE_PASS');assert.deepEqual(installed.created,phase.NAMES);
 const cloud=require('./production_cloud.cjs');const before=await cloud.inspect();assert.equal(before.projectId,P);assert.equal(before.projectNumber,'505828754933');assert.equal(before.bucket.name,P+'.firebasestorage.app');
 const config=JSON.parse(execFileSync('python3',['-c',"import plistlib,json;from pathlib import Path;r=Path.cwd();prod=plistlib.load(open(r/'Aogaku/GoogleService-Info.plist','rb'));assert prod['PROJECT_ID']=='forta-aogaku' and prod['BUNDLE_ID']=='com.forta2k25.Aogaku' and prod['GCM_SENDER_ID']=='505828754933';dev=plistlib.load(open(r/'Config/Firebase/Development/GoogleService-Info.plist','rb'));assert dev['PROJECT_ID']=='forta-aogaku-dev' and dev['BUNDLE_ID']=='com.forta2k25.Aogaku.dev';print(json.dumps({'production':prod['API_KEY'],'development':dev['API_KEY']}))"],{cwd:ROOT,encoding:'utf8'}));
 const users=[];save();
 async function create(project,key,role){const password=crypto.randomBytes(32).toString('base64url'),email=`ai-phase4-${role}-${proof.runId}@example.test`;const r=await fetch('https://identitytoolkit.googleapis.com/v1/accounts:signUp?key='+encodeURIComponent(key),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email,password,returnSecureToken:true}),signal:AbortSignal.timeout(45000)});const d=await r.json();assert(r.ok,'Synthetic Auth signup HTTP '+r.status);validateToken(d.idToken,project,d.localId);const u={project,key,uid:d.localId,token:d.idToken,email};users.push(u);proof.syntheticAccounts.push({project,uid:u.uid,email,created:true,deleted:false});save();return u;}
 async function remove(u){validateToken(u.token,u.project,u.uid);assert(proof.syntheticAccounts.some(x=>x.project===u.project&&x.uid===u.uid));const r=await fetch('https://identitytoolkit.googleapis.com/v1/accounts:delete?key='+encodeURIComponent(u.key),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({idToken:u.token}),signal:AbortSignal.timeout(45000)});assert(r.ok,'Synthetic Auth cleanup HTTP '+r.status);proof.syntheticAccounts.find(x=>x.project===u.project&&x.uid===u.uid).deleted=true;save();}
 try{
  const ordinary=await create(P,config.production,'ordinary'),dev=await create(D,config.development,'dev-token');
  for(const n of phase.NAMES){const item=installed.verified[n];assert(item.closed&&item.region==='asia-northeast1');const urls=[item.uri,`https://asia-northeast1-${P}.cloudfunctions.net/${n}`];
   for(const endpoint of urls)for(const [profile,token]of [['anonymous',null],['ordinary-authenticated',ordinary.token],['dev-token',dev.token]]){
    const body=n==='aiRejectLateUpload'?{data:{name:'avatars/closed-probe-not-uploaded.jpg',bucket:P+'.firebasestorage.app'}}:{data:{databaseId:'aogaku-ai',sourceId:'0'.repeat(64)}};
    const r=await fetch(endpoint,{method:'POST',redirect:'error',headers:{'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{})},body:JSON.stringify(body),signal:AbortSignal.timeout(45000)});
    assert([401,403].includes(r.status),'STOP: closed HTTP admission unexpected '+n+' '+profile+' HTTP '+r.status);
    proof.probes.push({function:n,endpointType:endpoint===item.uri?'Cloud Run':'cloudfunctions.net',profile,httpStatus:r.status,denied:true});save();
   }
  }
  proof.status='PASS';proof.sourceSha256=installed.artifactSha256;console.log('Closed production rejection PASS: all AI12 x two endpoint forms x anonymous/valid production UID/valid Dev token; no AI usage enabled');
 }catch(e){proof.status='STOPPED';proof.error=e.message;throw e;}
 finally{for(const u of users){try{await remove(u);}catch(e){proof.status='STOPPED';proof.cleanupError=e.message;save();throw e;}}save();}
}
module.exports={validateToken};if(require.main===module)main().catch(e=>{console.error(e.message);process.exitCode=1});
