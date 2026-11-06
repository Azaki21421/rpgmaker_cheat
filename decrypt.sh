#!/usr/bin/env sh
# ============================================================================
# decrypt.sh — Standalone RGSS Archive Decryptor / Unpacker
# Extracts all files from Game.rgss3a, Game.rgss2a, or Game.rgssad to disk.
#
# Usage:
#   ./decrypt.sh "/path/to/GameFolder"
# ============================================================================
set -e

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "$SCRIPT_DIR/inject.sh" --decrypt "$@"
