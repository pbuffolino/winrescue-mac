#!/usr/bin/env bash
# Verify the copy is real and openable BEFORE anything gets erased.
# "A file that exists is not the same as a file that opens."
#
# READ-ONLY. Usage: ./scripts/03-verify.sh [~/Recovered/<user>]
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

DEST="${1:-$STAGING}"
[ -d "$DEST" ] || { err "Not a directory: $DEST"; exit 1; }

banner "VERIFY RECOVERED DATA" "target: $DEST"
FAILED=0

step "Totals"
cmd_ok du -sh "$DEST"
COUNT="$(find "$DEST" -type f 2>/dev/null | wc -l | tr -d ' ')"
show "find \"$DEST\" -type f | wc -l"
note "Files: $COUNT"
[ "$COUNT" -gt 0 ] || { err "No files found."; exit 1; }

step "Zero-byte files"
show "find \"$DEST\" -type f -size 0"
ZERO="$(find "$DEST" -type f -size 0 2>/dev/null | wc -l | tr -d ' ')"
if [ "$ZERO" -gt 0 ]; then
  warn "$ZERO zero-byte files (failed copies, or OneDrive stubs)."
  find "$DEST" -type f -size 0 2>/dev/null | head -10 | while IFS= read -r f; do
    note "${f#$DEST/}"
  done
  FAILED=1
else
  ok "No zero-byte files."
fi

step "OneDrive placeholder check"
show "find \"$DEST\" -type f \\( -iname '*.jpg' -o -iname '*.heic' \\) -size -8k"
STUBS="$(find "$DEST" -type f \( -iname '*.jpg' -o -iname '*.heic' -o -iname '*.mp4' \) -size -8k 2>/dev/null | wc -l | tr -d ' ')"
note "Suspiciously small media files: $STUBS  (want 0)"
[ "$STUBS" -eq 0 ] && ok "No placeholder pattern." || { warn "Placeholders present — real data may still be in OneDrive."; FAILED=1; }

step "File integrity spot-check"
# `file` reads magic bytes: a truncated or carved-but-broken file shows up here
# as "data" rather than a real type. This is the check that catches bad copies.
note "Reading magic bytes on a sample — truncated files report as 'data'."
printf '\n'
BAD=0; CHECKED=0
while IFS= read -r f; do
  CHECKED=$(( CHECKED + 1 ))
  TYPE="$(file -b "$f" 2>/dev/null)"
  case "$TYPE" in
    data|empty|"") printf '  %s[BAD]%s  %-46.46s %s\n' "$C_RED" "$C_RST" "$(basename "$f")" "$TYPE"; BAD=$(( BAD + 1 )) ;;
    *)             printf '  %s[ok]%s   %-46.46s %.34s\n' "$C_GRN" "$C_RST" "$(basename "$f")" "$TYPE" ;;
  esac
done <<EOF
$(find "$DEST" -type f \( -iname '*.jpg' -o -iname '*.heic' -o -iname '*.png' \
   -o -iname '*.mp4' -o -iname '*.mov' -o -iname '*.pdf' -o -iname '*.docx' \) 2>/dev/null | head -25)
EOF
printf '\n'
if [ "$BAD" -gt 0 ]; then
  err "$BAD of $CHECKED sampled files are unreadable/corrupt."
  FAILED=1
else
  ok "All $CHECKED sampled files have valid headers."
fi

step "Verdict"
if [ "$FAILED" -eq 0 ]; then
  ok "Copy looks good."
  note "Still open a few files by hand — Preview for photos, Pages/Word for a doc."
  printf '\n'
  note "Only after that: transfer to the iPhone, then confirm on the phone"
  note "BEFORE erasing the M.2. Until then the source is the only copy."
else
  warn "Issues found above. Do NOT erase the source drive."
  note "Re-run ./scripts/02-copy.sh to retry — rsync resumes and fills gaps."
fi
finish
[ "$FAILED" -eq 0 ] || exit 1
