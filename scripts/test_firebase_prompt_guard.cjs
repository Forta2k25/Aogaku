const {test}=require('node:test'),assert=require('node:assert/strict');const {install}=require('./firebase_prompt_guard.cjs');
const lib=process.env.FIREBASE_TOOLS_LIB||'/Users/shum/anaconda3/lib/node_modules/firebase-tools/lib';
for(const project of ['forta-aogaku-dev','forta-aogaku'])test(`${project}: allow retry only; reject deletion, replacement and force`,async()=>{
 const p=install(lib,project),endpoint={id:'aiRejectLateUpload',project,region:'asia-northeast1',eventTrigger:{retry:true,eventType:'google.cloud.storage.object.v1.finalized',eventFilters:{bucket:project+'.firebasestorage.app'}}};
 const want=e=>({endpoints:{'asia-northeast1':{[e.id]:e}},requiredAPIs:[]});
 await p.promptForFailurePolicies({project,force:false},want(endpoint));
 await assert.rejects(p.promptForFailurePolicies({project,force:true},want(endpoint)));
 await assert.rejects(p.promptForFailurePolicies({project,force:false},want({...endpoint,id:'legacyHandler'})));
 await assert.rejects(p.promptForFailurePolicies({project,force:false},want({...endpoint,project:project+'-wrong'})));
 await assert.rejects(p.promptForFunctionDeletion([{id:'askCourseAI'}]));
 await assert.rejects(p.promptForUnsafeMigration([{unsafe:true,endpoint}],{project}));
 assert.equal(await p.promptForFunctionDeletion([]),true);
});

test('production Firestore guard rejects deletion or field replacement before mutation',async()=>{
 const {FirestoreApi}=require(lib+'/firestore/api.js'),api=Object.create(FirestoreApi.prototype);
 api.listIndexes=async()=>[{name:'existing'}];api.listFieldOverrides=async()=>[];api.upgradeOldSpec=x=>x;api.validateSpec=()=>{};api.indexMatchesSpec=()=>false;
 await assert.rejects(api.deploy({project:'forta-aogaku'},[],[], '(default)'),/index deletion/);
 api.listIndexes=async()=>[];api.listFieldOverrides=async()=>[{name:'existing-field'}];api.fieldMatchesSpec=()=>false;
 await assert.rejects(api.deploy({project:'forta-aogaku'},[],[]),/fieldOverride change/);
 for(const method of ['deleteIndex','deleteField','patchField','createDatabase'])await assert.rejects(api[method]({}),/forbidden/);
});
