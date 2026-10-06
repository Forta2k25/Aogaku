import importlib.util
import json
import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('firebase_dev', ROOT / 'scripts/firebase_dev.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class ConfigurationSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        for folder in ['Aogaku', 'Config/Firebase/Development']:
            (self.root / folder).mkdir(parents=True)
        self.write_plist('Aogaku/GoogleService-Info.plist', {'PROJECT_ID': 'protected-project', 'BUNDLE_ID': 'com.example.original'})
        self.write_plist('Config/Firebase/Development/GoogleService-Info.plist', {'PROJECT_ID': 'example-dev-project', 'BUNDLE_ID': 'com.forta2k25.Aogaku.dev'})
        (self.root / 'Config/firebase-development.json').write_text(json.dumps({'projectId': 'example-dev-project'}))

    def tearDown(self):
        self.temp.cleanup()

    def write_plist(self, name, value):
        (self.root / name).write_bytes(plistlib.dumps(value))

    def test_matching_dev_accepted(self):
        self.assertEqual(module.validate(self.root), 'example-dev-project')

    def test_cloud_operations_reject_an_unapproved_non_production_project(self):
        with self.assertRaises(ValueError):
            module.validate_approved(self.root)

    def test_approved_cloud_identity_requires_project_number_and_bucket(self):
        config = {'PROJECT_ID': 'forta-aogaku-dev', 'BUNDLE_ID': 'com.forta2k25.Aogaku.dev',
                  'GCM_SENDER_ID': '1064661805206', 'STORAGE_BUCKET': 'forta-aogaku-dev.firebasestorage.app'}
        self.write_plist('Config/Firebase/Development/GoogleService-Info.plist', config)
        manifest = {'projectId': 'forta-aogaku-dev', 'projectNumber': '1064661805206', 'storageBucket': config['STORAGE_BUCKET']}
        (self.root / 'Config/firebase-development.json').write_text(json.dumps(manifest))
        self.assertEqual(module.validate_approved(self.root), 'forta-aogaku-dev')
        for key in ['projectNumber', 'storageBucket']:
            wrong = dict(manifest, **{key: 'different'})
            (self.root / 'Config/firebase-development.json').write_text(json.dumps(wrong))
            with self.assertRaises(ValueError):
                module.validate_approved(self.root)

    def test_production_and_mismatch_rejected(self):
        for project in ['protected-project', 'different-dev-project']:
            (self.root / 'Config/firebase-development.json').write_text(json.dumps({'projectId': project}))
            with self.assertRaises(ValueError):
                module.validate(self.root)

    def test_debug_without_dev_never_copies_production(self):
        (self.root / 'Config/Firebase/Development/GoogleService-Info.plist').unlink()
        destination = self.root / 'build/App.app'
        destination.mkdir(parents=True)
        self.write_plist('build/App.app/GoogleService-Info.plist', {'PROJECT_ID': 'protected-project'})
        environment = dict(os.environ, SRCROOT=str(self.root), TARGET_BUILD_DIR=str(self.root / 'build'),
            UNLOCALIZED_RESOURCES_FOLDER_PATH='App.app', CONFIGURATION='Debug', PRODUCT_BUNDLE_IDENTIFIER='com.forta2k25.Aogaku.dev')
        subprocess.run(['python3', str(ROOT / 'scripts/prepare_firebase_config.py')], env=environment, check=True, capture_output=True)
        self.assertEqual(list(destination.glob('GoogleService*.plist')), [])

    def test_dev_bundle_mismatch_rejected(self):
        self.write_plist('Config/Firebase/Development/GoogleService-Info.plist', {'PROJECT_ID': 'example-dev-project', 'BUNDLE_ID': 'com.example.original'})
        with self.assertRaises(ValueError):
            module.validate(self.root)

    def build(self, configuration='Debug', bundle='com.forta2k25.Aogaku.dev'):
        destination = self.root / 'build/App.app'
        environment = dict(os.environ, SRCROOT=str(self.root), TARGET_BUILD_DIR=str(self.root / 'build'),
            UNLOCALIZED_RESOURCES_FOLDER_PATH='App.app', CONFIGURATION=configuration, PRODUCT_BUNDLE_IDENTIFIER=bundle)
        result = subprocess.run(['python3', str(ROOT / 'scripts/prepare_firebase_config.py')], env=environment, capture_output=True)
        return result, destination

    def test_debug_build_contains_only_development_configuration(self):
        result, destination = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        config = plistlib.loads((destination / 'GoogleService-Info-development.plist').read_bytes())
        self.assertEqual(config['PROJECT_ID'], 'example-dev-project')
        self.assertFalse((destination / 'GoogleService-Info-production.plist').exists())

    def test_build_stops_when_debug_is_given_production(self):
        (self.root / 'Config/firebase-development.json').write_text(json.dumps({'projectId': 'protected-project'}))
        self.write_plist('Config/Firebase/Development/GoogleService-Info.plist', {'PROJECT_ID': 'protected-project', 'BUNDLE_ID': 'com.forta2k25.Aogaku.dev'})
        result, destination = self.build()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(destination.glob('GoogleService*.plist')), [])

    def test_release_accepts_original_and_rejects_development(self):
        result, destination = self.build('Release', 'com.example.original')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((destination / 'GoogleService-Info-development.plist').exists())
        (self.root / 'Config/Firebase/Production').mkdir()
        self.write_plist('Config/Firebase/Production/GoogleService-Info.plist', {'PROJECT_ID': 'example-dev-project', 'BUNDLE_ID': 'com.example.original'})
        result, destination = self.build('Release', 'com.example.original')
        self.assertNotEqual(result.returncode, 0)

if __name__ == '__main__':
    unittest.main()
