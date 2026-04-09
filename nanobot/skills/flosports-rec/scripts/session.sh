#!/usr/bin/env bash
# session.sh — Session state helpers for flosports-rec
# Source this file from other scripts: source "$(dirname "$0")/session.sh"
set -euo pipefail

SESSION_DIR="${HOME}/.wrenvps/flosports"
SESSION_FILE="${SESSION_DIR}/session.json"
COOKIES_FILE="${SESSION_DIR}/cookies.txt"
TMUX_SESSION="flosports-rec"

# Ensure session directory exists
ensure_session_dir() {
  mkdir -p "$SESSION_DIR"
}

# Read a field from session state
# Usage: session_get .field_name
session_get() {
  local field="${1:?Usage: session_get .field}"
  if [[ ! -f "$SESSION_FILE" ]]; then
    echo "null"
    return
  fi
  jq -r "$field // empty" "$SESSION_FILE" 2>/dev/null || echo "null"
}

# Read raw JSON value (preserves null, arrays, etc.)
session_get_raw() {
  local field="${1:?Usage: session_get_raw .field}"
  if [[ ! -f "$SESSION_FILE" ]]; then
    echo "null"
    return
  fi
  jq "$field" "$SESSION_FILE" 2>/dev/null || echo "null"
}

# Write the full session state from stdin
# Usage: echo "$json" | session_write
session_write() {
  ensure_session_dir
  local tmp="${SESSION_FILE}.tmp"
  cat > "$tmp"
  mv "$tmp" "$SESSION_FILE"
}

# Update a single field in session state
# Usage: session_set .field "value"
session_set() {
  local field="${1:?Usage: session_set .field value}"
  local value="${2:?Usage: session_set .field value}"
  ensure_session_dir
  if [[ ! -f "$SESSION_FILE" ]]; then
    echo "ERROR: No active session. Run setup first." >&2
    return 1
  fi
  local tmp="${SESSION_FILE}.tmp"
  jq "${field} = ${value}" "$SESSION_FILE" > "$tmp"
  mv "$tmp" "$SESSION_FILE"
}

# Increment counter and return new value
session_increment_counter() {
  local current
  current=$(session_get_raw ".counter")
  local next=$(( current + 1 ))
  session_set ".counter" "$next"
  echo "$next"
}

# Add a recorded entry to the session
# Usage: session_add_recorded number name file size_mb
session_add_recorded() {
  local number="${1:?}"
  local name="${2:?}"
  local file="${3:?}"
  local size_mb="${4:?}"
  local entry
  entry=$(jq -n \
    --argjson num "$number" \
    --arg name "$name" \
    --arg file "$file" \
    --argjson size "$size_mb" \
    '{number: $num, name: $name, file: $file, size_mb: $size}')
  local tmp="${SESSION_FILE}.tmp"
  jq ".recorded += [$entry]" "$SESSION_FILE" > "$tmp"
  mv "$tmp" "$SESSION_FILE"
}

# Sanitize a group name for use in filenames
# "Jefferson HS (SRA)" → "Jefferson-HS-SRA"
sanitize_name() {
  local name="${1:?Usage: sanitize_name 'Group Name'}"
  echo "$name" \
    | sed 's/[^a-zA-Z0-9 -]//g' \
    | sed 's/  */ /g' \
    | sed 's/ /-/g' \
    | sed 's/--*/-/g' \
    | sed 's/^-//;s/-$//'
}

# Resolve cookie flags for yt-dlp
# Returns the cookie argument string or exits with error
resolve_cookies() {
  if [[ -f "$COOKIES_FILE" ]]; then
    echo "--cookies ${COOKIES_FILE}"
  elif command -v google-chrome &>/dev/null || command -v chromium-browser &>/dev/null; then
    echo "--cookies-from-browser chrome"
  else
    echo "ERROR: No cookies file at ${COOKIES_FILE} and no Chrome browser found." >&2
    echo "Export cookies first. See SKILL.md for instructions." >&2
    return 1
  fi
}

# Check available disk space in GB
# Usage: check_disk_space /path
check_disk_space() {
  local path="${1:-.}"
  if [[ "$(uname)" == "Darwin" ]]; then
    df -g "$path" | awk 'NR==2 {print $4}'
  else
    df -BG "$path" | awk 'NR==2 {print $4}' | sed 's/G//'
  fi
}

# Get file size in MB
file_size_mb() {
  local file="${1:?}"
  if [[ "$(uname)" == "Darwin" ]]; then
    stat -f %z "$file" 2>/dev/null | awk '{printf "%.0f", $1/1048576}'
  else
    stat -c %s "$file" 2>/dev/null | awk '{printf "%.0f", $1/1048576}'
  fi
}
