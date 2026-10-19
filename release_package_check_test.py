"""Tests release_package_check.py's archive rules.

  python release_package_check_test.py
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import release_package_check as check  # noqa: E402

V = "1.149.2.3"
P = f"Chrome-bin\\{V}\\"
GOOD = [f"{P}chrome.dll", f"{P}{V}.manifest",
        f"{P}custom_browser_version.manifest", "Chrome-bin\\chrome.exe"]


class ArchiveNamesTest(unittest.TestCase):
    def test_accepts_a_complete_archive(self):
        check.check_archive_names(GOOD, V)

    def test_rejects_stale_version_manifests(self):
        with self.assertRaisesRegex(check.CheckError, "expected only"):
            check.check_archive_names(GOOD + [f"{P}1.149.2.2.manifest"], V)

    def test_rejects_another_version_dir(self):
        with self.assertRaisesRegex(check.CheckError, "no Chrome-bin"):
            check.check_archive_names(GOOD, "1.149.2.4")


if __name__ == "__main__":
    unittest.main()
