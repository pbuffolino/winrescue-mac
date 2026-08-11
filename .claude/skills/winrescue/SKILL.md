---
name: winrescue
description: Recover files from a Windows drive (NTFS or BitLocker) attached to a Mac, without ever writing to the source. Use when a Windows disk, M.2 SSD, or external drive will not mount on macOS, shows as unreadable/red in Disk Utility, is BitLocker encrypted, was left dirty by Windows Fast Startup, or when specific files must be located and extracted from a Windows volume. Also use for "drive won't mount", "recover files from a dead laptop", "BitLocker locked drive", or forensic file hunting in NTFS.
---

# Drive recovery: Windows volumes on macOS, read-only

## THE ONE RULE

**Never write to, repair, mount read-write, or erase the source drive.** It is usually the
only copy. If asked to "just repair it", explain that repair writes to the only copy and
offer the read-only path instead.

Never run: `diskutil eraseDisk/eraseVolume/partitionDisk/reformat/zeroDisk/repairDisk/repairVolume`,
`fsck*`, `newfs_*`, `mkfs.*`, `dd` with any `of=` other than `/dev/null`, or `mount`
without an explicit read-only flag. Disk Utility's **"First Aid" writes** — do not suggest it.

## Supervision

Stop and ask before: anything needing `sudo`, reading file *contents* (as opposed to
metadata), extracting files, installing software, or ejecting. Show each `sudo` command
before running it. Never run this in auto-approve mode.

## Step 0 — is a Mac the right machine?

Ask before running anything; don't assume the user has weighed it. This toolset is the
**safest** route, not the fastest.

- **Stay here** if: the drive is failing, it's someone else's data, a repair tool has
  already been run on it, or the user only has a Mac.
- **Windows is faster** if: healthy drive, user's own data, Windows PC available. Say so.
  Warn them to write-protect first (`diskpart` → `attributes disk set readonly`), **decline
  the "scan and fix" prompt**, and never `manage-bde -resume` a suspended volume — it
  destroys the clear key and makes a readable drive unreadable.
- **No platform helps** if BitLocker is locked with no clear key and no recovery key. That's
  a conversation with the owner, not a tooling problem.

Estimate up front: 20–40 min once the path is known; 1–3 hrs for an unknown fault;
hours-to-days if imaging is needed. See `docs/PLATFORM-CHOICE.md`.

## Setup

```bash
python3 -m venv venv && ./venv/bin/pip install -r requirements.txt
./scripts/00-preflight.sh                 # verifies environment and dependencies
```

Raw-device reads need root. If `sudo` can't prompt (no TTY), enable Touch ID once:

```bash
echo 'auth sufficient pam_tid.so' | sudo tee /etc/pam.d/sudo_local
```

Never ask the user to type a password into the conversation.

## Procedure

1. **Identify** — `diskutil list`; confirm the target with the user.
2. **Survey** — `./scripts/survey.sh diskN` → `docs/00-diagnosis.md`.
3. **Branch on the exit code**:

   | Exit | Meaning | Action |
   |---|---|---|
   | 0 | Plain NTFS | `01-mount-ro.sh`, or go straight to no-mount |
   | 10 | Failing drive | `ddrescue` image **first**, then work from the image |
   | 20 | BitLocker | **`probe-50-bitlocker.py` before saying it's locked** |
   | 21 | Unidentified FS | no-mount path |
   | 22 | Damaged boot sector | no-mount path, **never repair** |

4. **List before extracting** — always show the user what's there first.
5. **Extract narrowly** — only what the owner asked for.
6. **Verify** — SHA-256 + magic bytes + actually open one file.
7. **Log** to `RECOVERY-LOG.md`; redact personal details if sharing.

## BitLocker: check for a clear key first ⚑

**"BitLocker encrypted" does not mean "needs the recovery key."** A *suspended* volume
carries a **clear key** on disk and unlocks with no password at all — the normal state for
Windows 11 device encryption never tied to a Microsoft account.

```bash
sudo ./venv/bin/python scripts/probe-50-bitlocker.py /dev/rdiskNsX
```

- **CLEAR KEY** → unlocks transparently; proceed to the no-mount path.
- **Locked** → note the printed **recovery key identifier**; ask the *owner* to fetch the
  matching key from `account.microsoft.com/devices/recoverykey`. Never ask for their
  password. Then `BITLOCKER_RECOVERY_KEY='xxxxxx-...' sudo ./venv/bin/python ...`

**Do not install `dislocker`** — no macOS build; pulls toward macFUSE, which costs an
Apple Silicon Mac its boot security.

## No-mount path (works when mounting can't)

```bash
sudo ./venv/bin/python scripts/04-list-nomount.py /dev/rdiskNsX
sudo ./venv/bin/python scripts/04-list-nomount.py /dev/rdiskNsX --find '*.jpg'
sudo ./venv/bin/python scripts/04-list-nomount.py /dev/rdiskNsX --recycle-bin
sudo ./venv/bin/python scripts/05-extract-nomount.py /dev/rdiskNsX --path Users/Sam/Pictures ~/Recovered
sudo chown -R "$USER" ~/Recovered
```

Both accept an image file in place of a device.

## Hunting one specific file

Search by **basename**, not extension. Then: `--since YYYY-MM` to narrow, `--recycle-bin`
(the `$I` record gives the original path and deletion time), `--archives` (a file can
exist **only** inside a `.zip`), and read `.lnk` shortcuts — they store the target's full
path and drive type. Only report "not found" after a whole-MFT search *and* an archive search.

## Environment facts — do not report these as damage

- **`MS-DOS (FAT)` + `Volume Total Space: 0 B` + no volume name = a FAILED PROBE**, not a
  FAT volume. Three filesystems claim the Microsoft Basic Data GUID at the same probe order.
- **Windows Recovery partition shows "no file system" on every Mac** — no bundle claims
  GUID `DE94BBA4-…`. Normal.
- **macOS 26 has no `/sbin/mount_ntfs`** (NTFS is UserFS). A dirty NTFS volume cannot be
  force-mounted; don't try to clear the flag by repairing.
- **`MSWIN4.1`** is ordinary Windows FAT32's OEM ID, including every EFI partition — not
  by itself a BitLocker marker.
- **`smartctl` exit status is a bitmask**: bit 3 = failing, bits 0–1 = read failed.
- **NTFS 8.3 short names double-count** (`Rockstar Games` *and* `ROCKST~1`). Dedupe on the
  MFT segment number — `ntfsread.dedupe_records()`.
- **Raw devices need sector-aligned reads** (`EINVAL` otherwise) — use `AlignedReader`.

## Performance

Benchmark the **real** path before quoting a duration — a synthetic AES benchmark said
125 MB/s where the actual library path did 4 MB/s (30 min vs 17 hours). `lib/fastcrypto.py`
patches dissect.fve's pure-Python XTS to OpenSSL (4 → ~90 MB/s); `open_volume()` enables it
automatically. If you change the crypto path, run
`fastcrypto.verify_against_reference()` and confirm byte-identical output.

**Extract targeted files rather than decrypting whole volumes** — seconds vs 45+ minutes.

## Custodial duties

The drive usually belongs to someone else. Confirm scope with the owner first. Read
metadata by default; contents only as the task requires. `logs/` holds filenames and is
personal information (gitignored) — never paste it. Don't suggest erasing the source until
the owner confirms they have everything. Delete `~/Recovered` after handoff.

## Reference

`CLAUDE.md` (rules + checkpoints) · `docs/PLAYBOOK.md` (step-by-step) ·
`docs/LESSONS.md` (lessons + antipatterns) · `README.md` (script reference)
