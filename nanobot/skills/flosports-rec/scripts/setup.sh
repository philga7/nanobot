#!/usr/bin/env bash
# setup.sh — Validate Flosports stream and prepare recording session
# Usage: bash setup.sh <url> [--format FORMAT] [--event-name "Event Name"]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=session.sh
source "${SCRIPT_DIR}/session.sh"

# --- Parse arguments ---
url=""
format=""
event_name=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --format)
      format="${2:?--format requires a value}"
      shift 2
      ;;
    --event-name)
      event_name="${2:?--event-name requires a value}"
      shift 2
      ;;
    --help|-h)
      echo "Usage: bash setup.sh <url> [--format FORMAT] [--event-name \"Event Name\"]"
      echo ""
      echo "Options:"
      echo "  --format FORMAT        yt-dlp format selector (default: bv+ba)"
      echo "  --event-name NAME      Event name for directory (default: Flosports-Event)"
      echo ""
      echo "Examples:"
      echo "  bash setup.sh https://www.flomarching.com/live/12345"
      echo "  bash setup.sh https://www.flomarching.com/live/12345 --event-name \"WGI World Championships\""
      echo "  bash setup.sh https://www.flomarching.com/live/12345 --format 3047+audio-0-eng"
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
  echo "Usage: bash setup.sh <url> [--format FORMAT] [--event-name \"Event Name\"]" >&2
  exit 1
fi

# --- Resolve cookies ---
echo "Checking cookies..."
cookie_flags=$(resolve_cookies)
echo "Using: ${cookie_flags}"

# --- Validate stream ---
echo ""
echo "Validating stream..."
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

# --- Defaults ---
event_date=$(date +%Y-%m-%d)
if [[ -z "$event_name" ]]; then
  event_name="Flosports-Event"
fi
dir_name=$(sanitize_name "$event_name")
output_dir="${HOME}/Flosports/${event_date}_${dir_name}"

# --- Check disk space ---
mkdir -p "${HOME}/Flosports"
free_gb=$(check_disk_space "${HOME}/Flosports")
echo ""
echo "Disk space available: ${free_gb} GB"
if [[ "$free_gb" -lt 5 ]]; then
  echo "WARNING: Less than 5 GB free. Recordings may fail." >&2
fi

# --- Create output directory ---
mkdir -p "$output_dir"
echo "Output directory: ${output_dir}"

# --- Write session state ---
ensure_session_dir
cat > "$SESSION_FILE" << EOF
{
  "event_name": "${event_name}",
  "event_date": "${event_date}",
  "stream_url": "${url}",
  "format": "${format}",
  "output_dir": "${output_dir}",
  "counter": 0,
  "status": "ready",
  "current_group": null,
  "start_time": null,
  "recorded": []
}
EOF
echo "Session state written to ${SESSION_FILE}"

# --- Create tmux session ---
if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  echo ""
  echo "WARNING: tmux session '${TMUX_SESSION}' already exists."
  echo "Kill it first with: tmux kill-session -t ${TMUX_SESSION}"
  echo "Or attach to it: tmux attach -t ${TMUX_SESSION}"
else
  tmux new-session -d -s "$TMUX_SESSION" -c "$output_dir"
  tmux split-window -v -t "$TMUX_SESSION" -c "$output_dir"
  # Select the bottom pane (control pane)
  tmux select-pane -t "${TMUX_SESSION}:0.1"
  echo ""
  echo "tmux session '${TMUX_SESSION}' created."
  echo "  Top pane:    yt-dlp capture"
  echo "  Bottom pane: control"
  echo "  Attach:      tmux attach -t ${TMUX_SESSION}"
fi

echo ""
echo "Session ready!"
echo "  Event:  ${event_name}"
echo "  Date:   ${event_date}"
echo "  Format: ${format}"
echo "  Output: ${output_dir}"
echo ""
echo "Next: bash ${SCRIPT_DIR}/record.sh start \"Group Name\""
