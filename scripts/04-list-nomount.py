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
import fnmatch
import os
import re
import struct
import sys
import datetime

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
from ntfsread import open_volume, human, walk, timestamps, dedupe_records  # noqa: E402

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
    pat = pattern if any(c in pattern for c in "*?[") else f"*{pattern}*"
    rx = re.compile(fnmatch.translate(pat), re.I)
    since_dt = None
    if since:
        parts = [int(x) for x in since.split("-")]
        since_dt = datetime.datetime(parts[0], parts[1] if len(parts) > 1 else 1,
                                     parts[2] if len(parts) > 2 else 1,
                                     tzinfo=datetime.timezone.utc)

    print(f"\nSearching the whole MFT for {pat}"
          + (f", modified since {since}" if since else "") + " ...\n")
    hits, n = [], 0
    for rec in ntfs.mft.segments():
        n += 1
        if n % 100000 == 0:
            print(f"  ... {n:,} records", file=sys.stderr, flush=True)
        try:
            if rec.is_dir():
                continue
            name = rec.filename
            if not name or not rx.match(name):
                continue
            if since_dt:
                mod, cre = timestamps(rec)
                if not any(t and t >= since_dt for t in (mod, cre)):
                    continue
            hits.append((rec.full_path(), rec))
        except Exception:
            continue
    hits = dedupe_records(hits)
    print(f"Scanned {n:,} MFT records -- {len(hits)} matches\n")
    for p, r in sorted(hits, key=lambda x: -(x[1].size() or 0))[:limit]:
        show(p.replace("\\", "/"), r)
    if not hits:
        print("  (nothing matched)")
        print("\n  Remember: the file may not have the extension you expect.")
        print("  Search by basename, and check archives -- see docs/LESSONS.md.")


def cmd_recycle(ntfs):
    """$I records hold the original path and deletion time; $R holds the data."""
    print("\nRecycle Bin contents\n")
    try:
        rb = ntfs.mft.get("$Recycle.Bin")
    except Exception:
        print("  (no $Recycle.Bin)")
        return
    for sid, ie in rb.listdir().items():
        if sid in (".", ".."):
            continue
        try:
            sd = ie.dereference()
            if not sd.is_dir():
                continue
        except Exception:
            continue
        print(f"  {sid}")
        for name, ie2 in sorted(sd.listdir().items()):
            if not name.upper().startswith("$I"):
                continue
            try:
                d = ie2.dereference().open().read()
                ver = struct.unpack_from("<Q", d, 0)[0]
                size = struct.unpack_from("<Q", d, 8)[0]
                ftv = struct.unpack_from("<Q", d, 16)[0]
                when = datetime.datetime(1601, 1, 1) + datetime.timedelta(
                    microseconds=ftv // 10)
                if ver >= 2:
                    nlen = struct.unpack_from("<I", d, 24)[0]
                    orig = d[28:28 + nlen * 2].decode("utf-16-le").rstrip("\x00")
                else:
                    orig = d[24:24 + 520].decode("utf-16-le").rstrip("\x00")
                print(f"      {human(size):>10}  deleted {when:%Y-%m-%d %H:%M}  {orig}")
                print(f"                  data file: {name.replace('$I', '$R', 1)}")
            except Exception as e:
                print(f"      {name}: unreadable ({e})")


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
