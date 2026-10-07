// Separate legacy maintenance guard: same-generation named updates only, pinned existing secrets.
const fs=require('fs'),path=require('path'),assert=require('assert/strict');
function install(lib,receipt,metadata){
 assert.equal(receipt.target.projectId,'forta-aogaku');
 const groups={quota:['askCourseAI','transcribeLectureAudio','generateReactionPaper'],deletion:['preDeleteCleanup','deleteAccountServerSide','onAuthUserDelete']};
 assert.deepEqual(receipt.authorizeNamedUpdates,groups[receipt.group]);
 require('./firebase_prompt_guard.cjs').install(lib,'forta-aogaku');
 const records=Object.fromEntries(metadata.records.map(r=>[r.name,r]));
 const validate=require(path.join(lib,'deploy/functions/validate.js')),backend=require(path.join(lib,'deploy/functions/backend.js')),sm=require(path.join(lib,'gcp/secretManager.js'));
 validate.secretsAreValid=async(project,want)=>{
  assert.equal(project,'forta-aogaku');
  for(const e of backend.allEndpoints(want)){
   assert(groups[receipt.group].includes(e.id),'Unapproved legacy function');
   const bindings=receipt.mode==='rollback-before-pilot'||receipt.group==='quota'?records[e.id].secretBindings:[];
   assert.deepEqual((e.secretEnvironmentVariables||[]).map(s=>s.key).sort(),bindings.map(s=>s.key).sort(),'Secret binding additions/removal not approved');
   for(const s of e.secretEnvironmentVariables||[]){const b=bindings.find(b=>b.key===s.key);assert.equal(s.secret,b.secret);assert(/^\d+$/.test(b.version));const version=await sm.getSecretVersion(project,b.secret,b.version);assert.equal(version.state,'ENABLED');assert.equal(String(version.versionId),b.version);s.projectId=b.projectId;s.version=b.version;}
  }
 };
 for(const name of ['createSecret','addSecretVersion','destroySecretVersion','deleteSecret'])if(typeof sm[name]==='function')sm[name]=async()=>{throw Error('STOP: Secret creation/rotation/destruction forbidden');};
 return validate;
}
module.exports={install};
if(process.env.AOGAKU_LEGACY_PROMPT_PRELOAD==='true'){
 const receipt=JSON.parse(fs.readFileSync(process.env.AOGAKU_LEGACY_SESSION));const idx=process.argv.indexOf('--project');assert.equal(process.argv[idx+1],'forta-aogaku');assert(!process.argv.includes('--force'));
 const lib=process.env.FIREBASE_TOOLS_LIB||path.dirname(path.dirname(fs.realpathSync(process.argv[1])));
 install(lib,receipt,JSON.parse(fs.readFileSync(path.join(__dirname,'../build/production-legacy-live.json'))));
}
