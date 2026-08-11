#!/usr/bin/env python3
"""Extract files off a Windows volume WITHOUT mounting it.

Copies matching files to a destination under $HOME, verifying each one as it
lands. Handles BitLocker transparently, reads deleted files out of the Recycle
Bin, and looks inside archives -- because a file's data is not always where its
name says it is.

SAFETY
  - The source is opened O_RDONLY. There is no write path to it.
  - The destination is refused if it is under /Volumes (i.e. any mounted
    volume, which could be the source itself).

VERIFICATION -- every extracted file gets:
  - a SHA-256, printed so copies can be compared
  - a magic-byte check against its extension ("exists" != "opens")
  - a size cross-check against the MFT record

Usage:
  05-extract-nomount.py /dev/rdisk4s3 --find '*.mp4' ~/Recovered
  05-extract-nomount.py /dev/rdisk4s3 --path Users/Sam/Videos ~/Recovered
  05-extract-nomount.py /dev/rdisk4s3 --find holiday --archives ~/Recovered
  05-extract-nomount.py /dev/rdisk4s3 --recycle-bin ~/Recovered
"""
import argparse
import hashlib
import os
import sys
import time
import zipfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
from ntfsread import (open_volume, human, walk,  # noqa: E402
                      dedupe_records, find_records, recycle_bin_items)

# offset -> expected magic. "A file that exists is not a file that opens."
MAGIC = {
    ".mp4": (4, b"ftyp"), ".mov": (4, b"ftyp"), ".m4v": (4, b"ftyp"),
    ".jpg": (0, b"\xff\xd8\xff"), ".jpeg": (0, b"\xff\xd8\xff"),
    ".png": (0, b"\x89PNG"), ".gif": (0, b"GIF8"),
    ".pdf": (0, b"%PDF"), ".zip": (0, b"PK"), ".docx": (0, b"PK"),
    ".xlsx": (0, b"PK"), ".pptx": (0, b"PK"),
    ".avi": (0, b"RIFF"), ".wav": (0, b"RIFF"),
    ".mkv": (0, b"\x1a\x45\xdf\xa3"), ".heic": (4, b"ftyp"),
}
ARCHIVE_EXT = (".zip",)


def check_magic(path):
    ext = os.path.splitext(path)[1].lower()
    want = MAGIC.get(ext)
    if not want:
        return None
    off, sig = want
    with open(path, "rb") as f:
        f.seek(off)
        return f.read(len(sig)) == sig


def safe_dest(dest):
    dest = os.path.abspath(os.path.expanduser(dest))
    if dest.startswith("/Volumes/"):
        sys.exit(f"REFUSING: '{dest}' is on a mounted volume, which may be the\n"
                 "source drive. Choose a destination under $HOME.")
    os.makedirs(dest, exist_ok=True)
    return dest


def extract_one(rec, outpath, expect_size=None):
    os.makedirs(os.path.dirname(outpath), exist_ok=True)
    h = hashlib.sha256()
    written, t0 = 0, time.time()
    with rec.open() as src, open(outpath, "wb") as dst:
        while True:
            chunk = src.read(8 * 1024 * 1024)
            if not chunk:
                break
            dst.write(chunk)
            h.update(chunk)
            written += len(chunk)
    el = max(time.time() - t0, 1e-3)
    ok_magic = check_magic(outpath)
    size_ok = (expect_size is None) or (written == expect_size)

    status = []
    if ok_magic is True:
        status.append("magic OK")
    elif ok_magic is False:
        status.append("MAGIC MISMATCH")
    if not size_ok:
        status.append(f"SIZE MISMATCH (mft said {expect_size})")
    if not status:
        status.append("copied")

    print(f"    {human(written):>10}  {written/1048576/el:>5.0f} MB/s  "
          f"{', '.join(status):<22} {os.path.basename(outpath)}")
    print(f"                sha256 {h.hexdigest()}")
    return written, (ok_magic is not False) and size_ok, h.hexdigest()


def gather(ntfs, args):
    """Return [(suggested_relative_name, record)]."""
    out = []
    if args.path:
        p = args.path.replace("\\", "/")
        rec = ntfs.mft.get(p)
        if rec.is_dir():
            out = [(sub, r) for sub, r in dedupe_records(list(walk(rec, "")))]
        else:
            out = [(os.path.basename(p), rec)]

    elif args.find:
        def progress(n):
            print(f"  ... {n:,} MFT records", file=sys.stderr, flush=True)

        hits, scanned = find_records(ntfs, args.find, args.since, progress)
        print(f"  scanned {scanned:,} MFT records")
        out = [(p.replace("\\", "/").split("/")[-1], r) for p, r in hits]
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("device")
    ap.add_argument("dest")
    ap.add_argument("--path")
    ap.add_argument("--find")
    ap.add_argument("--since")
    ap.add_argument("--recycle-bin", action="store_true")
    ap.add_argument("--archives", action="store_true",
                    help="also unpack matching files found inside .zip archives")
    ap.add_argument("--size", type=int)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    dest = safe_dest(args.dest)
    ntfs, info = open_volume(args.device, size=args.size)
    print(f"Destination: {dest}\n")

    targets = gather(ntfs, args)

    if args.recycle_bin:
        for orig, when, rrec, rname in recycle_bin_items(ntfs):
            base = orig.replace("\\", "/").split("/")[-1]
            targets.append((f"RecycleBin/{when:%Y%m%d}-{base}", rrec))

    if not targets:
        print("Nothing matched.")
        return

    print(f"{len(targets)} file(s) to extract"
          + (" (dry run)" if args.dry_run else "") + "\n")
    if args.dry_run:
        for name, rec in targets:
            print(f"    {human(rec.size() or 0):>10}  {name}")
        return

    total, okc, digests = 0, 0, {}
    for name, rec in sorted(targets, key=lambda x: x[0]):
        outp = os.path.join(dest, name)
        try:
            n, ok, dg = extract_one(rec, outp, rec.size())
        except Exception as e:
            print(f"    FAILED {name}: {e}")
            continue
        total += n
        okc += 1 if ok else 0
        digests.setdefault(dg, []).append(name)

        if args.archives and name.lower().endswith(ARCHIVE_EXT):
            try:
                with zipfile.ZipFile(outp) as z:
                    bad = z.testzip()
                    print(f"                archive: "
                          f"{'CRC FAILURE at ' + bad if bad else 'all CRCs OK'}")
                    for i in z.infolist():
                        if i.is_dir():
                            continue
                        sub = os.path.join(dest, os.path.basename(i.filename))
                        with z.open(i) as s, open(sub, "wb") as d:
                            while True:
                                c = s.read(8 * 1024 * 1024)
                                if not c:
                                    break
                                d.write(c)
                        m = check_magic(sub)
                        print(f"                unpacked -> {os.path.basename(sub)}"
                              f"  {human(os.path.getsize(sub))}"
                              f"  {'magic OK' if m is not False else 'MAGIC MISMATCH'}")
            except Exception as e:
                print(f"                archive unreadable: {e}")

    print("\n" + "=" * 70)
    print(f"Extracted {len(targets)} file(s), {human(total)}, "
          f"{okc}/{len(targets)} passed verification")
    dupes = {d: n for d, n in digests.items() if len(n) > 1}
    if dupes:
        print("\nIdentical content (same SHA-256) -- safe to keep just one:")
        for d, names in dupes.items():
            print(f"  {d[:16]}...  {', '.join(names)}")
    print(f"\nLocation: {dest}")
    print("Open a few by hand before telling anyone the recovery succeeded.")


if __name__ == "__main__":
    main()
