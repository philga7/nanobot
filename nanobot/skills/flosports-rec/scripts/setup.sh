#!/usr/bin/env bash
# setup.sh — Validate Flosports stream and prepare recording session
# First call creates the session; subsequent calls add channels.
# Usage: bash setup.sh <url> [--channel NAME] [--format FORMAT] [--event-name "Event Name"]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=session.sh
source "${SCRIPT_DIR}/session.sh"

# --- Parse arguments ---
url=""
format=""
event_name=""
channel="main"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel)
      channel="${2:?--channel requires a value}"
      shift 2
      ;;
    --format)
      format="${2:?--format requires a value}"
      shift 2
      ;;
    --event-name)
      event_name="${2:?--event-name requires a value}"
      shift 2
      ;;
    --help|-h)
      cat <<'HELP'
Usage: bash setup.sh <url> [--channel NAME] [--format FORMAT] [--event-name "Event Name"]

First call creates the session and first channel. Subsequent calls add channels
to the existing session.

Options:
  --channel NAME         Channel name, e.g. sa, sw, iw (default: main)
  --format FORMAT        yt-dlp format selector (default: bv+ba)
  --event-name NAME      Event name for directory (first call only)

Examples:
  bash setup.sh https://www.flomarching.com/live/111 --channel sa --event-name "WGI Worlds"
  bash setup.sh https://www.flomarching.com/live/222 --channel sw
  bash setup.sh https://www.flomarching.com/live/333 --channel iw --format 3047+audio-0-eng
HELP
      exit 0
      ;;
    -*)
      echo "ERROR: Unknown option: $1" >&2
      exit 1
      ;;
    *)
      if [[ -z "$url" ]]; then
        url="$1"
      else
        echo "ERROR: Unexpected argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$url" ]]; then
  echo "ERROR: Stream URL is required." >&2
  echo "Usage: bash setup.sh <url> [--channel NAME] [--format FORMAT] [--event-name NAME]" >&2
  exit 1
fi

# --- Resolve cookies ---
echo "Checking cookies..."
cookie_flags=$(resolve_cookies)
echo "Using: ${cookie_flags}"

# --- Validate stream ---
echo ""
echo "Validating stream for channel '${channel}'..."
# shellcheck disable=SC2086
if ! yt-dlp --simulate --verbose ${cookie_flags} "$url" 2>&1; then
  echo ""
  echo "ERROR: Stream validation failed. Check URL and cookies." >&2
  exit 1
fi
echo "Stream validated OK."

# --- List available formats ---
echo ""
echo "Available formats:"
# shellcheck disable=SC2086
yt-dlp ${cookie_flags} -F "$url" 2>&1 || true

# --- Auto-select format ---
if [[ -z "$format" ]]; then
  format="bv+ba"
  echo ""
  echo "Auto-selected format: best video + best audio (bv+ba)"
  echo "Override with: --format <format_id>"
fi

# --- Create or update session ---
is_new_session=false
if ! session_exists; then
  # First setup call — create the session
  is_new_session=true
  event_date=$(date +%Y-%m-%d)
  if [[ -z "$event_name" ]]; then
    event_name="Flosports-Event"
  fi
  dir_name=$(sanitize_name "$event_name")
  output_dir="${HOME}/Flosports/${event_date}_${dir_name}"

  # Check disk space
  mkdir -p "${HOME}/Flosports"
  free_gb=$(check_disk_space "${HOME}/Flosports")
  echo ""
  echo "Disk space available: ${free_gb} GB"
  if [[ "$free_gb" -lt 5 ]]; then
    echo "WARNING: Less than 5 GB free. Recordings may fail." >&2
  fi

  # Create output directory
  mkdir -p "$output_dir"

  # Write initial session state with first channel
  ensure_session_dir
  jq -n \
    --arg event_name "$event_name" \
    --arg event_date "$event_date" \
    --arg output_dir "$output_dir" \
    --arg ch "$channel" \
    --arg stream_url "$url" \
    --arg fmt "$format" \
    '{
      event_name: $event_name,
      event_date: $event_date,
      output_dir: $output_dir,
      channels: {
        ($ch): {
          stream_url: $stream_url,
          format: $fmt,
          counter: 0,
          status: "ready",
          current_group: null,
          start_time: null,
          recorded: []
        }
      }
    }' > "$SESSION_FILE"
  echo "Session created: ${SESSION_FILE}"
else
  # Subsequent call — add channel to existing session
  output_dir=$(session_get ".output_dir")

  if channel_exists "$channel"; then
    echo ""
    echo "WARNING: Channel '${channel}' already exists. Updating stream URL and format."
    channel_set "$channel" ".stream_url" "\"${url}\""
    channel_set "$channel" ".format" "\"${format}\""
  else
    # Check channel limit
    count=$(channel_count)
    if [[ "$count" -ge "$MAX_CHANNELS" ]]; then
      echo "WARNING: Already ${count} channels configured (max ${MAX_CHANNELS})." >&2
      echo "Simultaneous streams may degrade quality." >&2
    fi

    # Add new channel
    local_tmp="${SESSION_FILE}.tmp"
    jq --arg ch "$channel" \
       --arg stream_url "$url" \
       --arg fmt "$format" \
       '.channels[$ch] = {
          stream_url: $stream_url,
          format: $fmt,
          counter: 0,
          status: "ready",
          current_group: null,
          start_time: null,
          recorded: []
        }' "$SESSION_FILE" > "$local_tmp"
    mv "$local_tmp" "$SESSION_FILE"
    echo "Channel '${channel}' added to session."
  fi
fi

# Create channel output subdirectory
mkdir -p "${output_dir}/${channel}"

# --- Create or update tmux session ---
if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  # Create new tmux session with first window named after channel
  tmux new-session -d -s "$TMUX_SESSION" -n "$channel" -c "${output_dir}/${channel}"
  echo ""
  echo "tmux session '${TMUX_SESSION}' created."
else
  # Check if window for this channel already exists
  if tmux list-windows -t "$TMUX_SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$channel"; then
    echo ""
    echo "tmux window '${channel}' already exists."
  else
    tmux new-window -t "$TMUX_SESSION" -n "$channel" -c "${output_dir}/${channel}"
    echo ""
    echo "tmux window '${channel}' added."
  fi
fi

echo "  Attach: tmux attach -t ${TMUX_SESSION}"

# --- Summary ---
echo ""
if [[ "$is_new_session" == true ]]; then
  event_name_display=$(session_get ".event_name")
  event_date_display=$(session_get ".event_date")
  echo "Session ready!"
  echo "  Event:   ${event_name_display}"
  echo "  Date:    ${event_date_display}"
  echo "  Output:  ${output_dir}"
fi
echo "Channel '${channel}' ready."
echo "  Stream:  ${url}"
echo "  Format:  ${format}"
echo "  Files:   ${output_dir}/${channel}/"
echo ""
echo "Channels configured: $(channel_list | tr '\n' ' ')"
echo ""
echo "Next: bash ${SCRIPT_DIR}/record.sh start --channel ${channel} \"Group Name\""
