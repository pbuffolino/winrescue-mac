#!/usr/bin/env bash
# Copy the user profile off the source into ~/Recovered. Source is read-only;
# every write goes to $STAGING, which assert_not_source guarantees is not on
# the source volume.
#
# Usage: ./scripts/02-copy.sh /Volumes/<name> <windows-username>
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

VOL="${1:-}"; WUSER="${2:-}"
if [ -z "$VOL" ] || [ -z "$WUSER" ]; then
  err "Usage: $(basename "$0") /Volumes/<name> <windows-username>"
  exit 2
fi

U="$VOL/Users/$WUSER"
[ -d "$U" ] || { err "Profile not found: $U"; exit 1; }

banner "COPY FROM SOURCE" "$U  ->  $STAGING/$WUSER"

step "Safety preflight"
show "mount | grep ' on $VOL '     # source must be read-only"
assert_mounted_readonly "$VOL"
assert_not_source "$STAGING"
ok "Destination is not on the source volume."

DEST="$STAGING/$WUSER"
mkdir -p "$DEST"
LOG="$LOGS/copy-$(ts).log"

step "Copy plan"
note "Source (read-only): $U"
note "Destination       : $DEST"
note "Log               : $LOG"

step "Free-space check"
show "du -sk \"$U\"  vs  df -k \"$STAGING\""
SRC_KB="$(du -sk "$U" 2>/dev/null | awk '{print $1}')"
FREE_KB="$(df -k "$STAGING" | awk 'NR==2{print $4}')"
note "Source size : $(human "$(( SRC_KB * 1024 ))")"
note "Free space  : $(human "$(( FREE_KB * 1024 ))")"
if [ "$SRC_KB" -gt "$FREE_KB" ]; then
  err "Not enough free space. Refusing to start a copy that cannot complete."
  exit 1
fi
ok "Sufficient free space."

pause "Ready to start copying"
step "Copying"
# -rltD not -a: NTFS ownership/permissions are meaningless on APFS and only
# produce errors. --ignore-errors + --partial so one unreadable file does not
# abort the whole run. Re-running resumes where it left off.
note "rsync flags: -rltDvh --progress --partial --ignore-errors"
note "Safe to interrupt with Ctrl-C — re-running resumes."
printf '\n'

FOLDER_N=0
for D in Desktop Documents Pictures Videos Downloads Music OneDrive; do
  [ -d "$U/$D" ] || continue
  FOLDER_N=$(( FOLDER_N + 1 ))
  printf '\n%s%s  --- [%d] %s  (%s) ---%s\n' "$C_B" "$C_CYN" "$FOLDER_N" "$D" "$(clock)" "$C_RST"
  show "rsync -rltDvh --progress --partial --ignore-errors \"$U/$D\" \"$DEST/\""
  rsync -rltDvh --progress --partial --ignore-errors \
        "$U/$D" "$DEST/" 2>&1 | tee -a "$LOG" || warn "rsync reported errors in $D (continuing)"
  ok "$D done"
done

step "Copy complete"
ok "Copied $FOLDER_N folder(s) to $DEST"
cmd_ok du -sh "$DEST"
note "Log: $LOG"
printf '\n'
note "Next — verify BEFORE erasing anything:"
show "./scripts/03-verify.sh \"$DEST\""
finish
