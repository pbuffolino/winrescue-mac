# Security Policy

## What counts as a security issue here

This project is unusual: the highest-severity bug class is not remote code execution, it is
**anything that could write to a source drive**. That drive is frequently the only remaining
copy of someone's data, and a single write can destroy it permanently.

Report privately, **do not open a public issue**, if you find:

| Severity | Issue |
|---|---|
| **Critical** | Any code path that can write to, repair, or modify a source device |
| **Critical** | A way to bypass `refuse_destructive` or `assert_not_source` |
| **High** | A diagnostic that reports "healthy" or "safe" when it cannot actually tell — a confidently wrong verdict leads people to act destructively |
| **High** | Recovered data or personal information (filenames, SIDs, BitLocker keys) leaking into logs, output, or git history |
| **Medium** | Mishandling of BitLocker key material — keys written to disk, logged, or left in a temp file |
| **Medium** | Dependency vulnerabilities affecting the crypto path |

Ordinary crashes, usability problems and documentation errors are **not** security issues —
please open a normal issue for those.

## How to report

Use GitHub's private reporting:
**[Report a vulnerability](https://github.com/pbuffolino/winrescue-mac/security/advisories/new)**

Include:

- what the issue is, and which severity above it maps to
- the affected file and line
- how you found it, and how to reproduce it
- **redacted** evidence only — no real filenames, usernames, SIDs, volume GUIDs or
  recovery keys. Placeholders are fine and preferred.

Please do not include output from a real recovery job.

## Response

- Acknowledgement within **7 days**
- An assessment and plan within **14 days**
- Fixes for Critical issues prioritised over all other work

This is a small volunteer project, not a funded product — timelines are best effort. There
is no bug bounty.

## Disclosure

Please give a reasonable window to ship a fix before publishing. Credit is given in the
release notes unless you prefer otherwise.

## Scope

In scope: everything in this repository.

Out of scope: vulnerabilities in upstream dependencies (`dissect.ntfs`, `dissect.fve`,
`cryptography`) — report those to their maintainers, though telling us as well is
appreciated so we can pin or work around them.

## For users of this toolset

A few operational notes that are security-relevant:

- **`sudo` is used only to read raw devices.** Every invocation is `dd if=… of=/dev/null`
  or a Python `O_RDONLY` open. If you see this project asking for root for any other
  reason, that is a bug worth reporting.
- **BitLocker keys are never written to disk by this toolset.** Recovery keys are passed via
  the `BITLOCKER_RECOVERY_KEY` environment variable and held in memory. Be aware that
  environment variables can be visible to other processes on the same machine, and that
  shell history may capture the command — prefer `read -s` into the variable over typing it
  inline.
- **`logs/` contains filenames**, which are personal information. It is gitignored. Treat it
  as sensitive and delete it after a job.
- **Enabling Touch ID for `sudo`** (`/etc/pam.d/sudo_local`) is recommended in the docs and
  is a real change to your system's authentication configuration. It makes `sudo` usable
  without a TTY. Remove it with `sudo rm /etc/pam.d/sudo_local` if you do not want it.
