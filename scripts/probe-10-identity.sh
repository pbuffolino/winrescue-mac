#!/usr/bin/env bash
# PROBE 10 — IDENTITY: what is this drive, how big, and how fast is the link?
# READ-ONLY. No sudo required. Safe on a mounted or unmounted disk.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_disk_arg "${1:-}"
DISK="$(norm_disk "$1")"
disk_exists "$DISK" || { err "/dev/$DISK not found. Run: diskutil list"; exit 1; }

banner "PROBE 10 — DRIVE IDENTITY" "target: /dev/$DISK"

step "Partition map"
cmd diskutil list "/dev/$DISK"

step "Capacity vs. available space on this Mac"
SIZE="$(disk_size_bytes "$DISK")"
show "diskutil info -plist /dev/$DISK | plutil -extract Size raw -"
note "Source drive : $SIZE bytes ($(human "$SIZE"))"

FREE="$(df -k / | awk 'NR==2{print $4*1024}')"
show "df -k /"
note "Mac free     : $(human "$FREE")"
if [ "$SIZE" -gt 0 ] && [ "$FREE" -lt "$SIZE" ]; then
  warn "Internal free space is smaller than the source drive."
  note "A full ddrescue image will NOT fit. Copy selectively, or image to an external disk."
else
  ok "Enough internal free space to image this drive if that becomes necessary."
fi

step "Device details"
show "diskutil info /dev/$DISK   # key fields"
diskutil info "/dev/$DISK" 2>/dev/null | grep -E \
  'Device / Media Name|Volume Name|Protocol|Internal|Removable|Solid State|Device Block Size|Disk Size|SMART|Read-Only|Ejectable' \
  || true

step "USB link speed  <- the number that decides your copy time"
# macOS 26 uses SPUSBHostDataType; the older SPUSBDataType key no longer exists.
USBLOG="$LOGS/usb-$DISK-$(ts).txt"
show "system_profiler SPUSBHostDataType > $USBLOG"
system_profiler SPUSBHostDataType >"$USBLOG" 2>/dev/null || true
note "full output -> $USBLOG"
printf '\n'

SPEEDS="$(grep -E 'Speed:' "$USBLOG" 2>/dev/null | sed 's/^ *//' | sort -u || true)"
if [ -n "$SPEEDS" ]; then
  printf '%s\n' "$SPEEDS" | while IFS= read -r s; do note "$s"; done
else
  note "(no speed lines reported)"
fi
printf '\n'

if grep -qE 'Speed:.*480 Mb' "$USBLOG" 2>/dev/null; then
  warn "A device negotiated 480 Mb/s (USB 2.0 fallback)."
  note "If that is your enclosure, a 500 GB copy takes ~3 hours instead of ~20 minutes."
  note "Reseat the cable, avoid hubs, use a direct USB-C port -- then re-run this probe."
elif grep -qE 'Speed:.*(5 Gb|10 Gb|20 Gb|40 Gb)' "$USBLOG" 2>/dev/null; then
  ok "Link negotiated at USB 3.x speed or better."
fi

step "NVMe / storage controllers"
STORLOG="$LOGS/storage-$DISK-$(ts).txt"
show "system_profiler SPNVMeDataType SPStorageDataType > $STORLOG"
system_profiler SPNVMeDataType SPStorageDataType >"$STORLOG" 2>/dev/null || true
note "full output -> $STORLOG"

ok "Probe 10 complete."
finish
