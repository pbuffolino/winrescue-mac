#!/usr/bin/env python3
"""List files on a Windows volume WITHOUT mounting it.

Works on volumes macOS cannot mount at all: BitLocker (with a clear key or a
supplied recovery key), and NTFS left dirty by Windows Fast Startup, which
macOS 26 can no longer force-mount because /sbin/mount_ntfs is gone.

READ-ONLY, metadata only. Reads names, sizes and timestamps from the MFT. It
does not open the contents of any file -- see 05-extract-nomount.py for that.

Usage:
  04-list-nomount.py /dev/rdisk4s3                        # profiles + overview
  04-list-nomount.py /dev/rdisk4s3 --path Users/Sam/Videos
  04-list-nomount.py /dev/rdisk4s3 --find '*.mp4'         # whole volume
  04-list-nomount.py /dev/rdisk4s3 --find dashcam --since 2025-02
  04-list-nomount.py /dev/rdisk4s3 --recycle-bin          # deleted files
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
from ntfsread import (open_volume, human, walk, timestamps,  # noqa: E402
                      dedupe_records, find_records, recycle_bin_items)

# AppData and Windows dwarf everything and are almost never what is wanted.
NOISE = ("appdata", "windows", "program files", "program files (x86)",
         "programdata", "$recycle.bin", "system volume information")


def show(path, rec, indent="  "):
    size = rec.size() or 0
    mod, _ = timestamps(rec)
    try:
        cloud = rec.is_cloud_file()
    except Exception:
        cloud = False
    stub = "  [CLOUD STUB - no data on disk]" if cloud else ""
    when = f"  {mod:%Y-%m-%d %H:%M}" if mod else ""
    print(f"{indent}{human(size):>10}{when}  {path}{stub}")


def cmd_overview(ntfs):
    print("\nTop level of the volume:")
    root = ntfs.mft.get("/")
    for name, ie in sorted(root.listdir().items()):
        if name in (".", "..") or name.startswith("$"):
            continue
        try:
            r = ie.dereference()
        except Exception:
            continue
        print(f"    {'DIR ' if r.is_dir() else 'FILE'}  {name}")

    print("\nUser profiles:")
    try:
        users = ntfs.mft.get("Users")
    except Exception:
        print("    (no Users directory -- is this the Windows system volume?)")
        return
    for name, ie in sorted(users.listdir().items()):
        if name in (".", "..") or "~" in name:
            continue
        try:
            if not ie.dereference().is_dir():
                continue
        except Exception:
            continue
        if name.lower() in ("public", "default", "default user", "all users"):
            continue
        print(f"    {name}")
        for folder in ("Desktop", "Documents", "Pictures", "Videos",
                       "Downloads", "Music", "OneDrive"):
            try:
                rec = ntfs.mft.get(f"Users/{name}/{folder}")
            except Exception:
                continue
            files = dedupe_records(list(walk(rec, "")))
            total = sum((r.size() or 0) for _, r in files)
            stubs = 0
            for _, r in files:
                try:
                    stubs += 1 if r.is_cloud_file() else 0
                except Exception:
                    pass
            extra = f"   ({stubs} cloud stubs)" if stubs else ""
            print(f"        {folder:<12} {len(files):>7,} files  "
                  f"{human(total):>10}{extra}")


def cmd_path(ntfs, path):
    rec = ntfs.mft.get(path)
    if rec.is_dir():
        entries = dedupe_records(list(walk(rec, path)))
        print(f"\n{path}  --  {len(entries)} files")
        for p, r in sorted(entries, key=lambda x: -(x[1].size() or 0)):
            show(p, r)
        print(f"\n  total {human(sum((r.size() or 0) for _, r in entries))}")
    else:
        show(path, rec)


def cmd_find(ntfs, pattern, since=None, limit=500):
    print(f"\nSearching the whole MFT for {pattern}"
          + (f", modified since {since}" if since else "") + " ...\n")

    def progress(n):
        print(f"  ... {n:,} records", file=sys.stderr, flush=True)

    hits, scanned = find_records(ntfs, pattern, since, progress)
    print(f"Scanned {scanned:,} MFT records -- {len(hits)} matches\n")
    for p, r in sorted(hits, key=lambda x: -(x[1].size() or 0))[:limit]:
        show(p.replace("\\", "/"), r)
    if not hits:
        print("  (nothing matched)")
        print("\n  Remember: the file may not have the extension you expect.")
        print("  Search by basename, and check archives -- see docs/LESSONS.md.")


def cmd_recycle(ntfs):
    """$I holds the original path and deletion time; $R holds the data."""
    print("\nRecycle Bin contents\n")
    found = 0
    for orig, when, rrec, rname in recycle_bin_items(ntfs):
        found += 1
        print(f"  {human(rrec.size() or 0):>10}  deleted {when:%Y-%m-%d %H:%M}  {orig}")
        print(f"              data file: {rname}")
    if not found:
        print("  (nothing recoverable in the Recycle Bin)")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("device")
    ap.add_argument("--path")
    ap.add_argument("--find")
    ap.add_argument("--since", help="YYYY or YYYY-MM or YYYY-MM-DD")
    ap.add_argument("--recycle-bin", action="store_true")
    ap.add_argument("--size", type=int, help="override volume size in bytes")
    args = ap.parse_args()

    ntfs, info = open_volume(args.device, size=args.size)

    if args.path:
        cmd_path(ntfs, args.path.replace("\\", "/"))
    elif args.find:
        cmd_find(ntfs, args.find, args.since)
    elif args.recycle_bin:
        cmd_recycle(ntfs)
    else:
        cmd_overview(ntfs)


if __name__ == "__main__":
    main()
