#!/usr/bin/env bash
# PREFLIGHT — check this machine can actually run a recovery, before a real
# drive is on the line. Touches no disks. Safe to run any time.
#
# Usage: ./scripts/00-preflight.sh
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

[ "${1:-}" = "--gta-vi" ] && { _gta_vi; exit 0; }

banner "PREFLIGHT — environment and dependency check" "no drive is touched"
PROBLEMS=0
WARNINGS=0

step "macOS"
SW="$(sw_vers -productVersion 2>/dev/null)"
note "macOS $SW  ($(uname -m))"
case "${SW%%.*}" in
  1[3-9]|2[0-9]) ok "Supported." ;;
  *) warn "Developed on macOS 13+ / 26.x. Older versions may differ."; WARNINGS=$((WARNINGS+1)) ;;
esac

step "NTFS support on this machine"
# Documenting reality rather than assuming it: on macOS 26 there is no
# mount_ntfs at all, which is why the no-mount path exists.
if [ -x /sbin/mount_ntfs ]; then
  ok "/sbin/mount_ntfs present — read-only NTFS mounts may work."
else
  warn "No /sbin/mount_ntfs (expected on macOS 26; NTFS moved to UserFS)."
  note "A dirty NTFS volume CANNOT be force-mounted. Use the no-mount path:"
  note "  scripts/04-list-nomount.py / 05-extract-nomount.py"
  WARNINGS=$((WARNINGS+1))
fi
if [ -d /System/Library/Filesystems/ntfs.fs ]; then
  IMPL="$(plutil -p /System/Library/Filesystems/ntfs.fs/Contents/Info.plist 2>/dev/null \
          | awk '/FSImplementation/{getline; gsub(/[",]/,""); print $3; exit}')"
  note "ntfs.fs FSImplementation: ${IMPL:-unknown}"
fi

step "sudo (needed ONLY to read raw devices)"
if sudo -n true 2>/dev/null; then
  ok "sudo works without a prompt."
elif [ -f /etc/pam.d/sudo_local ] && grep -q pam_tid /etc/pam.d/sudo_local 2>/dev/null; then
  ok "Touch ID for sudo is configured (/etc/pam.d/sudo_local)."
else
  warn "sudo will prompt for a password."
  note "In a non-interactive or agent-driven session sudo CANNOT prompt"
  note "('a terminal is required'). Either run from a normal Terminal, or:"
  note "  echo 'auth sufficient pam_tid.so' | sudo tee /etc/pam.d/sudo_local"
  WARNINGS=$((WARNINGS+1))
fi

step "Python environment"
VENV="$REPO/venv/bin/python"
if [ -x "$VENV" ]; then
  ok "venv present: $VENV  ($("$VENV" -V 2>&1))"
  for MOD in dissect.ntfs dissect.fve cryptography; do
    if "$VENV" -c "import ${MOD//./_} " 2>/dev/null || \
       "$VENV" -c "import $MOD" 2>/dev/null; then
      VER="$("$VENV" -c "import $MOD,sys; print(getattr($MOD,'__version__','?'))" 2>/dev/null)"
      ok "  $MOD ${VER:-installed}"
    else
      err "  $MOD MISSING"
      PROBLEMS=$((PROBLEMS+1))
    fi
  done
else
  err "No venv. The no-mount and BitLocker paths will not run."
  note "  python3 -m venv venv && ./venv/bin/pip install -r requirements.txt"
  PROBLEMS=$((PROBLEMS+1))
fi

step "Optional command-line tools"
for T in smartctl ddrescue photorec testdisk; do
  if have "$T"; then ok "  $T"; else note "  $T not installed (brew install smartmontools ddrescue testdisk)"; fi
done
if have dislocker; then
  warn "dislocker is installed. It is not used and not needed here;"
  note "on Apple Silicon it pulls toward macFUSE, which reduces boot security."
  WARNINGS=$((WARNINGS+1))
fi
if kmutil showloaded 2>/dev/null | grep -qi fuse || \
   [ -d /Library/Filesystems/macfuse.fs ]; then
  warn "macFUSE appears to be present. This toolset does not need it."
  WARNINGS=$((WARNINGS+1))
else
  ok "No macFUSE / FUSE kernel extension — boot security intact."
fi

step "Safety guards (self-test)"
# Delegates to the real suite instead of keeping a second, smaller copy of the
# cases here. Two lists drift, and the one that drifts is always the one nobody
# runs -- which for a safety guard is the whole ballgame. CI runs the same file.
GUARD_TESTS="$REPO/tests/test-guards.sh"
if [ -f "$GUARD_TESTS" ]; then
  if GUARD_OUT="$(bash "$GUARD_TESTS" 2>&1)"; then
    ok "$(printf '%s' "$GUARD_OUT" | grep -E '^passed ' | head -1)"
    ok "All safety guards hold (tests/test-guards.sh)"
  else
    err "SAFETY GUARD TESTS FAILED — do not use this checkout."
    printf '%s\n' "$GUARD_OUT" | grep -E 'NOT OK|failed' | head -20
    PROBLEMS=$((PROBLEMS+1))
  fi
else
  err "tests/test-guards.sh is missing — cannot verify the safety guards."
  PROBLEMS=$((PROBLEMS+1))
fi

step "Staging destination"
note "Staging is $STAGING (deliberately outside this repo)"
FREE="$(df -k "$HOME" | awk 'NR==2{print $4*1024}')"
note "Free space on \$HOME: $(human "$FREE")"
( assert_not_source "$STAGING" ) >/dev/null 2>&1 \
  && ok "assert_not_source accepts the staging path" \
  || { err "assert_not_source rejects \$STAGING"; PROBLEMS=$((PROBLEMS+1)); }
( assert_not_source "/Volumes/AnyMountedVolume/x" ) >/dev/null 2>&1 \
  && { err "assert_not_source failed to reject /Volumes"; PROBLEMS=$((PROBLEMS+1)); } \
  || ok "assert_not_source rejects /Volumes destinations"

step "Attached disks"
diskutil list 2>/dev/null | grep -E '^/dev/disk.*(external|physical)' || note "(none)"

step "Verdict"
if [ "$PROBLEMS" -gt 0 ]; then
  err "$PROBLEMS blocking problem(s). Fix before running a recovery."
  finish; exit 1
fi
ok "Ready. $WARNINGS warning(s)."
printf '\n'
note "Next:"
show "diskutil list"
show "./scripts/survey.sh <diskX>"
finish
