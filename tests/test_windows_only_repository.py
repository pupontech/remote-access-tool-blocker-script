"""Scope regression: this standalone repository ships Windows App Control only."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class WindowsOnlyRepositoryTests(unittest.TestCase):
    def test_removed_components_do_not_exist(self):
        removed = [
            'src/eset', 'kits/2', 'kits/1', 'archive/eset-hips-poc',
            'docs/eset-import-guide.md', 'revert/docs/eset-remove-guide.txt',
            'revert/Install-ESET-Revert.v2026-10-11.1.ps1',
            'revert/Revert-RemoteAccessBlock.v2026-10-11.1.ps1',
            'tests/Test-EsetHandoff.ps1', 'tests/Test-EsetButtonRecovery.ps1',
            'tests/Test-ImportWorkflow.ps1',
        ]
        self.assertEqual([], [p for p in removed if (ROOT / p).exists()])

    def test_active_build_and_ci_have_no_website_layer(self):
        for rel in ('build/build-release.sh', '.github/workflows/powershell-ci.yml'):
            text = (ROOT / rel).read_text().lower()
            for forbidden in ('full-kit-eset', 'src/eset', 'kits/2', 'get-lolrmmurllist',
                              'install-eset-revert', 'test-esethandoff', 'test-importworkflow'):
                self.assertNotIn(forbidden, text, rel)

    def test_recovery_only_resolves_windows_variant(self):
        launcher = (ROOT / 'revert/Run-Revert.bat').read_text()
        self.assertIn('Revert-RemoteAccessBlock-WinOnly.v*.ps1', launcher)
        self.assertNotIn('Revert-RemoteAccessBlock.v*.ps1', launcher)


if __name__ == '__main__':
    unittest.main()
