#!/usr/bin/env node
// Dev-only reviewed source artifacts. Source PATCH is never automatically retried.
// Private URLs, source ZIPs, credentials and benchmark evidence stay in ignored build/.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto'),{execFileSync}=require('node:child_process');
const c=require('./dev_cloud.cjs'),v=require('./visual_router_dev.cjs'),p=require('./production_recognition_review.cjs'),reads=require('./production_read_retry.cjs'),{sourceManifest}=require('./deploy_production_phase3a.cjs');
const OUT=path.join(c.ROOT,'build/visual-latency/dev'),P=c.PROJECT,R=c.REGION,G='https://cloudfunctions.googleapis.com/v2/',parent=`projects/${P}/locations/${R}`,Q=`https://cloudtasks.googleapis.com/v2/${parent}/queues/aiProcessSource`;
const targets=['aiProcessSource','aiGetSource','aiGetEvidence'];
const modules=['lib/ai/index.js','lib/ai/visualExtraction.js','lib/ai/latency.js','lib/ai/localVisual.js','lib/ai/progressive.js'];
const sleep=ms=>new Promise(r=>setTimeout(r,ms)),sha=b=>crypto.createHash('sha256').update(b).digest('hex');
function save(n,x){fs.mkdirSync(OUT,{recursive:true,mode:0o700});fs.writeFileSync(path.join(OUT,n+'.json'),JSON.stringify(x,null,2),{mode:0o600});}
const load=n=>JSON.parse(fs.readFileSync(path.join(OUT,n+'.json')));
async function source(f,label){const issued=await c.request(G+f.name+':generateDownloadUrl','POST',{}),u=new URL(issued.downloadUrl);assert(u.protocol==='https:'&&(u.hostname==='storage.googleapis.com'||u.hostname.endsWith('.storage.googleapis.com')));const r=await reads.read(u.href,{}, {bytes:true,sourceName:label});const file=path.join(OUT,label+'.zip');fs.writeFileSync(file,r.data,{mode:0o600});return sourceManifest(file);}
async function prepare(){c.guard();const b=await v.snapshot();assert.equal(b.queue.state,'RUNNING');if(fs.existsSync(path.join(OUT,'baseline.json'))){const old=load('baseline');v.protectedCheck(old,b);assert.deepEqual(old.functions,b.functions);save('preparation-recheck',b);}else save('baseline',b);
 for(const name of targets){const f=b.functions.functions.find(x=>x.name===parent+'/functions/'+name);assert(f?.state==='ACTIVE');const m=await source(f,'original-'+name);if(name==='aiProcessSource')assert.equal(m['lib/ai/recognition.js'],sha(fs.readFileSync(path.join(c.ROOT,'functions/lib/ai/recognition.js'))),'Grounded worker prompt must not change');save('original-manifest-'+name,m);
  for(const mode of ['before','after']){execFileSync('python3',['-c',`import zipfile,sys,pathlib
src,dst,root,mode,*mods=sys.argv[1:]; z=zipfile.ZipFile(src); entries={n:z.read(n) for n in z.namelist() if not n.endswith('/')}
for n in mods:
 assert not n.startswith('/') and '..' not in n.split('/'); data=(pathlib.Path(root)/n).read_bytes()
 if mode=='before' and n.endswith('/visualExtraction.js'):
  text=data.decode(); assert text.count('options = {}')==2; text=text.replace('options = {}','options = {sequential: true, skipLocalFastPath: true}'); data=text.encode()
 entries[n]=data
with zipfile.ZipFile(dst,'w',zipfile.ZIP_DEFLATED) as out:
 for n,data in entries.items(): out.writestr(n,data)`,path.join(OUT,'original-'+name+'.zip'),path.join(OUT,mode+'-'+name+'.zip'),path.join(c.ROOT,'functions'),mode,...modules]);
   const candidate=sourceManifest(path.join(OUT,mode+'-'+name+'.zip'));assert(Object.keys(candidate).filter(n=>candidate[n]!==m[n]).every(n=>modules.includes(n)));assert(Object.keys(m).every(n=>candidate[n]));save(mode+'-manifest-'+name,candidate);
  }
 }
 console.log('PASS Dev fresh baseline; source-only three targets; original prompt/models/config preserved');}
