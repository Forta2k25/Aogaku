#!/usr/bin/env node
// Read-only Dev metadata audit. No source URLs, credentials, payloads or production calls.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
// Follow the actual installed CLI; npm's active global prefix may belong to another Node installation.
process.env.FIREBASE_TOOLS_LIB ||= path.dirname(path.dirname(fs.realpathSync(require('node:child_process').execFileSync('which',['firebase'],{encoding:'utf8'}).trim())));
const cloud=require('./dev_cloud.cjs'),ROOT=path.resolve(__dirname,'..'),D=path.join(ROOT,'build/recognition-lab-dev');
const endpoints={functions:`https://cloudfunctions.googleapis.com/v2/projects/${cloud.PROJECT}/locations/asia-northeast1/functions`,rules:`https://firebaserules.googleapis.com/v1/projects/${cloud.PROJECT}/releases`,indexes:`https://firestore.googleapis.com/v1/projects/${cloud.PROJECT}/databases/(default)/collectionGroups/-/indexes`,namedIndexes:`https://firestore.googleapis.com/v1/projects/${cloud.PROJECT}/databases/aogaku-ai/collectionGroups/-/indexes`,bucket:`https://storage.googleapis.com/storage/v1/b/${cloud.BUCKET}`,secretVersions:`https://secretmanager.googleapis.com/v1/projects/${cloud.PROJECT}/secrets/GROQ_API_KEY/versions`};
async function main(action){
 assert(['before','after'].includes(action));cloud.guard();const project=await cloud.request(`https://cloudresourcemanager.googleapis.com/v1/projects/${cloud.PROJECT}`);assert.equal(project.projectId,cloud.PROJECT);assert.equal(String(project.projectNumber),cloud.NUMBER);
 const snapshot=Object.fromEntries(await Promise.all(Object.entries(endpoints).map(async([k,url])=>[k,await cloud.request(url)])));for(const v of Object.values(snapshot))assert(!v.nextPageToken,'Paginated inventory needs review');
 fs.mkdirSync(D,{recursive:true,mode:0o700});const file=path.join(D,action+'.json');if(action==='before')assert(!fs.existsSync(file),'Never overwrite baseline');
 if(action==='after'){
  const before=JSON.parse(fs.readFileSync(path.join(D,'before.json')));const existing=before.functions.functions||[],after=snapshot.functions.functions||[];
  for(const f of existing)assert.deepEqual(after.find(x=>x.name===f.name),f,'Existing Dev Function drift');
  const additions=after.filter(x=>!existing.some(f=>f.name===x.name));assert.equal(additions.length,1);const f=additions[0];assert(f.name.endsWith('/recognitionLabRun'));assert.equal(f.state,'ACTIVE');assert.equal(f.buildConfig.runtime,'nodejs22');
  for(const k of Object.keys(before).filter(k=>k!=='functions'))assert.deepEqual(snapshot[k],before[k],'Protected Dev resource drift '+k);
  console.log('PASS: only one isolated Dev function added; existing Functions, Rules/indexes/bucket/Secret versions unchanged.');
 }else console.log('PASS: fresh Dev identity and protected resources baseline.');
 fs.writeFileSync(file,JSON.stringify(snapshot,null,2),{mode:0o600});
}
main(process.argv[2]).catch(e=>{console.error('STOP: '+String(e.message).split('\n')[0]);process.exitCode=1;});
