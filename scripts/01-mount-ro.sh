#!/usr/bin/env bash
# Mount a partition READ-ONLY, and refuse to proceed unless it really is.
#
# Uses `diskutil mount readOnly` first — the safest supported path. Falls back
# to an explicit `mount -t ntfs -o ro` only if that fails, which happens when
# Windows Fast Startup / hibernation left the NTFS volume "dirty".
#
# Usage: ./scripts/01-mount-ro.sh <diskXsY>
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_disk_arg "${1:-}"
PART="$(norm_disk "$1")"
disk_exists "$PART" || { err "/dev/$PART not found"; exit 1; }

banner "MOUNT READ-ONLY" "target: /dev/$PART"

step "Confirming filesystem type before mounting"
show "sudo dd if=/dev/r$PART bs=512 count=1 | head -c 11 | tail -c 8"
OEM="$(volume_oem_id "$PART")"
VERDICT="$(classify_oem "$OEM")"
note "Filesystem header: $VERDICT [$OEM]"
case "$VERDICT" in
  BITLOCKER*|"BitLocker To Go")
    err "This partition is BitLocker-encrypted. Mounting cannot work."
    note "See Phase 2 — the recovery key is the only route."
    exit 20
    ;;
esac

step "Mounting read-only"
if cmd_ok diskutil mount readOnly "/dev/$PART" && \
   diskutil info "/dev/$PART" 2>/dev/null | grep -q "Mounted: *Yes"; then
  ok "Mounted via diskutil."
else
  err "diskutil could not mount this volume read-only."
  printf '\n'
  # There is deliberately NO `mount -t ntfs` fallback here. macOS 26 ships no
  # /sbin/mount_ntfs at all -- NTFS moved to UserFS (ntfs.fs declares
  # FSImplementation => UserFS and contains only ntfs.util). Any such fallback
  # is dead code that fails with a confusing error. Verify on any machine:
  #     ls /sbin/mount_* | grep ntfs      # no output on macOS 26
  note "macOS 26 CANNOT force-mount a dirty NTFS volume: there is no"
  note "mount_ntfs helper any more. Repairing it is not an option either,"
  note "because every repair tool writes to the source."
  printf '\n'
  note "The usual causes, in order of likelihood:"
  note "  1. BitLocker      -> ./scripts/probe-50-bitlocker.py /dev/$PART"
  note "                       Check for a CLEAR KEY before assuming the"
  note "                       recovery key is needed -- suspended volumes"
  note "                       unlock with no key at all."
  note "  2. Dirty NTFS     -> Windows Fast Startup / hibernation left the"
  note "                       volume flagged. Do NOT repair it."
  note "  3. Damaged boot   -> probe 30 compares the backup boot sector."
  printf '\n'
  note "You do not need a mount to recover the data. Read it directly:"
  show "./scripts/04-list-nomount.py /dev/r$PART"
  show "./scripts/05-extract-nomount.py /dev/r$PART --find '*.jpg' ~/Recovered"
  finish
  exit 1
fi

MOUNTPOINT="$(diskutil info "/dev/$PART" 2>/dev/null | awk -F': *' '/Mount Point/{print $2; exit}')"
[ -n "$MOUNTPOINT" ] || MOUNTPOINT="$HOME/recovered-mount"

step "Verifying the mount is genuinely read-only"
show "mount | grep ' on $MOUNTPOINT '"
assert_mounted_readonly "$MOUNTPOINT"
note "Mount point: $MOUNTPOINT"
printf '\n'
note "Next steps:"
show "./scripts/probe-40-content.sh \"$MOUNTPOINT\""
show "./scripts/02-copy.sh \"$MOUNTPOINT\" <windows-username>"
finish
