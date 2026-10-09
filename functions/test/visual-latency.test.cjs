const {test}=require('node:test'),assert=require('node:assert/strict'),path=require('node:path');
const {semaphore,boundedPages}=require('../lib/ai/latency'),{extractAutoImage,extractAutoPDF}=require('../lib/ai/visualExtraction'),{imageUsage}=require('../lib/ai/pricing');
const fixtures=require('../../scripts/image_router_fixtures.cjs'),pdf=require('../../scripts/visual_router_fixtures.cjs');
const dir=path.resolve(__dirname,'../../build/visual-latency/unit'),cases=fixtures.generate(dir);
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
function cp(){const data=new Map();return {alive:async()=>{},load:async k=>data.get(k),save:async(k,v)=>data.set(k,v),data};}
function providers(probe,delay=0){const calls={ai:0,ocr:0,peakAI:0,peakOCR:0},active={ai:0,ocr:0};return {calls,ocr:async()=>{calls.ocr++;calls.peakOCR=Math.max(calls.peakOCR,++active.ocr);await sleep(delay);active.ocr--;return probe},ai:{recognize:async()=>{calls.ai++;calls.peakAI=Math.max(calls.peakAI,++active.ai);await sleep(delay);active.ai--;return {units:[{text:'Observation → Question. Only the visible connection.',method:'multimodal_ai',locator:{imageIndex:1},flags:[]}],totalUnits:1,failedUnits:[],recognition:imageUsage({prompt_tokens:100,completion_tokens:10,total_tokens:110},'qwen/qwen3.8-27b',delay)}}}};}
test('local connector skip preserves all real raster routes and selected final text',async()=>{
 for(const f of cases.filter(x=>x.type!=='pdf')){const before=providers(f.probe),after=providers(f.probe),file=path.join(dir,f.file);
 const b=await extractAutoImage(file,'test',cp(),before,{skipLocalFastPath:true}),a=await extractAutoImage(file,'test',cp(),after);
 assert.deepEqual(a.units,b.units,f.key);assert.equal(a.recognition.routing.pages[0].route,b.recognition.routing.pages[0].route,f.key);
 if(['two-label-arrow','short-arrow-flow'].includes(f.key)){assert.equal(before.calls.ocr,1);assert.equal(after.calls.ocr,0);assert.equal(a.recognition.routing.pages[0].ocrProbeSkipped,true);assert.equal(a.recognition.routing.pages[0].ocrProbeSkipReason,'local_connector_signal');}
 if(['plain','paragraph'].includes(f.key)){assert.equal(after.calls.ocr,1);assert.equal(after.calls.ai,0);}
 }
});
test('PDF native pages publish first, bounded providers preserve order/checkpoints/text',async()=>{
 const fs=require('node:fs'),file=path.join(dir,'parallel.pdf'),types=['diagram','text','scanned','diagram','scanned','text','diagram','scanned'];fs.writeFileSync(file,pdf.pdf(types));
 const c=cp(),p=providers(pdf.image('scanned').probe,40),preview=[];c.pageReady=async r=>preview.push(r.unit.locator.pageNumber);
 const result=await extractAutoPDF(file,'test',c,p);assert.deepEqual(preview.slice(0,2),[2,6]);assert.deepEqual(result.units.map(x=>x.locator.pageNumber),types.map((_,i)=>i+1));assert(p.calls.peakAI<=2&&p.calls.peakAI===2);assert(p.calls.peakOCR<=3);assert.equal(result.recognition.latency.nativePageCount,2);
 const previous={...p.calls};await extractAutoPDF(file,'test',c,p);assert.deepEqual(p.calls,previous);const cached=await extractAutoPDF(file,'test',c,p);assert.equal(cached.recognition.latency.providerCalls,0);assert.equal(cached.recognition.latency.checkpointHits,8);
 const b=await extractAutoPDF(file,'test',cp(),providers(pdf.image('scanned').probe),{sequential:true});assert.deepEqual(result.units,b.units);assert.deepEqual(result.recognition.routing.pages.map(x=>x.route),b.recognition.routing.pages.map(x=>x.route));
});
test('bounded jobs drain active failure, stop launching, preserve original error',async()=>{
 let started=0,active=0;const jobs=Array.from({length:10},(_,i)=>async()=>{started++;active++;await sleep(i?20:1);active--;if(i===0)throw Error('IMAGE_AI_RATE_LIMIT');return i});await assert.rejects(boundedPages(jobs,2),/IMAGE_AI_RATE_LIMIT/);assert.equal(active,0);assert.equal(started,2);
 const gate=semaphore(2);let peak=0;await Promise.all(Array.from({length:30},()=>gate(async()=>{peak=Math.max(peak,++active);await sleep(1);active--})));assert.equal(peak,2);
});
test('AI fast path failure makes no OCR call and publishes no checkpoint',async()=>{
 const f=cases.find(x=>x.key==='short-arrow-flow'),p=providers(f.probe),c=cp();p.ai.recognize=async()=>{throw Error('IMAGE_AI_RATE_LIMIT')};await assert.rejects(extractAutoImage(path.join(dir,f.file),'test',c,p),/RATE_LIMIT/);assert.equal(p.calls.ocr,0);assert(!c.data.has('image-auto-v1-final'));
});
test('operator resizing is Dev-only and never changes production/default dimensions',()=>{
 const {devVisualOptions}=require('../lib/ai/latency');for(const project of ['forta-aogaku','demo-aogaku-input','unknown'])assert.deepEqual(devVisualOptions(project,{benchmarkProviderMaxSide:1200}),{});assert.deepEqual(devVisualOptions('forta-aogaku-dev',{benchmarkProviderMaxSide:1200}),{providerMaxSide:1200});for(const side of [640,0,-1,Infinity,'1200',100000])assert.deepEqual(devVisualOptions('forta-aogaku-dev',{benchmarkProviderMaxSide:side}),{});
});
test('429 drains PDF work; retry processes only pages without final checkpoints',async()=>{
 const fs=require('node:fs'),file=path.join(dir,'retry.pdf');fs.writeFileSync(file,pdf.pdf(['diagram','text','diagram','diagram','diagram']));const c=cp(),p=providers(pdf.image('plain').probe,10),recognize=p.ai.recognize;let attempted=0;p.ai.recognize=async(...args)=>{if(++attempted===2){await sleep(1);throw Error('IMAGE_AI_RATE_LIMIT')}return recognize(...args)};
 await assert.rejects(extractAutoPDF(file,'test',c,p),/RATE_LIMIT/);const completedAI=[...c.data].filter(([key,x])=>key.match(/^pdf-auto-v1-page-\d+$/)&&x.unit.method==='multimodal_ai').length;const before=p.calls.ai;p.ai.recognize=recognize;const result=await extractAutoPDF(file,'test',c,p);assert.equal(p.calls.ai-before,4-completedAI);assert.deepEqual(result.units.map(x=>x.locator.pageNumber),[1,2,3,4,5]);assert.equal(p.calls.ocr,0);
});
test('preview requires owner, processing lease and current run, never ready/shared/stale',()=>{
 const {previewAllowed}=require('../lib/ai/progressive');const s={ownerUserId:'fake-owner',sourceType:'pdf',pipelineVersion:'pdf-auto-v1',status:'extracting',previewRun:'run-1',leaseToken:'run-1'};assert.equal(previewAllowed(s,'fake-owner'),true);for(const update of [{status:'ready'},{status:'deleted'},{status:'queued'},{previewRun:'old-run'},{previewRun:undefined,leaseToken:undefined},{sourceType:'image'}])assert.equal(previewAllowed({...s,...update},'fake-owner'),false);assert.equal(previewAllowed(s,'fake-member'),false);
});
test('provably text-only PDF has no render/OCR/Qwen; vector inspection is preserved elsewhere',async()=>{
 const {PDFDocument}=require('../node_modules/@napi-rs/canvas'),fs=require('node:fs'),doc=new PDFDocument();for(let i=0;i<10;i++){const ctx=doc.beginPage(800,1000);ctx.font='22px Arial';ctx.fillStyle='black';for(let row=0;row<8;row++)ctx.fillText('Synthetic lecture plain embedded paragraph '+row,60,100+row*40);doc.endPage();}const file=path.join(dir,'no-vectors.pdf');fs.writeFileSync(file,doc.close());const p=providers(pdf.image('plain').probe),result=await extractAutoPDF(file,'test',cp(),p);assert.equal(result.recognition.latency.renderCount,0);assert.equal(result.recognition.latency.nativePageCount,10);assert.equal(p.calls.ocr,0);assert.equal(p.calls.ai,0);
});
