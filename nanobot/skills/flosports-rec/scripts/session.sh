#!/usr/bin/env bash
# session.sh — Channel-aware session state helpers for flosports-rec
# Source this file from other scripts: source "$(dirname "$0")/session.sh"
set -euo pipefail

SESSION_DIR="${HOME}/.wrenvps/flosports"
SESSION_FILE="${SESSION_DIR}/session.json"
COOKIES_FILE="${SESSION_DIR}/cookies.txt"
TMUX_SESSION="flosports-rec"
MAX_CHANNELS=3
SERVE_PORT=8765
SERVE_PID_FILE="${SESSION_DIR}/serve.pid"

# Ensure session directory exists
ensure_session_dir() {
  mkdir -p "$SESSION_DIR"
}

# --- Top-level session helpers ---

# Read a top-level field from session state
# Usage: session_get .field_name
session_get() {
  local field="${1:?Usage: session_get .field}"
  if [[ ! -f "$SESSION_FILE" ]]; then
    echo "null"
    return
  fi
  jq -r "$field // empty" "$SESSION_FILE" 2>/dev/null || echo "null"
}

# Read raw JSON value (preserves null, arrays, objects)
session_get_raw() {
  local field="${1:?Usage: session_get_raw .field}"
  if [[ ! -f "$SESSION_FILE" ]]; then
    echo "null"
    return
  fi
  jq "$field" "$SESSION_FILE" 2>/dev/null || echo "null"
}

# Update a field in session state
# Usage: session_set .field "json_value"
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

# Check if session file exists
session_exists() {
  [[ -f "$SESSION_FILE" ]]
}

# --- Channel helpers ---

# Read a field from a specific channel
# Usage: channel_get <channel> .field
channel_get() {
  local ch="${1:?Usage: channel_get <channel> .field}"
  local field="${2:?Usage: channel_get <channel> .field}"
  session_get ".channels.\"${ch}\"${field}"
}

# Read raw JSON from a channel
channel_get_raw() {
  local ch="${1:?Usage: channel_get_raw <channel> .field}"
  local field="${2:?Usage: channel_get_raw <channel> .field}"
  session_get_raw ".channels.\"${ch}\"${field}"
}

# Update a field within a channel
# Usage: channel_set <channel> .field "json_value"
channel_set() {
  local ch="${1:?Usage: channel_set <channel> .field value}"
  local field="${2:?Usage: channel_set <channel> .field value}"
  local value="${3:?Usage: channel_set <channel> .field value}"
  session_set ".channels.\"${ch}\"${field}" "$value"
}

# Check if a channel exists in the session
channel_exists() {
  local ch="${1:?Usage: channel_exists <channel>}"
  local result
  result=$(session_get_raw ".channels.\"${ch}\"")
  [[ "$result" != "null" ]]
}

# List all channel names
channel_list() {
  if [[ ! -f "$SESSION_FILE" ]]; then
    return
  fi
  jq -r '.channels // {} | keys[]' "$SESSION_FILE" 2>/dev/null
}

# Count channels
channel_count() {
  if [[ ! -f "$SESSION_FILE" ]]; then
    echo "0"
    return
  fi
  jq '.channels // {} | length' "$SESSION_FILE" 2>/dev/null || echo "0"
}

# Increment counter for a channel and return new value
channel_increment_counter() {
  local ch="${1:?Usage: channel_increment_counter <channel>}"
  local current
  current=$(channel_get_raw "$ch" ".counter")
  local next=$(( current + 1 ))
  channel_set "$ch" ".counter" "$next"
  echo "$next"
}

# Add a recorded entry to a channel
# Usage: channel_add_recorded <channel> number name file size_mb
channel_add_recorded() {
  local ch="${1:?}"
  local number="${2:?}"
  local name="${3:?}"
  local file="${4:?}"
  local size_mb="${5:?}"
  local entry
  entry=$(jq -n \
    --argjson num "$number" \
    --arg name "$name" \
    --arg file "$file" \
    --argjson size "$size_mb" \
    '{number: $num, name: $name, file: $file, size_mb: $size}')
  local tmp="${SESSION_FILE}.tmp"
  jq ".channels.\"${ch}\".recorded += [$entry]" "$SESSION_FILE" > "$tmp"
  mv "$tmp" "$SESSION_FILE"
}

# --- Utility helpers ---

# Sanitize a group name for use in filenames
# "Jefferson HS (SRA)" -> "Jefferson-HS-SRA"
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

# Parse --channel flag from arguments, return channel name and remaining args
# Usage: eval "$(parse_channel_flag "$@")"
#   Sets: CHANNEL and REMAINING_ARGS
parse_channel_flag() {
  local channel="main"
  local args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --channel)
        channel="${2:?--channel requires a value}"
        shift 2
        ;;
      *)
        args+=("$1")
        shift
        ;;
    esac
  done
  echo "CHANNEL=$(printf '%q' "$channel")"
  if [[ ${#args[@]} -gt 0 ]]; then
    printf 'REMAINING_ARGS=('
    for a in "${args[@]}"; do
      printf '%q ' "$a"
    done
    printf ')\n'
  else
    echo 'REMAINING_ARGS=()'
  fi
}
