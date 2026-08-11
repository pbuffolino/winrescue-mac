#!/usr/bin/env bash
# Shared paths, output helpers, and the one safety guard that matters.
# Sourced by every script — the "never write to source" rule lives here, once.
#
# Targets bash 3.2 (what macOS ships at /bin/bash). No associative arrays,
# no ${var,,}, no mapfile.

# Derived from this file's own location, NOT hardcoded -- the repo has to work
# from any clone path, for any user, under any directory name.
#
# BASH_SOURCE is a bash-ism. Sourced from zsh (the macOS default shell) it is
# unset, `dirname ""` returns ".", and REPO silently resolves to two levels
# above the CURRENT directory -- which for someone standing in the repo root is
# $HOME. `mkdir -p "$LOGS" "$DOCS"` below then litters their home directory.
# Fail loudly rather than guess: a path helper that is wrong in silence is
# exactly how a destination guard ends up pointing somewhere it should not.
if [ -z "${BASH_SOURCE[0]:-}" ]; then
  printf 'common.sh must be sourced from bash, not %s.\n' "${SHELL##*/}" >&2
  printf 'Run the scripts directly (./scripts/00-preflight.sh), or use:\n' >&2
  printf '  bash -c ". <repo>/scripts/lib/common.sh; ..."\n' >&2
  return 1 2>/dev/null || exit 1
fi
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAGING="${STAGING:-$HOME/Recovered}"   # deliberately OUTSIDE the repo
LOGS="$REPO/logs"
DOCS="$REPO/docs"

mkdir -p "$LOGS" "$DOCS"

# ---------- output ----------
# Colour only when attached to a terminal, so tee'd logs stay clean.
if [ -t 1 ]; then
  C_RST=$'\033[0m'; C_B=$'\033[1m';   C_DIM=$'\033[2m'
  C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_RED=$'\033[31m'
  C_CYN=$'\033[36m'; C_MAG=$'\033[35m'
else
  C_RST=''; C_B=''; C_DIM=''; C_GRN=''; C_YEL=''; C_RED=''; C_CYN=''; C_MAG=''
fi

RULE="$(printf '%0.s-' $(seq 1 74))"

