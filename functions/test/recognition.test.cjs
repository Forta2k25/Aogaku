const {test}=require('node:test'),assert=require('node:assert/strict');
const {GroqImageRecognition,IMAGE_INSTRUCTIONS}=require('../lib/ai/recognition');
const {imageUsage,audioUsage}=require('../lib/ai/pricing');
const {admissionAllowed}=require('../lib/ai/admission');
const {chunksFor}=require('../lib/ai/domain');
const model='qwen/qwen3.8-27b',jpeg=Buffer.from([255,216,255,0]);
const response=(body,status=200)=>new Response(JSON.stringify(body),{status});
test('image original bytes -> AI-only text -> chunks, measured usage and pricing',async()=>{
 const calls=[];const provider=new GroqImageRecognition('test-only',async(url,options)=>{calls.push([url,options]);return response(calls.length===1?{data:[{id:model,active:true}]}:{model,usage:{prompt_tokens:2940,completion_tokens:417,total_tokens:3357},choices:[{finish_reason:'stop',message:{content:JSON.stringify({finalText:'親から子へ特徴が遺伝する。'})}}]});});
 const e=await provider.recognize(jpeg,'image/jpeg');assert.equal(e.units[0].text,'親から子へ特徴が遺伝する。');assert.equal(e.units[0].method,'multimodal_ai');assert.equal(e.raw,undefined);
 const request=JSON.parse(calls[1][1].body);assert.equal(request.model,model);assert.equal(request.reasoning_effort,'none');assert(request.messages[0].content[1].image_url.url.endsWith(jpeg.toString('base64')));assert(IMAGE_INSTRUCTIONS.includes('推測・補完しない'));
 assert.equal(e.recognition.totalTokens,3357);assert(Math.abs(e.recognition.estimatedCostUSD-.004020)<1e-12);assert.equal(chunksFor(e.units)[0].method,'multimodal_ai');
 assert(calls.every(c=>c[0].startsWith('https://api.groq.com/')));
});
test('provider 429/5xx safely fail retryable; no OCR/model fallback or automatic retry',async()=>{
 for(const status of [429,500,503]) { let calls=0;const p=new GroqImageRecognition('test-only',async()=>++calls===1?response({data:[{id:model}]}):response({},status));await assert.rejects(p.recognize(jpeg,'image/jpeg'),e=>e.retryable);assert.equal(calls,2); }
});
test('missing/invalid usage remains unknown; returned unpriced model never gets invented price',()=>{
 assert.equal(imageUsage({},model,1).estimatedCostUSD,null);assert.equal(imageUsage({prompt_tokens:1,completion_tokens:1,total_tokens:-1},'unknown',1).estimatedCostUSD,null);assert.equal(imageUsage({prompt_tokens:3,total_tokens:4},model,1).outputTokens,null);
});
test('invalid/truncated JSON never becomes evidence and measured usage survives',async()=>{
 for(const finish of ['stop','length']) {let calls=0;const p=new GroqImageRecognition('test-only',async()=>response(++calls===1?{data:[{id:model}]}:{model,usage:{prompt_tokens:10,completion_tokens:5,total_tokens:15},choices:[{finish_reason:finish,message:{content:'bad'}}]}));await assert.rejects(p.recognize(jpeg,'image/jpeg'),e=>e.retryable&&e.recognition.totalTokens===15);}
});
test('missing model rejects before billable request',async()=>{let calls=0;const p=new GroqImageRecognition('test-only',async()=>{calls++;return response({data:[]});});await assert.rejects(p.recognize(jpeg,'image/jpeg'),e=>e.code==='IMAGE_MODEL_UNAVAILABLE');assert.equal(calls,1);});
test('audio costs use billed seconds including per-part minimum; never tokens',()=>{const m=audioUsage(180,180,1);assert.equal(m.estimatedCostUSD,.002);assert.equal(m.inputTokens,null);assert.equal(m.model,'whisper-large-v3-turbo');assert.equal(audioUsage(3,10,1).billedAudioSeconds,10);});
test('public mode is opt-in, requires enforcement; existing production pilot contract preserved',()=>{
 assert(!admissionAllowed('forta-aogaku','public','[]',false,'anon'));
 assert(admissionAllowed('forta-aogaku','public','[]',true,'anon'));
 assert(!admissionAllowed('forta-aogaku','unknown','["anon"]',true,'anon'));
 assert(admissionAllowed('forta-aogaku','pilot','["pilot"]',false,'pilot'));
 assert(!admissionAllowed('forta-aogaku','pilot','["pilot"]',false,'outsider'));
 assert(!admissionAllowed('forta-aogaku','pilot','["*"]',false,'pilot'));
});
test('all new chunks have stable unit identity / offsets for exact overlap reconstruction',()=>{
 const units=[{text:'A'.repeat(1700),locator:{imageIndex:1},method:'multimodal_ai',flags:[]},{text:'A'.repeat(1700),locator:{startMs:0,endMs:1200},method:'groq_asr',flags:[]}];
 const chunks=chunksFor(units);assert.equal(chunks.length,4);assert.equal(chunks[1].locator.startChar,1300);assert.equal(chunks[1].locator.endChar,1700);assert.equal(chunks[2].unitIndex,1);
});

test('UTF-16 chunk offsets preserve complete surrogate pairs and exact source text',()=>{
 const text='a'.repeat(1299)+'😀'+'b'.repeat(198)+'😀'+'終'.repeat(2000);
 const chunks=chunksFor([{text,locator:{},method:'multimodal_ai',flags:[]}]);
 let rebuilt='',end=0;for(const chunk of chunks){assert(!/^[\uDC00-\uDFFF]|[\uD800-\uDBFF]$/.test(chunk.text));rebuilt+=chunk.text.slice(Math.max(0,end-chunk.locator.startChar));end=chunk.locator.endChar;}assert.equal(rebuilt,text);
});

test('unexpected provider model is refused, never silently priced or published',async()=>{
 let calls=0;const p=new GroqImageRecognition('test-only',async()=>response(++calls===1?{data:[{id:model}]}:{model:'other',usage:{prompt_tokens:1,completion_tokens:1},choices:[{finish_reason:'stop',message:{content:'{"finalText":"wrong model"}'}}]}));
 await assert.rejects(p.recognize(jpeg,'image/jpeg'),e=>e.code==='IMAGE_MODEL_MISMATCH'&&e.retryable);
});
test('image AI checkpoint contract rejects old OCR and missing metadata without any provider call',async()=>{
 const {extractImage}=require('../lib/ai/extractors');let calls=0;
 const provider={recognize:async()=>{calls++;throw Error('Should never call');}};
 for(const cached of [{units:[{text:'OCR',method:'vision_ocr',locator:{},flags:[]}]},
   {recognition:{...imageUsage({prompt_tokens:1,completion_tokens:1},model,1),model:'other'},units:[{text:'text',method:'multimodal_ai',locator:{},flags:[]}]}]) {
  await assert.rejects(extractImage('unused','image/jpeg','test-only',{alive:async()=>{},load:async key=>{assert.equal(key,'image-ai-v2');return cached;},save:async()=>assert.fail('No writes')},provider),e=>e.code==='IMAGE_PIPELINE_MISMATCH'&&e.retryable);
 }
 assert.equal(calls,0);
});
