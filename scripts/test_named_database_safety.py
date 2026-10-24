import unittest,sys,json,copy,subprocess
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).parent))
import firebase_production as prod
import firebase_named_dev as dev
class NamedDatabaseSafety(unittest.TestCase):
 def test_dev_config_is_named_only_and_closed(self):dev.check()
 def test_production_selects_named_database_in_real_cli_parser(self):
  for phase in ['rules','indexes']:
   command=prod.deploy_command(phase);only=command[command.index('--only')+1]
   code="const c=require('/Users/shum/anaconda3/lib/node_modules/firebase-tools/lib/firestore/fsConfig');const config=require('./firebase.production.json');const result=c.getFirestoreConfig('forta-aogaku',{only:process.argv[1],config:{src:config}});if(result.length!==1||result[0].database!=='aogaku-ai')throw Error('wrong database');"
   subprocess.run(['node','-e',code,only],cwd=prod.ROOT,check=True,capture_output=True)
 def test_rejects_default_database_even_with_deny_rules(self):
  value=prod.load(prod.ROOT/'firebase.production.json');value['firestore'][0]['database']='(default)'
  with patch.object(prod,'load',return_value=value),self.assertRaises(ValueError):prod.reject_known_ai_entries_bypass()
 def test_old_inventory_does_not_authorize_new_architecture(self):
  # A fresh live inventory becomes ready during an approved rollout. Model the
  # old receipt explicitly so this safety assertion never depends on cloud state.
  old=copy.deepcopy(prod.load(prod.ROOT/'build/production-live.json'))
  for key in ['aiDatabase','aiIndexes','aiFields','aiRules']:old.pop(key,None)
  with self.assertRaisesRegex(ValueError,'named production database'):prod.require_named_ready(old)
 def test_active_sources_forbid_implicit_admin_default_database(self):
  for path in (prod.ROOT/'functions/src').rglob('*'):
   if path.suffix in ['.js','.ts']:self.assertNotIn('admin.firestore()',path.read_text(),str(path))
 def test_no_cross_database_reference_in_legacy_quota_transactions(self):
  text=(prod.ROOT/'functions/src/legacy-ai/index.ts').read_text();self.assertNotIn('aiInputOwners/',text);self.assertIn('tx.get(accountDeletionFence(uid))',text);self.assertIn('const db = defaultDatabase()',text)
if __name__=='__main__':unittest.main()
