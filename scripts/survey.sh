#!/usr/bin/env bash
# SURVEY — orchestrator. Runs every read-only probe and writes docs/00-diagnosis.md.
#
# This is the first thing to run. It installs nothing, mounts nothing, and
# writes nothing outside this repo. Run it before deciding on any tooling.
#
# Usage: ./scripts/survey.sh <diskX> [/Volumes/<name>]
set -uo pipefail   # not -e: probes signal findings via exit codes we want to read
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SD/lib/common.sh"

require_disk_arg "${1:-}"
DISK="$(norm_disk "$1")"
VOL="${2:-}"

REPORT="$DOCS/00-diagnosis.md"
RAW="$LOGS/survey-$DISK-$(ts).txt"
STAMP="$(date '+%Y-%m-%d %H:%M:%S')"

printf 'Survey of /dev/%s — %s\n' "$DISK" "$STAMP" | tee "$RAW"
note "Raw transcript -> $RAW"

run_probe() {
  local script="$1"; shift
  printf '\n\n########## %s ##########\n' "$script" >>"$RAW"
  "$SD/$script" "$@" 2>&1 | tee -a "$RAW"
  return "${PIPESTATUS[0]}"
}

# Root is needed to READ raw devices (/dev/rdiskN). Prime the credential once
# here: probes 20 and 30 issue ~70 sudo calls, and probe 20's progress line
# uses \r, which would overwrite the password prompt mid-scan.
step "Priming sudo (needed only to READ raw devices; nothing is written)"
sudo -v || { err "sudo is required to read /dev/rdisk$DISK."; exit 1; }

run_probe probe-10-identity.sh   "$DISK"; RC10=$?
run_probe probe-20-health.sh     "$DISK"; RC20=$?
run_probe probe-30-filesystem.sh "$DISK"; RC30=$?

RC40="skipped"
if [ -n "$VOL" ]; then
  run_probe probe-40-content.sh "$VOL"; RC40=$?
fi

# ---------- interpret ----------
# Every exit code is mapped explicitly and there is a catch-all. An unmapped
# code must NEVER render as a clean bill of health: this report is the
# deliverable, and "Plain NTFS / Phase 1" on a drive that is actually
# encrypted or unreadable sends the operator down a path that cannot work.
case "$RC20" in
  0)  HEALTH="OK" ;;
  10) HEALTH="CONCERN — image with ddrescue before anything else" ;;
  *)  HEALTH="UNKNOWN (probe 20 exit $RC20) — see transcript" ;;
esac

case "$RC30" in
  0)  CRYPTO="Plain NTFS, not encrypted" ;;
  20) CRYPTO="BITLOCKER — run probe-50 before assuming a key is needed" ;;
  21) CRYPTO="UNIDENTIFIED filesystem — needs the no-mount path" ;;
  22) CRYPTO="NTFS with a DAMAGED BOOT SECTOR — recoverable, do not repair" ;;
  *)  CRYPTO="UNKNOWN (probe 30 exit $RC30) — see transcript" ;;
esac

case "$RC30" in
  20) NEXT="Run ./scripts/probe-50-bitlocker.py /dev/${DISK}s3 FIRST. A suspended
volume carries a clear key and unlocks with no recovery key at all. Only if
probe 50 reports no clear key does the owner need to fetch their key." ;;
  21|22) NEXT="Do NOT mount or repair. Use the no-mount path:
./scripts/04-list-nomount.py then ./scripts/05-extract-nomount.py" ;;
  0)  if [ "$RC20" -eq 10 ]; then
        NEXT="Phase 3 — image with ddrescue first, then recover from the image."
      else
        NEXT="Phase 1 — ./scripts/01-mount-ro.sh, then ./scripts/02-copy.sh"
      fi ;;
  *)  NEXT="STOP. Probe 30 returned an unmapped code ($RC30). Read the raw
transcript before touching the drive further." ;;
esac

# ---------- report ----------
{
  printf '# Diagnosis — /dev/%s\n\n' "$DISK"
  printf '_Generated %s by `scripts/survey.sh`. All probes read-only._\n\n' "$STAMP"
  printf '## Summary\n\n'
  printf '| Check | Result |\n|---|---|\n'
  printf '| Identity (probe 10) | exit %s |\n' "$RC10"
  printf '| Health (probe 20) | %s |\n' "$HEALTH"
  printf '| Filesystem (probe 30) | %s |\n' "$CRYPTO"
  printf '| Content (probe 40) | %s |\n\n' "$RC40"
  printf '**Next step:** %s\n\n' "$NEXT"
  printf '## Raw transcript\n\n`%s`\n\n' "$RAW"
  printf '## Full output\n\n```\n'
  cat "$RAW"
  printf '\n```\n'
} >"$REPORT"

hdr "Survey complete"
note "Health     : $HEALTH"
note "Filesystem : $CRYPTO"
printf '\n'
ok "Report -> $REPORT"
note "Next: $NEXT"
note "Record the outcome in RECOVERY-LOG.md."
