const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {chooseVisualRoute,emptyFeatures,aggregateRouting,routedPage}=require('../lib/ai/visualRouter');
const {extractAutoImage,extractAutoPDF}=require('../lib/ai/visualExtraction');
const {imageUsage}=require('../lib/ai/pricing');
const fixture=require('../../scripts/visual_router_fixtures.cjs');const dir=path.resolve(__dirname,'../../build/visual-router-fixtures'),manifest=fixture.generate(dir);
function checkpoint(){const values=new Map();let reservations=0;return {alive:async()=>{},load:async k=>values.get(k),save:async(k,v)=>values.set(k,v),reserveProviderCall:async()=>{reservations++},values,get reservations(){return reservations}};}
function providers(probe){const calls={ocr:0,ai:0};return {calls,ocr:async()=>{calls.ocr++;return probe},ai:{recognize:async()=>{calls.ai++;return {units:[{text:'Observation leads to a question and then an experiment. Synthetic visual evidence.',method:'multimodal_ai',locator:{imageIndex:1},flags:[]}],totalUnits:1,failedUnits:[],recognition:imageUsage({prompt_tokens:1969,completion_tokens:82,total_tokens:2051},'qwen/qwen3.8-27b',10)}}}};}
test('routing uses semantics even when OCR/native quality is perfect; ambiguous zone chooses AI',()=>{
 for(const extra of [{relationMark:true},{drawingScore:.8},{lineScore:.7},{nonTextCoverage:.7},{blockDispersion:1,readingOrderPenalty:1}]){const f={...emptyFeatures(),nativeTextLength:400,nativeTextQuality:1,ocrQuality:1,probeAvailable:true,...extra};assert.equal(chooseVisualRoute('pdf',f).route,'multimodal_ai');}
 assert.equal(chooseVisualRoute('pdf',{...emptyFeatures(),nativeTextLength:400,nativeTextQuality:1}).route,'native_text');assert.equal(chooseVisualRoute('image',{...emptyFeatures(),ocrQuality:1,probeAvailable:true}).route,'vision_ocr');
 assert.equal(chooseVisualRoute('image',{...emptyFeatures(),probeAvailable:true,ocrQuality:.6}).route,'multimodal_ai');
});
for(const f of manifest.images)test('real raster image routing: '+f.kind,async()=>{const cp=checkpoint(),p=providers(f.probe);const e=await extractAutoImage(path.join(dir,f.file),'test-only',cp,p);assert.equal(e.recognition.routing.pages[0].route,f.expected,JSON.stringify(e.recognition.routing.pages[0]));assert.equal(e.recognition.pipelineVersion,'image-auto-v1');assert.equal(p.calls.ocr,1);assert.equal(p.calls.ai,f.expected==='multimodal_ai'?1:0);assert(e.units[0].text);assert.equal(e.raw,undefined);
 const finalText=f.expected==='multimodal_ai'?'Observation leads to a question and then an experiment. Synthetic visual evidence.':f.probe.text.trim();
 assert.equal(e.units[0].text,finalText,'Only selected route text; no probe concatenation');
 const {chunksFor,selectContext}=require('../lib/ai/domain');const chunks=chunksFor(e.units);assert.equal(chunks.map(x=>x.text).join(''),finalText);assert.equal(selectContext(chunks.map(x=>({...x,sourceId:'synthetic'})),'lecture_summary','',30000).items[0].text,finalText);
 await extractAutoImage(path.join(dir,f.file),'test-only',cp,p);assert.equal(p.calls.ocr,1);assert.equal(p.calls.ai,f.expected==='multimodal_ai'?1:0);});
