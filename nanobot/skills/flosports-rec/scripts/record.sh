#!/usr/bin/env bash
# record.sh — Multi-channel Flosports recording controller
# Usage: bash record.sh start --channel sa "Group Name"
#        bash record.sh stop --channel sa
#        bash record.sh status [--channel sa]
#        bash record.sh list [--channel sa]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=session.sh
source "${SCRIPT_DIR}/session.sh"

cmd="${1:-}"
shift || true

# Parse --channel and remaining args from $@
eval "$(parse_channel_flag "$@")"
# Now CHANNEL and REMAINING_ARGS are set

# --- Helpers ---

require_session() {
  if [[ ! -f "$SESSION_FILE" ]]; then
    echo "ERROR: No active session. Run setup.sh first." >&2
    exit 1
  fi
}

require_channel() {
  if ! channel_exists "$CHANNEL"; then
    echo "ERROR: Channel '${CHANNEL}' not found. Run setup.sh --channel ${CHANNEL} first." >&2
    echo "Available channels: $(channel_list | tr '\n' ' ')" >&2
    exit 1
  fi
}

require_tmux_window() {
  if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "ERROR: tmux session '${TMUX_SESSION}' not found. Run setup.sh first." >&2
    exit 1
  fi
  if ! tmux list-windows -t "$TMUX_SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$CHANNEL"; then
    echo "ERROR: tmux window '${CHANNEL}' not found. Run setup.sh --channel ${CHANNEL} first." >&2
    exit 1
  fi
}

# Get the tmux target for a channel's window (first pane)
tmux_target() {
  local ch="${1:-$CHANNEL}"
  # Find window index by name
  local idx
  idx=$(tmux list-windows -t "$TMUX_SESSION" -F '#{window_name} #{window_index}' 2>/dev/null \
    | awk -v ch="$ch" '$1 == ch {print $2; exit}')
  if [[ -z "$idx" ]]; then
    echo "${TMUX_SESSION}:${ch}"
  else
    echo "${TMUX_SESSION}:${idx}.0"
  fi
}

# --- Commands ---

do_start() {
  local group="${REMAINING_ARGS[0]:-}"
  if [[ -z "$group" ]]; then
    echo "ERROR: Group name required." >&2
    echo "Usage: record.sh start --channel ${CHANNEL} \"Group Name\"" >&2
    exit 1
  fi
  require_session
  require_channel
  require_tmux_window

  local status
  status=$(channel_get "$CHANNEL" ".status")
  if [[ "$status" == "recording" ]]; then
    local current
    current=$(channel_get "$CHANNEL" ".current_group")
    echo "ERROR: Channel '${CHANNEL}' already recording '${current}'. Run 'stop' first." >&2
    exit 1
  fi

  # Increment counter and build filename
  local counter
  counter=$(channel_increment_counter "$CHANNEL")
  local padded
  padded=$(printf "%02d" "$counter")
  local safe_name
  safe_name=$(sanitize_name "$group")
  local filename="${padded}_${safe_name}.mp4"

  local output_dir
  output_dir=$(session_get ".output_dir")
  local channel_dir="${output_dir}/${CHANNEL}"
  mkdir -p "$channel_dir"

  local stream_url
  stream_url=$(channel_get "$CHANNEL" ".stream_url")
  local format
  format=$(channel_get "$CHANNEL" ".format")
  local cookie_flags
  cookie_flags=$(resolve_cookies)

  local output_path="${channel_dir}/${filename}"

  # Build yt-dlp command
  # shellcheck disable=SC2086
  local ytdlp_cmd="yt-dlp ${cookie_flags} --live-from-start -f '${format}' --merge-output-format mp4 -o '${output_path}' '${stream_url}'"

  # Launch in channel's tmux window
  local target
  target=$(tmux_target "$CHANNEL")
  tmux send-keys -t "$target" "$ytdlp_cmd" Enter

  # Update channel state
  local now
  now=$(date +%s)
  channel_set "$CHANNEL" ".status" '"recording"'
  channel_set "$CHANNEL" ".current_group" "\"${group}\""
  channel_set "$CHANNEL" ".start_time" "$now"

  echo "Recording started on channel '${CHANNEL}'."
  echo "  Group:  ${group}"
  echo "  File:   ${filename}"
  echo "  Output: ${output_path}"
  echo ""
  echo "Monitor: tmux attach -t ${TMUX_SESSION}"
  echo "Stop:    bash ${SCRIPT_DIR}/record.sh stop --channel ${CHANNEL}"
}