hdr()  { printf '\n%s%s== %s ==%s\n' "$C_B" "$C_CYN" "$*" "$C_RST"; }
ok()   { printf '%s  [OK]%s   %s\n'   "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s  [WARN]%s %s\n'   "$C_YEL" "$C_RST" "$*"; }
err()  { printf '%s  [FAIL]%s %s\n'   "$C_RED" "$C_RST" "$*" >&2; }
note() { printf '         %s\n' "$*"; }

ts()    { date +%Y%m%d-%H%M%S; }
clock() { date '+%H:%M:%S'; }

# ---------- guided-session output ----------
# The user runs these interactively and needs to see exactly what is happening.
STEP_N=0
SCRIPT_T0="$(date +%s)"

banner() {
  printf '\n%s%s\n' "$C_B" "$RULE"
  printf '  %s\n' "$1"
  [ -n "${2:-}" ] && printf '  %s%s%s\n' "$C_DIM" "$2" "$C_B"
  printf '%s%s\n' "$RULE" "$C_RST"
  printf '  %sREAD-ONLY: this script never writes to, repairs, or modifies the source.%s\n' "$C_DIM" "$C_RST"
  printf '  %sstarted %s%s\n\n' "$C_DIM" "$(clock)" "$C_RST"
}

step() {
  STEP_N=$(( STEP_N + 1 ))
  printf '\n%s%s[%02d] %s%s  %s(%s)%s\n' \
    "$C_B" "$C_MAG" "$STEP_N" "$*" "$C_RST" "$C_DIM" "$(clock)" "$C_RST"
  printf '%s%s%s\n' "$C_DIM" "$RULE" "$C_RST"
}

# Echo the exact command, then run it — screened through the destructive
# blocklist first. This is what makes a guided session auditable: you see the
# command before it executes.
cmd() {
  refuse_destructive "$@"
  printf '%s  $ %s%s\n' "$C_DIM" "$*" "$C_RST"
  "$@"
}

# Same, but tolerate failure (for probes where "no output" is a valid result).
cmd_ok() {
  refuse_destructive "$@"
  printf '%s  $ %s%s\n' "$C_DIM" "$*" "$C_RST"
  "$@" || true
}

# Show a command without running it — for describing the next manual step.
show() { printf '%s  $ %s%s\n' "$C_DIM" "$*" "$C_RST"; }

# In guided mode (GUIDED=1) pause between phases so the operator can read.
pause() {
  [ "${GUIDED:-0}" = "1" ] || return 0
  [ -t 0 ] || [ -e /dev/tty ] || return 0
  printf '\n%s  >> %s  [Enter to continue, Ctrl-C to stop]%s ' \
    "$C_YEL" "${1:-Continue?}" "$C_RST"
  read -r _ </dev/tty || true
  printf '\n'
}

finish() {
  local secs=$(( $(date +%s) - SCRIPT_T0 ))
  printf '\n%s%s%s\n' "$C_DIM" "$RULE" "$C_RST"
  printf '  %sfinished %s — %dm %02ds elapsed%s\n\n' \
    "$C_DIM" "$(clock)" "$(( secs / 60 ))" "$(( secs % 60 ))" "$C_RST"
}

# ============================================================================
# SAFETY — enforced, not merely documented.
#
# This toolset must NEVER execute a destructive command. The rules below are
# active guards, so a typo or a careless edit fails closed instead of
# destroying the only copy of someone's data.
#
# Categorically never used anywhere in this repo:
#   diskutil eraseDisk / eraseVolume / partitionDisk / reformat / zeroDisk
#   diskutil repairDisk / repairVolume      (these WRITE to the filesystem)
#   fsck / fsck_msdos / fsck_exfat -y       (fsck repairs = writes)
#   newfs_* / mkfs.*  |  dd of=/dev/disk*   |  rm -rf on /Volumes/*
#   mount without an explicit read-only flag
# ============================================================================

# Refuse any destination that could land on the source.
#
# /Volumes/* is the obvious case, but it is not sufficient: an explicit mount
# can put a source volume anywhere. So this also refuses any path that is at
# or under a CURRENTLY MOUNTED non-root filesystem, which catches
# $HOME/some-mount as well as /Volumes/*. Checked against the live mount
# table rather than a hardcoded list of paths.
assert_not_source() {
  local dest="$1" mp
  case "$dest" in
    /Volumes/*)
      err "REFUSING: '$dest' is under /Volumes — that may be the source drive."
      err "This toolset never writes to the source. Pick a destination under \$HOME."
      exit 1 ;;
  esac
  # Any other active mount point (excluding /, /System/Volumes/Data and friends).
  while IFS= read -r mp; do
    case "$mp" in
      /|/System/Volumes/*|/dev|/private/var/vm) continue ;;
    esac
    case "$dest/" in
      "$mp"/*)
        err "REFUSING: '$dest' is on the mounted filesystem '$mp'."
        err "That could be the source. Pick a destination on the internal disk."
        exit 1 ;;
    esac
  done <<EOF
$(mount | awk '{for (i=1;i<=NF;i++) if ($i=="on") {p=""; for (j=i+1;j<NF;j++) {if ($j=="(") break; p=p (p?" ":"") $j} print p; break}}' 2>/dev/null)
EOF
}

# Hard blocklist. Any command assembled at runtime is screened through this.
# Fails closed: if it looks destructive, we exit rather than guess.
refuse_destructive() {
  local cmd="$*"
  case "$cmd" in
    *"eraseDisk"*|*"eraseVolume"*|*"partitionDisk"*|*"reformat"*|*"zeroDisk"*|\
    *"repairDisk"*|*"repairVolume"*|*"newfs"*|*"mkfs"*|\
    *"fsck"*|*"rm -rf /Volumes"*|*"rm -r /Volumes"*)
      err "BLOCKED destructive command: $cmd"
      err "This toolset is read-only by construction. Refusing."
      exit 99
      ;;
  esac
  # dd is only ever allowed to READ: if= is fine, of= must be exactly
  # /dev/null. Matched on a word boundary, not as a substring -- a plain
  # *"of=/dev/null"* glob also accepts `of=/dev/null.img`, which is a real
  # file and a real overwrite.
  case " $cmd " in
    *" dd "*"of="*)
      case " $cmd " in
        *" of=/dev/null "*) : ;;
        *) err "BLOCKED: dd with a real of= target: $cmd"
           err "dd is used for reading only (of=/dev/null). Refusing."
           exit 99 ;;
      esac
      ;;
  esac
}

# Run a command only after screening it. Use for anything touching a device.
safe_run() { refuse_destructive "$@"; "$@"; }

# Is a mount point genuinely read-only? Returns a status; prints nothing.
# Callers decide what to do about it — a read-only probe can warn, a script
# that writes must refuse.
is_mounted_readonly() {
  mount | grep -F " on ${1} " | grep -q "read-only"
}

# Hard form: refuse to continue unless the mount really is read-only.
# Use this in anything that will subsequently write.
assert_mounted_readonly() {
  local mp="$1"
  if is_mounted_readonly "$mp"; then
    ok "Confirmed read-only mount: $mp"
  else
    err "'$mp' is NOT mounted read-only. Refusing to continue."
    err "Unmount it and use scripts/01-mount-ro.sh."
    exit 1
  fi
}

# Soft form: report, but let a read-only caller carry on.
# Returns non-zero if the mount is not read-only.
warn_if_not_readonly() {
  local mp="$1"
  if is_mounted_readonly "$mp"; then
    ok "Confirmed read-only mount: $mp"
    return 0
  fi
  warn "'$mp' is not mounted read-only."
  note "This probe only reads, so it will continue — but nothing else should"
  note "run against this volume until it is remounted with 01-mount-ro.sh."
  return 1
}

# ---------- disk helpers ----------
# Accepts disk4, /dev/disk4, or /dev/rdisk4 and returns the bare identifier.
norm_disk() {
  local d="${1:-}"
  d="${d#/dev/}"
  d="${d#r}"
  printf '%s' "$d"
}

require_disk_arg() {
  if [ -z "${1:-}" ]; then
    err "Usage: $(basename "${0:-script}") <diskX>    e.g. disk4"
    printf '\nAttached disks:\n' >&2
    diskutil list 2>/dev/null | grep -E '^/dev/disk' >&2 || true
    exit 2
  fi
}

disk_exists() { diskutil info "/dev/$1" >/dev/null 2>&1; }

disk_size_bytes() {
  diskutil info -plist "/dev/$1" 2>/dev/null \
    | plutil -extract Size raw - 2>/dev/null || echo 0
}

# List partition identifiers (disk4s1, disk4s2, ...) for a whole disk.
disk_partitions() {
  diskutil list "/dev/$1" 2>/dev/null \
    | awk -v d="$1" '$NF ~ "^"d"s[0-9]+$" { print $NF }'
}

human() {
  awk -v b="${1:-0}" 'BEGIN{
    split("B KB MB GB TB PB", u, " ");
    i=1; while (b >= 1024 && i < 6) { b /= 1024; i++ }
    printf (i==1 ? "%d %s" : "%.2f %s"), b, u[i]
  }'
}

# ---------- volume header forensics (all pure reads) ----------
# Every function here reads sectors off /dev/rdiskXsY and writes nothing.
# sudo is required to open a raw device; that is its only purpose.

# Read bytes 3-10 of a partition's FIRST sector (the filesystem OEM ID).
# NTFS -> "NTFS    " | BitLocker -> "-FVE-FS-" | Windows FAT32 -> "MSWIN4.1"
volume_oem_id() {
  sudo dd if="/dev/r$1" bs=512 count=1 2>/dev/null \
    | head -c 11 | tail -c 8 | LC_ALL=C tr -c '[:print:]' '.'
}

# Same 8 bytes, but from the partition's LAST sector.
#
# NTFS mirrors its boot sector there. "NTFS    " in the backup while the
# primary is garbage is the signature of a DAMAGED BOOT SECTOR -- which is
# recoverable, and is decisively NOT BitLocker. This one read separates the
# two diagnoses that need opposite responses.
backup_oem_id() {
  local part="$1" bytes sectors
  bytes="$(disk_size_bytes "$part")"
  [ "${bytes:-0}" -gt 512 ] || { printf '(unreadable)'; return 1; }
  sectors=$(( bytes / 512 ))
  sudo dd if="/dev/r$part" bs=512 count=1 skip=$(( sectors - 1 )) 2>/dev/null \
    | head -c 11 | tail -c 8 | LC_ALL=C tr -c '[:print:]' '.'
}

# Does the head of this partition carry BitLocker's FVE metadata?
#
# Checked positively rather than inferred from a failed NTFS probe, because
# "macOS could not identify it" has several causes and only one of them is
# encryption. Two independent markers in the first 64 KiB:
#   - the ASCII signature "-FVE-FS-"
#   - the BitLocker volume GUID 4967D63B-2E29-4AD8-8399-F6A339E3D00{0,1}
#     (mixed-endian on disk: 3b d6 67 49 29 2e d8 4a 83 99 f6 a3 39 e3 d0 ..)
# Echoes the markers found; returns 0 if any were.
fve_markers() {
  local part="$1" head_hex found=""
  head_hex="$(sudo dd if="/dev/r$part" bs=512 count=128 2>/dev/null \
                | xxd -p | tr -d '\n')"
  [ -n "$head_hex" ] || { printf '(unreadable)'; return 1; }

  # "-FVE-FS-" as hex
  case "$head_hex" in
    *2d4656452d46532d*) found="-FVE-FS- signature" ;;
  esac
  case "$head_hex" in
    *3bd66749292ed84a8399f6a339e3d0*)
      found="${found:+$found, }BitLocker volume GUID" ;;
  esac

  if [ -n "$found" ]; then printf '%s' "$found"; return 0; fi
  printf 'none'; return 1
}

# Shannon entropy, in bits per byte, of a 64 KiB sample at a byte offset.
#
# The tie-breaker when headers are ambiguous. Encrypted data is uniformly
# random and lands at ~7.99 everywhere. Real filesystem content is structured
# and varies -- zero runs read 0.00, text ~4.5, already-compressed media ~7.9.
# A volume that reads ~8.00 at EVERY sample point is encrypted whatever its
# header claims; one that varies is not.
sample_entropy() {
  local part="$1" skip_sectors="$2"
  sudo dd if="/dev/r$part" bs=512 count=128 skip="$skip_sectors" 2>/dev/null \
    | od -An -tu1 -v 2>/dev/null \
    | awk '
        { for (i = 1; i <= NF; i++) { h[$i]++; n++ } }
        END {
          if (n == 0) { print "n/a"; exit }
          e = 0
          for (b in h) { p = h[b] / n; e -= p * log(p) / log(2) }
          printf "%.2f", e
        }'
}

# Fraction of a sample that is zero bytes — distinguishes "unallocated" from
# "encrypted": encrypted volumes have essentially no zero runs.
sample_zero_pct() {
  local part="$1" skip_sectors="$2"
  sudo dd if="/dev/r$part" bs=512 count=128 skip="$skip_sectors" 2>/dev/null \
    | od -An -tu1 -v 2>/dev/null \
    | awk '
        { for (i = 1; i <= NF; i++) { n++; if ($i == 0) z++ } }
        END { if (n == 0) print "n/a"; else printf "%.1f", (z * 100) / n }'
}

# Classify an OEM ID.
#
# NOTE on "MSWIN4.1": that is the OEM ID Windows stamps on ORDINARY FAT32
# volumes -- including the EFI system partition of every Windows install. It
# is NOT by itself a BitLocker-To-Go marker. Treating it as one made probe 30
# flag the EFI partition of a healthy disk as encrypted, which set
# FOUND_BITLOCKER and reported the entire drive as BitLocker. A To Go volume
# is FAT32 *plus* FVE metadata, so the caller must confirm with fve_markers().
classify_oem() {
  case "$1" in
    "NTFS    ") printf 'NTFS (not encrypted)' ;;
    "-FVE-FS-") printf 'BITLOCKER ENCRYPTED' ;;
    "EXFAT   ") printf 'exFAT' ;;
    "MSWIN4.1") printf 'FAT32 (Windows-formatted)' ;;
    MSDOS*)     printf 'FAT' ;;
    *)          printf 'unknown/other' ;;
  esac
}

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Easter egg. Reachable via `./scripts/00-preflight.sh --gta-vi`.
# Undocumented on purpose. Touches nothing, reads nothing, writes nothing.
# ---------------------------------------------------------------------------
_gta_vi() {
  printf '\n%s%s\n' "$C_B$C_CYN" "$RULE"
  cat <<'ART'
        ██╗    ██╗██╗███╗   ██╗██████╗ ███████╗███████╗ ██████╗██╗   ██╗███████╗
        ██║    ██║██║████╗  ██║██╔══██╗██╔════╝██╔════╝██╔════╝██║   ██║██╔════╝
        ██║ █╗ ██║██║██╔██╗ ██║██████╔╝█████╗  ███████╗██║     ██║   ██║█████╗
        ██║███╗██║██║██║╚██╗██║██╔══██╗██╔══╝  ╚════██║██║     ██║   ██║██╔══╝
        ╚███╔███╔╝██║██║ ╚████║██║  ██║███████╗███████║╚██████╗╚██████╔╝███████╗
         ╚══╝╚══╝ ╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝╚══════╝╚══════╝ ╚═════╝ ╚═════╝ ╚══════╝
ART
  printf '%s%s%s\n\n' "$C_B$C_CYN" "$RULE" "$C_RST"
  printf '  %sESTIMATED TIME REMAINING%s\n' "$C_B" "$C_RST"
  printf '  %s\n' "------------------------------------------------------------"
  printf '  %-28s %s[████████████████████]%s  %s\n' \
    "Unlock BitLocker volume" "$C_GRN" "$C_RST" "done"
  printf '  %-28s %s[████████████████████]%s  %s\n' \
    "Decrypt 237 GB @ 92 MB/s" "$C_GRN" "$C_RST" "46 min"
  printf '  %-28s %s[████████████████████]%s  %s\n' \
    "Verify + hand back" "$C_GRN" "$C_RST" "11 sec"
  printf '  %-28s %s[███░░░░░░░░░░░░░░░░░]%s  %srecalculating...%s\n' \
    "Grand Theft Auto VI" "$C_YEL" "$C_RST" "$C_DIM" "$C_RST"
  printf '  %s\n\n' "------------------------------------------------------------"
  printf '  %s"Benchmark the real path before quoting a time."%s\n' "$C_DIM" "$C_RST"
  printf '  %sA synthetic benchmark said 30 minutes. The real one said 17 hours.%s\n' \
    "$C_DIM" "$C_RST"
  printf '  %sSome estimates are harder to fix than others.%s\n\n' "$C_DIM" "$C_RST"
  printf '  %sdocs/LESSONS.md §5%s\n' "$C_DIM" "$C_RST"
  printf '  %sNo drives were written to in the making of this joke.%s\n\n' \
    "$C_DIM" "$C_RST"
}
