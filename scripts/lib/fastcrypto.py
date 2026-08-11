#!/usr/bin/env python3
"""Make dissect.fve's AES-XTS fast enough to be usable.

WHY THIS EXISTS
---------------
dissect.fve is correct and well maintained, but its AES-XTS implementation
loops over 16-byte blocks in pure Python. Measured against a real BitLocker
volume over USB that is 4-7 MB/s -- about 17 hours for a 237 GB volume. Its
crypto backend is pycryptodome, which exposes no XTS mode, so there is nothing
faster underneath it.

This patches ONLY the innermost per-sector transform to use OpenSSL (via
`cryptography`). Everything structural in dissect -- run lists, the relocated
NTFS volume header, plain/sparse region handling -- is untouched, because that
is the part that is subtle and easy to get wrong.

Measured on an M1 Pro: 4-7 MB/s -> 87-92 MB/s, a 13-20x speedup, with output
verified byte-identical (SHA-256) at multiple offsets across the volume.

Key convention: dissect uses key[:16] as the data key and key[16:] as the tweak
key. OpenSSL's XTS with a 32-byte key splits it the same way, so the key passes
through unchanged.

ALWAYS verify after patching. `verify_against_reference()` does it for you.
"""
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from dissect.fve.crypto._pycryptodome import XtsMode
from dissect.fve.crypto.base import ENCRYPT


def _fast_crypt_sector(self, mode, buffer, iv):
    algo = algorithms.AES(self._xts_key)
    ctx = (Cipher(algo, modes.XTS(bytes(iv))).encryptor() if mode == ENCRYPT
           else Cipher(algo, modes.XTS(bytes(iv))).decryptor())
    buffer[:] = ctx.update(bytes(buffer)) + ctx.finalize()


_orig_init = XtsMode.__init__


def _patched_init(self, factory, key, key_size, iv_mode, iv_options,
                  sector_size=512, iv_sector_size=512):
    _orig_init(self, factory, key, key_size, iv_mode, iv_options,
               sector_size, iv_sector_size)
    self._xts_key = key           # full key1||key2, as OpenSSL expects


def enable():
    """Install the fast path. Idempotent; safe to call from every entry point."""
    if getattr(XtsMode, "_fast_installed", False):
        return
    XtsMode.__init__ = _patched_init
    XtsMode._crypt_sector = _fast_crypt_sector
    XtsMode._fast_installed = True


def disable():
    """Restore dissect's own implementation (used by the verifier)."""
    if not getattr(XtsMode, "_fast_installed", False):
        return
    XtsMode.__init__ = _orig_init
    del XtsMode._crypt_sector
    XtsMode._fast_installed = False


def verify_against_reference(open_stream, offsets=(0, 1 << 30), length=1 << 22):
    """Prove the fast path returns exactly what dissect would.

    `open_stream` must be a zero-arg callable returning a FRESH decrypted
    stream each time (state must not be shared between the two runs).

    Returns (ok, slow_mbps, fast_mbps). Never trust a crypto shortcut you have
    not diffed against the reference implementation.
    """
    import hashlib
    import time

    def digest_all():
        s = open_stream()
        out = []
        t0 = time.time()
        for off in offsets:
            s.seek(off)
            out.append(hashlib.sha256(s.read(length)).hexdigest())
        return out, time.time() - t0

    was_on = getattr(XtsMode, "_fast_installed", False)
    disable()
    ref, t_slow = digest_all()
    enable()
    fast, t_fast = digest_all()
    if not was_on:
        disable()

    mb = (len(offsets) * length) / 1048576
    return ref == fast, mb / max(t_slow, 1e-6), mb / max(t_fast, 1e-6)
