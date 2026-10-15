import sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).parent))
import audit_ai_firestore_schema as audit

class SchemaAudit(unittest.TestCase):
 def test_recursive_rule_matches_unregistered_entries_even_after_rename(self):
  pattern='/{path=**}/entries/{userId}'
  for path in ['classReviews/course/entries/user','aiSources/source/entries/user','aiSources/source/sourceEntries/item/entries/user']:
   self.assertTrue(audit.matches(pattern,path))
  self.assertFalse(audit.matches(pattern,'aiSources/source/runs/run/chunks/chunk'))
 def test_user_scoped_recursive_allow_does_not_match_top_level_ai(self):
  self.assertTrue(audit.matches('/users/{uid}/{sub=**}/{docId}','users/user/notes/note'))
  self.assertFalse(audit.matches('/users/{uid}/{sub=**}/{docId}','aiSources/source/runs/run/chunks/chunk'))
 def test_full_schema_inventory_and_rules_hierarchy(self):
  result=audit.audit();self.assertEqual(len(result['schema']['paths']),11)
  self.assertEqual(result['canonicalLegacyAllowCollisions'],[])
  self.assertEqual(result['iosDirectFirestoreFiles'],[])
  recursive={r['pattern'] for r in result['recursiveAllows']}
  self.assertEqual(recursive,{'/databases/{database}/documents/{path=**}/entries/{userId}','/databases/{database}/documents/users/{uid}/{sub=**}/{docId}'})
  self.assertTrue(result['productionRulesDeploymentSafe']);self.assertEqual(result['aiDatabaseId'],'aogaku-ai');self.assertFalse(result['defaultRulesChanged'])

if __name__=='__main__':unittest.main()
