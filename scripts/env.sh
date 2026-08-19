#!/usr/bin/env bash
# Shared between the upgrade scripts and the Makefile, so that reading .env and
# naming the upgrade marker happen in exactly one place.
#
# Source it, or call it: `bash scripts/lib.sh get VAR [FILE]` / `... marker`.

ENV_FILE_DEFAULT=".env"

# Raised by upgrade.sh between the backup and the end of the run; the Makefile
# guard refuses to start the stack while it exists.
UPGRADE_MARKER="backups/.upgrade-unfinished"

# Last assignment wins. Surrounding blanks and quotes go; a missing variable is an
# empty value, not an error, so callers under `set -e` do not have to guard it.
env_value() {
    grep -E "^[[:space:]]*$1=" "${2:-$ENV_FILE_DEFAULT}" 2>/dev/null \
        | tail -1 | cut -d= -f2- | tr -d '[:space:]"' || true
}

# Verbatim, for rewriting a value into another file unchanged.
env_value_raw() {
    grep -E "^[[:space:]]*$1=" "${2:-$ENV_FILE_DEFAULT}" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# The booleans django-environ recognises, so .env means the same thing everywhere.
env_true()  { case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in true|on|ok|y|yes|1) return 0 ;; esac; return 1; }
env_false() { case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in false|off|no|0) return 0 ;; esac; return 1; }

case "${1:-}" in
    get)    env_value "$2" "${3:-}" ;;
    getraw) env_value_raw "$2" "${3:-}" ;;
    marker) printf '%s\n' "$UPGRADE_MARKER" ;;
esac
