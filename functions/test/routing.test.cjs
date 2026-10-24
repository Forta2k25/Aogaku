const {test}=require('node:test'),assert=require('node:assert/strict');
const {ROUTING,validateRoute,routePrompt,parseRanked,routeCourse}=require('../lib/ai/routing');
const {CHAT}=require('../lib/ai/chat');
const {GEMINI_RETRY}=require('../lib/ai/gemini');GEMINI_RETRY.delaysMs=[0,0];
const code=c=>e=>e.code===c;
const courses=[{id:'c1',name:'経済数学',teacher:'山田',hint:'偏微分 ラグランジュ'},{id:'c2',name:'Reading II',teacher:'Smith',hint:'English reading'},{id:'c3',name:'西洋美術史 II',teacher:'',hint:''}];
const jpeg=Buffer.concat([Buffer.from([255,216,255]),Buffer.alloc(100,1)]).toString('base64');

test('route validation: bounded courses, unique ids, a question or a jpeg is required',()=>{
 const ok=validateRoute({question:'  偏微分って?  ',courses});assert.equal(ok.question,'偏微分って?');assert.equal(ok.courses.length,3);assert.equal(ok.image,undefined);
 assert.equal(validateRoute({question:'',courses,image:{mime:'image/jpeg',data:jpeg}}).image.mime,'image/jpeg');
 assert.equal(validateRoute({question:'あ'.repeat(5000),courses}).question.length,ROUTING.maxQuestionChars);
 for(const bad of [null,{question:'a'},{question:'a',courses:[]},{question:'a',courses:'x'},{question:'a',courses:Array(ROUTING.maxCourses+1).fill(courses[0])},
   {question:'a',courses:[courses[0],courses[0]]},{question:'a',courses:[{id:'',name:'x'}]},{question:'a',courses:[{id:'x',name:''}]},
   {question:'',courses},{question:'a',courses,image:{mime:'image/png',data:jpeg}},{question:'a',courses,image:{mime:'image/jpeg',data:'!!'}},
   {question:'a',courses,image:{mime:'image/jpeg',data:Buffer.from('not a jpeg').toString('base64')}},
   {question:'a',courses,image:{mime:'image/jpeg',data:Buffer.concat([Buffer.from([255,216]),Buffer.alloc(ROUTING.maxImageBytes)]).toString('base64')}}])
  assert.throws(()=>validateRoute(bad),code('INVALID_ROUTE'),JSON.stringify(bad)?.slice(0,60));
});
test('route prompt lists every course with its id and hint',()=>{
 const p=routePrompt(validateRoute({question:'偏微分',courses}));
 for(const w of ['ID: c1','経済数学','先生: 山田','ヒント: 偏微分 ラグランジュ','ID: c3','【質問】\n偏微分']) assert(p.includes(w),w);
 assert(routePrompt(validateRoute({question:'',courses,image:{mime:'image/jpeg',data:jpeg}})).includes('写真だけ'));
});
test('parseRanked: unknown ids, duplicates, bad confidences and weak candidates are dropped; sorted; max 3',()=>{
 const input=validateRoute({question:'a',courses});
 const raw=JSON.stringify({ranked:[{id:'c2',confidence:0.4,reason:'英文'},{id:'nope',confidence:0.99,reason:'x'},{id:'c1',confidence:1.7,reason:'偏微分'},{id:'c1',confidence:0.5,reason:'dup'},{id:'c3',confidence:0.05,reason:'弱い'},{id:'c2',confidence:'x',reason:'y'}]});
 const r=parseRanked(raw,input);
 assert.deepEqual(r.map(c=>[c.id,c.confidence]),[['c1',1],['c2',0.4]],'範囲外は丸め、一覧に無いID・重複・弱い候補は捨て、自信の高い順');
 assert.deepEqual(parseRanked('{"ranked":[]}',input),[]);
 for(const bad of ['not json','{}','{"ranked":"x"}']) assert.throws(()=>parseRanked(bad,input),code('ROUTE_INVALID_RESULT'));
 assert.equal(parseRanked(JSON.stringify({ranked:courses.map((c,i)=>({id:c.id,confidence:0.9-i*0.1,reason:'r'}))}),input).length,3);
});
const gem=(text,over={},finish='STOP')=>({modelVersion:CHAT.model,candidates:[{finishReason:finish,content:{parts:[{text}]}}],usageMetadata:{promptTokenCount:800,candidatesTokenCount:60,totalTokenCount:860},...over});
const ok=body=>async(u,init)=>({ok:true,status:200,json:async()=>body,init});
test('routeCourse: sends a structured-output request (with the photo first), returns ranked candidates and measured usage',async()=>{
 let sent;
 const r=await routeCourse('k',validateRoute({question:'この式は?',courses,image:{mime:'image/jpeg',data:jpeg}}),async(u,init)=>{sent=JSON.parse(init.body);return {ok:true,status:200,json:async()=>gem(JSON.stringify({ranked:[{id:'c1',confidence:0.9,reason:'偏微分'}]}))}});
 assert.deepEqual(r.ranked,[{id:'c1',confidence:0.9,reason:'偏微分'}]);assert.equal(r.recognition.totalTokens,860);
 assert.equal(sent.generationConfig.responseMimeType,'application/json');assert(sent.generationConfig.responseSchema);
 assert(sent.contents[0].parts[0].inline_data,'写真が、先頭');assert(sent.contents[0].parts.at(-1).text.includes('経済数学'));
});
test('routeCourse: truncated / wrong-model / HTTP failures never produce a guess',async()=>{
 const input=validateRoute({question:'a',courses});
 await assert.rejects(routeCourse('k',input,ok(gem('{"ranked":[',{},'MAX_TOKENS'))),code('ROUTE_INVALID_RESULT'));
 await assert.rejects(routeCourse('k',input,ok(gem('{"ranked":[]}',{modelVersion:'gemini-other'}))),code('CHAT_MODEL_MISMATCH'));
 await assert.rejects(routeCourse('',input,ok(gem('{}'))),code('CHAT_NOT_CONFIGURED'));
 await assert.rejects(routeCourse('k',input,async()=>({ok:false,status:429,json:async()=>({}),clone(){return this}})),e=>e.code==='CHAT_RATE_LIMIT'&&e.retryable);
});
