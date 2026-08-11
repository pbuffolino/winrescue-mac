#!/usr/bin/env bash
# PROBE 20 — HEALTH: is this drive dying? Decides "copy normally" vs "ddrescue first".
#
# READ-ONLY. Needs sudo *only to read* the raw device. Every dd here is
# `if=<device> of=/dev/null` — a read. No write, no repair, no fsck.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_disk_arg "${1:-}"
DISK="$(norm_disk "$1")"
disk_exists "$DISK" || { err "/dev/$DISK not found"; exit 1; }

banner "PROBE 20 — DRIVE HEALTH" "target: /dev/$DISK"

SMART_LOG="$LOGS/smart-$DISK-$(ts).txt"
CONCERN=0

step "SMART attributes"
if ! have smartctl; then
  warn "smartctl not installed — SMART attributes unavailable."
  note "Install with:  brew install smartmontools"
  note "(read-only tool; it only queries the drive). Skipping to surface read test."
else
  # Many USB-SATA / USB-NVMe bridges refuse SMART passthrough, and the correct
  # transport is not predictable — try each in turn.
  # smartctl returns a BITMASK, not success/failure:
  #   bit 0 (1)  command line parse error
  #   bit 1 (2)  device open failed          <- the only real "no passthrough"
  #   bit 2 (4)  some SMART command failed
  #   bit 3 (8)  DISK IS FAILING             <- non-zero, but a SUCCESSFUL read
  #   bits 4-7   prefail/old-age attributes tripped
  # Treating the exit status as a boolean discards a good read of a dying
  # drive as "the bridge does not support SMART" -- wrong in exactly the case
  # where the answer matters most. Only bits 0-1 mean we failed to read.
  GOT_SMART=0
  for MODE in auto sat nvme; do
    show "sudo smartctl -a -d $MODE /dev/$DISK"
    sudo smartctl -a -d "$MODE" "/dev/$DISK" >"$SMART_LOG" 2>&1
    RC=$?
    if [ $(( RC & 3 )) -eq 0 ] && grep -qiE 'Model|Serial|Device Model' "$SMART_LOG"; then
      ok "SMART read succeeded with -d $MODE (exit bitmask $RC)"
      [ $(( RC & 8 )) -ne 0 ] && err "smartctl bit 3 set: DRIVE REPORTS ITSELF AS FAILING"
      GOT_SMART=1
      break
    else
      note "  -d $MODE — no passthrough (exit $RC), trying next transport"
    fi
  done

  if [ "$GOT_SMART" -eq 0 ]; then
    warn "This USB bridge does not pass SMART through (very common)."
    note "Not a sign of drive failure — the enclosure is the limitation."
    note "The surface read test below is the fallback health signal."
  else
    note "full output -> $SMART_LOG"
    grep -iE 'Model|Serial|Capacity|Firmware' "$SMART_LOG" | head -6 || true

    printf '\n'
    grep -iE 'Percentage Used|Available Spare|Media and Data Integrity Errors|Unsafe Shutdowns|Power On Hours|Critical Warning' "$SMART_LOG" || true
    grep -iE 'Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable|Power_On_Hours|Reported_Uncorrect' "$SMART_LOG" || true

    printf '\n'
    if grep -iqE 'SMART overall-health.*(FAILED|FAIL)' "$SMART_LOG"; then
      err "SMART overall health: FAILED"
      CONCERN=1
    elif grep -iqE 'SMART overall-health.*PASSED' "$SMART_LOG"; then
      ok "SMART overall health: PASSED"
    fi

    # Non-zero on any of these means: image it before touching it further.
    for ATTR in 'Media and Data Integrity Errors' 'Reallocated_Sector_Ct' 'Current_Pending_Sector' 'Offline_Uncorrectable'; do
      VAL="$(grep -i "$ATTR" "$SMART_LOG" | head -1 | awk '{print $NF}' | tr -d ',')"
      case "$VAL" in
        ''|0) ;;
        *[!0-9]*) ;;
        *) warn "$ATTR = $VAL (non-zero)"; CONCERN=1 ;;
      esac
    done

    PCT="$(grep -i 'Percentage Used' "$SMART_LOG" | head -1 | awk '{print $NF}' | tr -d '%,')"
    case "$PCT" in
      ''|*[!0-9]*) ;;
      *) [ "$PCT" -ge 90 ] && { warn "Flash wear at ${PCT}% of rated life."; CONCERN=1; } \
                           || note "Flash wear: ${PCT}% of rated life." ;;
    esac
  fi
