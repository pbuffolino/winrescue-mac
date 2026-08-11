#!/usr/bin/env bash
# Safety-guard test suite.
#
# This is the most important test in the repo. The project's central claim is
# "never writes to the source drive", and these tests are what make that claim
# checkable rather than aspirational. CI runs them on every pull request.
#
# Runs anywhere bash does -- no disks are touched and no macOS-only tools are
# required, so it works on a Linux CI runner.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/lib/common.sh
. "$HERE/../scripts/lib/common.sh"

PASS=0
FAIL=0

t_blocked() {   # a command that MUST be refused with exit 99
  local desc="$1"; shift
  ( refuse_destructive "$@" ) >/dev/null 2>&1
  if [ $? -eq 99 ]; then
    PASS=$((PASS + 1)); printf '  ok       blocked: %s\n' "$desc"
  else
    FAIL=$((FAIL + 1)); printf '  NOT OK   ALLOWED THROUGH: %s -- %s\n' "$desc" "$*"
  fi
}

t_allowed() {   # a read-only command that MUST pass
  local desc="$1"; shift
  ( refuse_destructive "$@" ) >/dev/null 2>&1
  if [ $? -eq 0 ]; then
    PASS=$((PASS + 1)); printf '  ok       allowed: %s\n' "$desc"
  else
    FAIL=$((FAIL + 1)); printf '  NOT OK   WRONGLY BLOCKED: %s -- %s\n' "$desc" "$*"
  fi
}

t_dest_refused() {
  local d="$1"
  ( assert_not_source "$d" ) >/dev/null 2>&1
  if [ $? -ne 0 ]; then
    PASS=$((PASS + 1)); printf '  ok       destination refused: %s\n' "$d"
  else
    FAIL=$((FAIL + 1)); printf '  NOT OK   DESTINATION ACCEPTED: %s\n' "$d"
  fi
}

t_dest_ok() {
  local d="$1"
  ( assert_not_source "$d" ) >/dev/null 2>&1
  if [ $? -eq 0 ]; then
    PASS=$((PASS + 1)); printf '  ok       destination accepted: %s\n' "$d"
  else
    FAIL=$((FAIL + 1)); printf '  NOT OK   DESTINATION REFUSED: %s\n' "$d"
  fi
}

echo "== destructive commands must be refused =="
t_blocked "eraseDisk"        diskutil eraseDisk JHFS+ Name /dev/disk9
t_blocked "eraseVolume"      diskutil eraseVolume free n /dev/disk9s1
t_blocked "partitionDisk"    diskutil partitionDisk /dev/disk9 1 GPT JHFS+ N R
t_blocked "reformat"         diskutil reformat /dev/disk9s1
t_blocked "zeroDisk"         diskutil zeroDisk /dev/disk9
t_blocked "repairDisk"       diskutil repairDisk /dev/disk9
t_blocked "repairVolume"     diskutil repairVolume /dev/disk9s1
t_blocked "fsck"             fsck /dev/disk9s1
t_blocked "fsck_msdos -y"    fsck_msdos -y /dev/disk9s1
t_blocked "fsck_exfat"       fsck_exfat -y /dev/disk9s1
t_blocked "newfs_msdos"      newfs_msdos /dev/disk9s1
t_blocked "newfs_hfs"        newfs_hfs /dev/disk9s1
t_blocked "mkfs.ntfs"        mkfs.ntfs /dev/disk9s1
t_blocked "rm -rf /Volumes"  rm -rf /Volumes/Untitled
t_blocked "rm -r /Volumes"   rm -r /Volumes/Untitled

echo
echo "== dd may only ever READ =="
t_blocked "dd to a device"        dd if=/dev/zero of=/dev/disk9
t_blocked "dd to a file"          dd if=/dev/rdisk9 of=/tmp/image.img
# Regression: a substring match on "of=/dev/null" also accepts this real file.
t_blocked "dd of=/dev/null.img"   dd if=/dev/rdisk9 of=/dev/null.img
t_blocked "dd of=/dev/nullx"      dd if=/dev/rdisk9 of=/dev/nullx
t_allowed "dd of=/dev/null"       dd if=/dev/rdisk9 of=/dev/null bs=1m count=1

echo
echo "== read-only operations must pass =="
t_allowed "diskutil list"         diskutil list
t_allowed "diskutil info"         diskutil info /dev/disk9
t_allowed "mount readOnly"        diskutil mount readOnly /dev/disk9s1
t_allowed "rsync to \$HOME"       rsync -a /src "$HOME/Recovered"
t_allowed "unmountDisk"           diskutil unmountDisk /dev/disk9

echo
echo "== destination guard =="
t_dest_refused "/Volumes/Source/out"
t_dest_refused "/Volumes/anything"
t_dest_ok      "$HOME/Recovered"
t_dest_ok      "/tmp/recovered-test"

echo
echo "== soft guard returns instead of exiting =="
# Regression: assert_mounted_readonly exits internally, so `|| true` on it is
# dead code. Read-only probes must use the soft form.
( warn_if_not_readonly "/definitely/not/a/mount" ) >/dev/null 2>&1
if [ $? -ne 0 ]; then
  PASS=$((PASS + 1)); echo "  ok       warn_if_not_readonly returned non-zero without exiting"
else
  FAIL=$((FAIL + 1)); echo "  NOT OK   warn_if_not_readonly should report a non-read-only mount"
fi

echo
echo "== repo path derives from file location, not a hardcoded path =="
EXPECT="$(cd "$HERE/.." && pwd)"
if [ "$REPO" = "$EXPECT" ]; then
  PASS=$((PASS + 1)); echo "  ok       REPO resolves to $REPO"
else
  FAIL=$((FAIL + 1)); echo "  NOT OK   REPO=$REPO expected $EXPECT"
fi
case "$STAGING" in
  "$REPO"/*) FAIL=$((FAIL + 1)); echo "  NOT OK   STAGING is inside the repo: $STAGING" ;;
  *)         PASS=$((PASS + 1)); echo "  ok       STAGING is outside the repo: $STAGING" ;;
esac

echo
echo "== no script may contain a destructive command =="
# Greps the scripts themselves, so a careless edit is caught in review rather
# than at 2am against someone's only copy of their data.
OFFENDERS=0
while IFS= read -r f; do
  case "$f" in */lib/common.sh|*/tests/*) continue ;; esac
  if grep -nE '(diskutil[[:space:]]+(erase|partition|reformat|zero|repair))|(^|[^_[:alnum:]])(fsck|newfs_[a-z]+|mkfs\.[a-z]+)[[:space:]]|of=/dev/r?disk' "$f" \
       | grep -vE '^\s*[0-9]+:\s*#' | grep -qE '.'; then
    echo "  NOT OK   destructive pattern in $f:"
    grep -nE '(diskutil[[:space:]]+(erase|partition|reformat|zero|repair))|(^|[^_[:alnum:]])(fsck|newfs_[a-z]+|mkfs\.[a-z]+)[[:space:]]|of=/dev/r?disk' "$f" \
      | grep -vE '^\s*[0-9]+:\s*#' | sed 's/^/             /'
    OFFENDERS=$((OFFENDERS + 1))
  fi
done < <(find "$HERE/.." -name '*.sh' -not -path '*/venv/*' -not -path '*/.git/*')
if [ "$OFFENDERS" -eq 0 ]; then
  PASS=$((PASS + 1)); echo "  ok       no destructive commands in any script"
else
  FAIL=$((FAIL + 1))
fi

echo
echo "=================================================="
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || { echo "SAFETY TESTS FAILED — do not merge."; exit 1; }
echo "All safety guards hold."