async function prepareAfter(){
 const b=load('before-complete'),a=await v.snapshot();v.protectedCheck(b,a);assert.deepEqual(b.functions,a.functions);assert(!fs.existsSync(path.join(OUT,'after-pause-attempt.json')),'After mutation has already started');
 for(const name of ['aiProcessSource','aiCompleteSource']){
  if(name==='aiCompleteSource'){const f=a.functions.functions.find(x=>x.name.endsWith('/'+name));save('original-manifest-'+name,await source(f,'original-'+name));}
  const original=path.join(OUT,'original-'+name+'.zip');execFileSync('python3',['-c',`import zipfile,sys,pathlib
src,dst,root,*mods=sys.argv[1:]; z=zipfile.ZipFile(src); entries={n:z.read(n) for n in z.namelist() if not n.endswith('/')}
for n in mods: entries[n]=(pathlib.Path(root)/n).read_bytes()
with zipfile.ZipFile(dst,'w',zipfile.ZIP_DEFLATED) as out:
 for n,data in entries.items(): out.writestr(n,data)`,original,path.join(OUT,'after-'+name+'.zip'),path.join(c.ROOT,'functions'),...modules]);fs.chmodSync(path.join(OUT,'after-'+name+'.zip'),0o600);
  const candidate=sourceManifest(path.join(OUT,'after-'+name+'.zip')),old=load('original-manifest-'+name);assert(Object.keys(candidate).filter(n=>candidate[n]!==old[n]).every(n=>modules.includes(n)));save('after-manifest-'+name,candidate);
 }
 console.log('PASS fresh after artifacts; worker + complete telemetry; exact reviewed modules only');
}
async function deploy(mode){assert(['before','after'].includes(mode));const b=load(mode==='before'?'baseline':'before-complete'),a=await v.snapshot();v.protectedCheck(b,a);assert.deepEqual(a.functions,b.functions);assert.equal(a.queue.state,'RUNNING');assert(!fs.existsSync(path.join(OUT,mode+'-pause-attempt.json')),'No mutation replay');save(mode+'-pause-attempt',{status:'ATTEMPTED'});await c.request(Q+':pause','POST',{});assert.equal((await v.read(Q)).state,'PAUSED');
 let empty=false;for(let i=0;i<30;i++){const tasks=await v.read(Q+'/tasks?pageSize=100');if(!tasks.tasks?.length){empty=true;break;}await sleep(2000);}assert(empty,'Dev queue not drained');await sleep(10000);
 const names=mode==='before'?targets:['aiProcessSource','aiCompleteSource'];let expected=structuredClone(a.functions);
 for(const name of names){assert.deepEqual(sourceManifest(path.join(OUT,mode+'-'+name+'.zip')),load(mode+'-manifest-'+name),'Reviewed ZIP drift');if(mode==='after')for(const file of modules)assert.equal(load(mode+'-manifest-'+name)[file],sha(fs.readFileSync(path.join(c.ROOT,'functions',file))),'Source changed after review');assert(!fs.existsSync(path.join(OUT,mode+'-'+name+'-attempt.json')),'No source mutation replay');const F=parent+'/functions/'+name,before=await v.read(G+F);save(mode+'-'+name+'-attempt',{status:'STAGING_ATTEMPTED'});const issued=await c.request(G+parent+'/functions:generateUploadUrl','POST',{}),u=new URL(issued.uploadUrl);assert.equal(u.hostname,'storage.googleapis.com');assert(issued.storageSource.bucket.includes(c.NUMBER)&&issued.storageSource.bucket.includes(R));const staged=await fetch(u,{method:'PUT',redirect:'error',headers:{'Content-Type':'application/zip'},body:fs.readFileSync(path.join(OUT,mode+'-'+name+'.zip')),signal:AbortSignal.timeout(60000)});assert(staged.ok,'Staging HTTP '+staged.status);save(mode+'-'+name+'-attempt',{status:'PATCH_ATTEMPTED'});const op=await c.request(G+F+'?updateMask=buildConfig.source','PATCH',{name:F,buildConfig:{source:{storageSource:issued.storageSource}}});assert(op.name.startsWith(parent+'/operations/'));save(mode+'-'+name+'-operation',{name:op.name});
  let done=false;for(let i=0;i<240;i++){const operation=await v.read(G+op.name);save(mode+'-'+name+'-operation',operation);if(operation.done){assert(!operation.error,'Operation error '+operation.error?.code);done=true;break;}if(i%12===0)console.log('Dev '+name+' '+mode+' operation pending');await sleep(5000);}assert(done,'Operation timed out; do not replay PATCH');
  const installed=await v.read(G+F),manifest=await source(installed,mode+'-installed-'+name);p.postCheck(before,installed,manifest,load(mode+'-manifest-'+name));expected.functions=expected.functions.map(f=>f.name===F?installed:f);const snap=await v.snapshot();v.protectedCheck(b,snap);assert.deepEqual(snap.functions,expected,'Unselected function changed');assert.equal(snap.queue.state,'PAUSED');save(mode+'-'+name+'-attempt',{status:'POSTCHECK_PASS'});console.log('PASS Dev '+name+' '+mode+' full source/config/protected');
 }
 const final=await v.snapshot();v.protectedCheck(b,final);assert.deepEqual(final.functions,expected);assert.equal(final.queue.state,'PAUSED');save(mode+'-paused',final);save(mode+'-resume-attempt',{status:'ATTEMPTED'});await c.request(Q+':resume','POST',{});assert.equal((await v.read(Q)).state,'RUNNING');save(mode+'-complete',await v.snapshot());console.log('PASS Dev '+mode+' queue RUNNING restored; no env/IAM/Rules/Secret changes');}
module.exports={OUT,targets,modules,save,load,source};
if(require.main===module)(async()=>{const a=process.argv[2];if(a==='prepare')await prepare();else if(a==='prepare-after')await prepareAfter();else await deploy(a)})().catch(e=>{console.error('SAFE STOP Dev latency '+e.name+(e.httpStatus?' HTTP '+e.httpStatus:'')+' '+String(e.message).slice(0,180));process.exitCode=1});
