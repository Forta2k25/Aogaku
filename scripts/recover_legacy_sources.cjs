// Read-only recovery of the requested deployed legacy Functions source artifacts.
// SourceCodeGet's generateDownloadUrl is a read-only POST, never a deploy or write.
// No Secret payload or user bucket access. Download URLs are used in memory only.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const ROOT=path.resolve(__dirname,'..'),P='forta-aogaku',N='505828754933',R='asia-northeast1';
const names=['onAuthUserDelete','preDeleteCleanup','deleteAccountServerSide','askCourseAI','transcribeLectureAudio','generateReactionPaper','onIncomingRequest','onFriendshipCreated','onIncomingRequestDeleted'];
function sourceRef(f){
 const s=f.buildConfig?.sourceProvenance?.resolvedStorageSource||f.buildConfig?.source?.storageSource;
 if(s?.bucket&&s.object)return {bucket:s.bucket,object:s.object,generation:s.generation||null};
 if(f.sourceArchiveUrl?.startsWith('gs://')){const u=new URL(f.sourceArchiveUrl);return {bucket:u.hostname,object:decodeURIComponent(u.pathname.slice(1)),generation:u.hash.slice(1)||null};}
 return null;
}
function validateSource(s){
 assert(new RegExp(`^gcf-(?:v2-)?sources-${N}-${R}$`).test(s.bucket),'Source bucket must be the exact production Functions source bucket');
 assert(s.object&&!s.object.includes('..')&&!s.object.startsWith('/')&&s.object.endsWith('.zip'),'Only declared source ZIP objects');
 if(s.generation)assert(/^\d+$/.test(String(s.generation)));
}
async function main(){
 const lib=process.env.FIREBASE_TOOLS_LIB||'/Users/shum/anaconda3/lib/node_modules/firebase-tools/lib';
 const account=require(path.join(lib,'auth.js')).getGlobalDefaultAccount(),api=require(path.join(lib,'api.js'));
 if(!account?.tokens?.refresh_token)throw Error('CLI login required');
 const oauth=await fetch('https://oauth2.googleapis.com/token',{method:'POST',body:new URLSearchParams({client_id:api.clientId(),client_secret:api.clientSecret(),refresh_token:account.tokens.refresh_token,grant_type:'refresh_token'})});
 const credentials=await oauth.json();if(!oauth.ok||!credentials.access_token)throw Error('OAuth refresh failed');
 const get=async(url,bytes=false)=>{
  const r=await fetch(url,{method:'GET',redirect:'error',headers:{Authorization:`Bearer ${credentials.access_token}`},signal:AbortSignal.timeout(45000)});
  if(!r.ok)throw Error('Read-only recovery HTTP '+r.status);
  if(bytes){const b=Buffer.from(await r.arrayBuffer());assert(b.length<=100*1024*1024,'Source archive too large');return b;}
  return r.json();
 };
 const project=await get(`https://cloudresourcemanager.googleapis.com/v1/projects/${P}`);assert.equal(project.projectId,P);assert.equal(project.projectNumber,N);
 const dir=path.join(ROOT,'build/legacy-production-recovery');fs.mkdirSync(dir,{recursive:true,mode:0o700});fs.chmodSync(dir,0o700);
 const selected=process.argv.find(a=>a.startsWith('--only='))?.slice(7);if(selected)assert(names.includes(selected),'Unexpected recovery target');
 const privateFile=path.join(dir,'provenance.private.json');
 const records=selected&&fs.existsSync(privateFile)?JSON.parse(fs.readFileSync(privateFile)).records.filter(r=>r.function!==selected):[];
 for(const name of selected?[selected]:names){
  const url=`https://cloudfunctions.googleapis.com/v2/projects/${P}/locations/${R}/functions/${name}`;
  const f=await get(url);assert.equal(f.name,`projects/${P}/locations/${R}/functions/${name}`);
  const s=sourceRef(f);const record={function:name,environment:f.environment,runtime:f.buildConfig?.runtime,updateTime:f.updateTime,entryPoint:f.buildConfig?.entryPoint||name,source:s,recovered:false};
  if(process.argv.includes('--download')){
    const version=f.environment==='GEN_1'?'v1':'v2';
    const resource=`projects/${P}/locations/${R}/functions/${name}`;
    const versioned=version==='v1'?await get(`https://cloudfunctions.googleapis.com/v1/${resource}`):f;
    const response=await fetch(`https://cloudfunctions.googleapis.com/${version}/${resource}:generateDownloadUrl`,{method:'POST',redirect:'error',headers:{Authorization:`Bearer ${credentials.access_token}`,'Content-Type':'application/json'},body:JSON.stringify(version==='v1'&&versioned.versionId?{versionId:versioned.versionId}:{}),signal:AbortSignal.timeout(45000)});
    if(!response.ok)throw Error('SourceCodeGet HTTP '+response.status);
    const download=new URL((await response.json()).downloadUrl);
    assert(download.protocol==='https:'&&!download.username&&!download.password&&!download.port);
    assert(download.hostname==='storage.googleapis.com'||download.hostname.endsWith('.storage.googleapis.com'),'Only Storage signed downloads returned by SourceCodeGet');
    const archive=await fetch(download,{method:'GET',redirect:'error',signal:AbortSignal.timeout(45000)});
    if(!archive.ok)throw Error('Source archive GET HTTP '+archive.status);
    const bytes=Buffer.from(await archive.arrayBuffer());assert(bytes.length<=100*1024*1024);
    const after=await get(url);assert.equal(after.updateTime,f.updateTime,'Deployed function changed during recovery');
    const dest=path.join(dir,name+'.zip');fs.writeFileSync(dest,bytes,{mode:0o600});fs.chmodSync(dest,0o600);
    Object.assign(record,{versionId:versioned.versionId||null,sha256:require('node:crypto').createHash('sha256').update(bytes).digest('hex'),recovered:true});
  }
  records.push(record);
  console.log(JSON.stringify({function:name,environment:f.environment,sourceArchiveDeclared:!!s,recovered:record.recovered}));
 }
 const output=path.join(dir,'provenance.private.json');fs.writeFileSync(output,JSON.stringify({project:P,projectNumber:N,cloudWrites:0,records},null,2),{mode:0o600});fs.chmodSync(output,0o600);
}
module.exports={sourceRef,validateSource};
if(require.main===module)main().catch(e=>{console.error(e.message);process.exitCode=1;});
