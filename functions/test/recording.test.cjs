const {test}=require('node:test'),assert=require('node:assert/strict');
const {RECORDING,validateSegment,transcribeSegment,validateBlock,validateNote,blockPrompt,notePrompt,generateText}=require('../lib/ai/recording');
const {CHAT}=require('../lib/ai/chat');
const {GEMINI_RETRY}=require('../lib/ai/gemini');GEMINI_RETRY.delaysMs=[0,0];

const m4a=Buffer.concat([Buffer.from([0,0,0,0x20]),Buffer.from('ftypM4A '),Buffer.alloc(200,1)]).toString('base64');
const seg=(over={})=>({recordingId:'rec-12345678',index:0,durationSeconds:60,audio:m4a,...over});
const code=c=>e=>e.code===c;

test('segment validation: only a ~1 minute m4a with a sane id/index/duration is accepted',()=>{
 const ok=validateSegment(seg());assert.equal(ok.index,0);assert.equal(ok.recordingId,'rec-12345678');assert(Buffer.isBuffer(ok.audio));
 for(const bad of [{recordingId:'x'},{recordingId:'a/../b-12345'},{index:-1},{index:RECORDING.maxSegmentIndex+1},{index:1.5},
   {durationSeconds:0},{durationSeconds:RECORDING.segmentMaxSeconds+1},{durationSeconds:'60'},{audio:''},{audio:'!!'},
   {audio:Buffer.from('not an m4a at all, just text').toString('base64')},
   {audio:Buffer.alloc(RECORDING.maxSegmentBytes+1,0).toString('base64')}])
  assert.throws(()=>validateSegment(seg(bad)),e=>['INVALID_RECORDING','INVALID_DURATION','INVALID_AUDIO'].includes(e.code),JSON.stringify(bad).slice(0,60));
 assert.throws(()=>validateSegment(null),code('INVALID_RECORDING'));
});

const groqResponse=(segments,status=200)=>async()=>({ok:status>=200&&status<300,status,json:async()=>({segments})});
test('transcribeSegment: joins text, keeps times, drops silence, flags low confidence; the key stays in the header only',async()=>{
 let seen;
 const r=await transcribeSegment(Buffer.from('x'),'k',async(u,init)=>{seen={u,init};return groqResponse([
  {start:0,end:2.5,text:' 今日は偏微分をやります。',no_speech_prob:0.01,avg_logprob:-0.2,compression_ratio:1.2},
  {start:2.5,end:4,text:'(無音の幻聴)',no_speech_prob:0.95},
  {start:4,end:6,text:'えーと',no_speech_prob:0.1,avg_logprob:-1.5,compression_ratio:1.1},
  {start:6,end:7,text:'',no_speech_prob:0}])()});
 assert.equal(r.text,'今日は偏微分をやります。えーと');assert.equal(r.segments.length,2);
 assert.deepEqual([r.segments[0].startMs,r.segments[0].endMs,r.segments[0].lowConfidence],[0,2500,false]);assert.equal(r.segments[1].lowConfidence,true);
 assert(seen.u.startsWith('https://api.groq.com/'));assert.equal(seen.init.headers.Authorization,'Bearer k');assert(!String(seen.u).includes('k='));
});
test('transcribeSegment: missing key / provider errors map to codes; only overload is retryable',async()=>{
 await assert.rejects(transcribeSegment(Buffer.from('x'),''),code('ASR_NOT_CONFIGURED'));
 await assert.rejects(transcribeSegment(Buffer.from('x'),'k',groqResponse([],429)),e=>e.code==='ASR_UNAVAILABLE'&&e.retryable===true);
 await assert.rejects(transcribeSegment(Buffer.from('x'),'k',groqResponse([],503)),e=>e.retryable===true);
 await assert.rejects(transcribeSegment(Buffer.from('x'),'k',groqResponse([],400)),e=>e.code==='ASR_UNAVAILABLE'&&!e.retryable);
 await assert.rejects(transcribeSegment(Buffer.from('x'),'k',async()=>({ok:true,status:200,json:async()=>({})})),code('ASR_MISSING_TIMESTAMPS'));
 await assert.rejects(transcribeSegment(Buffer.from('x'),'k',async()=>{throw new Error('net')}),e=>e.code==='ASR_UNAVAILABLE'&&e.retryable===true);
});

