# Inventory and handoff

Per-job worksheet. Copy it, fill it in as you go, and keep it with `RECOVERY-LOG.md`.

Two jobs in one file: **record what was found**, then **get it back to the owner and stop
holding their data**. The second half matters more than it looks — the recovery is not
finished when the files are copied, it is finished when the owner has them and your copy
is gone.

> **Redact before sharing.** Filled in, this file contains someone's usernames, folder
> names and drive identifiers. Keep it local, and scrub it before it goes anywhere.

---

## Source

| Field | Value |
|---|---|
| Owner | |
| Scope agreed with owner | |
| Disk identifier | `disk?` |
| Model / capacity | |
| USB link speed | (480 Mb/s = USB 2.0 fallback — reseat before starting) |
| Partition scheme | |
| Target partition | `disk?s?` |
| Filesystem | NTFS / BitLocker / other |
| BitLocker protectors | clear key / recovery password / TPM / n\a |
| Windows username | |
| Read via | mount / no-mount / image |

## Health (probe 20)

| Field | Value |
|---|---|
| SMART available via bridge | yes / no (bridges often refuse — not a fault) |
| Overall health | |
| Reallocated / pending sectors | |
| Media & data integrity errors | |
| Flash wear (% used) | |
| Surface read test | ?/64 passed |

## Content

| Category | Files | Size |
|---|---|---|
| Photos | | |
| Videos | | |
| Documents | | |
| Audio | | |
| **Total** | | |

### Cloud-placeholder check

Files that exist but are ~0 KB are OneDrive stubs: the data is in the cloud, not on the
drive. No local tool can produce it.

| Field | Value |
|---|---|
| Suspected stubs (< 8 KB) | |
| Normal-sized files | |
| OneDrive folder present | yes / no |
| Folder redirection in use | yes / no |
| **Verdict** | real data / cloud stubs / mixed |

### Folder sizes

| Folder | Size |
|---|---|
| Desktop | |
| Documents | |
| Pictures | |
| Videos | |
| Downloads | |
| OneDrive | |

### Selection

Recovered data is usually far larger than the destination can hold. Record what was chosen
and why, so the decision is auditable later.

| Included | Size | Rationale |
|---|---|---|
| | | |

Deliberately **not** transferred:

---

## Before transferring

- [ ] `03-verify.sh` passed — no zero-byte files, no placeholders, sampled files open
- [ ] Opened several files **by hand** (Preview for photos, Word/Pages for a document).
      A file that exists is not a file that opens.
- [ ] Destination free space confirmed ≥ selection size
- [ ] Selection curated in `~/Recovered` — not sending the whole drive

## Method

Pick whatever suits the destination; none of this touches the source drive.

| Destination | Method |
|---|---|
| iPhone / iPad | **AirDrop** — no cable, no adapter, no Apple ID access needed |
| Android / any laptop | **LocalSend** (`brew install --cask localsend`) |
| External drive | Format it **exFAT** so both Windows and macOS can read it |
| Remote owner | Shared cloud link, expiring, password-protected |

Practical notes:

- Send in batches (~100–200 photos, or a few GB) rather than one enormous transfer.
- **Zip documents into a single archive.** Far more reliable than hundreds of individual
  files, and phones unzip with a tap.
- For AirDrop: receiver enables *Everyone for 10 Minutes* in Control Centre. Photos and
  videos land in **Photos**; other files land in **Files**.

## Batches sent

| # | Contents | Size | Method | Sent | Confirmed by owner |
|---|---|---|---|---|---|
| 1 | | | | | |
| 2 | | | | | |

---

## Sign-off

- [ ] Every batch confirmed present **and opening**, on the destination, **by the owner**
- [ ] Owner agrees nothing is missing
- [ ] Drive physically returned to the owner

> Until all three are ticked, the source drive is **the only copy**. Do not erase it.
> Whether it is ever erased is the **owner's** decision, not yours — hand it back rather
> than wiping it.

## Cleanup

This is someone else's personal data sitting on your machine. Once they confirm they have
everything, remove it. Keeping it indefinitely is not a neutral act.

Agree a retention window explicitly — *"I'll keep a copy for a week in case something's
missing"* — rather than letting it linger by default.

- [ ] Owner confirmed they have everything
- [ ] Retention window agreed: ______________
- [ ] Staging copy deleted after that window
- [ ] `logs/` cleared — the file index is a list of their filenames, which is itself
      personal information
- [ ] This worksheet redacted or destroyed

Deletion is deliberately **not** scripted. Run it yourself, once, having read the path:

```bash
ls ~/Recovered                    # look at what you are about to delete
rm -rf ~/Recovered/<username>     # only after the checklist above is complete
rm -f logs/fileindex-*.txt
```
