#!/usr/bin/env bash
# record.sh — Flosports recording controller
# Usage: bash record.sh start "Group Name"
#        bash record.sh stop
#        bash record.sh status
#        bash record.sh list
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=session.sh
source "${SCRIPT_DIR}/session.sh"

cmd="${1:-}"
shift || true

# --- Helpers ---

require_session() {
  if [[ ! -f "$SESSION_FILE" ]]; then
    echo "ERROR: No active session. Run setup.sh first." >&2
    exit 1
  fi
}

require_tmux() {
  if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "ERROR: tmux session '${TMUX_SESSION}' not found. Run setup.sh first." >&2
    exit 1
  fi
}

# --- Commands ---

do_start() {
  local group="${1:?Usage: record.sh start \"Group Name\"}"
  require_session
  require_tmux

  local status
  status=$(session_get ".status")
  if [[ "$status" == "recording" ]]; then
    local current
    current=$(session_get ".current_group")
    echo "ERROR: Already recording '${current}'. Run 'stop' first." >&2
    exit 1
  fi

  # Increment counter and build filename
  local counter
  counter=$(session_increment_counter)
  local padded
  padded=$(printf "%02d" "$counter")
  local safe_name
  safe_name=$(sanitize_name "$group")
  local filename="${padded}_${safe_name}.mp4"

  local output_dir
  output_dir=$(session_get ".output_dir")
  local stream_url
  stream_url=$(session_get ".stream_url")
  local format
  format=$(session_get ".format")
  local cookie_flags
  cookie_flags=$(resolve_cookies)

  local output_path="${output_dir}/${filename}"

  # Build yt-dlp command
  # shellcheck disable=SC2086
  local ytdlp_cmd="yt-dlp ${cookie_flags} --live-from-start -f '${format}' --merge-output-format mp4 -o '${output_path}' '${stream_url}'"

  # Launch in tmux top pane
  tmux send-keys -t "${TMUX_SESSION}:0.0" "$ytdlp_cmd" Enter

  # Update session state
  local now
  now=$(date +%s)
  session_set ".status" '"recording"'
  session_set ".current_group" "\"${group}\""
  session_set ".start_time" "$now"

  echo "Recording started."
  echo "  Group:  ${group}"
  echo "  File:   ${filename}"
  echo "  Output: ${output_path}"
  echo ""
  echo "Monitor: tmux attach -t ${TMUX_SESSION}"
  echo "Stop:    bash ${SCRIPT_DIR}/record.sh stop"
}

do_stop() {
  require_session
  require_tmux

  local status
  status=$(session_get ".status")
  if [[ "$status" != "recording" ]]; then
    echo "Not currently recording (status: ${status})."
    return 0
  fi

  local group
  group=$(session_get ".current_group")
  local counter
  counter=$(session_get_raw ".counter")
  local padded
  padded=$(printf "%02d" "$counter")
  local safe_name
  safe_name=$(sanitize_name "$group")
  local filename="${padded}_${safe_name}.mp4"
  local output_dir
  output_dir=$(session_get ".output_dir")
  local output_path="${output_dir}/${filename}"

  echo "Stopping recording for '${group}'..."

  # Send Ctrl+C to yt-dlp in tmux top pane
  tmux send-keys -t "${TMUX_SESSION}:0.0" C-c

  # Wait for yt-dlp to exit (up to 10 seconds)
  local waited=0
  while [[ $waited -lt 10 ]]; do
    # Check if yt-dlp is still running in the pane
    local pane_pid
    pane_pid=$(tmux display-message -t "${TMUX_SESSION}:0.0" -p '#{pane_pid}' 2>/dev/null || echo "")
    if [[ -n "$pane_pid" ]]; then
      # Check if any yt-dlp child process is running
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
    for f in "${output_dir}/${padded}_${safe_name}".*; do
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

    # Also check for yt-dlp's common split naming patterns
    if [[ -z "$video_file" ]]; then
      for f in "${output_dir}/${padded}_${safe_name}".f*.{mp4,webm,mkv}; do
        [[ -f "$f" ]] || continue
        video_file="$f"
        break
      done
    fi
    if [[ -z "$audio_file" ]]; then
      for f in "${output_dir}/${padded}_${safe_name}".f*.{m4a,mp3,aac,opus,webm}; do
        [[ -f "$f" ]] || continue
        # Skip if it's the same as the video file
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
      # Single file with format suffix — rename to clean name
      mv "$video_file" "$output_path"
      final_file="$output_path"
    else
      echo "WARNING: No output file found at expected path." >&2
      echo "Check ${output_dir} for partial files." >&2
    fi
  fi

  # Calculate elapsed time
  local start_time
  start_time=$(session_get_raw ".start_time")
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
    echo "Recording stopped."
    echo "  Group:    ${group}"
    echo "  File:     $(basename "$final_file")"
    echo "  Size:     ${size_mb} MB"
    [[ -n "$elapsed" ]] && echo "  Duration: ${elapsed}"
    echo "  Path:     ${final_file}"
  else
    echo ""
    echo "Recording stopped (no output file detected)."
  fi

  # Update session state
  session_set ".status" '"stopped"'
  session_set ".current_group" "null"
  session_set ".start_time" "null"

  # Add to recorded list
  if [[ -n "$final_file" && -f "$final_file" ]]; then
    session_add_recorded "$counter" "$group" "$(basename "$final_file")" "$size_mb"
  fi

  echo ""
  echo "Ready for next group: bash ${SCRIPT_DIR}/record.sh start \"Group Name\""
}

do_status() {
  require_session

  local status
  status=$(session_get ".status")
  local event_name
  event_name=$(session_get ".event_name")
  local event_date
  event_date=$(session_get ".event_date")
  local counter
  counter=$(session_get_raw ".counter")
  local output_dir
  output_dir=$(session_get ".output_dir")

  echo "Flosports Recording Status"
  echo "=========================="
  echo "  Event:     ${event_name}"
  echo "  Date:      ${event_date}"
  echo "  Status:    ${status}"
  echo "  Recorded:  ${counter} group(s)"
  echo "  Output:    ${output_dir}"

  if [[ "$status" == "recording" ]]; then
    local group
    group=$(session_get ".current_group")
    local start_time
    start_time=$(session_get_raw ".start_time")
    echo "  Recording: ${group}"
    if [[ "$start_time" != "null" && -n "$start_time" ]]; then
      local now
      now=$(date +%s)
      local secs=$((now - start_time))
      echo "  Elapsed:   $(( secs / 60 ))m $(( secs % 60 ))s"
    fi
  fi

  # Check if tmux session is alive
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
}

do_list() {
  require_session

  local count
  count=$(session_get_raw ".counter")
  if [[ "$count" == "0" || "$count" == "null" ]]; then
    echo "No recordings yet."
    return 0
  fi

  local output_dir
  output_dir=$(session_get ".output_dir")

  echo "Recorded Groups"
  echo "==============="
  # Read each entry from the recorded array
  local i=0
  while true; do
    local entry
    entry=$(jq -r ".recorded[$i] // empty" "$SESSION_FILE" 2>/dev/null)
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
  echo "Output directory: ${output_dir}"
}

# --- Main dispatch ---

case "$cmd" in
  start)
    do_start "${1:?Usage: record.sh start \"Group Name\"}"
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
  *)
    echo "Usage: bash record.sh {start|stop|status|list}" >&2
    echo ""
    echo "Commands:"
    echo "  start \"Group Name\"  Begin recording for a named group"
    echo "  stop                Stop current recording and finalize"
    echo "  status              Show current recording state"
    echo "  list                List all recorded groups"
    exit 1
    ;;
esac
