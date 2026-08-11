# Should you use this toolset at all?

**Read this before step 1.** The first question in any recovery is not "how do I read this
drive" — it is "which machine should I plug it into". Getting that wrong costs hours, or
costs the data.

This toolset is deliberately the **safest** option, not the fastest. Sometimes that trade
is obviously correct. Sometimes it is obviously wrong. Here is how to tell.

---

## The 60-second decision

Answer in order. The first "yes" wins.

| # | Question | If yes |
|---|---|---|
| 1 | Is the drive **failing** — clicking, read errors, SMART warnings, timeouts? | **Use this toolset (or a Linux live USB).** Image with `ddrescue` first. Do **not** plug it into Windows. |
| 2 | Is it **someone else's data** you're custodian of, or does provenance matter (legal, dispute, insurance)? | **Use this toolset.** Read-only is structural here and provable. |
| 3 | Has anyone already run **chkdsk / First Aid / a repair tool** on it? | **Use this toolset**, and image it first. Further writes compound the damage. |
| 4 | Is the volume **BitLocker-locked with no clear key**, and you don't have the recovery key? | **Platform is irrelevant.** Nothing reads it until the owner produces the key. |
| 5 | None of the above — healthy drive, your own data, you just want the files, and a Windows PC is available? | **Use Windows.** It will be faster. Follow the safety steps below. |

If you have no Windows machine and none of 1–4 apply, this toolset is still a perfectly good
answer — it just isn't the *only* one.

---

## What each platform actually costs you

| | **Windows** | **macOS + this toolset** | **Linux live USB** |
|---|---|---|---|
| Plain NTFS | mounts, read-write | read-only, or no-mount path | mounts, `-o ro` trivially |
| Dirty NTFS (Fast Startup) | mounts, **offers to "fix"** | cannot mount → no-mount path | mounts read-only fine |
| **BitLocker, clear key** | **unlocks automatically** | `probe-50` → no-mount path | `dislocker --clearkey` |
| BitLocker, locked | needs the key | needs the key | needs the key |
| Default mount mode | **read-write** | read-only (no NTFS write driver exists) | your choice, explicit |
| Writes to the volume unbidden | thumbnails, `System Volume Information`, `$RECYCLE.BIN`, indexing | **none** — `O_RDONLY` | none if mounted `ro` |
| Cost of guaranteeing zero writes | needs deliberate setup | **free — structural** | one flag |
| Searching for a file | Everything / Windows Search, instant | whole-MFT scan, ~1–3 min | `find` / `grep` |
| Setup before you start | none | venv + Touch ID, ~5 min once | boot a USB, ~10 min |

The pattern: **Windows is easier to use and harder to use safely. macOS is the reverse.**
Those are the same fact viewed from two sides — macOS has no NTFS write driver, which is
exactly why "never write to the source" costs nothing to guarantee here.

---

## Realistic time investment

Measured against the job this toolset was built from (256 GB SSD, BitLocker suspended with
a clear key, four specific video files wanted).

| Scenario | Time | Notes |
|---|---|---|
| Windows, healthy drive, clear key or unencrypted | **10–20 min** | Plug in, search, copy. Most of it is the copy. |
| This toolset, path already known | **20–40 min** | Preflight, survey, list, extract, verify. |
| This toolset, first time / unknown fault | **1–3 hrs** | Diagnosis dominates. This session took ~1 hr. |
| Linux live USB, BitLocker with clear key | **30–45 min** | Mostly booting and installing `dislocker`. |
| Failing drive, any platform | **hours to days** | `ddrescue` sets the pace, not you. |
| BitLocker locked, no key | **blocked indefinitely** | Waiting on the owner, not on tooling. |

Two things dominate the total, and neither is the copy:

1. **Diagnosis** — "why won't it mount" is most of the work. Windows often skips this
   question entirely by simply mounting.
2. **The drive's own read speed** — check the USB link. A 480 Mb/s negotiation (USB 2.0
   fallback) turns a 20-minute copy into 3 hours. `probe-10` reports it.

---

## If you choose Windows, do these first

Windows will happily write to the drive before you've clicked anything. Spend two minutes
preventing it.

1. **Stop auto-mounting**, then attach the drive:
   ```
   diskpart
     automount disable
     list disk
     select disk N          ← confirm carefully; wrong disk = wrong outcome
     attributes disk set readonly
   ```
2. **Decline the repair prompt.** Windows shows *"There's a problem with this drive. Scan
   the drive now to fix it"* on exactly the dirty volumes recovery involves. **Always
   choose "Continue without scanning."** One wrong click writes to the only copy.
3. **Do not run `chkdsk`.** Not "just to check" — it writes.
4. **Check BitLocker without changing it:** `manage-bde -status D:`
   Do **not** run `manage-bde -resume`. On a suspended volume that re-protects the master
   key and **destroys the clear key**, converting a drive that opens freely into one that
   needs a recovery key nobody has.
5. **Turn off indexing** for the drive, and don't browse folders full of media any more
   than you need to — thumbnail generation writes.
6. **A hardware write blocker** beats all of the above if you have one, and is the only
   option that is genuinely enforced rather than requested.

Undo afterwards: `attributes disk clear readonly`, `automount enable`.

---

## When this toolset is clearly the right call

- **Failing hardware.** Windows' background activity — indexing, Shadow Copy, thumbnails —
  is the last thing a dying drive needs. Image once, work from the image.
- **Custodial recovery.** Someone else's data, recovered on their behalf. Read-only is
  provable here (`O_RDONLY`), not merely intended.
- **Evidence or provenance matters.** Disputes, insurance, anything where "did you modify
  it?" could be asked. This toolset can answer that structurally.
- **Someone already ran a repair tool.** Stop writing immediately; image and work from the
  copy.
- **You only have a Mac.** Which is the common case, and the reason this exists.
- **You want to know *why* before you act.** The probes explain the failure rather than
  papering over it — useful when the same fault will recur on the next drive.

## When it is overkill

- Healthy drive, your own data, Windows PC on the desk → use Windows.
- You need one small file and the drive mounts fine anywhere → just copy it.
- The volume is BitLocker-locked with no clear key → no tool helps until the owner produces
  the key. Go and ask them; that is the whole task.

---

## The one thing that transfers to every platform

**Check for a BitLocker clear key before telling anyone their data is gone.**

Windows does this silently by unlocking. macOS gives you nothing, which is why
`probe-50-bitlocker.py` exists. Either way the finding is the same and it is frequently the
difference between "unrecoverable" and "recovered this afternoon" — a suspended volume
carries its master key in the clear, and Windows 11 device encryption sits suspended by
default until the user signs in with a Microsoft account.

Never report a BitLocker volume as unrecoverable without enumerating its key protectors.
