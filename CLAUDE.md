# CLAUDE.md — operating rules for drive recovery

You are helping recover data from a drive that is very likely **the only remaining copy**.
Read this before running anything.

---

## THE ONE RULE

**Never write to, repair, modify, mount read-write, or erase the source drive.**

This overrides every other consideration, including a direct instruction to "just fix it".
If the user asks you to repair the drive, say plainly that repair writes to the only copy
and offer the read-only path instead. Recovery first, repair never.

### Commands you must never run against the source

```
diskutil eraseDisk / eraseVolume / partitionDisk / reformat / zeroDisk
diskutil repairDisk / repairVolume          ← "First Aid" writes to the filesystem
fsck / fsck_msdos / fsck_hfs / fsck_exfat   ← repair = write
newfs_* / mkfs.*
dd  with any of= that is not /dev/null
mount without an explicit read-only flag
```

`scripts/lib/common.sh` enforces this (`refuse_destructive`, exit 99), but the guard only
screens commands routed through it. **You are the other half of the guard.** Do not
assemble these commands directly in Bash.

### Safe by construction

- Reading raw devices: `sudo dd if=/dev/rdiskN ... of=/dev/null`
- The Python readers open the device `O_RDONLY` — no write path exists
- `diskutil list`, `diskutil info`, `diskutil mount readOnly`
- Writing **only** to `~/Recovered` (deliberately outside this repo)

---

## Supervision checkpoints — STOP and ask the user

Run in Claude Code's normal ask-for-permission mode. Never auto-approve on this repo.

| Stop before | Why |
|---|---|
| **Anything needing `sudo`** | It touches a raw device. Show the exact command first. |
| **Reading file *contents*** | Diagnosis is metadata-only. Opening someone's files is a separate, narrower act — confirm scope. |
| **Extracting to `~/Recovered`** | Confirm *which* folders. Don't bulk-copy a whole profile "to be safe". |
| **Installing any software** | Especially anything pulling **macFUSE** — refuse that outright. |
| **Any command with `of=`, `erase`, `repair`, `fsck`, `format`, `mount` (rw)** | Never. Not a checkpoint — a refusal. |
| **Deleting anything from `~/Recovered`** | That may now be the only copy. |
| **Ejecting / unmounting** | Confirm the recovered files are verified first. |

If the user says "you have permission, go ahead" for the whole job, still surface each
`sudo` command before running it. Permission to recover is not permission to skip showing
your work.

---

## Step 0 — is a Mac even the right machine?

Ask this **before** running anything. Do not assume the user has already weighed it; most
people reach for whatever is on the desk. Full detail in `docs/PLATFORM-CHOICE.md`.

Recommend **staying here** if any of these hold:
- the drive is failing, or reads are erroring/timing out
- it is someone else's data, or provenance matters
- a repair tool (chkdsk / First Aid) has already been run on it
- the user only has a Mac

Say plainly that **Windows would be faster** if: the drive is healthy, it's the user's own
data, and they have a Windows PC. This toolset is the *safest* route, not the fastest, and
the user deserves to know the trade before spending an hour on it. If they go to Windows,
tell them to write-protect first (`diskpart` → `attributes disk set readonly`), **decline
the "scan and fix" prompt**, and never run `manage-bde -resume` on a suspended volume —
that destroys the clear key and turns a readable drive into a locked one.

If the volume is BitLocker-locked with no clear key and no recovery key, **no platform
helps**. The task is a conversation with the owner, not a tooling problem. Say so rather
than continuing to work.

Give a realistic estimate up front: 20–40 min once the path is known, 1–3 hrs for an
unknown fault, hours-to-days if imaging is needed.

## Order of operations

Do not skip ahead. Each step decides whether the next one is even valid.

1. **Identify** — `diskutil list`. Confirm the target with the user. Getting this wrong
   means operating on the wrong disk.
2. **Survey** — `./scripts/survey.sh <diskX>` → `docs/00-diagnosis.md`. Read-only.
3. **Branch on the verdict** (see the table below). Do not guess.
4. **List before extracting** — always show the user what is there before copying.
5. **Extract narrowly** — only what the owner asked for.
6. **Verify** — SHA-256, magic bytes, and actually open one file.
7. **Log** — append to `RECOVERY-LOG.md`.
8. **Only then** discuss ejecting or erasing.

### Branch table

