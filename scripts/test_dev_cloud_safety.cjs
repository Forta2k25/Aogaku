const {test} = require('node:test');
const assert = require('node:assert/strict');
const {assertURL,PROJECT:P,NUMBER:N,BUCKET:B} = require('./dev_cloud.cjs');
test('only approved Dev project and number API paths are accepted',()=>{
  for(const url of [`https://cloudresourcemanager.googleapis.com/v1/projects/${P}`,`https://serviceusage.googleapis.com/v1/projects/${N}/services:batchEnable`,`https://cloudfunctions.googleapis.com/v2/projects/${P}/locations/asia-northeast1/functions/aiProcessSource`]) assert.doesNotThrow(()=>assertURL(url));
});
test('other projects, global inventories, spoofed hosts and prefixes stop before request',()=>{
  for(const url of ['https://cloudresourcemanager.googleapis.com/v1/projects/other-project','https://cloudresourcemanager.googleapis.com/v1/projects',`https://cloudfunctions.googleapis.com/v2/projects/${P}-other/functions`,`https://example.com/v1/projects/${P}`,`http://cloudfunctions.googleapis.com/v2/projects/${P}`]) assert.throws(()=>assertURL(url),/STOP/);
});
test('Storage paths stay inside the exact Dev bucket',()=>{
  assert.doesNotThrow(()=>assertURL(`https://storage.googleapis.com/storage/v1/b/${B}/iam`));
  assert.throws(()=>assertURL(`https://storage.googleapis.com/storage/v1/b/${B}-other/iam`),/STOP/);
});
test('operator tooling cannot read a Secret Manager payload',()=>{
  assert.doesNotThrow(()=>assertURL(`https://secretmanager.googleapis.com/v1/projects/${P}/secrets/GROQ_API_KEY`));
  assert.throws(()=>assertURL(`https://secretmanager.googleapis.com/v1/projects/${P}/secrets/GROQ_API_KEY/versions/latest:access`),/STOP/);
});
test('log requests require exactly one Dev resource scope',()=>{
  assert.doesNotThrow(()=>assertURL('https://logging.googleapis.com/v2/entries:list',{resourceNames:[`projects/${P}`]}));
  assert.throws(()=>assertURL('https://logging.googleapis.com/v2/entries:list',{resourceNames:['projects/other-project']}),/STOP/);
  assert.throws(()=>assertURL('https://logging.googleapis.com/v2/entries:list'),/STOP/);
});
