import copy,json,sys,tempfile,time,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).parent))
import firebase_production as p
class ProductionSafety(unittest.TestCase):
 def test_local_configuration(self):p.check('forta-aogaku')
 def test_identity_rejects_alias_dev_default(self):
  for name in ['', 'default','production','forta-aogaku-dev','Forta-Aogaku']:
   with self.assertRaises(ValueError):p.check(name)
 def test_rules_preserve_every_legacy_permission(self):
  for kind in ['firestore','storage']:
   base=(p.CONF/('baseline.'+kind+'.rules')).read_text();merged=(p.CONF/(kind+'.rules')).read_text()
   p.rules_preserved(base,merged,kind)
   with self.assertRaises(ValueError):p.rules_preserved(base,merged.replace('allow read:', 'allow read, write:',1),kind)
   with self.assertRaises(ValueError):p.rules_preserved(base,merged.replace('lectureNotes','deletedNotes') if kind=='firestore' else merged.replace('avatars','other'),kind)
 def test_named_database_removes_boundary_collision_but_requires_new_production_approval(self):
  p.reject_known_ai_entries_bypass()
  # Keep the absent-database case independent of production rollout progress.
  missing=p.load(p.ROOT/'build/production-live.json');missing['aiDatabase']=None
  with tempfile.TemporaryDirectory() as directory:
   snapshot=Path(directory)/'missing.json';snapshot.write_text(json.dumps(missing))
   with self.assertRaisesRegex(ValueError,'named production database'):
    p.approval_check({'gates':{g:True for g in p.GATES}},snapshot,'rules')
 def test_allowlist_whole_deploy_legacy_link_are_denied(self):
  p.validate_functions(p.FUNCTIONS)
  for names in [[],['*'],['functions'],[*p.FUNCTIONS,'aiLinkSourceOffering'],[*p.FUNCTIONS[:-1],'askCourseAI']]:
   with self.assertRaises(ValueError):p.validate_functions(names)
 def test_deletion_replacement_proposals_denied(self):
  for change in [{'delete':['onAuthUserDelete']},{'replaceExisting':['askCourseAI']}]:
   with self.assertRaises(ValueError):p.reject_destructive_plan({'functions':list(p.FUNCTIONS),**change})
 def test_cli_commands_never_force_or_all_functions(self):
  for phase in ['functions','indexes','rules']:
   c=p.deploy_command(phase);self.assertEqual(c[c.index('--project')+1],'forta-aogaku');self.assertIn('--non-interactive',c);self.assertNotIn('--force',c)
   if phase=='functions':self.assertEqual(c[c.index('--only')+1].split(','),['functions:aogaku-ai:'+n for n in p.FUNCTIONS])
 def test_manifest_is_exact_and_private(self):
  endpoints=p.load(p.ROOT/'build/production-endpoints.json');p.validate_functions(endpoints.keys())
  for e in endpoints.values():self.assertEqual(e['region'],['asia-northeast1'])
  e=endpoints['aiRejectLateUpload']['eventTrigger'];self.assertEqual(e['region'],'us-central1');self.assertEqual(e['eventFilters']['bucket'],p.TARGET['bucket'])
 def test_live_identity_and_drift(self):
  s=p.load(p.ROOT/'build/production-live.json');p.live_check(s)
  mutations=[lambda d:d.update(projectNumber='1064661805206'),lambda d:d['bucket'].update(location='ASIA-NORTHEAST1'),lambda d:d['apps'].update(apps=[]),lambda d:d['rules']['firestore'].update(content='allow read: if true;'),lambda d:d['fields']['fields'].append({'name':'projects/forta-aogaku/databases/(default)/collectionGroups/extra/fields/x','indexConfig':{'indexes':[]}}),lambda d:d['functions']['functions'].append({'name':'projects/forta-aogaku/locations/asia-northeast1/functions/aiCreateSource','labels':{}}),lambda d:d['indexes']['indexes'].append({'name':'projects/forta-aogaku/databases/(default)/collectionGroups/new/indexes/x','queryScope':'COLLECTION','fields':[{'fieldPath':'x','order':'ASCENDING'},{'fieldPath':'y','order':'ASCENDING'}]})]
  for mutate in mutations:
   bad=copy.deepcopy(s);mutate(bad)
   with self.assertRaises(ValueError):p.live_check(bad)
  for field in ['publicBucketIAM','publicProjectIAM','publicDefaultACL']:
   bad=copy.deepcopy(s);bad['storagePrivacy'][field]=True
   with self.assertRaises(ValueError):p.live_check(bad)
  bad=copy.deepcopy(s);bad['secret']['latestState']='DISABLED'
  with self.assertRaises(ValueError):p.live_check(bad)
 def test_preserves_3_indexes_8_field_overrides_and_lifecycle(self):
  b=p.load(p.CONF/'baseline.indexes.json');m=p.load(p.CONF/'firestore.indexes.json');self.assertEqual(len(b['indexes']),3);self.assertEqual(len(b['fieldOverrides']),8);self.assertEqual(len(m['indexes']),4);self.assertEqual(m['fieldOverrides'],b['fieldOverrides'])
  b=p.load(p.CONF/'baseline.lifecycle.json');m=p.load(p.CONF/'storage.lifecycle.proposed.json');self.assertEqual(m['rule'][:-1],b['rule']);self.assertEqual(m['rule'][-1]['condition']['matchesPrefix'],['ai-inputs/'])
 def test_no_deploy_without_authorized_gates(self):
  snapshot=p.ROOT/'build/production-live.json'
  a={'target':p.TARGET,'phase':'functions','artifactSha256':p.artifact_hash(),'inventorySha256':p.sha(snapshot),'expiresAt':time.time()+300,'gates':{g:False for g in p.GATES}}
  with self.assertRaises(ValueError):p.approval_check(a,snapshot,'functions')
 def test_package_excludes_credentials_fixtures_legacy(self):
  files=[str(f.relative_to(p.ROOT/'build/production-functions')) for f in (p.ROOT/'build/production-functions/lib').rglob('*') if f.is_file()]
  self.assertTrue(files);self.assertNotIn('lib/index.js',files)
  for f in files:self.assertFalse(any(x in f for x in ['fixture','GoogleService','output-dev','DevIntegration']))
if __name__=='__main__':unittest.main()
