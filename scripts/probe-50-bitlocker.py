#!/usr/bin/env python3
"""PROBE 50 -- BITLOCKER: is this really unrecoverable, or just locked?

THE MOST IMPORTANT QUESTION IN THIS TOOLSET.

"BitLocker encrypted" is widely treated as "you need the recovery key or the
data is gone". That is often wrong. A BitLocker volume can carry a CLEAR KEY
protector, which means protection is SUSPENDED and the volume master key is
sitting on the disk in the clear. Such a volume unlocks with no password, no
recovery key, and no Microsoft account.

This is not exotic. Windows 11 device encryption enables itself during setup
and stays suspended with a clear key until the user signs in with a Microsoft
account. A machine that never got signed in sits in that state for its whole
life. In the case this toolset was built from, the volume's ONLY protector was
a clear key -- the difference between "tell the owner it is gone" and "recover
it this afternoon".

So: ALWAYS run this before telling anyone their data needs a recovery key.

Also reports the recovery-key IDENTIFIER. That is the ID the owner matches
against the list at account.microsoft.com/devices/recoverykey, which turns
"go find your key" into "find the key whose ID starts with these characters".

READ-ONLY. Opens the device O_RDONLY and reads metadata sectors. Writes nothing.

Usage: probe-50-bitlocker.py /dev/rdisk4s3
"""
import datetime
import os
import struct
import sys
import uuid

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
from ntfsread import AlignedReader, human, SECTOR   # noqa: E402

PROTECTION = {
    0x0000: ("CLEAR KEY", "SUSPENDED -- unlocks with NO password or recovery key"),
    0x0100: ("TPM", "needs the original motherboard's TPM"),
    0x0200: ("Startup key", "needs the USB startup key"),
    0x0500: ("TPM + PIN", "needs the original TPM and the user's PIN"),
    0x0800: ("RECOVERY PASSWORD", "the 48-digit key from the owner's account"),
    0x1000: ("TPM + startup key", "needs the original TPM and the USB key"),
    0x1100: ("TPM + PIN + startup key", "needs TPM, PIN and USB key"),
    0x2000: ("Password", "needs the user's BitLocker password"),
    0x4000: ("Smart card", "needs the smart card / certificate"),
}
ENCRYPTION = {
    0x8000: "AES-CBC 128 + diffuser", 0x8001: "AES-CBC 256 + diffuser",
    0x8002: "AES-CBC 128", 0x8003: "AES-CBC 256",
    0x8004: "AES-XTS 128", 0x8005: "AES-XTS 256",
}
ETYPE = {0x0000: "property", 0x0002: "VMK", 0x0003: "FVEK",
         0x0004: "validation", 0x0006: "startup key", 0x0007: "description",
         0x000b: "volume header block"}


