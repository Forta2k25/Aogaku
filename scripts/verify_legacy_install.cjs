// Future post-deploy/read-only verification. No source URL or Secret payload is retained.
const fs=require('fs'),path=require('path'),crypto=require('crypto'),assert=require('assert/strict'),{execFileSync}=require('child_process');
const ROOT=path.resolve(__dirname,'..'),P='forta-aogaku',N='505828754933',R='asia-northeast1';
function isPhase3bSlim(mode,group,installed){return mode==='candidate'&&group==='deletion'&&installed.groups?.deletion?.mode==='phase3b-runtime-db-correction';}
async function main(){
 const [mode,group]=process.argv.slice(2),groups={quota:['askCourseAI','transcribeLectureAudio','generateReactionPaper'],deletion:['preDeleteCleanup','deleteAccountServerSide','onAuthUserDelete']};assert(['candidate','safety-recovery','rollback-before-pilot'].includes(mode));assert(groups[group]);
 const ledgerPath=path.join(ROOT,'build/legacy-production-installation.json');
 const ledger=fs.existsSync(ledgerPath)?JSON.parse(fs.readFileSync(ledgerPath)):{groups:{}};
 // Source-only correction retained the live SA/Secret profile. Verify the
 // installed slim artifact, never demand replacing it with the generic package.
 if(isPhase3bSlim(mode,group,ledger)){
  const dir=path.join(ROOT,'build/production-phase3b'),read=n=>JSON.parse(fs.readFileSync(path.join(dir,n+'.json')));
  const artifact=require('./deploy_production_phase3b.cjs').artifact(),e2e=read('e2e'),cleanup=read('previous-fixture-cleanup');
  assert.equal(ledger.projectId,P);assert.equal(ledger.groups.deletion.artifactSha256,artifact.sourceSha256);
  assert.equal(e2e.status,'PASS');assert.equal(e2e.artifactSha256,artifact.sourceSha256);assert.equal(e2e.realUsersUsed,0);
  assert.deepEqual(e2e.results.map(r=>r.route),groups.deletion);assert(e2e.results.every(r=>r.status==='PASS'));
  assert.equal(cleanup.status,'PASS');assert.equal(cleanup.artifactSha256,artifact.sourceSha256);assert(cleanup.ownershipVerified);assert.equal(cleanup.results.length,2);
  execFileSync(process.execPath,[path.join(ROOT,'scripts/deploy_production_phase3b.cjs'),'postcheck'],{cwd:ROOT,stdio:'inherit'});
  const current=read('execution');assert.equal(current.status,'CONTROL_PLANE_PASS');assert(current.protectedResourcesUnchanged);
  for(const f of ledger.groups.deletion.functions){assert(f.sourceVerified);assert.equal(f.updateTime,current.verified[f.name].updateTime);assert.equal(current.verified[f.name].sourceSha256,artifact.sourceSha256);}
  ledger.groups.deletion.verifiedAt=new Date().toISOString();fs.writeFileSync(ledgerPath,JSON.stringify(ledger,null,2)+'\n',{mode:0o600});
  console.log('PASS: installed Phase3b slim deletion source/runtime/SA/Secret, E2E and previous fixture cleanup verified read-only');return;
 }
 await require('./production_cloud.cjs').legacyMetadata();
 const live=JSON.parse(fs.readFileSync(path.join(ROOT,'build/production-legacy-live.json')));assert.equal(live.projectId,P);assert.equal(live.projectNumber,N);
 const records=Object.fromEntries(live.records.map(r=>[r.name,r]));
 const installationFile=path.join(ROOT,'build/legacy-production-installation.json');
 const installed=fs.existsSync(installationFile)?JSON.parse(fs.readFileSync(installationFile)):{groups:{}};
 // Phase3a intentionally uses a slim three-callable artifact. Never demand a
 // redeploy of the six-handler package merely to verify already installed AI.
 const slim=mode==='candidate'&&group==='quota'&&installed.groups?.quota?.mode==='phase3a-source-only';
 const phase3aTool=slim?require('./deploy_production_phase3a.cjs'):null;
 const phase3a=slim?phase3aTool.assertArtifact():null;
 const phase3aBaseline=slim?JSON.parse(fs.readFileSync(path.join(ROOT,'build/production-phase3a/baseline.json'))):null;
 const source=path.join(ROOT,slim?'build/production-phase3a/candidate':'build/production-legacy-'+mode);
 const desired=slim?Object.fromEntries(groups.quota.map(n=>[n,{environment:'GEN_1',serviceAccount:phase3aBaseline.legacy[n].serviceAccountEmail,secretBindings:phase3aBaseline.legacy[n].secretEnvironmentVariables}])):JSON.parse(fs.readFileSync(path.join(ROOT,'build/production-legacy-'+mode,'lib/metadata.json')));
 const lib=process.env.FIREBASE_TOOLS_LIB||'/Users/shum/anaconda3/lib/node_modules/firebase-tools/lib',account=require(path.join(lib,'auth.js')).getGlobalDefaultAccount(),api=require(path.join(lib,'api.js'));
 const oauth=await fetch('https://oauth2.googleapis.com/token',{method:'POST',body:new URLSearchParams({client_id:api.clientId(),client_secret:api.clientSecret(),refresh_token:account.tokens.refresh_token,grant_type:'refresh_token'})});const auth=await oauth.json();assert(oauth.ok&&auth.access_token);
 const request=async(url,method='GET',body)=>{const r=await fetch(url,{method,redirect:'error',headers:{Authorization:'Bearer '+auth.access_token,'Content-Type':'application/json'},...(body?{body:JSON.stringify(body)}:{}),signal:AbortSignal.timeout(45000)});assert(r.ok,'Source metadata HTTP '+r.status);return r.json();};
 const expected={};function walk(dir){for(const entry of fs.readdirSync(dir,{withFileTypes:true})){const p=path.join(dir,entry.name);if(entry.isDirectory())walk(p);else if(entry.isFile())expected[path.relative(source,p)]=crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');}}walk(path.join(source,'lib'));for(const n of ['package.json','package-lock.json'])expected[n]=crypto.createHash('sha256').update(fs.readFileSync(path.join(source,n))).digest('hex');
 const dir=path.join(ROOT,'build/legacy-install-verification');fs.mkdirSync(dir,{recursive:true,mode:0o700});const expectedFile=path.join(dir,'expected-'+mode+'.json');fs.writeFileSync(expectedFile,JSON.stringify(expected),{mode:0o600});
 const verified=[];
 for(const name of groups[group]){
  const r=records[name],want=desired[name];assert.equal(r.environment,want.environment);assert.equal(r.codebase,'default');assert.equal(r.runtime,'nodejs22');assert.equal(r.serviceAccount,want.serviceAccount);
  const bindings=x=>x.map(b=>[b.key,b.secret,String(b.version)]).sort();assert.deepEqual(bindings(r.secretBindings),bindings(want.secretBindings));
  const resource=`projects/${P}/locations/${R}/functions/${name}`,version=r.environment==='GEN_1'?'v1':'v2';const f=await request(`https://cloudfunctions.googleapis.com/${version}/${resource}`);
  if(slim)assert.deepEqual(phase3aTool.runtimeCore(f),phase3aTool.runtimeCore(phase3aBaseline.legacy[name]));
  const download=await request(`https://cloudfunctions.googleapis.com/${version}/${resource}:generateDownloadUrl`,'POST',version==='v1'?{versionId:f.versionId}:{});const url=new URL(download.downloadUrl);assert.equal(url.protocol,'https:');assert(url.hostname==='storage.googleapis.com'||url.hostname.endsWith('.storage.googleapis.com'));assert(!url.username&&!url.password&&!url.port);
  const response=await fetch(url,{redirect:'error',signal:AbortSignal.timeout(45000)});assert(response.ok);const bytes=Buffer.from(await response.arrayBuffer());assert(bytes.length<=100*1024*1024);
  const zip=path.join(dir,name+'-'+crypto.createHash('sha256').update(bytes).digest('hex')+'.zip');fs.writeFileSync(zip,bytes,{mode:0o600});
  if(slim)assert.deepEqual(phase3aTool.sourceManifest(zip),phase3a.files);
  const verify="import sys,json,zipfile,hashlib; z=zipfile.ZipFile(sys.argv[1]); wanted=json.load(open(sys.argv[2])); names=z.namelist(); roots=[n[:-len('package.json')] for n in names if n=='package.json' or n.endswith('/package.json') and '/node_modules/' not in n]; assert len(roots)==1; prefix=roots[0]; assert all(hashlib.sha256(z.read(prefix+n)).hexdigest()==h for n,h in wanted.items()), 'Installed source mismatch'";
  execFileSync('python3',['-c',verify,zip,expectedFile],{stdio:['ignore','ignore','pipe']});const after=await request(`https://cloudfunctions.googleapis.com/v2/${resource}`);assert.equal(after.updateTime,r.updateTime,'Function changed during verification');verified.push({name,updateTime:r.updateTime,sourceVerified:true});
 }
 const output=path.join(ROOT,'build/legacy-production-installation.json'),receipt=fs.existsSync(output)?JSON.parse(fs.readFileSync(output)):{projectId:P,groups:{}};
 const hash=slim?phase3a.sourceSha256:execFileSync('python3',['-c',"import sys;sys.path.insert(0,'scripts');import firebase_legacy_production as p;print(p.artifact_hash(sys.argv[1]))",mode],{cwd:ROOT,encoding:'utf8'}).trim();receipt.groups[group]={mode:slim?'phase3a-source-only':mode,artifactSha256:hash,verifiedAt:new Date().toISOString(),functions:verified};fs.writeFileSync(output,JSON.stringify(receipt,null,2),{mode:0o600});console.log('PASS: installed '+group+' generation/runtime/SA/Secret versions and complete source files match approved artifact');
}
module.exports={isPhase3bSlim};
if(require.main===module)main().catch(e=>{console.error(e.message);process.exitCode=1});
