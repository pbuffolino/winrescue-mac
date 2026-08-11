## What this changes

<!-- One or two sentences. -->

## Why

<!-- What recovery scenario does this help with? -->

## What breaks if this is wrong

<!-- For this project this matters more than what the change does. If it touches a
     device, say what happens to someone's only copy of their data if there's a bug. -->

---

## Required checks

- [ ] **This does not add any path that can write to, repair, or modify a source drive**
- [ ] Does not require macFUSE or any kernel extension
- [ ] `bash tests/test-guards.sh` passes (100% green)
- [ ] `python tests/test_lib.py` passes
- [ ] `./scripts/00-preflight.sh` still passes
- [ ] **No personal data**: no real filenames, Windows usernames, SIDs, volume GUIDs,
      drive serials, or BitLocker keys/key IDs anywhere in the diff

## If this touches diagnosis logic

- [ ] Unknown states report `UNKNOWN` and stop — never a healthy-looking default
- [ ] New exit codes are mapped in `survey.sh` **and** documented in `README.md`

## If this touches the crypto or read path

- [ ] Verified byte-identical against the reference implementation
      (`fastcrypto.verify_against_reference()`) — paste the result
- [ ] Performance claims measured on the **real** path, not a synthetic benchmark

## Testing

<!-- How did you test? Real hardware, disk image, or synthetic?
     If real hardware: confirm the source was unchanged afterwards. -->
