# winrescue-mac

Recover files from a Windows disk using a Mac — **without ever writing to the source drive.**

Handles NTFS *and* BitLocker, including volumes macOS cannot mount at all.

Built for the common real-world case: a Windows laptop dies, someone pulls the M.2 SSD,
drops it in a USB enclosure, and plugs it into a MacBook. The volume then refuses to
mount, and the usual advice ("run First Aid", "repair the disk") is exactly wrong,
because every repair tool writes to the only copy of the data.

This toolset diagnoses *why* it won't mount and reads the files off it **without mounting
it at all**.

---

## First: should you use this at all?

This is the **safest** option, not the fastest. On a healthy drive with your own data and a
Windows PC to hand, Windows is genuinely quicker — it will often just mount the volume,
including a BitLocker volume that is suspended, and you're done in fifteen minutes.

Use **this toolset** when any of these is true:

- The drive is **failing** — Windows' indexing and thumbnailing are the last thing a dying disk needs
- It is **someone else's data**, or provenance matters (dispute, insurance, legal)
- Someone has **already run chkdsk / First Aid** on it — stop writing, image it
- **You only have a Mac** (the common case)

Use **Windows** when: healthy drive, your own data, and a Windows machine is available —
but read the safety steps first, because Windows mounts read-write by default and offers to
"fix" exactly the volumes you must not let it touch.

**Nothing helps** if the volume is BitLocker-locked with no clear key and no recovery key —
that's a conversation with the owner, not a tooling problem.

→ **[`docs/PLATFORM-CHOICE.md`](docs/PLATFORM-CHOICE.md)** — decision table, realistic time
estimates per scenario, and how to make Windows safe if you go that way.

---

## The one rule

> **Nothing here writes to, repairs, or modifies the source drive.**

Enforced in code, not documentation:

| Guard | Where | What it does |
|---|---|---|
| `refuse_destructive` | `scripts/lib/common.sh` | Blocklist: `eraseDisk`, `partitionDisk`, `repairVolume`, `fsck`, `newfs`, `mkfs`, `rm -rf /Volumes`. Exits 99. |
| `refuse_destructive` (dd rule) | same | `dd` may only read. `of=` must be **exactly** `/dev/null` — word-matched, so `of=/dev/null.img` is blocked. |
| `assert_not_source` | same | Refuses destinations under `/Volumes` **or any currently-mounted non-root filesystem**, checked against the live mount table. |
| `assert_mounted_readonly` | same | Hard guard for anything that will write. |
| `warn_if_not_readonly` | same | Soft guard for read-only probes — returns a status instead of exiting. |
| `os.O_RDONLY` | `scripts/lib/ntfsread.py` | The Python readers open the device read-only at the syscall level. There is no write path. |

Regression-tested: 12/12 destructive commands blocked, 4/4 read-only equivalents allowed.

**Commands this toolset will never run:** `diskutil eraseDisk / eraseVolume /
partitionDisk / reformat / zeroDisk / repairDisk / repairVolume`, `fsck*`, `newfs_*`,
`mkfs.*`, `dd of=<anything but /dev/null>`, `mount` without an explicit read-only flag.

---

## Requirements

### macOS
- macOS 13+ (developed and verified on **macOS 26.6.1**, Apple Silicon M1 Pro)
- Admin account — `sudo` is needed **only to read raw devices** (`/dev/rdiskN`)

### Strongly recommended: Touch ID for sudo
Raw-device reads need root. In a non-interactive or agent-driven session `sudo` cannot
prompt for a password (`sudo: a terminal is required`). Touch ID fixes this cleanly:

```bash
echo 'auth sufficient pam_tid.so' | sudo tee /etc/pam.d/sudo_local
```

Without it, run the scripts from a normal Terminal window so `sudo` can prompt.
To undo: `sudo rm /etc/pam.d/sudo_local`.

### Python (required for the no-mount and BitLocker paths)

```bash
cd winrescue-mac
python3 -m venv venv
./venv/bin/pip install -r requirements.txt
```

| Package | Why |
|---|---|
| `dissect.ntfs` | Read NTFS without mounting it |
| `dissect.fve` | BitLocker (FVE) volume handling |
| `cryptography` | OpenSSL AES-XTS — **13–20× faster** than the pure-Python path |

### Optional command-line tools

```bash
brew install smartmontools ddrescue testdisk
```

| Tool | Used by | Needed when |
|---|---|---|
| `smartctl` | `probe-20` | Drive health check |
| `ddrescue` | Phase 3 | The drive is failing and must be imaged first |
| `photorec` / `testdisk` | Last resort | The filesystem itself is gone and files must be carved |

