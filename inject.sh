#!/usr/bin/env sh
# ============================================================================
# inject.sh — Cross-platform POSIX launcher for RPGMCheat (Linux / macOS)
# Runs without Ruby using Python 3 (inject.py), or falls back to Ruby if needed.
# ============================================================================

set -e

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

if command -v python3 >/dev/null 2>&1; then
  exec python3 "$SCRIPT_DIR/inject.py" "$@"
elif command -v python >/dev/null 2>&1; then
  exec python "$SCRIPT_DIR/inject.py" "$@"
elif command -v ruby >/dev/null 2>&1; then
  exec ruby "$SCRIPT_DIR/inject.rb" "$@"
else
  echo "[Error] Neither Python 3 nor Ruby was found in PATH." >&2
  echo "        On Windows without Python/Ruby, run inject.bat instead." >&2
  exit 1
fi
