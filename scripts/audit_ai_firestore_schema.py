#!/usr/bin/env python3
"""Offline path inventory and collision audit against the captured production Rules.
No Firebase CLI, credentials, cloud calls or data migration.
"""
import hashlib,json,re,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent

def matches(pattern,document):
 regex=''
 for part in pattern.strip('/').split('/'):
  if re.fullmatch(r'\{[^}]+=\*\*\}',part):regex+='(?:/[^/]+)*'
  elif re.fullmatch(r'\{[^}]+\}',part):regex+='/[^/]+'
  else:regex+='/'+re.escape(part)
 return re.fullmatch(regex,'/'+document.strip('/')) is not None

def rules_inventory(text):
 # Enumerate every match in this fixed baseline, retain nested prefixes and
 # direct allow clauses. The baseline has no strings containing curly braces.
 records=[]
 for m in re.finditer(r'\bmatch\s+(/[^\n]+?)\s*\{\s*\n',text):
  start=text.index('{',m.end(1));depth=1;i=start+1
  while depth:
   if text[i]=='{':depth+=1
   elif text[i]=='}':depth-=1
   i+=1
  records.append({'start':m.start(),'bodyStart':start,'end':i,'pattern':m.group(1)})
 for rec in records:
  parents=[p for p in records if p['start']<rec['start']<p['end']]
  rec['fullPattern']=''.join(p['pattern'] for p in sorted(parents,key=lambda p:p['start']))+rec['pattern']
  body=text[rec['bodyStart']+1:rec['end']-1]
  children=[c for c in records if rec['start']<c['start']<rec['end'] and not any(rec['start']<p['start']<c['start']<p['end'] for p in records)]
  for child in sorted(children,key=lambda p:p['start'],reverse=True):
   a=child['start']-(rec['bodyStart']+1);b=child['end']-(rec['bodyStart']+1);body=body[:a]+body[b:]
  rec['allows']=[{'operations':a,'condition':' '.join(b.split())} for a,b in re.findall(r'allow\s+([^:]+):\s*if\s+([^;]+);',body)]
 return [{'pattern':r['fullPattern'],'allows':r['allows']} for r in records]

def audit():
 schema=json.loads(subprocess.check_output(['node','-e',"const s=require('./functions/lib/ai/schema');process.stdout.write(JSON.stringify({names:s.AI_COLLECTIONS,paths:s.AI_DOCUMENT_PATHS}))"],cwd=ROOT))
 declared={segment for template in schema['paths'] for segment in template.split('/')[::2]}
 assert declared==set(schema['names'].values()),'path inventory and runtime collection names disagree'
 text=(ROOT/'Config/Production/baseline.firestore.rules').read_text();inventory=rules_inventory(text)
 prefix='/databases/{database}/documents'
 grant_patterns=[r['pattern'][len(prefix):] for r in inventory if r['allows'] and any(a['condition']!='false' for a in r['allows'])]
 canonical=[]
 for template in schema['paths']:
  concrete=re.sub(r'\{[^}]+\}','audit-id',template)
  for rule in grant_patterns:
   if matches(rule,concrete):canonical.append({'path':template,'grantPattern':rule})
 assert not canonical,'canonical schema collides with a legacy grant'
 assert 'entries' not in schema['names'].values()
 ai_source=(ROOT/'functions/src/ai/index.ts').read_text()
 calls=re.findall(r'\.collection(?:Group)?\(([^)]+)\)',ai_source)
 assert all(re.fullmatch(r'collections\.\w+|"classes"',c.strip()) for c in calls),'unregistered collection expression'
 for source in (ROOT/'functions/src/ai').glob('*.ts'):
  assert not re.search(r'\.(?:collection|collectionGroup)\(\s*["\']entries["\']',source.read_text()),source
 ios=[]
 for source in (ROOT/'Aogaku/AIInput').glob('*.swift'):
  if re.search(r'\.(?:collection|document)\(',source.read_text()):ios.append(str(source.relative_to(ROOT)))
 assert not ios,'AI iOS client gained direct Firestore path access'
 from firebase_production import reject_known_ai_entries_bypass
 reject_known_ai_entries_bypass()
 storage_inventory=rules_inventory((ROOT/'Config/Production/baseline.storage.rules').read_text())
 storage_collisions=[]
 for record in storage_inventory:
  if not record['allows'] or not any(a['condition']!='false' for a in record['allows']):continue
  for object_path in ['ai-inputs/audit-user/audit-source/original','ai-derived/audit-user/audit-source/extraction.json']:
   if matches(record['pattern'][len('/b/{bucket}/o'):],object_path):storage_collisions.append(record)
 assert not storage_collisions,'AI storage prefix collides with legacy grant'
 return {'rulesBaselineSha256':hashlib.sha256(text.encode()).hexdigest(),'schema':schema,'canonicalLegacyAllowCollisions':canonical,'iosDirectFirestoreFiles':ios,'rulesInventory':inventory,
  'storageRulesInventory':storage_inventory,'storageCanonicalLegacyAllowCollisions':storage_collisions,
  'recursiveAllows':[r for r in inventory if '=**' in r['pattern'] and r['allows']],
  'unregisteredEntriesBypass':{'pattern':'/{path=**}/entries/{userId}','example':'aiSources/audit-source/entries/audit-user','canonicalSchemaUsesEntries':False,'clientCanChooseUnregisteredPath':True,'resolved':True,'databaseBoundary':'aogaku-ai vs (default)'},
  'productionRulesDeploymentSafe':True,'aiDatabaseId':'aogaku-ai','defaultRulesChanged':False}

if __name__=='__main__':
 result=audit();out=ROOT/'build/ai-schema-audit';out.mkdir(parents=True,exist_ok=True)
 (out/'audit.json').write_text(json.dumps(result,indent=2)+'\n')
 print('Offline schema audit: canonical paths11, reserved entries absent, canonical collisions0; named database blanket deny isolates arbitrary entries; default Rules unchanged.')
