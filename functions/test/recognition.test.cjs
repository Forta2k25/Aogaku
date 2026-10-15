const {test}=require('node:test'),assert=require('node:assert/strict');
const {GeminiImageRecognition,IMAGE_INSTRUCTIONS}=require('../lib/ai/recognition');
const {GEMINI_RETRY}=require('../lib/ai/gemini');GEMINI_RETRY.delaysMs=[0,0];
const {imageUsage,audioUsage}=require('../lib/ai/pricing');
const {admissionAllowed}=require('../lib/ai/admission');
const {chunksFor}=require('../lib/ai/domain');
const model='gemini-3.5-flash-lite',jpeg=Buffer.from([255,216,255,0]);
const response=(body,status=200)=>new Response(JSON.stringify(body),{status});
const gem=(text,{finish='STOP',usage={promptTokenCount:10,candidatesTokenCount:5,totalTokenCount:15},modelVersion=model}={})=>({modelVersion,usageMetadata:usage,candidates:[{finishReason:finish,content:{parts:[{text}]}}]});
test('image original bytes -> AI-only text -> chunks, measured usage and pricing',async()=>{
 const calls=[];const provider=new GeminiImageRecognition('test-only',async(url,options)=>{calls.push([url,options]);return response(gem(JSON.stringify({finalText:'親から子へ特徴が遺伝する。'}),{usage:{promptTokenCount:2940,candidatesTokenCount:317,thoughtsTokenCount:100,totalTokenCount:3357}}));});
 const e=await provider.recognize(jpeg,'image/jpeg');assert.equal(e.units[0].text,'親から子へ特徴が遺伝する。');assert.equal(e.units[0].method,'multimodal_ai');assert.equal(e.raw,undefined);
 const request=JSON.parse(calls[0][1].body);assert.equal(request.generationConfig.temperature,0);assert.equal(request.generationConfig.responseMimeType,'application/json');assert.equal(request.contents[0].parts[0].inline_data.data,jpeg.toString('base64'));assert.equal(request.systemInstruction.parts[0].text,IMAGE_INSTRUCTIONS);assert(IMAGE_INSTRUCTIONS.includes('推測・補完しない'));
 assert.equal(calls[0][0],'https://generativelanguage.googleapis.com/v1beta/models/'+model+':generateContent');assert.equal(calls[0][1].headers['x-goog-api-key'],'test-only');
 assert.equal(e.recognition.provider,'gemini');assert.equal(e.recognition.outputTokens,417,'thinking tokens are billed as output');assert.equal(e.recognition.totalTokens,3357);assert(Math.abs(e.recognition.estimatedCostUSD-(2940/1e6*.30+417/1e6*2.50))<1e-12);assert.equal(chunksFor(e.units)[0].method,'multimodal_ai');
 assert(calls.every(c=>c[0].startsWith('https://generativelanguage.googleapis.com/')));
});
test('overload (429/503) is retried briefly then fails retryable; other errors are not retried; no OCR/model fallback',async()=>{
 for(const status of [429,503]) { let calls=0;const p=new GeminiImageRecognition('test-only',async()=>{calls++;return response({},status)});await assert.rejects(p.recognize(jpeg,'image/jpeg'),e=>e.retryable&&e.code===(status===429?'IMAGE_AI_RATE_LIMIT':'IMAGE_AI_UNAVAILABLE'));assert.equal(calls,3); }
 let calls=0;const p=new GeminiImageRecognition('test-only',async()=>{calls++;return response({},500)});await assert.rejects(p.recognize(jpeg,'image/jpeg'),e=>e.retryable);assert.equal(calls,1);
 calls=0;const q=new GeminiImageRecognition('test-only',async()=>++calls===1?response({},503):response(gem(JSON.stringify({finalText:'復旧後の結果'}))));assert.equal((await q.recognize(jpeg,'image/jpeg')).units[0].text,'復旧後の結果');assert.equal(calls,2);
});
test('missing/invalid usage remains unknown; returned unpriced model never gets invented price',()=>{
 assert.equal(imageUsage({},model,1).estimatedCostUSD,null);assert.equal(imageUsage({prompt_tokens:1,completion_tokens:1,total_tokens:-1},'unknown',1).estimatedCostUSD,null);assert.equal(imageUsage({prompt_tokens:3,total_tokens:4},model,1).outputTokens,null);
});
test('invalid/truncated JSON never becomes evidence; usage survives (invalid JSON is retried once in place, truncation is not)',async()=>{
 let calls=0;const p=new GeminiImageRecognition('test-only',async()=>{calls++;return response(gem('bad',{finish:'STOP'}))});
 await assert.rejects(p.recognize(jpeg,'image/jpeg'),e=>e.retryable&&e.code==='IMAGE_AI_INVALID_RESULT'&&e.recognition.totalTokens===30);assert.equal(calls,2);
 calls=0;const q=new GeminiImageRecognition('test-only',async()=>{calls++;return response(gem('bad',{finish:'MAX_TOKENS'}))});
 await assert.rejects(q.recognize(jpeg,'image/jpeg'),e=>e.retryable&&e.code==='IMAGE_AI_INCOMPLETE'&&e.recognition.totalTokens===15);assert.equal(calls,1);
});
test('a malformed JSON answer is retried once in place; both calls are billed; schema is requested',async()=>{
 const sent=[];let calls=0;const p=new GeminiImageRecognition('test-only',async(u,o)=>{sent.push(JSON.parse(o.body));return response(++calls===1?gem('{"finalText": "壊れた',{finish:'STOP'}):gem(JSON.stringify({finalText:'直った結果'})))});
 const e=await p.recognize(jpeg,'image/jpeg');assert.equal(e.units[0].text,'直った結果');assert.equal(calls,2);assert.equal(e.recognition.totalTokens,30);
 assert.equal(sent[0].generationConfig.responseSchema.required[0],'finalText');assert.equal(sent[0].generationConfig.responseSchema.type,'OBJECT');
});
test('parseFinalText: valid JSON, salvage of finalText from broken JSON, and null when absent',()=>{
 const {parseFinalText}=require('../lib/ai/recognition');
 assert.equal(parseFinalText('{"finalText":"a\\nb"}'),'a\nb');
 assert.equal(parseFinalText('{"visibleText":["x" "y"],"finalText":"救えた\\"文\\"章"}'),'救えた"文"章');
 assert.equal(parseFinalText('{"visibleText":["x" "y"],"finalText":"生の\n改行"}'),'生の\n改行');
 assert.equal(parseFinalText('not json'),null);assert.equal(parseFinalText('{"a":1}'),null);
});
test('missing key rejects before any provider request',async()=>{let calls=0;const p=new GeminiImageRecognition('',async()=>{calls++;return response({})});await assert.rejects(p.recognize(jpeg,'image/jpeg'),e=>e.code==='IMAGE_AI_NOT_CONFIGURED');assert.equal(calls,0);});
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
 const p=new GeminiImageRecognition('test-only',async()=>response(gem('{"finalText":"wrong model"}',{modelVersion:'gemini-other'})));
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

test('structured visible-only response publishes only readable finalText, never intermediate fields',async()=>{
 const finalText='Observation → Question → Hypothesis → Experiment → Conclusion → Result の順に矢印で示されている。戻り矢印は確認できない。';
 const p=new GeminiImageRecognition('test-only',async(url,options)=>{
  const sent=JSON.parse(options.body);assert.equal(sent.systemInstruction.parts[0].text,IMAGE_INSTRUCTIONS);assert.equal(sent.contents[0].role,'user');assert.equal(sent.contents[0].parts.length,1);
  return response(gem(JSON.stringify({visibleText:['Observation','Result'],visibleRelations:['Observation → Question'],description:'円形配置',uncertainty:['戻り矢印は確認できない'],finalText}),{usage:{promptTokenCount:1000,candidatesTokenCount:120,totalTokenCount:1120}}));
 });
 const e=await p.recognize(jpeg,'image/jpeg');assert.equal(e.units[0].text,finalText);assert.equal(e.raw,undefined);
 assert(!JSON.stringify(chunksFor(e.units)).includes('visibleRelations'));assert.equal(e.recognition.totalTokens,1120);
});
