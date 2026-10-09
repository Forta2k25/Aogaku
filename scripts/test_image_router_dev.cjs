const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
const {modules}=require('./image_router_dev.cjs');
test('Dev image routing patch has exactly two modules and one worker; no env/IAM/Rules/Secret mutation',()=>{
 assert.deepEqual(modules,['lib/ai/visualRouter.js','lib/ai/visualExtraction.js']);const s=fs.readFileSync(__dirname+'/image_router_dev.cjs','utf8');
 for(const forbidden of [':setIamPolicy','updateMask=serviceConfig',':access','firebase deploy','AI_INPUT_ALLOWED_UIDS=','forta-aogaku.cloudfunctions.net'])assert(!s.includes(forbidden));
 assert(s.includes("'?updateMask=buildConfig.source'"));assert(s.includes('No automatic mutation replay'));assert(s.includes('p.postCheck(before,after,manifest'));assert(s.includes('Real route'));assert(s.includes('FinalText -> Unit/chunks/Evidence/retrieval'));assert(s.includes("assert.deepEqual(a.functions,load('after-paused').functions)"));
});
test('PDF feature extraction cannot consume image-only connector analysis',()=>{
 const s=fs.readFileSync(__dirname+'/../functions/src/ai/visualExtraction.ts','utf8');assert(s.includes("raster(bytes, probe.words, kind === \"image\")"));assert(s.includes('...(imageOnly ? imageConnectorFeatures(data, w, h, words) : {})'));
 const router=require('../functions/lib/ai/visualRouter'),f={...router.emptyFeatures(),connectorComponents:1,probeAvailable:true,ocrQuality:1,nativeTextQuality:1};assert.equal(router.chooseVisualRoute('pdf',f).route,'native_text');assert.equal(router.chooseVisualRoute('image',f).route,'multimodal_ai');
});
