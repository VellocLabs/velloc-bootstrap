"""Tests bootstrap_cli.py's default repository URLs.

  python scripts/bootstrap_cli_test.py
"""

import argparse
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bootstrap_cli as cli  # noqa: E402

PUBLIC_SRC_URL = "https://github.com/VellocLabs/velloc-chromium.git"
PUBLIC_CORE_URL = "https://github.com/VellocLabs/velloc-core.git"
URL_ENV = ("SRC_URL", "CUSTOM_BROWSER_URL")


def empty_args() -> argparse.Namespace:
    return argparse.Namespace(src_url=None, src_branch=None, src_revision=None)


class DefaultUrlsTest(unittest.TestCase):
    def resolve(self, **env):
        clean = {k: v for k, v in os.environ.items() if k not in URL_ENV}
        clean.update(env)
        with mock.patch.dict(os.environ, clean, clear=True):
            return cli.resolve_inputs(empty_args())

    def test_defaults_are_public_https_repositories(self):
        src_url, _, _, core_url, _, _ = self.resolve()
        self.assertEqual(src_url, PUBLIC_SRC_URL)
        self.assertEqual(core_url, PUBLIC_CORE_URL)

    def test_environment_overrides_the_defaults(self):
        src_url, _, _, core_url, _, _ = self.resolve(
            SRC_URL="https://example.test/src.git",
            CUSTOM_BROWSER_URL="https://example.test/core.git",
        )
        self.assertEqual(src_url, "https://example.test/src.git")
        self.assertEqual(core_url, "https://example.test/core.git")


if __name__ == "__main__":
    unittest.main()
