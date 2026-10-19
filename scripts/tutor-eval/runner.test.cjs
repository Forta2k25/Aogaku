'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {run}=require('../tutor_eval.cjs');
const {readRun,compare}=require('./core.cjs');
const {rescore}=require('../tutor_eval_rescore.cjs');
test('runner uses real prior replies, resends image, saves visible answer and no key/memo',async()=>{
 const temp=fs.mkdtempSync(path.join(os.tmpdir(),'tutor-runner-test-')),originalFetch=global.fetch,oldKey=process.env.GEMINI_API_KEY;
 const out=path.join(temp,'run');let calls=0;
 try{
  fs.writeFileSync(path.join(temp,'t1_worksheet.jpg'),Buffer.from([255,216,255,0]));
  process.env.GEMINI_API_KEY='fake-private-test-key';
  global.fetch=async(url,options)=>{
   calls++;const body=JSON.parse(options.body);
   assert(body.contents[0].parts.some(p=>p.inline_data));
   if(calls>1)assert(body.contents.some(t=>t.role==='model'&&t.parts.some(p=>p.text?.includes('実応答'+(calls-1)))));
   const text=`[[作業]]private work memo[[/作業]]\n実応答${calls} 街並みは名詞句です。\n[[次]]\n問2の名詞句とは？\n英語の文に直して`;
   return new Response('data: '+JSON.stringify({modelVersion:'gemini-3.5-flash-lite',candidates:[{finishReason:'STOP',content:{parts:[{text}]}}],usageMetadata:{promptTokenCount:100,candidatesTokenCount:50,totalTokenCount:150}})+'\n\n',{headers:{'content-type':'text/event-stream'}});
  };
  assert.equal(await run(['--only','legacy-03','--fixtures',temp,'--out',out]),0);
  assert.equal(calls,3);const result=readRun(out);assert.equal(result.manifest.complete,true);assert.equal(result.summary.trials,1);assert.equal(result.summary.turns,3);assert.equal(result.summary.trialStatus.unscored,1);
  const saved=fs.readdirSync(out).map(f=>fs.readFileSync(path.join(out,f),'utf8')).join('');
  assert(!saved.includes('fake-private-test-key'));assert(!saved.includes('private work memo'));
  assert(result.rows.every(r=>r.metrics.firstVisibleMs!==null));
  const rescored=path.join(temp,'rescored');rescore(out,rescored);const refreshed=readRun(rescored);assert.equal(refreshed.manifest.rescoredFrom,result.manifest.runId);assert.deepEqual(refreshed.rows.map(r=>r.text),result.rows.map(r=>r.text));assert.equal(compare(refreshed,refreshed).regressions.length,0);assert.throws(()=>rescore(out,rescored));
 }finally{global.fetch=originalFetch;if(oldKey===undefined)delete process.env.GEMINI_API_KEY;else process.env.GEMINI_API_KEY=oldKey;fs.rmSync(temp,{recursive:true,force:true});}
});
test('provider rejection records transport failure with unknown cost and no reflected key',async()=>{
 const temp=fs.mkdtempSync(path.join(os.tmpdir(),'tutor-rejection-test-')),originalFetch=global.fetch,oldKey=process.env.GEMINI_API_KEY;
 try{
  process.env.GEMINI_API_KEY='fake-reflected-key';global.fetch=async()=>new Response(JSON.stringify({error:{message:'fake-reflected-key'}}),{status:400});
  const out=path.join(temp,'run');assert.equal(await run(['--only','dev-integral','--out',out]),2);
  const result=readRun(out);assert.equal(result.summary.apiErrors,1);assert.equal(result.summary.cost.unknownTurns,1);assert.equal(result.rows[0].error.httpStatus,400);
  assert(!fs.readFileSync(path.join(out,'results.jsonl'),'utf8').includes('fake-reflected-key'));
 }finally{global.fetch=originalFetch;if(oldKey===undefined)delete process.env.GEMINI_API_KEY;else process.env.GEMINI_API_KEY=oldKey;fs.rmSync(temp,{recursive:true,force:true});}
});
test('eval model override uses actual requested model and leaves unpriced cost unknown',async()=>{
 const temp=fs.mkdtempSync(path.join(os.tmpdir(),'tutor-model-test-')),originalFetch=global.fetch,oldKey=process.env.GEMINI_API_KEY;
 try{
  process.env.GEMINI_API_KEY='fake-model-key';let called=false;
  global.fetch=async(url)=>{
   called=true;assert(url.includes('/models/gemini-3.5-flash:streamGenerateContent'));
   return new Response('data: '+JSON.stringify({modelVersion:'gemini-3.5-flash',candidates:[{finishReason:'STOP',content:{parts:[{text:'資料のe^xは誤りで、正しくはe^x(1+x)です。\n[[次]]\n積の微分とは？\n別の問題を解く'}]}}],usageMetadata:{promptTokenCount:100,candidatesTokenCount:40,totalTokenCount:140}})+'\n\n');
  };
  const out=path.join(temp,'run');assert.equal(await run(['--only','dev-derivative','--model','gemini-3.5-flash','--out',out]),0);assert(called);
  const result=readRun(out);assert.equal(result.manifest.model,'gemini-3.5-flash');assert.equal(result.manifest.modelOverride,true);assert.equal(result.rows[0].metrics.estimatedCostUSD,null);assert.equal(result.rows[0].metrics.costUnknownReason,'unpriced_model');assert.equal(result.summary.cost.unknownTurns,1);
 }finally{global.fetch=originalFetch;if(oldKey===undefined)delete process.env.GEMINI_API_KEY;else process.env.GEMINI_API_KEY=oldKey;fs.rmSync(temp,{recursive:true,force:true});}
});
test('unexpected model identity aborts the experiment after one request',async()=>{
 const temp=fs.mkdtempSync(path.join(os.tmpdir(),'tutor-identity-test-')),originalFetch=global.fetch,oldKey=process.env.GEMINI_API_KEY;
 try{
  let calls=0;process.env.GEMINI_API_KEY='fake-identity-key';global.fetch=async()=>{calls++;return new Response('data: '+JSON.stringify({modelVersion:'gemini-3.6-flash',candidates:[{finishReason:'STOP',content:{parts:[{text:'e^x(1+x)'}]}}]})+'\n\n');};
  const out=path.join(temp,'run');assert.equal(await run(['--only','dev-derivative','--model','gemini-3.5-flash','--repeat','3','--out',out]),2);assert.equal(calls,1);
  const result=readRun(out);assert.equal(result.manifest.complete,false);assert.equal(result.manifest.abortReason,'CHAT_MODEL_MISMATCH');assert.equal(result.rows[0].error.category,'model_identity');
 }finally{global.fetch=originalFetch;if(oldKey===undefined)delete process.env.GEMINI_API_KEY;else process.env.GEMINI_API_KEY=oldKey;fs.rmSync(temp,{recursive:true,force:true});}
});
