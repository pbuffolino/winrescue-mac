#!/usr/bin/env python3
"""Read-only access to a Windows volume from macOS -- without mounting it.

This is the heart of the toolset. It opens a raw device (or an image file)
O_RDONLY, transparently unlocks BitLocker if present, and hands back a
dissect.ntfs object you can walk, stat and extract from.

WHY NOT JUST MOUNT IT
---------------------
On macOS 26 you often cannot:
  - BitLocker volumes are not mountable by macOS at all.
  - /sbin/mount_ntfs no longer exists (NTFS moved to UserFS), so there is no
    way to force-mount a dirty NTFS volume left behind by Fast Startup.
Reading the filesystem ourselves sidesteps both, and has the useful property
that it CANNOT write: the file descriptor is opened read-only.

SAFETY
------
os.open(path, os.O_RDONLY) is the only way this module touches the source.
There is no write path, no repair, no fsck, no mount. That is enforced by the
open flags, not by convention.
"""
import datetime
import fnmatch
import io
import os
import re
import struct
from collections import OrderedDict

SECTOR = 512

# NTFS 8.3 short-name marker (FOO~1). Module level: dedupe_records is called
# per directory walk, and re.compile in the body recompiles it every time.
_SHORTNAME = re.compile(r"~\d")


class AlignedReader(io.RawIOBase):
    """Byte-addressable read-only view over a raw macOS device.

    /dev/rdiskN only accepts sector-aligned seeks and whole-sector reads --
    unaligned access fails with EINVAL (errno 22). This widens every read to
    block boundaries and slices the result back down.

    A small LRU of recently-read blocks matters more than it looks: NTFS
    metadata walks hit the same MFT sectors over and over, and on an encrypted
    volume every miss costs a decrypt as well as a read.
    """

    def __init__(self, path, size=None, block=1 << 20, cache=1024):
        self._fd = os.open(path, os.O_RDONLY)   # read-only by construction
        self._pos = 0
        self._block = block
        # OrderedDict, not dict + a list: evicting from a list is pop(0), which
        # is O(n) in the cache size, and this evicts on every miss once warm.
        # move_to_end/popitem are O(1).
        self._cache = OrderedDict()
        self._cachemax = cache
        if size is None:
            size = _device_size(path, self._fd)
        self._size = size
        self.size = size            # dissect reads `.size` as a plain attribute

    def readable(self):
        return True

    def seekable(self):
        return True

    def writable(self):
        return False

    def _blk(self, idx):
        hit = self._cache.get(idx)
        if hit is not None:
            self._cache.move_to_end(idx)
            return hit
        os.lseek(self._fd, idx * self._block, os.SEEK_SET)
        data = os.read(self._fd, self._block)
        self._cache[idx] = data
        if len(self._cache) > self._cachemax:
            self._cache.popitem(last=False)      # evict least recently used
        return data

    def read(self, n=-1):
        if n is None or n < 0:
            n = max(self._size - self._pos, 0)
        out = bytearray()
        while n > 0:
            idx, off = divmod(self._pos, self._block)
            blk = self._blk(idx)
            if not blk:
                break
            chunk = blk[off: off + n]
            if not chunk:
                break
            out += chunk
            self._pos += len(chunk)
            n -= len(chunk)
        return bytes(out)

    def readinto(self, b):
        d = self.read(len(b))
        b[: len(d)] = d
        return len(d)

    def seek(self, pos, whence=io.SEEK_SET):
        if whence == io.SEEK_SET:
            self._pos = pos
        elif whence == io.SEEK_CUR:
            self._pos += pos
        else:
            self._pos = self._size + pos
        return self._pos

    def tell(self):
        return self._pos

    def close(self):
        try:
            os.close(self._fd)
        except Exception:
            pass
        super().close()


