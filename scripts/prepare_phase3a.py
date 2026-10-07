#!/usr/bin/env python3
"""Offline three-callable artifact; recovered dependency lock, no new AI worker."""
import json,hashlib,zipfile,shutil,subprocess
from pathlib import Path
from firebase_production import ROOT,check,require
NAMES=('askCourseAI','transcribeLectureAudio','generateReactionPaper')
def prepare():
 check('forta-aogaku')
 directory=ROOT/'build/production-phase3a';directory.mkdir(exist_ok=True)
 records={r['name']:r for r in json.loads((ROOT/'build/production-legacy-live.json').read_text())['records']}
 expected={r['function']:r for r in json.loads((ROOT/'functions/recovered/deployed/provenance.json').read_text())['records']}
 original_zip=ROOT/'build/legacy-production-recovery/askCourseAI.zip'
 for name in NAMES:
  record=records[name];require(record['updateTime']==expected[name]['updateTime'],'live version drift')
  archive=ROOT/'build/legacy-production-recovery'/f'{name}.zip'
  require(hashlib.sha256(archive.read_bytes()).hexdigest()==expected[name]['sha256'],'fresh source ZIP differs from recovered original')
  with zipfile.ZipFile(archive) as z:require(hashlib.sha256(z.read('lib/index.js')).hexdigest()==expected[name]['codeSha256'],'live code SHA differs')
 subprocess.run(['npm','--prefix','functions','run','build'],cwd=ROOT,check=True)
 out=directory/'candidate';require(not out.exists(),'candidate already exists; preserve approved artifact')
 (out/'lib/legacy-ai').mkdir(parents=True)
 for name in ['index.js','account-state.js']:shutil.copy2(ROOT/'functions/lib/legacy-ai'/name,out/'lib/legacy-ai'/name)
 (out/'lib/index.js').write_text("const legacy = require('./legacy-ai');\n"+''.join(f'exports.{n} = legacy.{n};\n' for n in NAMES))
 with zipfile.ZipFile(original_zip) as z:
  pkg=json.loads(z.read('package.json'));pkg['scripts']={}
  require(pkg['engines']=={'node':'22'} and set(pkg['dependencies'])=={'firebase-admin','firebase-functions'},'original dependency/runtime mismatch')
  (out/'package.json').write_text(json.dumps(pkg,indent=2)+'\n')
  (out/'package-lock.json').write_bytes(z.read('package-lock.json'))
 files=sorted(p for p in out.rglob('*') if p.is_file());manifest={str(p.relative_to(out)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
 require(set(manifest)=={'lib/index.js','lib/legacy-ai/index.js','lib/legacy-ai/account-state.js','package.json','package-lock.json'},'artifact file leak')
 code=(out/'lib/legacy-ai/index.js').read_text();require('require("../ai")' not in code and 'require("./account-state")' in code,'legacy imports new AI worker')
 guard=(out/'lib/legacy-ai/account-state.js').read_text();require('aiSources' not in guard and 'taskQueue' not in guard,'new ingestion leaked into guard')
 archive=directory/'candidate.zip'
 with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_DEFLATED) as z:
  for p in files:
   item=zipfile.ZipInfo(str(p.relative_to(out)),date_time=(2026,10,7,0,0,0));item.compress_type=zipfile.ZIP_DEFLATED;item.external_attr=0o100644<<16;z.writestr(item,p.read_bytes())
 proof={'names':list(NAMES),'files':manifest,'sourceSha256':hashlib.sha256(json.dumps(manifest,sort_keys=True,separators=(',',':')).encode()).hexdigest(),'zipSha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'entrySha256':manifest['lib/index.js'],'legacyCodeSha256':manifest['lib/legacy-ai/index.js'],'before':{n:{'codeSha256':expected[n]['codeSha256'],'zipSha256':expected[n]['sha256'],'updateTime':records[n]['updateTime']} for n in NAMES},'exportedFunctions':list(NAMES),'namedSourceWrites':False,'newDependencies':False}
 (directory/'artifact.json').write_text(json.dumps(proof,indent=2)+'\n');(directory/'artifact.json').chmod(0o600)
 (out/'node_modules').symlink_to(ROOT/'functions/node_modules',target_is_directory=True)
 print('PASS: fresh recovered source matched; slim three-callable artifact; original dependency lock; no new AI workers/sources')
if __name__=='__main__':prepare()
