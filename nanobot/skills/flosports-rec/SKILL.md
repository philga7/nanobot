---
name: flosports-rec
description: "Semi-automated Flosports live stream recording controller. Start/stop recordings per group with automatic file naming, sequential numbering, and split-file merging via yt-dlp and ffmpeg. Use for WGI, DCI, or any Flosports live event."
metadata: {"nanobot":{"emoji":"🎥","os":["darwin","linux"],"requires":{"bins":["yt-dlp","ffmpeg","tmux","jq"]}}}
---

# Flosports Live Stream Recorder

Semi-automated recording controller for Flosports live streams (FloMarching,
FloDrums, etc.). The operator decides when to start/stop per group; the skill
handles file naming, merging, and organization.

## Prerequisites

- `yt-dlp` (latest — `pip install -U yt-dlp`)
- `ffmpeg` (for merging split audio/video files)
- `tmux` (session management)
- `jq` (JSON state management)
- Flosports account with active subscription
- Cookies exported to `~/.wrenvps/flosports/cookies.txt`

## Cookie Setup

Export cookies once before event day. The skill checks for cookies in this order:

1. `~/.wrenvps/flosports/cookies.txt` (preferred — Netscape format)
2. `--cookies-from-browser chrome` (fallback if Chrome is available)

To export cookies:

```bash
# Option A: Use yt-dlp to export from Chrome
yt-dlp --cookies-from-browser chrome --cookies ~/.wrenvps/flosports/cookies.txt \
  --simulate "https://www.flomarching.com/live/12345"

# Option B: Use a browser extension (EditThisCookie, Get cookies.txt)
# Export from FloMarching after logging in, save to ~/.wrenvps/flosports/cookies.txt
```

## Commands

### setup

Validate a stream URL, check quality options, and prepare a recording session.

```bash
bash {baseDir}/scripts/setup.sh <url> [--format FORMAT] [--event-name "Event Name"]
```

- Validates the stream is accessible
- Lists available format IDs
- Creates output directory: `~/Flosports/<date>_<Event-Name>/`
- Creates tmux session `flosports-rec` with capture + control panes
- Writes initial session state

### start

Begin recording for a named group.

```bash
bash {baseDir}/scripts/record.sh start "Group Name"
```

- Increments the sequential counter
- Sanitizes group name for filename: `01_Group-Name.mp4`
- Launches yt-dlp in the tmux capture pane
- Updates session state to `recording`

### stop

Stop the current recording and finalize the file.

```bash
bash {baseDir}/scripts/record.sh stop
```

- Sends Ctrl+C to yt-dlp in tmux pane
- Waits up to 10 seconds for clean exit
- Checks for split files (separate video + audio), auto-merges with ffmpeg
- Deletes split files after successful merge
- Reports final file path and size
- Updates session state to `stopped`

### status

Show current recording state.

```bash
bash {baseDir}/scripts/record.sh status
```

Reports: recording/stopped, current group, elapsed time, total files recorded.

### list

Show all recorded groups for this session.

```bash
bash {baseDir}/scripts/record.sh list
```

Lists groups with sequential number, name, filename, and size.

## Directory Layout

```
~/Flosports/
  2026-04-10_WGI-World-Championships/
    01_Jefferson-HS-SRA.mp4
    02_Avon-HS-SWA.mp4
    03_Dartmouth-HS-IW.mp4
    ...
```

- One folder per event, named `<date>_<Event-Name>`
- Files numbered sequentially by performance order
- Group names sanitized: spaces to hyphens, special chars removed

## Session State

Stored at `~/.wrenvps/flosports/session.json`:

```json
{
  "event_name": "WGI World Championships",
  "event_date": "2026-04-10",
  "stream_url": "https://www.flomarching.com/live/12345",
  "format": "bv+ba",
  "output_dir": "~/Flosports/2026-04-10_WGI-World-Championships",
  "counter": 2,
  "status": "stopped",
  "current_group": null,
  "start_time": null,
  "recorded": [
    {"number": 1, "name": "Jefferson HS SRA", "file": "01_Jefferson-HS-SRA.mp4", "size_mb": 245},
    {"number": 2, "name": "Avon HS SWA", "file": "02_Avon-HS-SWA.mp4", "size_mb": 312}
  ]
}
```

## tmux Layout

```
┌─────────────────────────────────────┐
│  yt-dlp capture (active recording)  │  ← top pane (pane 0)
├─────────────────────────────────────┤
│  Control (status / last action)     │  ← bottom pane (pane 1)
└─────────────────────────────────────┘
```

- Session name: `flosports-rec`
- Attach to monitor: `tmux attach -t flosports-rec`

## Edge Cases

- **Stream goes down mid-recording:** yt-dlp exits; stop detects this, finalizes what was captured, and alerts the operator.
- **Disk space:** setup checks available disk. Warns if less than 5 GB free.
- **Cookies expire:** yt-dlp fails with auth error. Re-export cookies and re-run setup.
- **Special characters in group name:** Sanitized to hyphens. `"Jefferson HS (SRA)"` becomes `Jefferson-HS-SRA`.
- **Double start:** If status is already `recording`, refuses and warns. Run `stop` first.
- **Interrupted session:** Session state is persisted after each operation. Counter and file list survive restarts.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `ERROR: cookies` | Re-export cookies to `~/.wrenvps/flosports/cookies.txt` |
| Split files not merging | Ensure `ffmpeg` is on PATH; check disk space |
| tmux session exists | Kill old session: `tmux kill-session -t flosports-rec` |
| Wrong format quality | Re-run setup with `--format <id>` after checking `yt-dlp -F <url>` |
| yt-dlp outdated | Update: `pip install -U yt-dlp` |
