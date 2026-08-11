#!/usr/bin/env bash
# PROBE 30 — FILESYSTEM: NTFS, BitLocker, or something else?
# This probe decides Phase 1 (plain copy) vs Phase 2 (BitLocker recovery key).
#
# READ-ONLY. sudo is used only to read the first 512 bytes of each partition.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_disk_arg "${1:-}"
DISK="$(norm_disk "$1")"
disk_exists "$DISK" || { err "/dev/$DISK not found"; exit 1; }

banner "PROBE 30 — FILESYSTEM & ENCRYPTION" "target: /dev/$DISK"

step "Enumerating partitions"
show "diskutil list /dev/$DISK"
PARTS="$(disk_partitions "$DISK")"
[ -n "$PARTS" ] || { err "No partitions found on /dev/$DISK"; exit 1; }
note "Found: $(printf '%s ' $PARTS)"

step "Reading each partition's filesystem header"
note "fstyp reports BitLocker volumes as NTFS, so the 8-byte OEM ID at offset 3"
note "is the authoritative check. Both operations are pure reads."
show "fstyp /dev/<part>"
show "sudo dd if=/dev/r<part> bs=512 count=1 | head -c 11 | tail -c 8"
printf '\n'
printf '%-12s %-22s %-12s %-12s %s\n' "PART" "NAME" "SIZE" "FSTYP" "HEADER VERDICT"
printf '%-12s %-22s %-12s %-12s %s\n' "----" "----" "----" "-----" "--------------"

for P in $PARTS; do
  NAME="$(diskutil info "/dev/$P" 2>/dev/null | awk -F': *' '/Volume Name/{print $2; exit}')"
  [ -n "$NAME" ] || NAME="(none)"
  PSIZE="$(disk_size_bytes "$P")"

  # fstyp is built in at /sbin/fstyp. It reports BitLocker volumes as NTFS,
  # which is exactly why the header read below is the authoritative check.
  FS="$(fstyp "/dev/$P" 2>/dev/null | head -1)"
  [ -n "$FS" ] || FS="-"

  OEM="$(volume_oem_id "$P")"
  VERDICT="$(classify_oem "$OEM")"

  printf '%-12s %-22.22s %-12s %-12s %s\n' \
    "$P" "$NAME" "$(human "$PSIZE")" "$FS" "$VERDICT  [$OEM]"

done
# This loop deliberately does NOT choose a target partition. It used to pick the
# largest partition whose classify_oem verdict was NTFS or BitLocker -- which
# silently skipped any partition whose header could not be read, and an
# unreadable header is the entire reason this probe exists. The verdict section
# below starts from the largest partition by SIZE and reads its headers directly.

step "Current mount state"
show "mount | grep /dev/$DISK"
mount | grep -F "/dev/$DISK" || note "No partitions from this disk are currently mounted."

step "Forensics on the largest data partition"
# If the primary boot sector is unreadable, one read decides everything:
# NTFS mirrors its boot sector in the partition's LAST sector. "NTFS" there
# while sector 0 is garbage means a DAMAGED BOOT SECTOR -- recoverable, and
# decisively not BitLocker. Without this check the two diagnoses look
# identical from macOS, and they need opposite responses.
BIG=""; BIG_SZ=0
for P in $PARTS; do
  PSIZE="$(disk_size_bytes "$P")"
  if [ "${PSIZE:-0}" -gt "$BIG_SZ" ]; then BIG="$P"; BIG_SZ="$PSIZE"; fi
done
note "Largest partition: $BIG ($(human "$BIG_SZ"))"

PRI="$(volume_oem_id "$BIG")"
BAK="$(backup_oem_id "$BIG")"
FVE="$(fve_markers "$BIG")"
printf '\n'
note "primary  sector 0   : [$PRI]  -> $(classify_oem "$PRI")"
note "backup   last sector: [$BAK]  -> $(classify_oem "$BAK")"
note "BitLocker FVE markers: $FVE"

printf '\n'
note "Entropy across the volume (8.00 everywhere = encrypted):"
SECTORS=$(( BIG_SZ / 512 ))
printf '         %-14s %-9s %s\n' "OFFSET" "ENTROPY" "ZERO%"
for FRAC in 0 1 2 3; do
  SKIP=$(( SECTORS / 4 * FRAC ))
  # One read per sample point yields both figures.
  read -r ENT ZERO <<EOF
$(sample_stats "$BIG" "$SKIP")
EOF
  printf '         %-14s %-9s %s\n' "$(human $(( SKIP * 512 )))" "$ENT" "$ZERO"
done

step "Verdict"
case "$PRI" in
  "-FVE-FS-")
    err "BITLOCKER ENCRYPTED on $BIG."
    printf '\n'
    note "DO NOT stop here. 'Encrypted' does not mean 'needs the recovery key'."
    note "A SUSPENDED volume carries a CLEAR KEY and unlocks with no key at all"
    note "-- the common state for Windows 11 device encryption that was never"
    note "tied to a Microsoft account. Check before telling anyone it is gone:"
    printf '\n'
    show "./scripts/probe-50-bitlocker.py /dev/r$BIG"
    printf '\n'
    note "Do NOT install dislocker: it needs libfuse/macFUSE, which costs an"
    note "Apple Silicon Mac its boot security. The Python path needs neither."
    finish
    exit 20 ;;
  "NTFS    ")
    ok "Plain NTFS, not encrypted."
    note "macOS reads NTFS read-only natively."
    printf '\n'
    show "./scripts/01-mount-ro.sh $BIG"
    note "If that fails (dirty volume), skip the mount entirely:"
    show "./scripts/04-list-nomount.py /dev/r$BIG"
    finish
    exit 0 ;;
esac

case "$BAK" in
  "NTFS    ")
    err "NTFS WITH A DAMAGED BOOT SECTOR on $BIG."
    note "Sector 0 is unreadable but the backup boot sector in the last sector"
    note "is intact, so the filesystem itself is very likely fine."
    printf '\n'
    note "Do NOT repair it -- every repair tool writes to the source. Read it"
    note "directly instead; the no-mount reader rebuilds from the backup:"
    show "./scripts/04-list-nomount.py /dev/r$BIG"
    finish
    exit 22 ;;
esac

err "UNIDENTIFIED FILESYSTEM on $BIG."
note "macOS could not identify it and neither boot sector says NTFS."
printf '\n'
note "Before assuming failure, rule out the cheap explanations:"
note "  - macOS shows an unidentifiable Microsoft Basic Data partition as"
note "    'MS-DOS (FAT)' with 0 bytes. That is a FAILED PROBE, not a finding."
note "  - A Windows Recovery partition always reads as 'no file system' on"
note "    macOS: no filesystem bundle claims its GUID. Not a fault."
note "  - No partitions at all? Suspect an M.2 keying mismatch (NVMe M-key vs"
note "    SATA B+M-key) with the enclosure before assuming a dead drive."
printf '\n'
note "Then try reading it without a mount, and carving if that fails:"
show "./scripts/04-list-nomount.py /dev/r$BIG"
finish
exit 21