do_stop() {
  require_session
  require_channel
  require_tmux_window

  local status
  status=$(channel_get "$CHANNEL" ".status")
  if [[ "$status" != "recording" ]]; then
    echo "Channel '${CHANNEL}' not currently recording (status: ${status})."
    return 0
  fi

  local group
  group=$(channel_get "$CHANNEL" ".current_group")
  local counter
  counter=$(channel_get_raw "$CHANNEL" ".counter")
  local padded
  padded=$(printf "%02d" "$counter")
  local safe_name
  safe_name=$(sanitize_name "$group")
  local filename="${padded}_${safe_name}.mp4"
  local output_dir
  output_dir=$(session_get ".output_dir")
  local channel_dir="${output_dir}/${CHANNEL}"
  local output_path="${channel_dir}/${filename}"

  echo "Stopping recording for '${group}' on channel '${CHANNEL}'..."

  # Send Ctrl+C to yt-dlp in channel's tmux window
  local target
  target=$(tmux_target "$CHANNEL")
  tmux send-keys -t "$target" C-c

  # Wait for yt-dlp to exit (up to 10 seconds)
  local waited=0
  while [[ $waited -lt 10 ]]; do
    local pane_pid
    pane_pid=$(tmux display-message -t "$target" -p '#{pane_pid}' 2>/dev/null || echo "")
    if [[ -n "$pane_pid" ]]; then
      if ! pgrep -P "$pane_pid" -f "yt-dlp" >/dev/null 2>&1; then
        break
      fi
    else
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done

  if [[ $waited -ge 10 ]]; then
    echo "WARNING: yt-dlp may not have exited cleanly after 10 seconds."
  fi

  # Check for the expected output file
  local final_file=""
  if [[ -f "$output_path" ]]; then
    final_file="$output_path"
  else
    # Check for split files that need merging
    local video_file=""
    local audio_file=""
    for f in "${channel_dir}/${padded}_${safe_name}".*; do
      [[ -f "$f" ]] || continue
      case "$f" in
        *.f[0-9]*.mp4|*.f[0-9]*.webm|*.fhls-*.mp4)
          if [[ -z "$video_file" ]]; then
            video_file="$f"
          fi
          ;;
        *.faudio*.mp4|*.faudio*.m4a|*.faudio*.webm)
          audio_file="$f"
          ;;
      esac
    done

    if [[ -z "$video_file" ]]; then
      for f in "${channel_dir}/${padded}_${safe_name}".f*.{mp4,webm,mkv}; do
        [[ -f "$f" ]] || continue
        video_file="$f"
        break
      done
    fi
    if [[ -z "$audio_file" ]]; then
      for f in "${channel_dir}/${padded}_${safe_name}".f*.{m4a,mp3,aac,opus,webm}; do
        [[ -f "$f" ]] || continue
        [[ "$f" == "$video_file" ]] && continue
        audio_file="$f"
        break
      done
    fi

    if [[ -n "$video_file" && -n "$audio_file" ]]; then
      echo "Found split files, merging..."
      echo "  Video: $(basename "$video_file")"
      echo "  Audio: $(basename "$audio_file")"
      if ffmpeg -i "$video_file" -i "$audio_file" \
        -c:v copy -c:a aac -b:a 192k \
        "$output_path" -y -loglevel warning; then
        echo "Merge complete."
        rm -f "$video_file" "$audio_file"
        final_file="$output_path"
      else
        echo "WARNING: ffmpeg merge failed. Split files preserved." >&2
        final_file="$video_file"
      fi
    elif [[ -n "$video_file" ]]; then
      mv "$video_file" "$output_path"
      final_file="$output_path"
    else
      echo "WARNING: No output file found at expected path." >&2
      echo "Check ${channel_dir} for partial files." >&2
    fi
  fi

  # Calculate elapsed time
  local start_time
  start_time=$(channel_get_raw "$CHANNEL" ".start_time")
  local now
  now=$(date +%s)
  local elapsed=""
  if [[ "$start_time" != "null" && -n "$start_time" ]]; then
    local secs=$((now - start_time))
    elapsed="$(( secs / 60 ))m $(( secs % 60 ))s"
  fi

  # Report results
  local size_mb=0
  if [[ -n "$final_file" && -f "$final_file" ]]; then
    size_mb=$(file_size_mb "$final_file")
    echo ""
    echo "Recording stopped on channel '${CHANNEL}'."
    echo "  Group:    ${group}"
    echo "  File:     $(basename "$final_file")"
    echo "  Size:     ${size_mb} MB"
    [[ -n "$elapsed" ]] && echo "  Duration: ${elapsed}"
    echo "  Path:     ${final_file}"
  else
    echo ""
    echo "Recording stopped on channel '${CHANNEL}' (no output file detected)."
  fi

  # Update channel state
  channel_set "$CHANNEL" ".status" '"stopped"'
  channel_set "$CHANNEL" ".current_group" "null"
  channel_set "$CHANNEL" ".start_time" "null"

  # Add to recorded list
  if [[ -n "$final_file" && -f "$final_file" ]]; then
    channel_add_recorded "$CHANNEL" "$counter" "$group" "$(basename "$final_file")" "$size_mb"
  fi

  echo ""
  echo "Ready for next group: bash ${SCRIPT_DIR}/record.sh start --channel ${CHANNEL} \"Group Name\""
}

