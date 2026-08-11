# Contributing

Contributions are welcome. This tool runs against drives that are often **the only
remaining copy** of someone's data, so the bar for anything that touches a device is
deliberately high.

---

## The one rule

> **Nothing in this repo may write to, repair, modify, or erase the source drive.**

Any pull request that adds a write path to a source device will be declined regardless of
how useful the feature is. This is the project's entire reason to exist.

Concretely, a PR must never introduce:

- `diskutil eraseDisk / eraseVolume / partitionDisk / reformat / zeroDisk / repairDisk / repairVolume`
- `fsck*`, `newfs_*`, `mkfs.*`
- `dd` with any `of=` other than `/dev/null`
- `mount` without an explicit read-only flag
- anything requiring **macFUSE** or another kernel extension

`tests/test-guards.sh` enforces this in CI, including a scan of the scripts themselves.
If your change makes that suite fail, the change is wrong — not the test.

New device access should go through `AlignedReader` in `scripts/lib/ntfsread.py`, which
opens `O_RDONLY`. That makes "read-only" a property of the file descriptor rather than a
promise in a comment.

---

## Before you open a PR

```bash
python3 -m venv venv && ./venv/bin/pip install -r requirements.txt
./scripts/00-preflight.sh      # environment check — touches no disks
bash tests/test-guards.sh      # safety suite — must be 100% green
./venv/bin/python tests/test_lib.py
```

All three run in CI on every PR. Running them locally first saves a round trip.

---

## Privacy — read this before pasting output

Recovery work involves other people's data. **A filename is personal information**, and
anything committed to git history is effectively permanent.

Never include in an issue, PR, commit or test fixture:

- real filenames, folder names or directory listings
- Windows usernames, SIDs (`S-1-5-21-…`)
- BitLocker recovery keys **or key identifiers**
- volume GUIDs, drive serial numbers
- absolute paths containing a real home directory
- screenshots of file listings

Redact with obvious placeholders (`Users/Sam/...`, `A1B2C3D4-...`). CI runs a privacy scan
that fails the build on several of these patterns, but it is a backstop, not a substitute
for checking.

`logs/`, `venv/`, `docs/00-diagnosis.md` and `~/Recovered` are gitignored for this reason.
Do not add exceptions.

---

## What is most useful

Ranked roughly by value:

1. **Other filesystems** — exFAT, ReFS, or Linux volumes, via the same read-only pattern.
2. **Other encryption** — VeraCrypt, or BitLocker configurations not yet handled (TPM-only,
   startup-key, BitLocker To Go on removable media).
3. **Verified environment facts** — macOS changes underneath this tool. If something in
   `docs/LESSONS.md` is wrong on your version, a correction *with the command that proves
   it* is very welcome.
4. **Recovery scenarios we handle badly** — a case where the toolset gave a confidently
   wrong answer is a high-value bug report. That has happened before and is documented.
5. **Performance**, where measured. See below.
6. **Windows/Linux equivalents** of the no-mount path.

---

## Standards

**Shell** — bash 3.2 compatible (that is what macOS ships at `/bin/bash`): no associative
arrays, no `${var,,}`, no `mapfile`. Source `scripts/lib/common.sh` for output helpers and
guards. Pass `shellcheck` at `warning` severity.

**Python** — 3.11+, standard library plus what is already in `requirements.txt`. Adding a
dependency needs justification in the PR description. No kernel extensions, ever.

**Comments** — explain *why*, especially where the code is non-obvious for a reason. This
codebase is full of "this looks wrong but macOS made me do it"; those comments are load
bearing. Say what breaks if the line is changed.

**Diagnostics must fail closed.** If a probe cannot determine something, it must report
`UNKNOWN` and stop — never a healthy-looking default. A tool that says "fine" when it means
"I don't know" is worse than no tool. See antipattern A in `docs/LESSONS.md`.

---

## Performance claims

Benchmark the **real** path, not a synthetic proxy, and say how you measured. A synthetic
AES benchmark in this project once read 30× faster than the actual code path — the
difference between a 30-minute and a 17-hour estimate.

If you change anything in the crypto path, you must show byte-identical output against the
reference implementation:

```python
fastcrypto.verify_against_reference(open_stream)
```

Unverified crypto shortcuts will not be merged.

---

## Commits and review

- Focused commits with a clear subject line; imperative mood.
- Describe **what breaks if this is wrong** in the PR body — for this project that matters
  more than what the change does.
- Every PR needs review and approval from a code owner before merge. CI must be green.
- Squash merge; the branch is deleted on merge.

## Testing against real hardware

You do not need a real drive for most changes — the test suites use temp files. If you do
test against hardware:

- use a drive you own, or a disk image
- confirm the source is unchanged afterwards (`diskutil info` before/after: partition map,
  sizes and UUIDs must match)
- never include real output in the PR

## Reporting a security or safety issue

If you find a path where this toolset could **write to a source drive**, treat it as a
security issue and follow `SECURITY.md` — do not open a public issue.

## Code of conduct

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).
