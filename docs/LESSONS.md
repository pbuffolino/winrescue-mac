# Lessons learned

From a real recovery: an HP Windows 11 laptop's 256 GB Samsung NVMe SSD, pulled into a
USB-C enclosure, attached to an M1 Pro MacBook on macOS 26.6.1. Disk Utility showed the
whole disk red and nothing would mount.

Outcome: the volume was BitLocker encrypted **but suspended with a clear key**, so it
unlocked with no recovery key at all. Four requested video files were located and
extracted, verified playable, in about an hour of wall-clock time — most of it spent
learning the things below.

---

## 1. "Won't mount" is a symptom with several very different causes

macOS gives you almost nothing to distinguish them, and they need opposite responses.

| Cause | Signal | Response |
|---|---|---|
| BitLocker | `-FVE-FS-` at offset 3 of sector 0 | Check protectors — may need no key at all |
| Damaged boot sector | sector 0 garbage, **last sector says `NTFS`** | Read via backup; **never repair** |
| Dirty NTFS (Fast Startup) | `hiberfil.sys` present, FS identifies as NTFS | Read without mounting |
| Genuinely unknown | neither boot sector is NTFS, high entropy everywhere | Carve as last resort |

The single cheapest discriminator: **read the last sector of the partition.** NTFS mirrors
its boot sector there. `NTFS` in the backup while sector 0 is garbage means the filesystem
is intact and only the boot sector is damaged — highly recoverable, and decisively not
encryption.

### Entropy is the tie-breaker
Encrypted data is uniformly random. Sample a few 64 KB windows across the volume and
compute Shannon entropy per byte:

| Content | Entropy | Zero % |
|---|---|---|
| Encrypted | **8.00** everywhere | ~0.4% |
| Never-written region | 0.00 | 100% |
| Text | ~4.4 | varies |
| Already-compressed media | ~7.9 | low |

Validated against `/dev/urandom` (8.00), `/dev/zero` (0.00) and plain text (4.44) before
trusting it. A volume reading 8.00 at *every* allocated sample is encrypted whatever its
header claims.

---

## 2. BitLocker is often not the wall it looks like ⚑

**The single most valuable lesson here.**

"BitLocker encrypted" is widely treated as "produce the recovery key or the data is gone".
But BitLocker can be **suspended**, in which case a **clear key** protector sits on the
disk and the volume master key is stored unencrypted. Such a volume unlocks with no
password, no recovery key, and no Microsoft account.

This is not an edge case. Windows 11 device encryption turns itself on during setup and
stays suspended with a clear key until the user signs in with a Microsoft account. A
machine that never got signed in sits like that for its entire life. In this case the
volume's **only** protector was a clear key.

**Always enumerate the key protectors before telling anyone their data is unrecoverable.**
`probe-50-bitlocker.py` does it, and cross-checks all three redundant metadata copies.

Also worth extracting even when it *is* locked: the **recovery key identifier**. That GUID
is what the owner matches against the list at `account.microsoft.com/devices/recoverykey`,
turning "go find your key" into "find the key whose ID starts with `A1B2C3D4`".

---

## 3. macOS 26 removed the NTFS mount helper

Verified:

```bash
ls /sbin/mount_* | grep ntfs        # no output
plutil -p /System/Library/Filesystems/ntfs.fs/Contents/Info.plist | grep FSImplementation
#   "FSImplementation" => [ 0 => "UserFS" ]
```

The bundle ships only `ntfs.util` (a probe helper) and `BootCampFormatter`. **There is no
NTFS mount helper to invoke.** Any `mount -t ntfs -o ro` fallback — including the one this
repo originally shipped — is dead code, and a dirty NTFS volume cannot be force-mounted at
all. Reading the filesystem directly is the only route, which is fine, and safer.

---

## 4. Two macOS readings that look like damage and are not

- **`MS-DOS (FAT)` with `Volume Total Space: 0 B` and no volume name.** `msdos.fs`,
  `exfat.fs` and `ntfs.fs` all claim the Microsoft Basic Data GUID
  (`EBD0A0A2-B9E5-4433-87C0-68B6B72699C7`) at the same `FSProbeOrder` (2000). When none
  match, macOS shows a fallback personality. That is a **failed probe**, not a FAT volume.
- **Windows Recovery partition = "no file system".** Nothing in
  `/System/Library/Filesystems/` claims GUID `DE94BBA4-06D6-4DA6-AD24-16F0BB3AB8A5`, so
  macOS cannot identify a WinRE partition on *any* drive. Normal.