do_status() {
  require_session

  local event_name
  event_name=$(session_get ".event_name")
  local event_date
  event_date=$(session_get ".event_date")
  local output_dir
  output_dir=$(session_get ".output_dir")

  echo "Flosports Recording Status"
  echo "=========================="
  echo "  Event:     ${event_name}"
  echo "  Date:      ${event_date}"
  echo "  Output:    ${output_dir}"

  # tmux status
  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "  tmux:      active"
  else
    echo "  tmux:      not running"
  fi

  # Disk space
  if [[ -d "$output_dir" ]]; then
    local free_gb
    free_gb=$(check_disk_space "$output_dir")
    echo "  Disk free: ${free_gb} GB"
  fi

  echo ""

  # If --channel specified, show just that channel; otherwise show all
  local channels_to_show
  if [[ "$CHANNEL" != "main" ]] || channel_exists "$CHANNEL"; then
    if [[ "$CHANNEL" != "main" ]]; then
      channels_to_show="$CHANNEL"
    else
      channels_to_show=$(channel_list)
    fi
  else
    channels_to_show=$(channel_list)
  fi

  # Show per-channel status
  for ch in $channels_to_show; do
    if ! channel_exists "$ch"; then
      echo "  Channel '${ch}': not found"
      continue
    fi

    local ch_status ch_counter ch_group
    ch_status=$(channel_get "$ch" ".status")
    ch_counter=$(channel_get_raw "$ch" ".counter")

    printf "  [%s] %-10s  %s recording(s)" "$ch" "$ch_status" "$ch_counter"

    if [[ "$ch_status" == "recording" ]]; then
      ch_group=$(channel_get "$ch" ".current_group")
      local ch_start
      ch_start=$(channel_get_raw "$ch" ".start_time")
      printf "  | NOW: %s" "$ch_group"
      if [[ "$ch_start" != "null" && -n "$ch_start" ]]; then
        local now secs
        now=$(date +%s)
        secs=$((now - ch_start))
        printf " (%dm %ds)" "$(( secs / 60 ))" "$(( secs % 60 ))"
      fi
    fi
    echo ""
  done
}

do_list() {
  require_session

  local output_dir
  output_dir=$(session_get ".output_dir")

  # If --channel specified (and not default "main" when no flag given), show just that channel
  local channels_to_show
  if [[ "$CHANNEL" != "main" ]]; then
    channels_to_show="$CHANNEL"
  else
    # Check if "main" channel exists; if not, show all
    if channel_exists "main"; then
      channels_to_show="main"
    else
      channels_to_show=$(channel_list)
    fi
  fi

  local any_recordings=false

  for ch in $channels_to_show; do
    if ! channel_exists "$ch"; then
      echo "Channel '${ch}': not found"
      continue
    fi

    local ch_counter
    ch_counter=$(channel_get_raw "$ch" ".counter")
    if [[ "$ch_counter" == "0" || "$ch_counter" == "null" ]]; then
      echo "Channel '${ch}': no recordings yet."
      echo ""
      continue
    fi

    any_recordings=true
    echo "Channel: ${ch}"
    echo "$(printf '=%.0s' {1..40})"

    local i=0
    while true; do
      local entry
      entry=$(jq -r ".channels.\"${ch}\".recorded[$i] // empty" "$SESSION_FILE" 2>/dev/null)
      [[ -z "$entry" ]] && break

      local num name file size
      num=$(echo "$entry" | jq -r '.number')
      name=$(echo "$entry" | jq -r '.name')
      file=$(echo "$entry" | jq -r '.file')
      size=$(echo "$entry" | jq -r '.size_mb')

      printf "  %02d. %-30s %s (%s MB)\n" "$num" "$name" "$file" "$size"
      i=$((i + 1))
    done
    echo ""
  done

  if [[ "$any_recordings" == false ]]; then
    echo "No recordings yet across any channel."
  fi

  echo "Output directory: ${output_dir}"
}

