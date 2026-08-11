# Transfer to iPhone

## Destination phone

| Field | Value |
|---|---|
| Model | |
| Port | USB-C (15+) / Lightning (14 or older) |
| Free space before | |
| Owner | someone else — do not assume Apple ID access |

## Pre-transfer checks

- [ ] `03-verify.sh` passed — no zero-byte files, no placeholders, sampled files open
- [ ] Opened several files by hand (Preview for photos, Pages/Word for a document)
- [ ] iPhone free space confirmed ≥ selection size
- [ ] Selection curated in `~/Recovered` — not sending the whole drive

## Method

**Default: AirDrop.** No cable, no adapter, no Apple ID access needed.

1. iPhone → Control Center → hold connectivity block → AirDrop → **Everyone for 10 Minutes**
2. Mac → select in Finder → right-click → Share → AirDrop → pick the phone
3. Photos/videos land in **Photos**; documents land in **Files**

Send in batches (~100–200 photos or a few GB). Zip documents into one archive — far more
reliable than hundreds of individual files, and the Files app unzips with a tap.

Fallbacks: LocalSend (`brew install --cask localsend`) for large batches; USB-C flash
drive formatted exFAT if the phone is an iPhone 15+; a shared cloud link otherwise.

## Batches sent

| # | Contents | Size | Method | Sent | Confirmed on phone |
|---|---|---|---|---|---|
| 1 | | | | | |
| 2 | | | | | |

## Sign-off

- [ ] All batches confirmed present and opening **on the phone**, by the owner
- [ ] Owner agrees nothing is missing
- [ ] Only now is the M.2 considered free to erase — **and that is the owner's call, not
      yours.** Hand the drive back rather than erasing it.

> Until every box above is ticked, the M.2 is the only copy. Do not erase it.

## Handoff and cleanup

This is someone else's personal data sitting on your Mac. Once they confirm they have
everything, remove it — retaining it indefinitely is not a neutral act.

Keep `~/Recovered` only as long as the owner wants a safety net, and agree that window
explicitly (e.g. "I'll keep a copy for a week in case something's missing").

- [ ] Owner confirmed they have everything they need
- [ ] Retention window agreed: ______________
- [ ] Staging copy deleted after that window
- [ ] `logs/` cleared — the file index is a list of their filenames

Deletion is deliberately **not** scripted. Run it yourself, once, having read the path:

```bash
ls ~/Recovered                 # look at what you are about to delete
rm -rf ~/Recovered/<username>  # only after the checklist above is complete
rm -f "$REPO"/logs/fileindex-*.txt
```

- [ ] Drive physically returned to the owner