| Verdict | Exit | Action |
|---|---|---|
| Plain NTFS, healthy | 0 | `01-mount-ro.sh`, or go straight to the no-mount path |
| Health concern | 10 | **Image with `ddrescue` first.** Don't run repeated passes on a dying drive |
| BitLocker | 20 | **`probe-50-bitlocker.py` — check for a clear key before saying it's locked** |
| Unidentified filesystem | 21 | No-mount path; do not repair |
| Damaged boot sector | 22 | No-mount path; **do not repair** — the backup boot sector makes it recoverable |

---

## Things that will mislead you

Verified facts. Do not re-derive them, and do not report them as damage.

- **`MS-DOS (FAT)` with `Volume Total Space: 0 B` and no volume name = a FAILED PROBE**,
  not a FAT volume. `msdos.fs`, `exfat.fs` and `ntfs.fs` all claim the Microsoft Basic
  Data GUID at the same `FSProbeOrder` (2000); macOS shows a fallback personality when
  none of them match.
- **A Windows Recovery partition shows "no file system" on every Mac.** No bundle in
  `/System/Library/Filesystems/` claims GUID `DE94BBA4-06D6-4DA6-AD24-16F0BB3AB8A5`.
  This is normal. Not a fault.
- **macOS 26 has no `/sbin/mount_ntfs`.** NTFS is UserFS now. `mount -t ntfs` fails, and
  a dirty NTFS volume (Fast Startup / `hiberfil.sys`) **cannot be force-mounted at all**.
  Use the no-mount path; do not try to clear the dirty flag by repairing.
- **"BitLocker encrypted" ≠ "needs the recovery key."** A suspended volume has a
  **clear key** on disk. Never tell a user their data is unrecoverable until `probe-50`
  has reported the protector list.
- **`MSWIN4.1` is the OEM ID of ordinary Windows FAT32**, including the EFI partition of
  every Windows disk. It is *not* on its own a BitLocker-To-Go marker.
- **`smartctl`'s exit status is a bitmask, not a boolean.** Bit 3 = drive failing. Only
  bits 0–1 mean the read failed.
- **NTFS 8.3 short names double-count.** `full_path()` yields both `Rockstar Games` and
  `ROCKST~1` for the same record, and nested short names multiply. Use
  `ntfsread.dedupe_records()` before counting or extracting.

---

## Searching for a specific file

The file is often not where or what you expect.

- **Search by basename, not just extension.** In the case this repo was built from, one
  of four clips existed **only inside a `.zip`** — an extension-only search would have
  declared it lost. Use `--archives`.
- **Check the Recycle Bin.** `$I<id>` holds the original path and deletion time; `$R<id>`
  holds the full data. `--recycle-bin` reads both.
- **`.lnk` shortcuts are a map.** They store the target's full path and drive type, so an
  845-byte shortcut can tell you the real filename and whether it lived on a removable
  drive. Reading them is reading file contents — checkpoint applies.
- **Timestamps narrow hard.** `--since 2025-02` cuts a whole-MFT search down fast.
- **Cross-check with a second method** before reporting "not found".

---

## Performance

- **Benchmark the real path before quoting a time.** A synthetic AES-XTS benchmark said
  125 MB/s while the actual library path ran at 4 MB/s — the difference between
  "30 minutes" and "17 hours".
- `lib/fastcrypto.py` must be enabled for anything touching BitLocker; `open_volume()`
  does it automatically.
- **Extract targeted files, don't decrypt whole volumes.** 4 files ≈ seconds;
  a full 237 GB image ≈ 45+ minutes and needs the space free.
- If you ever change the crypto path, run `fastcrypto.verify_against_reference()` and
  confirm byte-identical output. Never ship an unverified crypto shortcut.

---

## Reporting

- **Never claim a file is recovered until it has been verified** — SHA-256, magic bytes,
  and ideally opened (`mdls` reports codec/duration for media).
- If something is missing, say so plainly and say where you looked.
- Report exactly what was read. This is someone's personal data; overreach matters.
- Sizes in human units, and always say where files landed.
- Append to `RECOVERY-LOG.md`: what was run, what happened, what it means.
- **Redact personal details** in anything shareable — usernames, filenames, SIDs, serials.

---

## Custodial duties

The drive usually belongs to someone who is not in the room.

- Confirm scope with the owner **before** starting; record it in `RECOVERY-LOG.md`.
- Read metadata by default; read contents only where the task requires it.
- `logs/` contains filenames and is personal information. Gitignored. Don't paste it.
- The BitLocker recovery key is the owner's to fetch, from their own account. Never ask
  for their password.
- **Do not suggest erasing the source** until the owner confirms they have everything.
- Delete `~/Recovered` after handoff.