fi

pause "Ready to run the surface read test"
step "Surface read test (sampled, read-only)"
SIZE="$(disk_size_bytes "$DISK")"
if [ "$SIZE" -le 0 ]; then
  warn "Could not determine size; skipping read test."
else
  MB=$(( SIZE / 1048576 ))
  SAMPLES=64
  note "Reading 1 MB at $SAMPLES points across $(human "$SIZE") (~64 MB total)."
  note "Raw device /dev/r$DISK bypasses the buffer cache, so timings are real."
  show "sudo dd if=/dev/r$DISK bs=1m count=1 skip=<offset> of=/dev/null   x${SAMPLES}"
  printf '\n'

  ERRORS=0; SLOW=0
  for i in $(seq 0 $((SAMPLES - 1))); do
    OFF=$(( MB / SAMPLES * i ))
    PCT=$(( (i + 1) * 100 / SAMPLES ))
    printf '\r  %s  sample %02d/%d  %3d%%  offset %s%s' \
      "$C_DIM" "$((i + 1))" "$SAMPLES" "$PCT" "$(human "$(( OFF * 1048576 ))")" "$C_RST"

    START="$(perl -MTime::HiRes=time -e 'printf "%.4f", time' 2>/dev/null || echo 0)"

    if ! sudo dd if="/dev/r$DISK" bs=1m count=1 skip="$OFF" of=/dev/null 2>>"$LOGS/readtest-$DISK.log"; then
      printf '\r%*s\r' 70 ''
      err "READ ERROR at offset ${OFF} MB (sample $i/$SAMPLES)"
      ERRORS=$(( ERRORS + 1 ))
      continue
    fi

    END="$(perl -MTime::HiRes=time -e 'printf "%.4f", time' 2>/dev/null || echo 0)"
    ELAPSED="$(awk -v a="$START" -v b="$END" 'BEGIN{printf "%.3f", b-a}')"
    if awk -v e="$ELAPSED" 'BEGIN{exit !(e > 1.0)}'; then
      printf '\r%*s\r' 70 ''
      warn "Slow read at ${OFF} MB: ${ELAPSED}s for 1 MB"
      SLOW=$(( SLOW + 1 ))
    fi
  done
  printf '\r%*s\r' 70 ''

  printf '\n'
  if [ "$ERRORS" -gt 0 ]; then
    err "$ERRORS/$SAMPLES sample reads FAILED."
    CONCERN=1
  elif [ "$SLOW" -gt 0 ]; then
    warn "$SLOW/$SAMPLES sample reads were slow (>1s per MB)."
    CONCERN=1
  else
    ok "All $SAMPLES sample reads succeeded at normal speed."
  fi
fi

step "Verdict"
if [ "$CONCERN" -eq 1 ]; then
  err "DRIVE SHOWS SIGNS OF TROUBLE."
  note "Do NOT run repeated recovery passes against it."
  note "Go to Phase 3: image once with ddrescue, then recover from the image:"
  note "  brew install ddrescue"
  note "  diskutil unmountDisk /dev/$DISK"
  note "  sudo ddrescue -d -r3 /dev/$DISK \"$STAGING/drive.img\" \"$STAGING/drive.map\""
  finish
  exit 10
else
  ok "No health red flags. A normal read-only copy is appropriate."
  finish
fi
