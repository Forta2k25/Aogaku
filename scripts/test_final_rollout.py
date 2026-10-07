import json,sys,tempfile,time,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).parent))
import firebase_production as p
import firebase_legacy_production as legacy
class FinalRollout(unittest.TestCase):
 def test_inventory_read_time_is_not_an_unstable_approval_hash(self):
  data={'readAt':'first-read','projectId':'forta-aogaku','records':[{'name':'x','updateTime':'stable'}]}
  with tempfile.TemporaryDirectory() as d:
   f=Path(d)/'inventory.json';f.write_text(json.dumps(data));initial=p.inventory_hash(f);data['readAt']='second-read';f.write_text(json.dumps(data));self.assertEqual(initial,p.inventory_hash(f));data['records'][0]['updateTime']='changed';f.write_text(json.dumps(data));self.assertNotEqual(initial,p.inventory_hash(f))
 def test_exact_group_commands_and_no_force(self):
  for group,names in legacy.GROUPS.items():
   for mode in legacy.MODES:
    c=legacy.command(group,mode);self.assertEqual(c[c.index('--only')+1].split(','),['functions:default:'+n for n in names]);self.assertNotIn('--force',c)
 def test_phase_gates_are_not_circular(self):
  self.assertNotIn('accountDeletionHookIntegrated',p.PHASE_GATES['indexes']);self.assertIn('accountDeletionHookIntegrated',p.PHASE_GATES['functions']);self.assertNotIn('internalTestUIDsConfigured',p.PHASE_GATES['functions-closed']);self.assertIn('productionDeploymentAuthorized',p.PHASE_GATES['functions-closed'])
 def test_packages_keep_generation_region_and_no_notification_exports(self):
  for mode in legacy.MODES:
   ep=p.load(p.ROOT/'build'/('legacy-'+mode+'-endpoints.json'));self.assertEqual(set(ep),set(sum(legacy.GROUPS.values(),())))
   for name,e in ep.items():self.assertEqual(e['region'],['asia-northeast1']);self.assertEqual(e['platform'],'gcfv2' if name in ['preDeleteCleanup','deleteAccountServerSide'] else 'gcfv1')
 def test_maintenance_requires_named_approval_and_no_pilot_rollback(self):
  a={'target':p.TARGET,'group':'quota','mode':'rollback-before-pilot','artifactSha256':legacy.artifact_hash('rollback-before-pilot'),'authorizeNamedUpdates':list(legacy.GROUPS['quota']),'expiresAt':time.time()+300,'gates':{g:True for g in ['productionDeploymentAuthorized','legacyRegressionApproved','iamAndApisReviewed','rollbackReviewed']},'noAIInputsEverAccepted':False}
  with tempfile.TemporaryDirectory() as d:
   f=Path(d)/'live.json';f.write_bytes((p.ROOT/'build/production-legacy-live.json').read_bytes());a['inventorySha256']=p.inventory_hash(f)
   with self.assertRaisesRegex(ValueError,'after AI inputs'):legacy.approve(a,'quota','rollback-before-pilot',f)
if __name__=='__main__':unittest.main()
