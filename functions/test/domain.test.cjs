const {test} = require('node:test');
const assert = require('node:assert/strict');
const {validateCreate, hash, canRead, mayPublish, chunksFor, selectContext, weekKey} = require('../lib/ai/domain');
const {mergeSegments} = require('../lib/ai/extractors');
const valid = () => ({clientRequestId:'request-1',type:'note',title:'授業メモ',mime:'text/plain',text:'社会思想の資料',context:{localCourseId:'c1',year:2026,semester:'fall',dayID:20730}});
test('all four inputs have explicit type/size validation', () => {
  for (const [type,mime,size,durationSeconds] of [['note','text/plain',3],['image','image/jpeg',100],['pdf','application/pdf',100],['audio','audio/mp4',100,60]]) {
    assert.equal(validateCreate({...valid(),type,mime,size,durationSeconds}).type,type);
  }
  assert.throws(() => validateCreate({...valid(),type:'exe'}));
  assert.throws(() => validateCreate({...valid(),type:'image',mime:'application/pdf',size:1}));
  assert.throws(() => validateCreate({...valid(),type:'pdf',mime:'application/pdf',size:30*1024**2}));
  assert.throws(() => validateCreate({...valid(),type:'audio',mime:'audio/mp4',size:1,durationSeconds:5401}));
});
test('identity is stable, user-specific and separators cannot collide', () => {
  assert.equal(hash('uid','receipt'),hash('uid','receipt'));
  assert.notEqual(hash('uid1','receipt'),hash('uid2','receipt'));
  assert.notEqual(hash('a_b','c'),hash('a','b_c'));
  assert.throws(() => validateCreate({...valid(),clientRequestId:'../other'}));
});
test('private, raw and knowledge visibility remain independent', () => {
  const s={status:'ready',ownerUserId:'a',rawVisibility:'private',knowledgeVisibility:'course'};
  assert.equal(canRead(s,'a',false),true);
  assert.equal(canRead(s,'b',false),false);
  assert.equal(canRead(s,'b',true),true);
  assert.equal(canRead(s,'b',true,true),false);
  assert.equal(canRead({...s,status:'deleting'},'a',true),false);
  assert.equal(canRead({...s,knowledgeVisibility:'private'},'b',true),false);
});
test('late and duplicate workers cannot publish deleted or superseded runs', () => {
  assert.equal(mayPublish({status:'indexing',leaseToken:'new'},'new'),true);
  assert.equal(mayPublish({status:'indexing',leaseToken:'new'},'old'),false);
  assert.equal(mayPublish({status:'deleted',leaseToken:'new'},'new'),false);
  assert.equal(mayPublish({status:'ready',leaseToken:null},'new'),false);
});
test('long note chunks preserve exact source offsets', () => {
  const text='あ'.repeat(3300);
  const chunks=chunksFor([{text,locator:{},method:'note',flags:[]}]);
  assert.equal(chunks.length,3);
  for(const c of chunks) assert.equal(text.slice(c.locator.startChar,c.locator.endChar),c.text);
  const pdf=chunksFor([{text,locator:{pageNumber:3},method:'pdf_text',flags:[]}]);
  assert.ok(pdf.every(c=>c.locator.pageNumber===3));
});
test('Japanese questions retrieve matching evidence; irrelevant data is not fabricated', () => {
  const data=[{sourceId:'a',text:'カントの哲学について'},{sourceId:'b',text:'授業日程の案内'}];
  assert.equal(selectContext(data,'question','カント',200).items[0].sourceId,'a');
  assert.equal(selectContext(data,'question','量子力学',200).items.length,0);
});
test('summary budget spans sources and reports omitted text', () => {
  const data=[{sourceId:'a',text:'a'.repeat(40)},{sourceId:'a',text:'b'.repeat(40)},{sourceId:'b',text:'c'.repeat(40)}];
  const result=selectContext(data,'lecture_summary','',80);
  assert.deepEqual(result.items.map(c=>c.sourceId),['a','b']);
  assert.equal(result.truncated,true);
});
test('weekly quota resets at Monday in Japan, not host time', () => {
  assert.equal(weekKey(new Date('2026-10-04T14:59:59Z')),'2026-09-28');
  assert.equal(weekKey(new Date('2026-10-04T15:00:00Z')),'2026-10-05');
});
test('audio overlap keeps continuation and converts to original timestamps', () => {
  const units=mergeSegments([
    {offset:0,coreStart:0,result:{segments:[{start:898,end:900,text:'社会契約について'}]}},
    {offset:898,coreStart:900,result:{segments:[{start:0,end:2,text:'社会契約について'},{start:1,end:5,text:'社会契約について考えます'}]}}
  ],1000);
  assert.equal(units.length,2);
  assert.equal(units[1].text,'考えます');
  assert.equal(units[1].locator.startMs,899000);
  assert.equal(units[1].locator.endMs,903000);
  assert.ok(units[1].flags.includes('overlap_boundary'));
});
test('no speech does not become fabricated lecture content', () => {
  assert.deepEqual(mergeSegments([{offset:0,coreStart:0,result:{segments:[{start:0,end:1,text:'ご視聴ありがとうございました',no_speech_prob:.99}]}}],10),[]);
  assert.throws(()=>mergeSegments([{offset:0,coreStart:0,result:{text:'missing timestamps'}}],10));
});
