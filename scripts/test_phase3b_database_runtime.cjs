// Offline test of the exact installed, SDK-only deletion artifact.
// REST source-only deployment does not inject Firebase CLI param defaults.
const {test}=require('node:test'),assert=require('node:assert/strict'),{spawnSync}=require('node:child_process');
function probe(value){
 const env={...process.env};delete env.AI_FIRESTORE_DATABASE_ID;
 if(value!==undefined)env.AI_FIRESTORE_DATABASE_ID=value;
 return spawnSync(process.execPath,['-e',"const d=require('./build/production-phase3b/candidate/lib/ai/databases.js');try{console.log(d.aiDatabaseId())}catch(e){console.error(e.message);process.exitCode=1}"],{cwd:require('node:path').resolve(__dirname,'..'),env,encoding:'utf8'});
}
test('Deletion artifact resolves its explicit named DB without CLI parameter injection',()=>{
 const r=probe();assert.equal(r.status,0,r.stderr.trim());assert.equal(r.stdout.trim(),'aogaku-ai');
});
test('Explicit named DB is accepted',()=>{const r=probe('aogaku-ai');assert.equal(r.status,0);assert.equal(r.stdout.trim(),'aogaku-ai');});
for(const [label,value] of [['empty',''],['default','(default)'],['other','other-db']]) {
 test('Explicit '+label+' database is rejected',()=>{const r=probe(value);assert.equal(r.status,1);assert.equal(r.stderr.trim(),'AI_DATABASE_MISMATCH');});
}