for(const f of manifest.pdfs)test('actual PDF renderer/page analyzer: '+f.file,async()=>{
 // For scanned page probes, the rendered bitmap has the same normalized boxes as the source.
 const p=providers(fixture.image('scanned').probe),cp=checkpoint();const e=await extractAutoPDF(path.join(dir,f.file),'test-only',cp,p);assert.deepEqual(e.recognition.routing.pages.map(x=>x.route),f.expected,JSON.stringify(e.recognition.routing.pages));assert.deepEqual(e.units.map(x=>x.locator.pageNumber),f.types.map((_,i)=>i+1));assert.equal(e.recognition.pipelineVersion,'pdf-auto-v1');const ai=f.expected.filter(x=>x==='multimodal_ai').length;assert.equal(p.calls.ai,ai);assert.equal(p.calls.ocr,f.expected.filter(x=>x==='vision_ocr').length);assert.equal(e.recognition.inputTokens,1969*ai);assert.equal(e.recognition.routing.counts.native_text,f.expected.filter(x=>x==='native_text').length);assert(!JSON.stringify(e.recognition).includes('rawText'));await extractAutoPDF(path.join(dir,f.file),'test-only',cp,p);assert.equal(p.calls.ai,ai);
});
test('selected AI failure remains retryable; completed probes survive retry; no OCR evidence fallback',async()=>{
 const f=manifest.images.find(x=>x.kind==='arrows'),cp=checkpoint(),p=providers(f.probe);p.ai.recognize=async()=>{p.calls.ai++;throw Object.assign(Error('IMAGE_AI_UNAVAILABLE'),{retryable:true})};
 await assert.rejects(extractAutoImage(path.join(dir,f.file),'test-only',cp,p),e=>e.retryable);assert.equal(p.calls.ai,1);assert.equal(p.calls.ocr,1);assert(!cp.values.has('image-auto-v1-final'));
 await assert.rejects(extractAutoImage(path.join(dir,f.file),'test-only',cp,p));assert.equal(p.calls.ocr,1,'OCR probe not billed again on retry');
});
test('billing includes OCR probe even for AI route; no unknown token/cost becomes zero',()=>{
 const f={...emptyFeatures(),relationMark:true};const ai=routedPage(chooseVisualRoute('image',f),{imageIndex:1},1,1,imageUsage({prompt_tokens:1969,completion_tokens:82,total_tokens:2051},'qwen/qwen3.8-27b',1));const total=aggregateRouting([ai],'image',1);assert.equal(total.routing.ocrUnits,1);assert(Math.abs(total.estimatedCostUSD-(.0019032+.0015))<1e-10);
 const native=routedPage(chooseVisualRoute('pdf',{...emptyFeatures(),nativeTextQuality:1}),{pageNumber:1},1,0);assert.equal(native.totalTokens,0);assert.equal(native.estimatedCostUSD,0);
 const unknown=routedPage(chooseVisualRoute('image',f),{imageIndex:1},1,1,imageUsage({},'qwen/qwen3.8-27b',1));assert.equal(aggregateRouting([unknown],'image',1).estimatedCostUSD,null);
});
test('provided science PDF: Scientific Method and image page use AI; simple text stays native',{skip:!fs.existsSync(path.resolve(__dirname,'../../build/visual-router-before/science.pdf'))},async()=>{
 const {openRouterPDF,analyzePDFPage}=require('../lib/ai/visualExtraction'),pdf=await openRouterPDF(path.resolve(__dirname,'../../build/visual-router-before/science.pdf'));
 try{assert.equal(pdf.doc.numPages,30);for(const [number,expected]of [[4,'multimodal_ai'],[6,'native_text'],[27,'multimodal_ai']]){const p=await pdf.doc.getPage(number),analysis=await analyzePDFPage(p,pdf.OPS);assert.equal(chooseVisualRoute('pdf',analysis.features).route,expected);p.cleanup();}}finally{await pdf.destroy();}
});

const imageCases=require('../../scripts/image_router_fixtures.cjs').generate(path.resolve(__dirname,'../../build/image-router-fixtures'));
for(const f of imageCases)test('image-only connector regression, OCR has no arrows: '+f.key,async()=>{
 const cp=checkpoint(),p=providers(f.probe),file=path.resolve(__dirname,'../../build/image-router-fixtures',f.file);
 const e=await (f.type==='pdf'?extractAutoPDF:extractAutoImage)(file,'test-only',cp,p),pages=e.recognition.routing.pages;
 assert.deepEqual(pages.map(x=>x.route),f.type==='pdf'?f.expected:[f.expected]);
 if(f.key.includes('arrow')){assert.equal(pages[0].features.relationMark,false);assert.equal(pages[0].features.lineScore,0);assert(pages[0].features.connectorComponents>0);assert.equal(pages[0].provider,'groq');assert.equal(pages[0].model,'qwen/qwen3.8-27b');assert.equal(e.units[0].text,'Observation leads to a question and then an experiment. Synthetic visual evidence.');}
 if(f.type==='pdf')assert(pages.every(x=>x.features.connectorComponents===undefined),'PDF signals must remain unchanged');
});
test('image-only geometry never changes PDF decisions or unreadable-probe fail-closed routing',()=>{
 const f={...emptyFeatures(),nativeTextQuality:1,ocrQuality:1,probeAvailable:true,connectorComponents:2};
 assert.equal(chooseVisualRoute('pdf',f).route,'native_text');assert.equal(chooseVisualRoute('image',f).route,'multimodal_ai');
 assert.equal(chooseVisualRoute('image',{...emptyFeatures()}).route,'multimodal_ai');
});

test('short arrow raster survives resolution changes and AI failures never publish probe text',async()=>{
 const {createCanvas,loadImage}=require('../node_modules/@napi-rs/canvas'),f=require('../../scripts/image_router_fixtures.cjs').relation(true),original=await loadImage(f.bytes);
 for(const width of [320,800,1600]){const canvas=createCanvas(width,width*1.25);canvas.getContext('2d').drawImage(original,0,0,canvas.width,canvas.height);const file=path.resolve(__dirname,'../../build/image-router-fixtures/scale-'+width+'.png');fs.writeFileSync(file,canvas.toBuffer('image/png'));const p=providers(f.probe),cp=checkpoint();const result=await extractAutoImage(file,'test-only',cp,p);assert.equal(result.units[0].method,'multimodal_ai');assert.equal(p.calls.ai,1);}
 const fcase=imageCases.find(x=>x.key==='short-arrow-flow'),file=path.resolve(__dirname,'../../build/image-router-fixtures',fcase.file),p=providers(fcase.probe),cp=checkpoint();p.ai.recognize=async()=>{p.calls.ai++;throw Object.assign(Error('IMAGE_AI_UNAVAILABLE'),{retryable:true});};
 await assert.rejects(extractAutoImage(file,'test-only',cp,p),e=>e.retryable);assert.equal(p.calls.ocr,1);assert.equal(p.calls.ai,1);assert(!cp.values.has('image-auto-v1-final'));
});