### Do NOT install

- **`dislocker`** — the obvious BitLocker tool, but on Apple Silicon Homebrew it depends
  on `libfuse` (no macOS bottle) and in practice pulls toward **macFUSE**, a kernel
  extension that costs the Mac its boot security. The Python path here needs neither and
  is faster. See `docs/LESSONS.md`.

---

## Quick start (human)

```bash
diskutil list                          # find the disk, e.g. disk4
./scripts/survey.sh disk4              # read-only diagnosis -> docs/00-diagnosis.md
```

Then follow the verdict:

| Survey says | Do this |
|---|---|
| Plain NTFS, healthy | `./scripts/01-mount-ro.sh disk4s3` → `02-copy.sh` |
| **BitLocker** | `./scripts/probe-50-bitlocker.py /dev/rdisk4s3` — **check for a clear key first** |
| Unidentified / damaged boot sector | `./scripts/04-list-nomount.py /dev/rdisk4s3` |
| Health concern | Image with `ddrescue` first, then work from the image |

The no-mount path works regardless and is usually the fastest route to the data:

```bash
sudo ./venv/bin/python scripts/04-list-nomount.py /dev/rdisk4s3
sudo ./venv/bin/python scripts/05-extract-nomount.py /dev/rdisk4s3 \
     --find '*.jpg' ~/Recovered
```

---

## Quick start (Claude Code or another agent)

The repo ships `CLAUDE.md` (operating rules + supervision checkpoints) and a skill at
`.claude/skills/winrescue/SKILL.md`.

```bash
cd winrescue-mac
claude
```

Then: *"A Windows drive is attached as disk4. Recover the owner's photos. Follow CLAUDE.md."*

The agent is instructed to **stop and ask** before: running anything needing `sudo`,
writing outside `~/Recovered`, extracting personal files, and installing software.
See **Supervision checkpoints** in `CLAUDE.md`. Run it in Claude Code's default
ask-for-permission mode — do not use auto-approve for drive recovery.

---

## Scripts

Every script is read-only against the source. "Writes" below means the repo or `~/Recovered`.

### Diagnosis

| Script | Input | Output | Sudo |
|---|---|---|---|
| `survey.sh <diskX> [/Volumes/x]` | whole-disk id | `docs/00-diagnosis.md`, `logs/`, exit code | yes (primes once) |
| `probe-10-identity.sh <diskX>` | whole-disk id | partition map, size, **USB link speed**, `logs/` | no |
| `probe-20-health.sh <diskX>` | whole-disk id | SMART + 64-point sampled surface read | read-only |
| `probe-30-filesystem.sh <diskX>` | whole-disk id | FS/encryption verdict + entropy profile | read-only |
| `probe-40-content.sh <mountpoint>` | mounted path | file counts, sizes, OneDrive stub check | no |
| `probe-50-bitlocker.py <device>` | `/dev/rdiskXsY` | **key protectors, clear-key verdict, recovery key ID** | read-only |

**Exit codes** (`survey.sh` maps every one; unmapped codes render as `UNKNOWN`, never as healthy):

| Code | Meaning |
|---|---|
| 0 | Plain NTFS, not encrypted |
| 10 | Health concern — image before proceeding |
| 20 | BitLocker — **run probe-50 before assuming a key is needed** |
| 21 | Unidentified filesystem — use the no-mount path |
| 22 | NTFS with a damaged boot sector — recoverable, do not repair |

### Recovery

| Script | Input | Output |
|---|---|---|
| `01-mount-ro.sh <diskXsY>` | partition id | read-only mount, or a diagnosis of why it can't mount |
| `02-copy.sh <vol> <winuser>` | mounted path + username | `~/Recovered/<user>/`, rsync log |
| `03-verify.sh [dir]` | recovered dir | zero-byte / stub / magic-byte report |
| `04-list-nomount.py <device> [...]` | `/dev/rdiskXsY` | file listing — **no mount required** |
| `05-extract-nomount.py <device> <dest> [...]` | device + dest | extracted files + SHA-256 + verification |

**`04-list-nomount.py` modes**

```bash
04-list-nomount.py /dev/rdisk4s3                        # profiles + folder sizes
04-list-nomount.py /dev/rdisk4s3 --path Users/Sam/Videos
04-list-nomount.py /dev/rdisk4s3 --find '*.mp4'         # whole-MFT search
04-list-nomount.py /dev/rdisk4s3 --find report --since 2025-02
04-list-nomount.py /dev/rdisk4s3 --recycle-bin          # deleted files + original paths
```