def _device_size(path, fd):
    """Size in bytes. diskutil is authoritative for devices; lseek for images."""
    import subprocess
    dev = path.replace("/dev/r", "/dev/")
    try:
        out = subprocess.run(["diskutil", "info", "-plist", dev],
                             capture_output=True, timeout=15).stdout
        if b"<key>Size</key>" in out:
            seg = out.split(b"<key>Size</key>", 1)[1]
            return int(seg.split(b"<integer>", 1)[1].split(b"</integer>", 1)[0])
    except Exception:
        pass
    try:
        n = os.lseek(fd, 0, os.SEEK_END)
        os.lseek(fd, 0, os.SEEK_SET)
        if n:
            return n
    except OSError:
        pass
    raise RuntimeError(f"Cannot determine the size of {path}; pass size= explicitly.")


def human(b):
    b = float(b or 0)
    for u in ["B", "KB", "MB", "GB", "TB"]:
        if b < 1024:
            return f"{b:.0f} {u}" if u == "B" else f"{b:.1f} {u}"
        b /= 1024
    return f"{b:.1f} PB"


def is_bitlocker(fh):
    """BitLocker stamps '-FVE-FS-' at offset 3 of the volume's first sector."""
    pos = fh.tell()
    fh.seek(0)
    head = fh.read(SECTOR)
    fh.seek(pos)
    return head[3:11] == b"-FVE-FS-"


def open_volume(dev, size=None, quiet=False, fast=True):
    """Open a Windows volume read-only and return (ntfs, info).

    Handles both plain NTFS and BitLocker. For BitLocker it will unlock with a
    clear key if one is present -- see docs/LESSONS.md on why you must always
    check for that before telling anyone they need a recovery key.

    Returns a dissect.ntfs.NTFS and a dict describing how it was opened.
    """
    if fast:
        import fastcrypto
        fastcrypto.enable()

    from dissect.ntfs import NTFS

    raw = AlignedReader(dev, size=size)
    info = {"device": dev, "size": raw.size, "bitlocker": False,
            "unlocked_with": None}

    if not is_bitlocker(raw):
        if not quiet:
            print(f"Plain NTFS volume: {dev} ({human(raw.size)})")
        return NTFS(raw), info

    from dissect.fve.bde import BDE

    bde = BDE(raw)
    info.update(bitlocker=True, version=bde.version, encrypted=bde.encrypted)

    if bde.has_clear_key():
        bde.unlock_with_clear_key()
        info["unlocked_with"] = "clear key"
    else:
        key = os.environ.get("BITLOCKER_RECOVERY_KEY")
        pw = os.environ.get("BITLOCKER_PASSWORD")
        if key:
            bde.unlock_with_recovery_password(key)
            info["unlocked_with"] = "recovery password"
        elif pw:
            bde.unlock_with_passphrase(pw)
            info["unlocked_with"] = "passphrase"
        else:
            raise SystemExit(
                "BitLocker volume with no clear key.\n"
                "  The owner's recovery key is required. Ask them to fetch it\n"
                "  themselves from https://account.microsoft.com/devices/recoverykey\n"
                "  then re-run with BITLOCKER_RECOVERY_KEY=xxxxxx-xxxxxx-...\n"
                "  Run probe-50-bitlocker.py first to get the key IDENTIFIER,\n"
                "  which is what they match against in that list.")

    if not bde.unlocked:
        raise SystemExit("BitLocker unlock failed.")
    if not quiet:
        print(f"Unlocked {dev} with its {info['unlocked_with']} (read-only).")
    return NTFS(bde.open()), info


# ---------------------------------------------------------------- MFT helpers

def dedupe_records(entries):
    """Drop NTFS 8.3 short-name duplicates.

    listdir()/full_path() surface BOTH the long name and the 8.3 short name for
    the same MFT record ('Rockstar Games' and 'ROCKST~1'), and nested short
    names multiply combinatorially down a path. Counting or copying without
    deduplicating inflates totals and extracts the same bytes several times.

    Keyed on the MFT segment number, which is the record's real identity.

    Picking the winner by path LENGTH is wrong: 'Rockstar Games/GTAIV~1/f' is
    longer than 'Rockstar Games/GTA IV/f' yet still carries a short-name
    component. Rank by how many 8.3 components a path contains (fewer wins),
    and only use length as a tie-breaker.
    """
    def rank(path):
        parts = path.replace("\\", "/").split("/")
        return (sum(1 for p in parts if _SHORTNAME.search(p)), -len(path))

    best = {}
    for path, rec in entries:
        try:
            seg = rec.segment
        except Exception:
            seg = path
        cur = best.get(seg)
        if cur is None or rank(path) < rank(cur[0]):
            best[seg] = (path, rec)
    return list(best.values())


