#!/usr/bin/env bash
# PROBE 40 — CONTENT: how much is actually there, and is it real data?
# Answers the two questions that decide the iPhone strategy:
#   how big is it, and are these files or OneDrive placeholders?
#
# READ-ONLY. Only `find`, `du`, `ls`, `stat`. Requires the read-only mount.
# Usage: ./probe-40-content.sh /Volumes/<name> [windows-username]
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

VOL="${1:-}"
if [ -z "$VOL" ]; then
  err "Usage: $(basename "$0") /Volumes/<name> [windows-username]"
  printf '\nMounted volumes:\n' >&2; ls -1 /Volumes >&2
  exit 2
fi
[ -d "$VOL" ] || { err "'$VOL' is not a directory"; exit 1; }

# We only ever read here, so this is advisory. It must use the SOFT guard:
# assert_mounted_readonly() calls `exit 1` internally, so the old
# `assert_mounted_readonly "$VOL" || true` never reached the `|| true` and
# hard-exited the probe. A guard that exits cannot be made advisory by its
# caller — the guard itself has to return a status.
warn_if_not_readonly "$VOL" || true

banner "PROBE 40 — CONTENT SURVEY" "source: $VOL"

INDEX="$LOGS/fileindex-$(ts).txt"

step "Windows user profiles"
show "ls -1 $VOL/Users"
if [ ! -d "$VOL/Users" ]; then
  warn "No Users/ directory at '$VOL' — is this the Windows system partition?"
  ls -1 "$VOL" | head -20
  exit 1
fi
ls -1 "$VOL/Users" | grep -viE '^(Public|Default|Default User|All Users|desktop.ini)$' || true

WUSER="${2:-}"
if [ -z "$WUSER" ]; then
  WUSER="$(ls -1 "$VOL/Users" | grep -viE '^(Public|Default|Default User|All Users|desktop.ini)$' | head -1)"
  note "No username given; using '$WUSER'. Pass one explicitly to override."
fi
U="$VOL/Users/$WUSER"
[ -d "$U" ] || { err "Profile not found: $U"; exit 1; }
ok "Profile: $U"

pause "Ready to scan folder sizes (this is the slow part)"
step "Folder sizes"
warn "A full scan of a large NTFS volume through macOS's read-only driver is SLOW."
note "Tens of minutes is normal and is NOT a sign of a failing disk."
printf '\n'
for D in Desktop Documents Pictures Videos Downloads Music OneDrive; do
  [ -d "$U/$D" ] || continue
  printf '  %s  measuring %s ...%s' "$C_DIM" "$D" "$C_RST"
  SZ="$(du -sh "$U/$D" 2>/dev/null | awk '{print $1}')"
  printf '\r  %-14s %10s\n' "$D" "${SZ:-?}"
done

step "Building file index (one pass, reused by every check below)"
show "find \"$U\" -type f | xargs stat -f '%z %N' > $INDEX"
note "Live file count shown below; this is the long one."
printf '\n'

# Run the scan in the background so we can show a live count instead of
# leaving the operator staring at a blank terminal for ten minutes.
( find "$U" -type f -print0 2>/dev/null | xargs -0 stat -f '%z %N' 2>/dev/null >"$INDEX" ) &
SCAN_PID=$!
while kill -0 "$SCAN_PID" 2>/dev/null; do
  N="$(wc -l <"$INDEX" 2>/dev/null | tr -d ' ')"
  printf '\r  %s  indexed %s files ... %s%s' "$C_DIM" "${N:-0}" "$(clock)" "$C_RST"
  sleep 2
done
wait "$SCAN_PID" 2>/dev/null || true
printf '\r%*s\r' 70 ''

TOTAL="$(wc -l <"$INDEX" | tr -d ' ')"
BYTES="$(awk '{s+=$1} END{printf "%d", s+0}' "$INDEX")"
ok "$TOTAL files, $(human "$BYTES") total"
note "index -> $INDEX"

