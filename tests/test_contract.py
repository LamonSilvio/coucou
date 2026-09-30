"""Cross-platform configuration/packaging checks, not live API or regression tests."""
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

class ConfigurationTests(unittest.TestCase):
    def test_model_catalog(self):
        catalog = json.loads((ROOT / 'NotchBuddy/Resources/OpenAIModels.json').read_text())
        self.assertIn(catalog['defaultModel'],catalog['models'])
        for model in catalog['models'].values():
            self.assertIsInstance(model['vision'],bool)
            self.assertTrue(set(model['tools']) <= {'web_search','code_interpreter','function'})
            self.assertTrue(set(model['reasoning']) <= {'low','medium','high'})

    def test_catalog_has_no_credentials(self):
        value = (ROOT / 'NotchBuddy/Resources/OpenAIModels.json').read_text().lower()
        for marker in ['api_key','authorization','sk-','token']:
            self.assertNotIn(marker,value)

    def test_original_license_not_removed(self):
        self.assertIn('Copyright (c) 2026 Louis Raillé',(ROOT/'LICENSE').read_text())
        self.assertIn('All rights reserved',(ROOT/'LICENSE-ASSETS.md').read_text())

if __name__ == '__main__':
    unittest.main()
