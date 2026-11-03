#!/usr/bin/env python3
"""Source-only privacy/docs checks. Never reads devices or recovery outputs."""
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PATTERNS = {
    "Windows SID": r"S-1-5-21-[0-9]{5,}",
    "BitLocker key": r"[0-9]{6}-[0-9]{6}-[0-9]{6}-[0-9]{6}-[0-9]{6}",
    "absolute home path": r"/Users/[a-z][a-z0-9_.-]+/(Github|Documents|Desktop|Downloads)",
    "Windows user path": r"C:\\+Users\\+[A-Za-z][A-Za-z0-9_. -]+\\+",
    "private key": r"BEGIN (RSA|OPENSSH|PGP|EC) PRIVATE KEY",
}
REQUIRED = (
    "README.md", "CLAUDE.md", "CONTRIBUTING.md", "CODE_OF_CONDUCT.md", "SECURITY.md",
    "LICENSE", "requirements.txt", "docs/PLAYBOOK.md", "docs/LESSONS.md",
    "docs/PLATFORM-CHOICE.md", "docs/HANDOFF.md", ".claude/skills/winrescue/SKILL.md",
)


def check_sources(paths, root=ROOT):
    # Only tracked source paths are read, never ignored logs or recovered data.
    root = Path(root)
    denied = ("logs/", "venv/", "staging/", "recovered/", "Recovered/")
    if any(path.startswith(denied) or path in ("docs/00-diagnosis.md", ".claude/settings.local.json") for path in paths):
        raise SystemExit("Private/runtime path tracked; refuse to read its contents")
    files = [root / path for path in paths if path]
    for path in files:
        if not path.resolve().is_relative_to(root.resolve()) or path.is_symlink():
            raise SystemExit("Source file escapes the checkout; review required")
        if re.search(r"\.(jpg|jpeg|png|heic|mp4|mov|avi|mkv|pdf|docx|xlsx|img|dmg|zip)$", path.name, re.I):
            raise SystemExit("Media/data-like file tracked; inspect locally without publishing its name")
        try:
            text = path.read_text()
        except (UnicodeError, OSError):
            raise SystemExit("Unreadable tracked source; privacy scan incomplete")
        for label, pattern in PATTERNS.items():
            if re.search(pattern, text):
                raise SystemExit(f"Privacy audit failed: possible {label}; inspect locally without publishing content")
        if path.suffix == ".md":
            for link in re.findall(r"\]\(([A-Za-z0-9_./-]+\.md)\)", text):
                if not (path.parent / link).is_file():
                    raise SystemExit("Internal documentation link does not resolve")
    for name in REQUIRED:
        if not (root / name).is_file():
            raise SystemExit("Required source documentation is missing")
    ignore = (root / ".gitignore").read_text().splitlines()
    for entry in ("logs/", "venv/", "docs/00-diagnosis.md", ".claude/settings.local.json", "*.img"):
        if entry not in ignore:
            raise SystemExit("Required privacy ignore entry is missing")
    print("Tracked-source privacy, ignore rules and internal documentation checks passed")


if __name__ == "__main__":
    top = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], cwd=ROOT, text=True).strip()
    if Path(top).resolve() != ROOT.resolve():
        raise SystemExit("Run this gate from its own Git source checkout")
    paths = subprocess.check_output(["git", "ls-files", "--cached", "-z"], cwd=ROOT).decode().split("\0")
    check_sources(paths)