Nearly filed both as evidence of corruption. Checking `Info.plist` took two minutes and
prevented a wrong diagnosis.

---

## 5. Benchmark the real path, not a proxy

A synthetic AES-XTS benchmark using `cryptography` measured **125 MB/s** → "about 30
minutes for 237 GB". The actual `dissect.fve` read path measured **4 MB/s** → **~17 hours**.

The gap: `dissect.fve` implements XTS by looping over 16-byte blocks in pure Python, and
its backend (`pycryptodome`) exposes no XTS mode at all.

Isolating the bottleneck properly mattered:

| Layer | Throughput |
|---|---|
| Raw device read (`os.read`, no crypto) | **421 MB/s** |
| dissect.fve pure-Python XTS | 4–7 MB/s |
| Patched to OpenSSL XTS | **87–92 MB/s** |

The device was never the problem. **Never quote a duration from a synthetic benchmark.**

---

## 6. Patch the hot loop, keep the library's logic

The fix was to override only `XtsMode._crypt_sector` to call OpenSSL, leaving every
structural part of `dissect.fve` — run lists, the relocated NTFS volume header, plain and
sparse region handling — untouched. Those are the subtle parts; reimplementing them would
have risked silent corruption.

**Then verify.** SHA-256 of 4 MB at four offsets across the volume, patched vs unpatched:
identical. A crypto shortcut you have not diffed against the reference is a liability.
`fastcrypto.verify_against_reference()` exists so this is one call.

---

## 7. Don't decrypt a volume to recover a file

The plan was a 237 GB decrypted image (~46 min, 237 GB of disk) so the volume could be
mounted and browsed. Once the target files were identified, targeted extraction moved
**1 GB in about 11 seconds**.

Full-image decryption is for browsing an unknown volume. If you know what you want,
extract it.

---

## 8. Finding a file: the file is not where or what you expect

Four dashcam clips were requested. How each was actually found:

