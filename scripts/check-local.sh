#!/usr/bin/env bash
# Source-only checks. No installers, devices, mounts or recovered files are used.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v shellcheck >/dev/null || { echo 'Missing shellcheck; request installation approval separately.' >&2; exit 1; }
bash tests/test-guards.sh
shell_inputs=()
while IFS= read -r -d '' input; do
  bash -n "$input"
  shell_inputs+=("$input")
done < <(find scripts tests -name '*.sh' -type f -print0)
shellcheck --severity=warning -e SC1091 -e SC2181 -e SC2317 "${shell_inputs[@]}"
for minor in 11 12 13; do
  case "$minor" in
    11) python="${WINRESCUE_PYTHON_311:-python3.11}" ;;
    12) python="${WINRESCUE_PYTHON_312:-python3.12}" ;;
    13) python="${WINRESCUE_PYTHON_313:-python3.13}" ;;
  esac
  command -v "$python" >/dev/null || { echo "Missing Python 3.$minor; no runtime is installed by this check." >&2; exit 1; }
  "$python" - "$minor" <<'VERSION'
import sys
assert sys.version_info[:2] == (3, int(sys.argv[1])), "Use the requested Python matrix runtime"
VERSION
  "$python" -m compileall -q scripts/
  "$python" -m ruff check scripts/ --select E9,F63,F7,F82
  "$python" -m unittest discover -s tests -p 'test_local_privacy.py'
  "$python" tests/test_lib.py
  "$python" scripts/check-local-source.py
 done
printf 'Local checks passed across Python 3.11/3.12/3.13. Record exact-head Codex reviews before merge.\n'