# `grep -c` PRINTS "0" and EXITS 1 when nothing matches. The old
# `grep -icE ... || echo 0` therefore emitted "0\n0" on an empty category,
# which then blew up `[ "$STUBS" -gt 0 ]` with "integer expression expected".
# And under `set -o pipefail`, a non-matching grep inside a pipeline made the
# whole function return non-zero, which under `set -e` killed the script from
# inside a command substitution. Both are fixed by swallowing grep's status
# and forcing a clean integer out of awk.
count_ext() { grep -icE "\.($1)\$" "$INDEX" 2>/dev/null | head -1 | tr -dc '0-9'; echo; }
size_ext()  { { grep -iE "\.($1)\$" "$INDEX" 2>/dev/null || true; } \
                | awk '{s+=$1} END{printf "%d", s+0}'; }

step "Breakdown by category"
printf '%-14s %10s %14s\n' "CATEGORY" "FILES" "SIZE"
for ROW in \
  "Photos:jpg|jpeg|heic|png|gif|bmp|tiff|raw|cr2|nef|dng" \
  "Videos:mp4|mov|avi|mkv|wmv|m4v|3gp|mts" \
  "Documents:pdf|doc|docx|xls|xlsx|ppt|pptx|txt|rtf|odt|csv" \
  "Audio:mp3|m4a|wav|flac|aac"
do
  LABEL="${ROW%%:*}"; PAT="${ROW#*:}"
  printf '%-14s %10s %14s\n' "$LABEL" "$(count_ext "$PAT")" "$(human "$(size_ext "$PAT")")"
done

step "OneDrive placeholder check  <- most important number in this probe"
# The single most important number here. Windows 11 "Files On-Demand" leaves
# cloud stubs on disk: the file exists, the data does not.
STUBS="$(awk '$1 < 8192' "$INDEX" | grep -icE '\.(jpg|jpeg|heic|png|mp4|mov|pdf|docx|xlsx)$' | head -1 | tr -dc '0-9')"
REAL="$(awk '$1 >= 8192' "$INDEX" | grep -icE '\.(jpg|jpeg|heic|png|mp4|mov|pdf|docx|xlsx)$' | head -1 | tr -dc '0-9')"
STUBS="${STUBS:-0}"; REAL="${REAL:-0}"
note "Suspiciously small media/doc files (<8 KB): $STUBS"
note "Normal-sized media/doc files:             $REAL"

if [ "$STUBS" -gt 0 ] && [ "$STUBS" -gt "$REAL" ]; then
  err "MOST FILES LOOK LIKE ONEDRIVE PLACEHOLDERS, NOT REAL DATA."
  note "The actual content lives in the OneDrive account, not on this drive."
  note "No local recovery tool can produce it — sign in to OneDrive and download."
  note "Copying now would spend hours transferring zero-byte stubs."
elif [ "$STUBS" -gt 0 ]; then
  warn "Some placeholders present ($STUBS). Mixed local/cloud storage."
  note "Verify a few open correctly before trusting the whole copy."
else
  ok "No placeholder pattern detected — files appear to be real local data."
fi

if [ -d "$U/OneDrive" ]; then
  warn "OneDrive folder present."
  note "On Windows 11, Desktop/Documents/Pictures are often redirected into it."
  note "If the normal folders look empty, the real data is under $U/OneDrive."
fi

step "20 largest files"
sort -rn "$INDEX" 2>/dev/null | head -20 | while read -r SZ PATHNAME; do
  printf '%12s  %s\n' "$(human "$SZ")" "${PATHNAME#$U/}"
done

step "iPhone capacity reality check"
PV_BYTES="$(( $(size_ext "jpg|jpeg|heic|png|gif|bmp|tiff|raw|cr2|nef|dng") + $(size_ext "mp4|mov|avi|mkv|wmv|m4v|3gp|mts") ))"
DOC_BYTES="$(size_ext "pdf|doc|docx|xls|xlsx|ppt|pptx|txt|rtf|odt|csv")"
note "Photos + videos : $(human "$PV_BYTES")"
note "Documents       : $(human "$DOC_BYTES")"
printf '\n'
note "Check the iPhone's free space: Settings > General > iPhone Storage."
if [ "$PV_BYTES" -gt 68719476736 ]; then
  warn "Photos/videos exceed 64 GB — will not fit on most phones as-is."
  note "Curate in $STAGING first, or use a shared cloud link instead of AirDrop."
fi

ok "Probe 40 complete."
finish
