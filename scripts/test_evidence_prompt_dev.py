import unittest
import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).parent))
from deploy_detection_dev import deploy_names

class EvidencePromptDeployTest(unittest.TestCase):
    def test_only_processing_worker_updates_for_prompt(self):
        self.assertEqual(deploy_names(['--evidence-prompt']), ('aiProcessSource',))
    def test_previous_cohorts_are_preserved(self):
        self.assertEqual(deploy_names(['--image-route']), ('aiListSources', 'aiProcessSource'))
        self.assertEqual(len(deploy_names(['--visual-router'])), 10)
        self.assertNotIn('aiLinkSourceOffering', deploy_names(['--visual-router']))
    def test_unsafe_and_mixed_selectors_reject(self):
        for args in [['--force'], ['--project','forta-aogaku'], ['--evidence-prompt','--visual-router'], ['functions']]:
            with self.assertRaises(AssertionError): deploy_names(args)

if __name__ == '__main__': unittest.main()