- **Three** sat in `Users\<user>\Videos\`.
- **One existed only inside a `.zip`.** No loose `.MP4` anywhere on the volume. An
  extension-only search would have reported it permanently lost. **Always look inside
  archives.**
- **A fourth 266 MB MP4 was in the Recycle Bin.** Its `$I` record named the original path
  and deletion time; SHA-256 proved it byte-identical to a file still present, so it was a
  duplicate, not a fifth clip. **`$I`/`$R` pairs are free evidence.**
- **`.lnk` shortcuts gave the trail.** Four 845-byte desktop shortcuts stored full target
  paths (`D:\...MP4`) and a drive-type flag saying **REMOVABLE**. That first looked like a
  dead end — "the files are on an SD card we don't have" — but it supplied exact filenames
  to search for, which then turned up on C:.

Takeaways: search by **basename**, look **inside archives**, check the **Recycle Bin**,
read **`.lnk` targets**, and use **timestamps** to narrow. Cross-check with a second
method before reporting "not found".

---

## 9. NTFS 8.3 short names silently double everything

`listdir()` and `full_path()` return **both** the long name and the 8.3 short name for the
same record — `Rockstar Games` *and* `ROCKST~1` — and nested short names multiply
combinatorially down a path. One file appeared **eight times** in a listing.

Left unhandled this inflates file counts and sizes, and makes an extractor copy the same
bytes repeatedly. Deduplicate on the **MFT segment number**, which is the record's real
identity. `ntfsread.dedupe_records()`.

---

## 10. Raw devices demand aligned I/O

`/dev/rdiskN` rejects unaligned seeks and partial-sector reads with `EINVAL` (errno 22).
Everything must be widened to sector boundaries and sliced back down — `AlignedReader`.

Two related gotchas:
- Block-cache the reads. NTFS metadata walks hit the same MFT sectors constantly, and on
  an encrypted volume every miss costs a decrypt too.
- `dissect` reads `.size` as an **attribute**, not a method. Exposing `size()` as a method
  produces `TypeError: unsupported operand type(s) for -: 'method' and 'int'`.

---

## 11. sudo in an agent session

Raw-device reads need root, and `sudo` cannot prompt without a TTY:

```
sudo: a terminal is required to read the password
```

Neither `sudo -v` nor `sudo -S` helps from a non-interactive harness, and sudo 1.9.17
scopes its credential cache **per-TTY**, so priming it in another window does not carry
over. Never ask the user to paste a password into a transcript.

The clean fix — Touch ID:

```bash
echo 'auth sufficient pam_tid.so' | sudo tee /etc/pam.d/sudo_local
```

PAM satisfies the auth before sudo ever tries to read from a terminal, so non-TTY `sudo`
works. This single change unblocked the entire recovery.

---

## 12. dislocker is a dead end on Apple Silicon

The standard BitLocker-on-Unix tool. On Homebrew ARM macOS:

```
Error: dislocker: no bottle available!
Error: libfuse: no bottle available!
```

It depends on `libfuse`, which has no macOS build, and the practical alternative —
**macFUSE** — is a kernel extension that requires reducing an Apple Silicon Mac's boot
security. That is not a reasonable trade for a file copy.

`dissect.fve` + `dissect.ntfs` + an OpenSSL patch needs no kernel extension, no reduced
security, and ran faster. **Don't spend time on dislocker on a Mac.**

---

# Antipatterns

Real defects found in this repo's *own* first-draft tooling. They are worth naming because
each is easy to write and hard to notice.

### A. Reporting health on an unmapped exit code ⚑
`survey.sh` interpreted only exit 20 and 10, so probe-30's exit 1 ("could not identify the
filesystem") fell through to the defaults and the generated diagnosis read
**"Plain NTFS — Phase 1: mount read-only and copy"**. The report — the actual deliverable —
would have asserted the opposite of the truth and sent the operator into a mount that
cannot succeed.

**Fail closed. Map every code and always add a catch-all that renders as `UNKNOWN`.**
A diagnostic that reports "healthy" when it means "I don't know" is worse than no
diagnostic.

### B. A signature that matches healthy hardware
`MSWIN4.1` was classified as "BitLocker To Go". It is the OEM ID Windows stamps on
ordinary FAT32 volumes — **including the EFI partition of every Windows disk**. The probe
would have flagged the EFI partition of a perfectly healthy drive, set `FOUND_BITLOCKER`,
and reported the whole disk as encrypted. Test signatures against the *healthy* case too.

### C. Treating a bitmask as a boolean
`if sudo smartctl -a ...; then` — smartctl returns a bitmask: bit 1 = device open failed,
but **bit 3 = the disk is failing**. A successful read of a dying drive returns non-zero,
so the script concluded "this bridge doesn't support SMART" and discarded the result —
wrong in precisely the case where it matters. Check `RC & 3`, not `RC`.

### D. `grep -c` with `|| echo 0`
`grep -c` prints `0` **and** exits 1 when nothing matches, so `grep -icE ... || echo 0`
yields `"0\n0"`. That then fails `[ "$STUBS" -gt 0 ]` with
`integer expression expected`. Any category with zero files crashed the probe.

### E. `set -euo pipefail` + a grep that legitimately finds nothing
Inside a function, a non-matching grep makes the pipeline return non-zero, the function
return non-zero, and `set -e` kill the script **from inside a command substitution**.
"No matches" is a normal result, not an error.

### F. A guard that exits, called as if it returned
```bash
assert_mounted_readonly "$VOL" || true    # the || true is dead code
```
The function calls `exit 1` internally, so `|| true` is never reached. **A guard cannot be
made advisory by its caller** — it has to return a status. Hence the `assert_` (hard) and
`warn_if_` (soft) pair.

### G. A blocklist that only sees commands routed through it
`refuse_destructive` screened commands passed to the `cmd` wrapper, but the riskiest calls
— `sudo dd`, `sudo mount`, `rsync` — were invoked directly and never screened. A guard is
only as good as its call sites; claiming "enforced in code" was half true.

### H. Substring matching a safety-critical value
`*"of=/dev/null"*` also accepts `of=/dev/null.img` — a real file, a real overwrite.
Word-boundary match safety-critical tokens.

### I. A destination guard narrower than its name
`assert_not_source` refused only `/Volumes/*`, while the repo's own mount fallback put the
source at `$HOME/recovered-mount` — a path the guard did not cover. It now checks the live
mount table.

---

## Procedure that worked

1. **Non-destructive diagnosis first**, and interpret cautiously — most "damage" was not.
2. **Verify environment assumptions against the actual machine.** `Info.plist`, `ls
   /sbin/mount_*`. Two minutes each, several wrong conclusions avoided.
3. **Isolate the bottleneck before optimising.** Device 421 MB/s vs crypto 4 MB/s.
4. **Keep the trusted library's logic; replace only the hot path — then diff the output.**
5. **List before extracting.** Cheap, and it keeps the owner's scope decision informed.
6. **Verify recovered files three ways**: size vs MFT, magic bytes, and actually open one.
7. **Prefer targeted extraction** over whole-volume operations.
8. **Never mount, never repair.** The whole job completed with the source `O_RDONLY`.
