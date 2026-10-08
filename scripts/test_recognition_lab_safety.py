import json
from pathlib import Path
import subprocess
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]

class LabSafety(unittest.TestCase):
    def test_separate_dev_only_codebase(self):
        config = json.loads((ROOT / 'firebase.recognition-lab.json').read_text())
        self.assertEqual(set(config), {'functions'})
        self.assertEqual(len(config['functions']), 1)
        self.assertEqual(config['functions'][0]['codebase'], 'recognition-lab')
        source = (ROOT / 'scripts/recognition_lab_dev.py').read_text()
        self.assertIn("'--project', 'forta-aogaku-dev'", source)
        self.assertIn("'functions:recognition-lab:' + FUNCTION", source)
        self.assertNotIn("'--force'", source)

    def test_lab_isolated_from_production_settings(self):
        # Production AI source is intentionally integrated on this branch. Lab code
        # still cannot access its databases, enqueue jobs, or change environment config.
        protected = ['functions/package.json', 'functions/package-lock.json', 'Config/Production', 'Aogaku/GoogleService-Info.plist', 'firebase.production.json', 'firestore.rules', 'storage.rules']
        self.assertEqual(subprocess.check_output(['git', 'diff', '--name-only', 'HEAD', '--', *protected], cwd=ROOT, text=True), '')
        code = '\n'.join(p.read_text() for p in (ROOT / 'recognition-lab/functions/src').glob('*.ts'))
        for forbidden in ['firebase-admin', 'getFirestore(', 'getStorage(', 'getFunctions(', 'aiCreateSource', 'enqueue(']: self.assertNotIn(forbidden, code)

    def test_debug_only_ui_and_permission(self):
        for source in (ROOT / 'Aogaku/RecognitionLab').glob('*.swift'):
            text = source.read_text().strip(); self.assertTrue(text.startswith('#if DEBUG')); self.assertTrue(text.endswith('#endif'))
        self.assertIn('NSSpeechRecognitionUsageDescription', (ROOT / 'Config/Info-Debug.plist').read_text())
        self.assertNotIn('NSSpeechRecognitionUsageDescription', (ROOT / 'Aogaku/Info.plist').read_text())
        scheme = ET.parse(ROOT / 'Aogaku.xcodeproj/xcshareddata/xcschemes/Aogaku-AI-Recognition-Lab.xcscheme')
        self.assertEqual(scheme.find('LaunchAction').get('buildConfiguration'), 'Debug')
        variables = {x.get('key'): x.get('value') for x in scheme.findall('./LaunchAction/EnvironmentVariables/EnvironmentVariable')}
        self.assertEqual(variables, {'AOGAKU_BACKEND': 'development', 'AOGAKU_RECOGNITION_LAB': '1'})

    def test_passwordless_lab_preserves_server_uid_boundary(self):
        service = (ROOT / 'Aogaku/RecognitionLab/RecognitionLabService.swift').read_text()
        ui = (ROOT / 'Aogaku/RecognitionLab/RecognitionLabViewController.swift').read_text()
        self.assertIn('signInAnonymously()', service)
        self.assertIn('if let uid = currentUID() { return uid }', service)
        self.assertNotIn('signIn(withEmail:', ui)
        self.assertNotIn('isSecureTextEntry', ui)
        domain = (ROOT / 'recognition-lab/functions/src/domain.ts').read_text()
        self.assertIn('if (!uid) throw new LabError("LAB_AUTH_REQUIRED")', domain)
        self.assertIn('!values.includes(uid)', domain)
        registration = (ROOT / 'scripts/recognition_lab_device.cjs').read_text()
        self.assertIn('next=[...cfg.allowedUIDs,uid]', registration)
        self.assertIn('user.providerUserInfo', registration)
        self.assertIn('updateMask=serviceConfig.environmentVariables', registration)
        self.assertIn('await manifest(f.name)', registration)

    def test_private_files_excluded(self):
        for file in ['Config/recognition-lab.local.json', 'recognition-lab/functions/.env.forta-aogaku-dev', 'build/recognition-lab-dev/credentials.json']:
            self.assertEqual(subprocess.run(['git', 'check-ignore', '-q', file], cwd=ROOT).returncode, 0)
            self.assertEqual(subprocess.check_output(['git', 'ls-files', '--', file], cwd=ROOT, text=True), '')

if __name__ == '__main__': unittest.main()
