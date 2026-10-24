const {test}=require('node:test'),assert=require('node:assert/strict');
const p=require('../lib/pricing'),d=require('../lib/domain'),{GroqImageInterpreter,groqAudio}=require('../lib/providers');
const structure={sections:[],warnings:[]};
const near=(a,b)=>assert(Math.abs(a-b)<1e-12,`${a} != ${b}`);
test('Measured image usage: 2940/417/3357 tokens -> exact input/output/total estimate',()=>{
 const u=p.measuredUsage({prompt_tokens:2940,completion_tokens:417,total_tokens:3357});
 assert.deepEqual(u,{promptTokens:2940,completionTokens:417,totalTokens:3357});
 const cost=p.estimateImage(d.IMAGE_MODEL,u);near(cost.inputCostUSD,0.002352);near(cost.outputCostUSD,0.001668);near(cost.estimatedCostUSD,0.004020);
 assert.equal(cost.pricing.pricingAsOf,'2026-10-08');
});
test('Missing/invalid usage is unknown, never zero or independently tokenized',()=>{
 for(const raw of [undefined,{prompt_tokens:-1,completion_tokens:'2',total_tokens:NaN},{prompt_tokens:12.5}]){
  const u=p.measuredUsage(raw);assert.deepEqual(u,{promptTokens:null,completionTokens:null,totalTokens:null});assert.equal(p.estimateImage(d.IMAGE_MODEL,u).estimatedCostUSD,null);
 }
 const u=p.measuredUsage({prompt_tokens:100,completion_tokens:10});assert.equal(u.totalTokens,null);near(p.estimateImage(d.IMAGE_MODEL,u).estimatedCostUSD,0.00012);
 assert.equal(p.estimateImage('unknown-model',u).estimatedCostUSD,null);
});
test('Audio is per hour, minimum 10 seconds, no undocumented rounding',()=>{
 const short=p.estimateAudio(d.AUDIO_MODEL,3);assert.equal(short.billedAudioSeconds,10);near(short.estimatedCostUSD,10/3600*0.04);
 const exact=p.estimateAudio(d.AUDIO_MODEL,10.125);assert.equal(exact.billedAudioSeconds,10.125);
 const long=p.estimateAudio(d.AUDIO_MODEL,180);near(long.estimatedCostUSD,0.002);
 const api=p.estimateAudio(d.AUDIO_MODEL,15,12.3);assert.equal(api.audioDurationSeconds,12.3);assert.equal(api.durationSource,'Groq response duration');
 assert.equal(p.estimateAudio(d.AUDIO_MODEL,0).estimatedCostUSD,null);
});
test('OCR one image has standard paid estimate, with explicit free tier/volume assumptions',()=>{
 const c=p.estimateOCR();near(c.estimatedCostUSD,0.0015);assert.equal(c.imageUnits,1);assert.equal(c.pricing.freeMonthlyUnits,1000);
 assert.deepEqual(c.pricing.volumeTiers,[{fromUnit:1001,pricePerThousand:1.5},{fromUnit:5000001,pricePerThousand:0.6}]);assert(c.notes.join(' ').includes('Monthly usage is unknown'));
});
test('Real provider response usage survives structured-output error and truncated response',async()=>{
 for(const [finish,content] of [['stop','invalid JSON'],['length','{}']]){
  let n=0;const ai=new GroqImageInterpreter('test-only',async()=>new Response(JSON.stringify(++n===1?{data:[{id:d.IMAGE_MODEL}]}:{model:d.IMAGE_MODEL,usage:{prompt_tokens:2940,completion_tokens:417,total_tokens:3357},choices:[{finish_reason:finish,message:{content}}]})));
  const result=await d.compareImage('vision_llm',Buffer.from('img'),'image/jpeg',{recognize:()=>assert.fail()},ai);
  assert(result.results[0].error);assert.equal(result.results[0].usage.totalTokens,3357);near(result.results[0].estimatedCost.estimatedCostUSD,0.004020);assert.equal(result.finalEvidenceText,'');
 }
});
test('Provider success propagates measured usage and combined OCR + AI costs without double-counting',async()=>{
 let n=0;const ai=new GroqImageInterpreter('test-only',async()=>new Response(JSON.stringify(++n===1?{data:[{id:d.IMAGE_MODEL}]}:{model:d.IMAGE_MODEL,usage:{prompt_tokens:2940,completion_tokens:417,total_tokens:3357},choices:[{finish_reason:'stop',message:{content:JSON.stringify(structure)}}]})));
 const result=await d.compareImage('vision_ocr_llm',Buffer.from('img'),'image/jpeg',{recognize:async()=>({text:'test',structured:{},estimatedCost:p.estimateOCR()})},ai);
 assert.equal(result.results.length,2);near(result.results.reduce((v,x)=>v+x.estimatedCost.estimatedCostUSD,0),0.00552);assert(result.totalProcessingMs>=0);
});
test('HTTP failure does not invent a free request or usage',async()=>{
 let n=0;const ai=new GroqImageInterpreter('test-only',async()=>++n===1?new Response(JSON.stringify({data:[{id:d.IMAGE_MODEL}]})):new Response('{}',{status:429}));
 const result=await d.compareImage('vision_llm',Buffer.from('img'),'image/jpeg',{recognize:()=>assert.fail()},ai);
 assert.equal(result.results[0].error,'LAB_PROVIDER_RATE_LIMIT');assert.equal(result.results[0].estimatedCost.estimatedCostUSD,null);
});
test('Audio provider returns measured duration billing estimate and independent timestamp JSON',async()=>{
 // Valid 1-second mono PCM WAV, ffprobe executes locally; provider response is mocked.
 const bytes=Buffer.alloc(44+16000*2);bytes.write('RIFF');bytes.writeUInt32LE(bytes.length-8,4);bytes.write('WAVEfmt ',8);bytes.writeUInt32LE(16,16);bytes.writeUInt16LE(1,20);bytes.writeUInt16LE(1,22);bytes.writeUInt32LE(16000,24);bytes.writeUInt32LE(32000,28);bytes.writeUInt16LE(2,32);bytes.writeUInt16LE(16,34);bytes.write('data',36);bytes.writeUInt32LE(bytes.length-44,40);
 const result=await groqAudio(bytes,'audio/wav','test-only',async()=>new Response(JSON.stringify({text:'synthetic',duration:1,segments:[{start:0,end:1,text:'synthetic'}]})));
 assert.equal(result.error,null);assert.equal(result.estimatedCost.audioDurationSeconds,1);assert.equal(result.estimatedCost.billedAudioSeconds,10);near(result.estimatedCost.estimatedCostUSD,10/3600*0.04);assert.equal(result.usage,undefined);assert(JSON.parse(result.structuredResult).segments.length);
});
