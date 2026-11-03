#!/usr/bin/env python3
"""Synthetic privacy regressions only; never inspect private or recovered files."""
import contextlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/check-local-source.py"
SPEC = importlib.util.spec_from_file_location("local_source_checks", SCRIPT)
CHECKS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKS)


class PrivacyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="winrescue-source-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.paths = list(CHECKS.REQUIRED) + [".gitignore", "synthetic.txt"]
        for name in self.paths:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("Public synthetic source\n")
        (self.root / ".gitignore").write_text("logs/\nvenv/\ndocs/00-diagnosis.md\n.claude/settings.local.json\n*.img\n")

    def check(self):
        with contextlib.redirect_stdout(io.StringIO()):
            CHECKS.check_sources(self.paths, self.root)

    def test_conservative_key_fragment_threshold_is_preserved(self):
        # Five groups were blocked by the former CI, even though a full key has eight.
        for groups in range(5, 9):
            with self.subTest(groups=groups):
                (self.root / "synthetic.txt").write_text("-".join(["123456"] * groups))
                with self.assertRaisesRegex(SystemExit, "possible BitLocker key"):
                    self.check()

    def test_safe_synthetic_sources_pass(self):
        self.check()

    def test_private_path_is_rejected_before_any_content_read(self):
        with patch.object(Path, "read_text", side_effect=AssertionError("unexpected content read")):
            with self.assertRaisesRegex(SystemExit, "refuse to read"):
                CHECKS.check_sources(["logs/synthetic.txt"], self.root)

    def test_missing_internal_doc_link_blocks(self):
        (self.root / "README.md").write_text("[Missing](missing.md)")
        with self.assertRaisesRegex(SystemExit, "does not resolve"):
            self.check()


if __name__ == "__main__":
    unittest.main()
