# Playbook — from "it won't mount" to recovered files

Follow in order. Each step decides whether the next is valid. Every command here is
read-only against the source.

---

## 0. Before touching anything

**Is this even the right machine?** See [`PLATFORM-CHOICE.md`](PLATFORM-CHOICE.md). Short version:

| Situation | Where |
|---|---|
| Failing drive · someone else's data · repair already attempted · Mac-only | **here** |
| Healthy drive, your own data, Windows PC available | **Windows** — faster, but write-protect it first |
| BitLocker locked, no clear key, no recovery key | **nowhere** — go and ask the owner |

Time to expect: 20–40 min once the path is known; 1–3 hrs on an unknown fault (diagnosis
dominates); hours-to-days if the drive is failing and needs imaging.

- [ ] **Confirm scope with the owner.** Which folders? Anything they'd rather you didn't copy?
- [ ] Record owner + agreed scope in `RECOVERY-LOG.md`.
- [ ] Confirm free space on the Mac ≥ what you intend to recover.
- [ ] **Do not** let anyone run Disk Utility "First Aid" on the drive. It writes.

If the drive is making unusual noises or reads are timing out, **stop** and go to
[Phase 3](#phase-3--failing-drive).

---

## 1. Identify the disk

```bash
diskutil list
```

Confirm the identifier with the user before proceeding. A typo here operates on the wrong
disk.

```bash
diskutil info diskN | grep -E 'Device / Media Name|Disk Size|Protocol|Read-Only'
```

**No partitions at all?** Before concluding the drive is dead, suspect an **M.2 keying
mismatch** — an NVMe (M-key) drive in a SATA (B+M-key) enclosure, or vice versa, looks
exactly like total failure.

---

## 2. Survey (read-only)

```bash
./scripts/survey.sh diskN
```

Writes `docs/00-diagnosis.md`. Runs probes 10 (identity + USB link speed), 20 (health),
30 (filesystem/encryption).

**Check the USB link speed.** A 480 Mb/s negotiation means USB 2.0 fallback and turns a
20-minute copy into 3 hours. Reseat the cable, avoid hubs, use a direct port.

### Read the verdict

| Exit | Verdict | Go to |
|---|---|---|
| 0 | Plain NTFS, healthy | [Phase 1](#phase-1--plain-ntfs) |
| 10 | Health concern | [Phase 3](#phase-3--failing-drive) |
| 20 | BitLocker | [Phase 2](#phase-2--bitlocker) |
| 21 | Unidentified filesystem | [Phase 4](#phase-4--no-mount) |
| 22 | Damaged boot sector | [Phase 4](#phase-4--no-mount) — **do not repair** |

Anything else, including `UNKNOWN`: stop and read the raw transcript in `logs/`.

### Don't misread these

- `MS-DOS (FAT)`, 0 bytes, no volume name → **failed probe**, not a FAT volume.
- Windows Recovery partition → "no file system" on every Mac. Normal.
- `hiberfil.sys` present → Fast Startup left the volume dirty. Expected, not damage.

---

## Phase 1 — plain NTFS

```bash
./scripts/01-mount-ro.sh diskNsX
./scripts/probe-40-content.sh /Volumes/<name>
```

Probe 40 answers the two questions that decide the rest: how much data is really there,
and whether the files are real or **OneDrive placeholders** (present but ~0 KB — the data
is in the cloud, not on the disk).

```bash
./scripts/02-copy.sh /Volumes/<name> <windows-username>
./scripts/03-verify.sh ~/Recovered/<windows-username>
```

**If the mount fails**, it is almost certainly a dirty volume. macOS 26 cannot force-mount
one — there is no `mount_ntfs`. Do **not** repair it. Go to [Phase 4](#phase-4--no-mount);
you don't need a mount.

---

## Phase 2 — BitLocker

**Do not tell the owner their data is gone yet.**

```bash
sudo ./venv/bin/python scripts/probe-50-bitlocker.py /dev/rdiskNsX
```

### If it reports CLEAR KEY

Protection is **suspended** and the master key is on the disk. It unlocks with no password
and no recovery key. Go straight to [Phase 4](#phase-4--no-mount) — everything works
transparently.

This is the normal state for Windows 11 device encryption that was never tied to a
Microsoft account. Check it every time.

### If it reports a locked volume

The data is AES-encrypted and the key is not on the drive. Note the **recovery key
identifier** probe-50 prints.

Ask the **owner** to fetch their key themselves:
`https://account.microsoft.com/devices/recoverykey` — they match the key whose ID begins
with the characters you were given. **Never ask for their account password.**

Then:

```bash
BITLOCKER_RECOVERY_KEY='xxxxxx-xxxxxx-...' \
  sudo ./venv/bin/python scripts/04-list-nomount.py /dev/rdiskNsX
```

**Do not install `dislocker`.** No macOS build, and it pulls toward macFUSE, which costs
an Apple Silicon Mac its boot security.

---

## Phase 3 — failing drive

Read errors, slow reads, or SMART flags. **Minimise reads of the original.** Image once,
then work from the image.

```bash
diskutil unmountDisk /dev/diskN          # unmount, never erase
sudo ddrescue -n -d /dev/rdiskN ~/drive.img ~/drive.map   # fast first pass
sudo ddrescue -d -r3 /dev/rdiskN ~/drive.img ~/drive.map  # retry bad areas
```

Image **the partition** (`diskNsX`) rather than the whole disk if space is tight, and
confirm free space exceeds the image size *before* starting.

Every tool here accepts an image file in place of a device:

```bash
sudo ./venv/bin/python scripts/04-list-nomount.py ~/drive.img
```

---

## Phase 4 — no-mount recovery

The general-purpose path. Works for BitLocker (clear key or supplied key), dirty NTFS,
damaged boot sectors, and images.

### 1. Look before you copy

```bash
sudo ./venv/bin/python scripts/04-list-nomount.py /dev/rdiskNsX
```

Shows profiles, folder sizes and cloud-stub counts. Then narrow:

```bash
... 04-list-nomount.py /dev/rdiskNsX --path Users/Sam/Pictures
... 04-list-nomount.py /dev/rdiskNsX --find '*.jpg'
... 04-list-nomount.py /dev/rdiskNsX --find invoice --since 2025-02
... 04-list-nomount.py /dev/rdiskNsX --recycle-bin
```

### 2. Hunting one specific file

In order of usefulness:

1. **Search by basename**, not extension — `--find taxreturn`.
2. **Narrow by date** — `--since 2025-02`.
3. **Check the Recycle Bin** — `--recycle-bin` shows original paths and deletion times.
4. **Look inside archives** — `--archives`. A file can exist *only* inside a `.zip`.
5. **Read `.lnk` shortcuts** — they store the target's full path and drive type, which
   tells you the real filename and whether it lived on removable media.

Only report "not found" after a whole-MFT search **and** an archive search.

### 3. Extract

```bash
sudo ./venv/bin/python scripts/05-extract-nomount.py /dev/rdiskNsX \
     --path Users/Sam/Pictures ~/Recovered --dry-run
sudo ./venv/bin/python scripts/05-extract-nomount.py /dev/rdiskNsX \
     --path Users/Sam/Pictures ~/Recovered
```

Each file gets a SHA-256, a magic-byte check and a size cross-check. Duplicate content is
reported so you can drop redundant copies.

```bash
sudo chown -R "$USER" ~/Recovered      # files land root-owned when run under sudo
```

### 4. Verify for real

```bash
./scripts/03-verify.sh ~/Recovered
mdls -name kMDItemDurationSeconds -name kMDItemCodecs ~/Recovered/some.mp4
open ~/Recovered/some.jpg
```

**Open at least one file by hand.** A file that exists is not a file that opens.

---

## 5. Hand off and clean up

- [ ] Owner confirms they have everything they need.
- [ ] `RECOVERY-LOG.md` updated.
- [ ] Eject: `diskutil eject diskN`.
- [ ] **Only after the owner confirms**, the source may be considered free to erase — their
      call, not yours.
- [ ] Delete `~/Recovered` once handed over. Keeping someone's personal data indefinitely
      is not neutral.
- [ ] If publishing this repo, check `logs/` and `RECOVERY-LOG.md` for personal details.

---

## Emergency: "I already ran First Aid / repair"

Repair writes to the filesystem, so some metadata is already overwritten. Do not run it
again, and do not run it a third time "to be sure".

1. Stop using the drive immediately.
2. Image it now (Phase 3) and work only from the image.
3. Recover from the image with Phase 4; if the MFT is gone, carve with `photorec` into a
   destination on the internal disk.
