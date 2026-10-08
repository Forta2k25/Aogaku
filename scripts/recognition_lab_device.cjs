#!/usr/bin/env node
// Dev-only anonymous provider setup / exact device admission. No production requests or credential logging.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),cp=require('node:child_process');
process.env.FIREBASE_TOOLS_LIB ||= path.dirname(path.dirname(fs.realpathSync(cp.execFileSync('which',['firebase'],{encoding:'utf8'}).trim())));
const c=require('./dev_cloud.cjs');
async function authConfig(method='GET',body) {
 c.guard();
 const url=`https://identitytoolkit.googleapis.com/admin/v2/projects/${c.PROJECT}/config`+(method==='PATCH'?'?updateMask=signIn.anonymous.enabled':'');
 const r=await fetch(url,{method,headers:{Authorization:`Bearer ${await c.token()}`,'Content-Type':'application/json'},...(body?{body:JSON.stringify(body)}:{})});
 const value=await r.json();assert(r.ok,`Dev Auth config HTTP ${r.status}`);
 assert([`projects/${c.PROJECT}/config`,`projects/${c.NUMBER}/config`].includes(value.name),'Unexpected Auth project');return value;
}
async function enableAnonymous() {
 const before=await authConfig();
 if(!before.signIn?.anonymous?.enabled)await authConfig('PATCH',{signIn:{anonymous:{enabled:true}}});
 const after=await authConfig();assert.equal(after.signIn.anonymous.enabled,true);
 const old=structuredClone(before),now=structuredClone(after);
 if(now.signIn.anonymous){delete now.signIn.anonymous.enabled;if(!Object.keys(now.signIn.anonymous).length)delete now.signIn.anonymous;}
 if(old.signIn?.anonymous){delete old.signIn.anonymous.enabled;if(!Object.keys(old.signIn.anonymous).length)delete old.signIn.anonymous;}
 assert.deepEqual(now,old,'Unexpected Dev Auth config drift');
 console.log('PASS: Dev Anonymous enabled; other Auth settings unchanged; no Function update.');
}
async function manifest(name) {
 const d=await c.request(`https://cloudfunctions.googleapis.com/v2/${name}:generateDownloadUrl`,'POST',{});
 const u=new URL(d.downloadUrl);assert(u.protocol==='https:'&&(u.hostname==='storage.googleapis.com'||u.hostname.endsWith('.storage.googleapis.com')));
 const response=await fetch(u);assert(response.ok,'Source download failed');const bytes=Buffer.from(await response.arrayBuffer());assert(bytes.length<100*1024*1024);
 return cp.execFileSync('python3',['-c','import sys,zipfile,io,hashlib,json;z=zipfile.ZipFile(io.BytesIO(sys.stdin.buffer.read()));print(json.dumps(sorted((x.filename,hashlib.sha256(z.read(x)).hexdigest()) for x in z.infolist() if not x.is_dir())))'],{input:bytes,maxBuffer:20*1024*1024}).toString();
}
async function registerDevice(uid) {
 assert(/^[A-Za-z0-9_-]{1,128}$/.test(uid),'Invalid device UID');c.guard();
 const users=await c.request(`https://identitytoolkit.googleapis.com/v1/projects/${c.PROJECT}/accounts:lookup`,'POST',{localId:[uid]});
 const user=users.users?.[0];assert(users.users?.length===1&&user&&user.localId===uid&&!user.disabled,'Dev Auth user not found/enabled');
 assert(!user.email&&!user.phoneNumber&&!user.passwordHash&&!user.providerUserInfo?.length,'Device registration requires an anonymous Dev account');
 const listURL=`https://cloudfunctions.googleapis.com/v2/projects/${c.PROJECT}/locations/${c.REGION}/functions`;
 const before=await c.request(listURL);assert(!before.nextPageToken,'Paginated inventory needs review');
 const f=before.functions.find(x=>x.name.endsWith('/recognitionLabRun'));assert(f&&f.state==='ACTIVE');
 const env=f.serviceConfig.environmentVariables;assert.equal(env.RECOGNITION_LAB_ENABLED,'true');
 const cfgFile=path.join(c.ROOT,'Config/recognition-lab.local.json'),envFile=path.join(c.ROOT,'recognition-lab/functions/.env.forta-aogaku-dev');
 const cfg=JSON.parse(fs.readFileSync(cfgFile));assert.equal(cfg.projectId,c.PROJECT);
 assert.deepEqual(JSON.parse(env.RECOGNITION_LAB_ALLOWED_UIDS),cfg.allowedUIDs,'Local/live allowlist drift');
 assert.equal(fs.readFileSync(envFile,'utf8').trim(),['RECOGNITION_LAB_ENABLED=true','RECOGNITION_LAB_ALLOWED_UIDS='+JSON.stringify(cfg.allowedUIDs)].join('\n'));
 if(cfg.allowedUIDs.includes(uid)){console.log('PASS: device already allowed; no changes.');return;}
 const functionIAMURL=`https://cloudfunctions.googleapis.com/v2/${f.name}:getIamPolicy`,runIAMURL=`https://run.googleapis.com/v2/${f.serviceConfig.service}:getIamPolicy`;
 const functionIAM=await c.request(functionIAMURL),runIAM=await c.request(runIAMURL);
 const source=await manifest(f.name),next=[...cfg.allowedUIDs,uid],environment={...env,RECOGNITION_LAB_ALLOWED_UIDS:JSON.stringify(next)};
 // Exactly one env-only PATCH. Never automatically retry a mutation.
 const operation=await c.request(`https://cloudfunctions.googleapis.com/v2/${f.name}?updateMask=serviceConfig.environmentVariables`,'PATCH',{name:f.name,serviceConfig:{environmentVariables:environment}});
 assert(operation.name?.startsWith(`projects/${c.PROJECT}/locations/${c.REGION}/operations/`));
 let state=operation;
 for(let i=0;!state.done&&i<180;i++){await new Promise(r=>setTimeout(r,5000));state=await c.request('https://cloudfunctions.googleapis.com/v2/'+operation.name);}
 assert(state.done&&!state.error,'Function operation did not complete successfully');
 const after=await c.request(listURL);assert(!after.nextPageToken);const installed=after.functions.find(x=>x.name===f.name);
 assert.equal(installed.state,'ACTIVE');assert.equal(await manifest(f.name),source,'Installed full source changed');
 assert.deepEqual(installed.serviceConfig.environmentVariables,environment);
 const compared=structuredClone(installed);compared.updateTime=f.updateTime;compared.serviceConfig.environmentVariables=env;compared.serviceConfig.revision=f.serviceConfig.revision;
 for(const key of ['build','source','sourceProvenance'])compared.buildConfig[key]=f.buildConfig[key];
 assert.deepEqual(compared,f,'Non-environment metadata drift');
 for(const original of before.functions.filter(x=>x.name!==f.name))assert.deepEqual(after.functions.find(x=>x.name===original.name),original,'Other Dev Function changed');
 assert.equal(after.functions.length,before.functions.length);
 assert.deepEqual(await c.request(functionIAMURL),functionIAM,'Function IAM drift');
 assert.deepEqual(await c.request(runIAMURL),runIAM,'Run IAM drift');
 cfg.allowedUIDs=next;fs.writeFileSync(cfgFile,JSON.stringify(cfg,null,2)+'\n',{mode:0o600});fs.chmodSync(cfgFile,0o600);
 fs.writeFileSync(envFile,'RECOGNITION_LAB_ENABLED=true\nRECOGNITION_LAB_ALLOWED_UIDS='+JSON.stringify(next)+'\n',{mode:0o600});fs.chmodSync(envFile,0o600);
 console.log(`PASS: Dev device registered; allowlist ${next.length-1} -> ${next.length}; source/other Functions unchanged. Private UID not logged.`);
}
async function main(){
 c.guard();const project=await c.request(`https://cloudresourcemanager.googleapis.com/v1/projects/${c.PROJECT}`);assert.equal(project.projectId,c.PROJECT);assert.equal(String(project.projectNumber),c.NUMBER);
 if(process.argv[2]==='enable-anonymous')return enableAnonymous();
 assert.equal(process.argv[2],'register-device');const uid=fs.readFileSync(0,'utf8').trim();return registerDevice(uid);
}
if(require.main===module)main().catch(e=>{console.error(`STOP: ${e instanceof assert.AssertionError ? 'Verification failed; inspect locally before any retry.' : 'Dev request/setup failed; no mutation retry.'} (HTTP ${Number.isInteger(e.httpStatus)?e.httpStatus:'unknown'})`);process.exitCode=1;});
module.exports={enableAnonymous,registerDevice};
