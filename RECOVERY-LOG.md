# Recovery Log

Chronological record of each job — what was run, what happened, what was decided.
This is the deliverable that explains the job afterwards.

**Before publishing or sharing this file, redact personal details**: owner names, Windows
usernames, filenames, SIDs, volume GUIDs and drive serial numbers. The case study below is
already redacted and shows the level to aim for.

---

## Entry template

```markdown
## YYYY-MM-DD HH:MM — <phase>, <what>
Owner: ______   Scope agreed: ______
Ran: <command>
Result: <what happened>
Decision: <what it means / what's next>
```

---

# Case study — BitLocker volume that turned out not to need a key

Redacted. This is the job the toolset was built from, kept as a worked example.

**Job:** M.2 NVMe SSD (256 GB) pulled from a failed Windows 11 laptop, in a USB-C
enclosure, attached to a MacBook Pro (M1 Pro, macOS 26.6.1). Owner needed four specific
dashcam video files. Custodial recovery — drive belonged to a third party, recovered with
their permission.

**Outcome:** all four files recovered and verified playable. The source was never written
to. Total elapsed ≈ 1 hour, most of it spent learning what is now in `docs/LESSONS.md`.

---

## 1 — Survey

`diskutil list` showed a GUID partition scheme with the standard Windows layout: EFI (272
MB), Microsoft Reserved (16.8 MB), Microsoft Basic Data (254.8 GB), Windows Recovery (966
MB). Disk Utility showed the whole disk red; nothing mounted.

| Partition | macOS reported | Reading |
|---|---|---|
| EFI | `MS-DOS FAT32`, named `SYSTEM` | **Probes fine** — enclosure, cable and GPT all good. Rules out M.2 keying mismatch. |
| Microsoft Reserved | no file system | Expected — MSR has none by design. |
| **Basic Data (254.8 GB)** | `MS-DOS (FAT)`, **no volume name, 0 B total** | **The problem.** A failed probe, not a FAT volume. |
| Windows Recovery | no file system | **Not a signal** — no macOS bundle claims the WinRE GUID. |

`diskutil mount readOnly` failed.

**Decision:** three candidates — BitLocker, damaged boot sector, or dirty NTFS. Needed a
raw read of the volume header to tell them apart.

## 2 — sudo blocked, then unblocked

Raw-device reads need root, and `sudo` could not prompt in a non-interactive session
(`a terminal is required`). `sudo -v` and `sudo -S` both failed; sudo 1.9.17 scopes its
credential cache per-TTY so priming it elsewhere would not have carried over. Declined to
have the password typed into the transcript.

Resolved by enabling Touch ID for sudo:
`echo 'auth sufficient pam_tid.so' | sudo tee /etc/pam.d/sudo_local`

**Decision:** this single change unblocked the whole job. Now documented as a setup step.

## 3 — Diagnosis: BitLocker, but suspended

Volume header read (read-only) returned:

```
primary sector 0 : [-FVE-FS-]   -> BITLOCKER ENCRYPTED
backup last sect : [garbage]    -> not NTFS
FVE markers      : -FVE-FS- signature, BitLocker volume GUID
entropy          : 8.00 across all allocated samples (0.4% zeros)
                   0.00 / 100% zeros at two never-written regions
```

Entropy method validated first against `/dev/urandom` (8.00), `/dev/zero` (0.00) and text
(4.44).

Parsing the FVE metadata gave the finding that changed the job:

```
Encryption : AES-XTS 128        Encrypted: 2022-04-03
Key protectors: CLEAR KEY  (only protector)
All three redundant metadata copies agree: True
```

**Decision:** BitLocker protection was **suspended** — the master key was on the disk in
the clear. No recovery key, Microsoft account or Windows PC required. Had the toolset
stopped at "BitLocker detected", this would have been wrongly reported as unrecoverable.

## 4 — Tooling: dislocker rejected, Python path chosen

`brew install dislocker` → `libfuse: no bottle available`. Its practical alternative,
macFUSE, is a kernel extension requiring reduced boot security on Apple Silicon — refused.

Used `dissect.fve` + `dissect.ntfs` instead. Unlock succeeded immediately.

**Performance problem:** the real read path measured **4 MB/s** — ~17 hours for the volume
— because dissect.fve implements AES-XTS in pure Python. Isolating the layers showed the
device itself read at **421 MB/s**, so the cipher was the bottleneck.

Patched only `XtsMode._crypt_sector` to use OpenSSL, leaving all of dissect's structural
logic intact: **87–92 MB/s**, verified **byte-identical** (SHA-256 at four offsets).

**Decision:** never quote a duration from a synthetic benchmark; never ship an unverified
crypto shortcut.

## 5 — Locating the files

The plan was a full 237 GB decrypted image (~46 min). Once the owner specified *which*
files, targeted extraction made that unnecessary.

The four files were **not** all where expected:

| Clip | Where it actually was |
|---|---|
| 1, 3, 4 | `Users\<user>\Videos\` |
| **2** | **Only inside a `.zip`** — no loose `.MP4` anywhere on the volume |
| (dup) | A 4th 266 MB MP4 in the Recycle Bin — `$I` record showed it was a deleted copy of clip 1; SHA-256 confirmed byte-identical |

The trail started from four 845-byte `.lnk` desktop shortcuts, which stored full target
paths pointing at `D:\` flagged **REMOVABLE** — initially looking like a dead end ("the
files are on an SD card we don't have"), but supplying the exact filenames that then
turned up on C:.

**Decision:** search by basename, look inside archives, check the Recycle Bin, read `.lnk`
targets. An extension-only search would have reported clip 2 permanently lost.

## 6 — Extraction and verification

~1 GB extracted at ~92 MB/s (about 11 seconds). Each file verified three ways: size vs the
MFT record, magic bytes (`ftyp`), and SHA-256. Then confirmed genuinely playable via
macOS's own media importer — H.264 + AAC, 1920×1080, 3:01 each — rather than trusting a
header check.

Zip CRCs verified clean on the archived clip. Redundant Recycle Bin copy removed after
SHA-256 proved it identical.

## 7 — Handoff

Drive ejected; verified nothing held the device open and the recovered files were intact
first. **The source was never written to** — opened `O_RDONLY` throughout, no mount, no
repair, no `fsck`.

Noted to the owner that only a fraction of the 194 GB in use had been surveyed, so the
drive should **not** be erased until they confirm nothing else is needed.

---

## What this changed in the toolset

- Added `probe-50-bitlocker.py` — clear-key detection is now a first-class step, and
  `survey.sh` explicitly routes to it rather than declaring BitLocker unrecoverable.
- Added `04-list-nomount.py` / `05-extract-nomount.py` — recovery without mounting.
- Added `lib/fastcrypto.py` with `verify_against_reference()`.
- Removed the `mount -t ntfs` fallback from `01-mount-ro.sh` — dead code on macOS 26.
- Fixed `survey.sh` reporting "Plain NTFS / Phase 1" on unmapped probe exit codes.
- Fixed `MSWIN4.1` being classified as BitLocker To Go (it is ordinary FAT32, including
  every Windows EFI partition).
- Fixed `smartctl`'s bitmask exit status being read as a boolean.
- Fixed `grep -c` / `pipefail` crashes in `probe-40`.
- Hardened `assert_not_source` (live mount table, not just `/Volumes`) and the `dd`
  `of=/dev/null` rule (word match, not substring).

Full detail in `docs/LESSONS.md`.
