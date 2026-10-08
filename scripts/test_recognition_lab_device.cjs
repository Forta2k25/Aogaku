const {test}=require('node:test'),assert=require('node:assert/strict');
const c=require('./dev_cloud.cjs'),lab=require('./recognition_lab_device.cjs');
c.guard=()=>{};c.token=async()=>'test-only-not-a-credential';
const config=()=>({name:`projects/${c.NUMBER}/config`,signIn:{email:{enabled:true,passwordRequired:true}},authorizedDomains:['example.test']});
test('Anonymous enable uses exact Dev endpoint and only anonymous-enabled update mask',async()=>{
 let state=config();const calls=[];global.fetch=async(url,options)=>{calls.push([url,options]);if(options.method==='PATCH')state.signIn.anonymous={enabled:true};return new Response(JSON.stringify(state));};
 await lab.enableAnonymous();assert.equal(calls.length,3);
 assert(calls.every(([url])=>url.startsWith(`https://identitytoolkit.googleapis.com/admin/v2/projects/${c.PROJECT}/config`)));
 assert(calls[1][0].endsWith('?updateMask=signIn.anonymous.enabled'));
 assert.deepEqual(JSON.parse(calls[1][1].body),{signIn:{anonymous:{enabled:true}}});
 assert.deepEqual(state.signIn.email,{enabled:true,passwordRequired:true});
});
test('Already enabled provider never PATCHes',async()=>{
 const state=config();state.signIn.anonymous={enabled:true};const calls=[];
 global.fetch=async(url,options)=>{calls.push(options.method);return new Response(JSON.stringify(state));};
 await lab.enableAnonymous();assert.deepEqual(calls,['GET','GET']);
});
test('Unexpected project metadata is rejected before mutation',async()=>{
 let calls=0;global.fetch=async()=>{calls++;return new Response(JSON.stringify({...config(),name:'projects/unapproved/config'}));};
 await assert.rejects(lab.enableAnonymous());assert.equal(calls,1);
});
test('Auth mutation failure is not retried',async()=>{
 const calls=[];global.fetch=async(url,options)=>{calls.push(options.method);return new Response(JSON.stringify(config()),{status:options.method==='PATCH'?503:200});};
 await assert.rejects(lab.enableAnonymous());assert.deepEqual(calls,['GET','PATCH']);
});
test('Device registration refuses nonanonymous accounts without Function mutation',async()=>{
 const original=c.request;let calls=0;c.request=async()=>{calls++;return {users:[{localId:'synthetic-device',email:'user@example.test'}]};};
 try{await assert.rejects(lab.registerDevice('synthetic-device'));assert.equal(calls,1);}finally{c.request=original;}
});