test('block and note validation: bounded, ordered, and never trusted to be well-formed',()=>{
 const b=validateBlock({text:'  講義の文字  ',startMinute:10,endMinute:20,previousSummary:'前の要約'});
 assert.deepEqual([b.text,b.startMinute,b.endMinute,b.previousSummary],['講義の文字',10,20,'前の要約']);
 assert.equal(validateBlock({text:'あ'.repeat(20000),startMinute:0,endMinute:10}).text.length,RECORDING.blockMaxChars);
 for(const bad of [null,{text:'',startMinute:0,endMinute:1},{text:'a',startMinute:5,endMinute:1},{text:'a',startMinute:-1,endMinute:1},{text:'a',startMinute:0,endMinute:RECORDING.minuteMax+1},{text:'a',startMinute:'0',endMinute:1}])
  assert.throws(()=>validateBlock(bad),code('INVALID_RECORDING'));
 const n=validateNote({summaries:[{startMinute:0,endMinute:10,text:'要約1'},{startMinute:10,endMinute:20,text:'要約2'}]});assert.equal(n.summaries.length,2);
 for(const bad of [null,{summaries:[]},{summaries:'x'},{summaries:Array(RECORDING.maxSummaries+1).fill({startMinute:0,endMinute:1,text:'a'})},
   {summaries:[{startMinute:3,endMinute:1,text:'a'}]},{summaries:[{startMinute:0,endMinute:1,text:''}]},
   {summaries:Array(15).fill({startMinute:0,endMinute:1,text:'あ'.repeat(RECORDING.summaryMaxChars)})}])
  assert.throws(()=>validateNote(bad),code('INVALID_RECORDING'));
});
test('prompts: the time range and the transcript are present; the previous summary is marked context-only',()=>{
 const p=blockPrompt({text:'本文',startMinute:10,endMinute:20,previousSummary:'前の要約'});
 assert(p.includes('10〜20分の文字起こし')&&p.includes('本文')&&p.includes('前の要約')&&p.includes('繰り返さない'));
 assert(!blockPrompt({text:'本文',startMinute:0,endMinute:10,previousSummary:''}).includes('直前までの要約'));
 const n=notePrompt({summaries:[{startMinute:0,endMinute:10,text:'A'},{startMinute:10,endMinute:20,text:'B'}]});
 assert(n.indexOf('0〜10分')<n.indexOf('10〜20分')&&n.includes('A')&&n.includes('B'));
});

const gem=(text,over={},finish='STOP')=>({modelVersion:CHAT.model,candidates:[{finishReason:finish,content:{parts:[{text}]}}],usageMetadata:{promptTokenCount:3000,candidatesTokenCount:300,totalTokenCount:3300},...over});
const ok=body=>async()=>({ok:true,status:200,json:async()=>body});
test('generateText: returns text + measured usage; truncated, empty, wrong-model and HTTP errors fail without a half answer',async()=>{
 const r=await generateText('k','SYS','USER',ok(gem('話題: 偏微分')));
 assert.equal(r.text,'話題: 偏微分');assert.equal(r.recognition.totalTokens,3300);assert(r.recognition.estimatedCostUSD>0);
 await assert.rejects(generateText('k','S','U',ok(gem('途中',{},'MAX_TOKENS'))),code('CHAT_INVALID_RESULT'));
 await assert.rejects(generateText('k','S','U',ok(gem('  '))),code('CHAT_INVALID_RESULT'));
 await assert.rejects(generateText('k','S','U',ok(gem('x',{modelVersion:'gemini-other'}))),code('CHAT_MODEL_MISMATCH'));
 await assert.rejects(generateText('','S','U',ok(gem('x'))),code('CHAT_NOT_CONFIGURED'));
 await assert.rejects(generateText('k','S','U',async()=>({ok:false,status:429,json:async()=>({}),clone(){return this}})),e=>e.code==='CHAT_RATE_LIMIT'&&e.retryable===true);
});

test('segment language: auto/ja/en are accepted (old clients default to ja); anything else is refused',()=>{
 assert.equal(validateSegment(seg()).language,'ja');
 for(const l of ['auto','ja','en']) assert.equal(validateSegment(seg({language:l})).language,l);
 for(const bad of ['fr','','JA',null,5,'auto ']) assert.throws(()=>validateSegment(seg({language:bad})),code('INVALID_RECORDING'),String(bad));
});
test('transcribeSegment sends the language only when it is fixed; auto lets Whisper detect it (English lectures)',async()=>{
 const langs=[];
 const capture=async(u,init)=>{langs.push(init.body.get('language'));return groqResponse([{start:0,end:2,text:' Partial derivatives.',no_speech_prob:0.01,avg_logprob:-0.2,compression_ratio:1.2}])()};
 for(const l of ['ja','en','auto']) await transcribeSegment(Buffer.from('x'),'k',capture,l);
 assert.deepEqual(langs,['ja','en',null],'auto は language を送らない');
 langs.length=0;await transcribeSegment(Buffer.from('x'),'k',capture);assert.deepEqual(langs,['ja'],'既定は日本語(これまでどおり)');
});