def pread(f, off, ln):
    s = (off // SECTOR) * SECTOR
    e = ((off + ln + SECTOR - 1) // SECTOR) * SECTOR
    f.seek(s)
    return f.read(e - s)[off - s: off - s + ln]


def g(b):
    return str(uuid.UUID(bytes_le=b)).upper()


def ft(v):
    if not v:
        return "-"
    try:
        return str(datetime.datetime(1601, 1, 1) + datetime.timedelta(microseconds=v // 10))
    except Exception:
        return "?"


def walk_entries(data, depth=0):
    """FVE metadata entries; VMK entries nest their own sub-entries."""
    out, pos = [], 0
    while pos + 8 <= len(data):
        esize, etype, vtype, _ = struct.unpack_from("<HHHH", data, pos)
        if esize < 8 or pos + esize > len(data):
            break
        body = data[pos + 8: pos + esize]
        if etype == 0x0002 and len(body) >= 28:
            out.append({
                "kind": "VMK",
                "key_id": g(body[0:16]),
                "created": ft(struct.unpack_from("<Q", body, 16)[0]),
                "protection": struct.unpack_from("<H", body, 26)[0],
            })
            out += walk_entries(body[28:], depth + 1)
        elif etype == 0x0007 and body:
            try:
                out.append({"kind": "description",
                            "text": body.decode("utf-16-le").strip("\x00")})
            except Exception:
                pass
        else:
            out.append({"kind": ETYPE.get(etype, hex(etype))})
        pos += esize
    return out


def main(dev):
    raw = AlignedReader(dev)
    boot = pread(raw, 0, SECTOR)

    print("=" * 74)
    print(f" PROBE 50 -- BITLOCKER   {dev}  ({human(raw.size)})")
    print("=" * 74)

    if boot[3:11] != b"-FVE-FS-":
        print(f"\n  Not a BitLocker volume (OEM ID at offset 3 = {boot[3:11]!r}).")
        print("  If macOS still will not mount it, run probe-30 for the")
        print("  damaged-boot-sector vs unknown-filesystem diagnosis.")
        return 1

    print("\n  BitLocker signature confirmed (-FVE-FS- at offset 3).")

    # The pointer to the FVE metadata moved between BitLocker versions, so
    # instead of hardcoding an offset, treat every 8-byte little-endian value
    # in the boot sector as a candidate and keep the ones that actually land on
    # a metadata block. Self-validating, and version independent.
    cands = []
    for off in range(0, SECTOR - 8):
        (v,) = struct.unpack_from("<Q", boot, off)
        if 0x10000 < v < raw.size and v % SECTOR == 0:
            cands.append(v)
    blocks = [v for v in dict.fromkeys(cands) if pread(raw, v, 8) == b"-FVE-FS-"]
    if not blocks:
        print("  Could not locate an FVE metadata block.")
        return 2
    print(f"  {len(blocks)} metadata copies at: {', '.join(hex(b) for b in blocks)}")

    protector_sets, first = [], None
    for off in blocks:
        mh = pread(raw, off + 64, 48)
        msize, ver, hsize, _ = struct.unpack_from("<IIII", mh, 0)
        vguid, enc = g(mh[16:32]), struct.unpack_from("<H", mh, 0x24)[0]
        created = struct.unpack_from("<Q", mh, 0x28)[0]
        body = pread(raw, off + 64 + hsize, max(msize - hsize, 8192))
        entries = walk_entries(body)
        vmks = [e for e in entries if e.get("kind") == "VMK"]
        protector_sets.append(tuple(sorted(v["protection"] for v in vmks)))
        if first is None:
            first = (vguid, enc, created, vmks, entries)

    vguid, enc, created, vmks, entries = first
    print(f"\n  Volume GUID   : {vguid}")
    print(f"  Encryption    : {ENCRYPTION.get(enc, hex(enc))}")
    print(f"  Encrypted on  : {ft(created)}")

    agree = len(set(protector_sets)) == 1
    print(f"  Metadata copies agree: {agree}"
          + ("" if agree else "   <-- copies DISAGREE, treat with suspicion"))

    print("\n  Key protectors")
    print("  " + "-" * 70)
    clear = None
    for v in vmks:
        label, meaning = PROTECTION.get(v["protection"],
                                        (f"unknown ({hex(v['protection'])})", ""))
        print(f"    {label}")
        print(f"      key ID  : {v['key_id']}")
        print(f"      created : {v['created']}")
        print(f"      meaning : {meaning}")
        if v["protection"] == 0x0000:
            clear = v
        print()

    print("=" * 74)
    if clear:
        print("  VERDICT: CLEAR KEY PRESENT -- BitLocker protection is SUSPENDED.")
        print("  This volume unlocks with NO password and NO recovery key.")
        print("\n  Next:")
        print("    ./scripts/04-list-nomount.py " + dev)
        print("    ./scripts/05-extract-nomount.py " + dev + " <pattern> ~/Recovered")
        return 0

    rec = [v for v in vmks if v["protection"] == 0x0800]
    print("  VERDICT: LOCKED. The owner's recovery key is required.")
    print("  The data is AES-encrypted and the key is NOT on this drive.")
    if rec:
        for v in rec:
            short = v["key_id"].split("-")[0]
            print(f"\n  Recovery key IDENTIFIER: {v['key_id']}")
            print(f"  The owner looks for a key whose ID begins {short} at")
            print("    https://account.microsoft.com/devices/recoverykey")
    print("\n  Ask the OWNER to sign in and fetch it themselves.")
    print("  Never ask for their account password. Then re-run with:")
    print("    BITLOCKER_RECOVERY_KEY=xxxxxx-... ./scripts/04-list-nomount.py " + dev)
    return 20


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("Usage: probe-50-bitlocker.py /dev/rdiskXsY")
    sys.exit(main(sys.argv[1]))