do_serve() {
  require_session

  # Check if already serving
  if [[ -f "$SERVE_PID_FILE" ]]; then
    local old_pid
    old_pid=$(cat "$SERVE_PID_FILE")
    if kill -0 "$old_pid" 2>/dev/null; then
      echo "ERROR: File server already running (PID ${old_pid})." >&2
      echo "Run 'serve-down' first to stop it." >&2
      exit 1
    fi
    # Stale PID file
    rm -f "$SERVE_PID_FILE"
  fi

  local output_dir
  output_dir=$(session_get ".output_dir")
  local serve_root
  serve_root=$(dirname "$output_dir")
  local event_dir_name
  event_dir_name=$(basename "$output_dir")

  if [[ ! -d "$output_dir" ]]; then
    echo "ERROR: Output directory not found: ${output_dir}" >&2
    exit 1
  fi

  # Open firewall port
  if command -v ufw &>/dev/null; then
    echo "Opening firewall port ${SERVE_PORT}/tcp..."
    ufw allow "${SERVE_PORT}/tcp" >/dev/null 2>&1 || \
      echo "WARNING: Could not add ufw rule. May need sudo." >&2
  fi

  # Start Python http.server in background, serving from parent of output_dir
  echo "Starting file server on port ${SERVE_PORT}..."
  cd "$serve_root"
  python3 -m http.server "$SERVE_PORT" --bind 0.0.0.0 &>/dev/null &
  local pid=$!
  cd - >/dev/null

  # Verify it started
  sleep 1
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "ERROR: File server failed to start." >&2
    exit 1
  fi

  echo "$pid" > "$SERVE_PID_FILE"

  # Detect server IP
  local host
  host=$(curl -s --max-time 2 ifconfig.me 2>/dev/null || hostname -f 2>/dev/null || hostname 2>/dev/null || echo "localhost")

  echo ""
  echo "File server running (PID ${pid})."
  echo ""
  echo "Browse all: http://${host}:${SERVE_PORT}/${event_dir_name}/"
  echo ""

  # List per-channel URLs
  for ch in $(channel_list); do
    local ch_dir="${output_dir}/${ch}"
    [[ -d "$ch_dir" ]] || continue
    local has_files=false
    for f in "$ch_dir"/*.mp4; do
      [[ -f "$f" ]] || continue
      has_files=true
      local fname
      fname=$(basename "$f")
      echo "  http://${host}:${SERVE_PORT}/${event_dir_name}/${ch}/${fname}"
    done
    if [[ "$has_files" == false ]]; then
      echo "  Channel '${ch}': no recordings yet"
    fi
  done

  echo ""
  echo "Stop with: bash ${SCRIPT_DIR}/record.sh serve-down"
}

do_serve_down() {
  if [[ ! -f "$SERVE_PID_FILE" ]]; then
    echo "No file server running (no PID file)."
    return 0
  fi

  local pid
  pid=$(cat "$SERVE_PID_FILE")

  if kill -0 "$pid" 2>/dev/null; then
    echo "Stopping file server (PID ${pid})..."
    kill "$pid" 2>/dev/null
    # Wait briefly for clean exit
    local waited=0
    while [[ $waited -lt 5 ]] && kill -0 "$pid" 2>/dev/null; do
      sleep 1
      waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
    echo "File server stopped."
  else
    echo "File server not running (stale PID ${pid})."
  fi

  rm -f "$SERVE_PID_FILE"

  # Close firewall port
  if command -v ufw &>/dev/null; then
    echo "Closing firewall port ${SERVE_PORT}/tcp..."
    ufw delete allow "${SERVE_PORT}/tcp" >/dev/null 2>&1 || \
      echo "WARNING: Could not remove ufw rule. May need sudo." >&2
  fi
}

# --- Main dispatch ---

case "$cmd" in
  start)
    do_start
    ;;
  stop)
    do_stop
    ;;
  status)
    do_status
    ;;
  list)
    do_list
    ;;
  serve)
    do_serve
    ;;
  serve-down)
    do_serve_down
    ;;
  *)
    cat <<'USAGE'
Usage: bash record.sh {start|stop|status|list|serve|serve-down} [--channel NAME] [args...]

Commands:
  start --channel sa "Group Name"   Begin recording for a named group
  stop --channel sa                 Stop current recording and finalize
  status [--channel sa]             Show recording state (all channels if omitted)
  list [--channel sa]               List recorded groups (all channels if omitted)
  serve                             Start file server on port 8765 (opens ufw)
  serve-down                        Stop file server (closes ufw)
USAGE
    exit 1
    ;;
esac