def timestamps(rec):
    """(modified, created) for an MFT record, or (None, None)."""
    try:
        a = rec.attributes.get(0x10)[0].attribute
        return a.last_modification_time, a.creation_time
    except Exception:
        return None, None


def walk(rec, prefix="", depth=0, maxdepth=40, skip_dirs=()):
    """Yield (path, record) for every file beneath `rec`. Metadata only."""
    try:
        items = list(rec.listdir().items())
    except Exception:
        return
    for name, ie in items:
        if name in (".", ".."):
            continue
        try:
            child = ie.dereference()
        except Exception:
            continue
        path = f"{prefix}/{name}" if prefix else name
        try:
            if child.is_dir():
                if depth < maxdepth and name.lower() not in skip_dirs:
                    yield from walk(child, path, depth + 1, maxdepth, skip_dirs)
            else:
                yield path, child
        except Exception:
            continue


def parse_since(spec):
    """'2025' | '2025-02' | '2025-02-14' -> aware datetime, or None."""
    if not spec:
        return None
    q = [int(x) for x in str(spec).split("-")]
    return datetime.datetime(q[0],
                             q[1] if len(q) > 1 else 1,
                             q[2] if len(q) > 2 else 1,
                             tzinfo=datetime.timezone.utc)


def find_records(ntfs, pattern, since=None, progress=None):
    """Search the whole MFT by filename. Returns deduplicated [(path, record)].

    Bare words are wrapped in globs, so --find report matches *report*.

    Ordering matters for speed: the cheap filename match is applied BEFORE
    full_path(), which walks the parent chain and is comparatively expensive.
    Calling it on every record instead of on matches only turns a scan of a
    few hundred thousand records into minutes of extra work.
    """
    pat = pattern if any(c in pattern for c in "*?[") else f"*{pattern}*"
    rx = re.compile(fnmatch.translate(pat), re.I)
    since_dt = parse_since(since)

    hits, n = [], 0
    for rec in ntfs.mft.segments():
        n += 1
        if progress and n % 100000 == 0:
            progress(n)
        try:
            if rec.is_dir():
                continue
            name = rec.filename
            if not name or not rx.match(name):      # cheap test first
                continue
            if since_dt:
                mod, cre = timestamps(rec)
                if not any(t and t >= since_dt for t in (mod, cre)):
                    continue
            hits.append((rec.full_path(), rec))     # expensive, matches only
        except Exception:
            continue
    return dedupe_records(hits), n


def recycle_bin_items(ntfs):
    """Deleted files that still have their data.

    Windows splits a recycled file in two: $I<id> holds the original full path
    and the deletion timestamp, $R<id> holds the untouched file data. Pairing
    them recovers both the content and where it came from.

    Yields (original_path, deleted_datetime, data_record, r_name).
    """
    try:
        rb = ntfs.mft.get("$Recycle.Bin")
    except Exception:
        return
    for sid, ie in rb.listdir().items():
        if sid in (".", ".."):
            continue
        try:
            sd = ie.dereference()
            if not sd.is_dir():
                continue
            entries = sd.listdir()
        except Exception:
            continue
        for name, ie2 in entries.items():
            if not name.upper().startswith("$I"):
                continue
            try:
                d = ie2.dereference().open().read()
                ver = struct.unpack_from("<Q", d, 0)[0]
                ftv = struct.unpack_from("<Q", d, 16)[0]
                when = datetime.datetime(1601, 1, 1) + datetime.timedelta(
                    microseconds=ftv // 10)
                if ver >= 2:
                    nlen = struct.unpack_from("<I", d, 24)[0]
                    orig = d[28:28 + nlen * 2].decode("utf-16-le").rstrip("\x00")
                else:
                    orig = d[24:24 + 520].decode("utf-16-le").rstrip("\x00")
                rname = name.replace("$I", "$R", 1)
                rrec = entries.get(rname)
                if rrec is not None:
                    yield orig, when, rrec.dereference(), rname
            except Exception:
                continue