**`05-extract-nomount.py` modes**

```bash
05-extract-nomount.py /dev/rdisk4s3 --path Users/Sam/Pictures ~/Recovered
05-extract-nomount.py /dev/rdisk4s3 --find '*.mp4' ~/Recovered
05-extract-nomount.py /dev/rdisk4s3 --find holiday --archives ~/Recovered   # look inside .zip
05-extract-nomount.py /dev/rdisk4s3 --recycle-bin ~/Recovered
05-extract-nomount.py /dev/rdisk4s3 --find '*.jpg' ~/Recovered --dry-run
```

Every extracted file gets a SHA-256, a magic-byte check against its extension, and a size
cross-check against the MFT. Identical files are reported so duplicates can be dropped.

**Locked BitLocker volume?** Once the owner supplies their key:

```bash
BITLOCKER_RECOVERY_KEY='xxxxxx-xxxxxx-...' \
  sudo ./venv/bin/python scripts/04-list-nomount.py /dev/rdisk4s3
```

### Library

| File | Purpose |
|---|---|
| `lib/common.sh` | Safety guards, output helpers, volume-header forensics |
| `lib/ntfsread.py` | `AlignedReader` (raw-device reads), `open_volume()`, MFT helpers |
| `lib/fastcrypto.py` | OpenSSL AES-XTS patch + **`verify_against_reference()`** |

---

## What this toolset knows that cost real time to learn

Full write-up in **`docs/LESSONS.md`**. The short version:

- **"BitLocker" does not mean "you need the recovery key."** A *suspended* volume carries
  a **clear key** on disk and unlocks with no key at all — the normal state for Windows 11
  device encryption that was never tied to a Microsoft account. **Always run `probe-50`
  before telling anyone their data is gone.**
- **macOS 26 has no `/sbin/mount_ntfs`.** NTFS moved to UserFS. Any `mount -t ntfs`
  fallback is dead code, and a dirty NTFS volume cannot be force-mounted at all.
- **`MS-DOS (FAT)` with 0 bytes and no volume name is a *failed probe*, not a finding.**
  Three filesystems claim the Microsoft Basic Data GUID at the same probe order.
- **A Windows Recovery partition always shows "no file system" on macOS.** No bundle
  claims its GUID. Not damage.
- **Benchmark the real path before quoting a time.** A synthetic AES benchmark said
  125 MB/s; the actual library path ran at 4 MB/s — 30 min vs 17 hours.
- **Don't decrypt 237 GB to recover 1 GB.** Targeted extraction took seconds.

---

## Working with someone else's data

This is usually a **custodial** job — the drive belongs to someone else.

- **Confirm scope with the owner before starting**, and log it in `RECOVERY-LOG.md`.
- **Metadata by default.** Diagnosis reads names, sizes and timestamps — not contents.
  Reading file *contents* is a deliberate step (extraction, or parsing a `.lnk`), and
  should be narrowed to what the owner asked for.
- **`logs/` is personal information.** A list of filenames is as revealing as the files.
  Gitignored. Don't paste it into chats or issues.
- **The recovery key is theirs to fetch.** Ask them to sign into their own Microsoft
  account. Never ask for their password.
- **Hand back and clean up.** Delete `~/Recovered` once they confirm receipt.
- **Do not erase the source** until the owner has confirmed they have everything.

`~/Recovered` is deliberately **outside this repo** so recovered data cannot be committed.

---

## Repo layout

```
CLAUDE.md                     operating rules for an AI agent + supervision checkpoints
README.md                     this file
RECOVERY-LOG.md               per-job chronological log (the deliverable)
requirements.txt              Python dependencies
docs/LESSONS.md               lessons learned, antipatterns, environment facts
docs/PLAYBOOK.md              decision tree from "won't mount" to recovered files
docs/HANDOFF.md               per-job worksheet: inventory, transfer, sign-off, cleanup
docs/00-diagnosis.md          generated by survey.sh
scripts/                      probes, recovery tools, lib/
.claude/skills/winrescue/      reusable skill
logs/                         raw probe output (gitignored — contains filenames)
```

---

## Licence / sharing

Share it. It contains no personal data by design: `logs/` and `~/Recovered` are excluded,
and the case study in `RECOVERY-LOG.md` is redacted. **If you fork this after a real job,
check `logs/` and `RECOVERY-LOG.md` before publishing.**
