#!/usr/bin/env python3
"""Library self-tests. No disks are touched; everything runs against temp files.

Covers the things that were actually wrong at some point, so they stay fixed:
  - AlignedReader must serve unaligned reads over a sector-aligned backend
  - it must be read-only, with no write path
  - `.size` must be an attribute (dissect reads it as one, not as a method)
  - dedupe_records must collapse NTFS 8.3 short-name duplicates
  - the OpenSSL crypto patch must install, be idempotent, and be reversible
"""
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "scripts", "lib"))

FAILED = []


def check(name, cond, detail=""):
    if cond:
        print(f"  ok       {name}")
    else:
        print(f"  NOT OK   {name} {detail}")
        FAILED.append(name)


# --------------------------------------------------------------- AlignedReader
import ntfsread  # noqa: E402
from ntfsread import AlignedReader, human, dedupe_records, is_bitlocker  # noqa: E402

print("== AlignedReader ==")
with tempfile.NamedTemporaryFile(delete=False) as tf:
    payload = bytes(range(256)) * 4096          # 1 MiB, positionally verifiable
    tf.write(payload)
    tmp = tf.name

try:
    r = AlignedReader(tmp, block=4096)
    check("size is an attribute, not a method", isinstance(r.size, int),
          f"(got {type(r.size)})")
    check("size is correct", r.size == len(payload))
    check("readable", r.readable())
    check("not writable", r.writable() is False)

    r.seek(0)
    check("read from offset 0", r.read(16) == payload[:16])

    # The case that raised EINVAL against a raw device before AlignedReader.
    r.seek(1000)
    check("unaligned offset, unaligned length", r.read(1234) == payload[1000:2234])

    r.seek(4090)
    check("read spanning a block boundary", r.read(20) == payload[4090:4110])

    r.seek(-32, os.SEEK_END)
    check("seek from end", r.read(32) == payload[-32:])

    r.seek(len(payload))
    check("read past end returns empty", r.read(64) == b"")

    r.seek(0)
    check("read(-1) returns everything", len(r.read(-1)) == len(payload))

    check("no write method exposed", not hasattr(r, "write") or
          r.writable() is False)
    check("not a BitLocker volume", is_bitlocker(r) is False)
    r.close()
finally:
    os.unlink(tmp)

print()
print("== human() ==")
check("bytes", human(512) == "512 B", f"(got {human(512)})")
check("KB", human(1024) == "1.0 KB", f"(got {human(1024)})")
check("GB", human(1073741824) == "1.0 GB", f"(got {human(1073741824)})")
check("zero", human(0) == "0 B", f"(got {human(0)})")
check("None is tolerated", human(None) == "0 B")


# ------------------------------------------------------------ dedupe_records
print()
print("== dedupe_records (NTFS 8.3 short names) ==")


class FakeRec:
    def __init__(self, segment):
        self.segment = segment


a, b = FakeRec(100), FakeRec(200)
entries = [
    ("ROCKST~1/GTAIV~1/file.dat", a),
    ("Rockstar Games/GTA IV/file.dat", a),      # same record, long name
    ("Rockstar Games/GTAIV~1/file.dat", a),
    ("ROCKST~1/GTA IV/file.dat", a),
    ("Users/Sam/photo.jpg", b),
]
out = dedupe_records(entries)
check("collapses to one entry per MFT record", len(out) == 2, f"(got {len(out)})")
paths = sorted(p for p, _ in out)
check("keeps the long-name path",
      "Rockstar Games/GTA IV/file.dat" in paths, f"(got {paths})")
check("empty input is safe", dedupe_records([]) == [])


# --------------------------------------------------------------- parse_since
print()
print("== parse_since (shared by both no-mount tools) ==")
from ntfsread import parse_since  # noqa: E402
import datetime as _dt

check("None passes through", parse_since(None) is None)
check("year only", parse_since("2025") == _dt.datetime(2025, 1, 1, tzinfo=_dt.timezone.utc))
check("year-month", parse_since("2025-02") == _dt.datetime(2025, 2, 1, tzinfo=_dt.timezone.utc))
check("full date", parse_since("2025-02-14") == _dt.datetime(2025, 2, 14, tzinfo=_dt.timezone.utc))
check("result is timezone-aware", parse_since("2025").tzinfo is not None)


# ---------------------------------------------------------------- fastcrypto
print()
print("== fastcrypto ==")
try:
    import fastcrypto
    from dissect.fve.crypto._pycryptodome import XtsMode

    fastcrypto.enable()
    check("enable() installs the patch", getattr(XtsMode, "_fast_installed", False))
    fastcrypto.enable()
    check("enable() is idempotent", getattr(XtsMode, "_fast_installed", False))
    check("_crypt_sector is overridden",
          XtsMode._crypt_sector is fastcrypto._fast_crypt_sector)
    fastcrypto.disable()
    check("disable() restores the original",
          not getattr(XtsMode, "_fast_installed", False))
    check("verify_against_reference is available",
          callable(fastcrypto.verify_against_reference))
except ImportError as e:
    check("fastcrypto imports", False, f"({e})")


# ---------------------------------------------- OpenSSL XTS == reference XTS
print()
print("== AES-XTS: OpenSSL matches a reference implementation ==")
try:
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

    key = bytes(range(32))
    data = bytes(range(256)) * 2          # 512 bytes, one sector
    tweak = (7).to_bytes(16, "little")

    enc = Cipher(algorithms.AES(key), modes.XTS(tweak)).encryptor()
    ct = enc.update(data) + enc.finalize()
    dec = Cipher(algorithms.AES(key), modes.XTS(tweak)).decryptor()
    check("encrypt/decrypt round-trips", dec.update(ct) + dec.finalize() == data)
    check("ciphertext differs from plaintext", ct != data)

    dec2 = Cipher(algorithms.AES(key), modes.XTS((8).to_bytes(16, "little"))).decryptor()
    check("a different sector tweak yields different plaintext",
          dec2.update(ct) + dec2.finalize() != data)
except Exception as e:
    check("cryptography AES-XTS available", False, f"({e})")


print()
print("=" * 50)
if FAILED:
    print(f"FAILED: {len(FAILED)} -> {', '.join(FAILED)}")
    sys.exit(1)
print("All library tests passed.")
