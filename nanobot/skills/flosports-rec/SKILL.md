---
name: flosports-rec
description: "Semi-automated Flosports live stream recording controller with multi-channel support. Record up to 3 simultaneous streams per WGI/DCI classification with automatic file naming, sequential numbering, and split-file merging via yt-dlp and ffmpeg."
metadata: {"nanobot":{"emoji":"🎥","os":["darwin","linux"],"requires":{"bins":["yt-dlp","ffmpeg","tmux","jq","python3"]}}}
---

# Flosports Live Stream Recorder

Semi-automated recording controller for Flosports live streams (FloMarching,
FloDrums, etc.) with multi-channel support. Record up to 3 simultaneous streams
organized by WGI/DCI classification. The operator decides when to start/stop per
group; the skill handles file naming, merging, and organization.

## Prerequisites

- `yt-dlp` (latest -- `pip install -U yt-dlp`)
- `ffmpeg` (for merging split audio/video files)
- `tmux` (session management)
- `jq` (JSON state management)
- `python3` (for serve command file server)
- Flosports account with active subscription
- Cookies exported to `~/.wrenvps/flosports/cookies.txt`

## Cookie Setup

Export cookies once before event day. The skill checks for cookies in this order:

1. `~/.wrenvps/flosports/cookies.txt` (preferred -- Netscape format)
2. `--cookies-from-browser chrome` (fallback if Chrome is available)

To export cookies:

```bash
# Option A: Use yt-dlp to export from Chrome
yt-dlp --cookies-from-browser chrome --cookies ~/.wrenvps/flosports/cookies.txt \
  --simulate "https://www.flomarching.com/live/12345"

# Option B: Use a browser extension (EditThisCookie, Get cookies.txt)
# Export from FloMarching after logging in, save to ~/.wrenvps/flosports/cookies.txt
```

## Multi-Channel Architecture

Each channel maps to a WGI classification or custom label. Channels are
independent -- each has its own stream URL, format, counter, and recorded list.

Common channel names: `sa` (Scholastic A), `so` (Scholastic Open),
`sw` (Scholastic World), `ia` (Independent A), `io` (Independent Open),
`iw` (Independent World), or any custom name like `main`.

Up to 3 channels can record simultaneously, each in its own tmux window.

## Commands

### setup

Validate a stream URL and prepare a recording session or add a channel.

```bash
# First call: creates session + first channel
bash {baseDir}/scripts/setup.sh <url> --channel sa --event-name "WGI World Championships"

# Add more channels to existing session
bash {baseDir}/scripts/setup.sh <url2> --channel sw
bash {baseDir}/scripts/setup.sh <url3> --channel iw --format 3047+audio-0-eng
```

Options:
- `--channel NAME` -- channel name (default: `main`)
- `--format FORMAT` -- yt-dlp format selector (default: `bv+ba`)
- `--event-name NAME` -- event name for directory (first call only)

### start

Begin recording for a named group on a channel.

```bash
bash {baseDir}/scripts/record.sh start --channel sa "Avon HS"
bash {baseDir}/scripts/record.sh start --channel sw "Colony HS"
```

### stop

Stop the current recording on a channel.

```bash
bash {baseDir}/scripts/record.sh stop --channel sa
```

### status

Show recording state. Without `--channel`, shows all channels.

```bash
bash {baseDir}/scripts/record.sh status
bash {baseDir}/scripts/record.sh status --channel sa
```

### list

Show recorded groups. Without `--channel`, shows all channels.

```bash
bash {baseDir}/scripts/record.sh list
bash {baseDir}/scripts/record.sh list --channel sa
```

### serve

Start a lightweight file server (Python http.server) on port 8765 serving
the event output directory. Opens the firewall port via ufw.

```bash
bash {baseDir}/scripts/record.sh serve
```

- Launches `python3 -m http.server 8765` in background
- Runs `ufw allow 8765/tcp` to open the port
- Reports download URLs for all channels
- PID saved to `~/.wrenvps/flosports/serve.pid`

### serve-down

Stop the file server and close the firewall port.

```bash
bash {baseDir}/scripts/record.sh serve-down
```

- Kills the background Python server process
- Runs `ufw delete allow 8765/tcp` to close the port
- No auto-cleanup -- the user decides when to take it down

## Directory Layout

```
~/Flosports/
  2026-04-10_WGI-World-Championships/
    sa/
      01_Avon-HS.mp4
      02_Jefferson-HS.mp4
    sw/
      01_Colony-HS.mp4
      02_Shelton-HS.mp4
    iw/
      01_Aimachi.mp4
```

- One folder per event, named `date_Event-Name`
- Subdirectory per channel
- Files numbered sequentially within each channel
- Group names sanitized: spaces to hyphens, special chars removed

## Session State

Stored at `~/.wrenvps/flosports/session.json`:

```json
{
  "event_name": "WGI World Championships",
  "event_date": "2026-04-10",
  "output_dir": "/root/Flosports/2026-04-10_WGI-World-Championships",
  "channels": {
    "sa": {
      "stream_url": "https://www.flomarching.com/live/12345",
      "format": "bv+ba",
      "counter": 2,
      "status": "stopped",
      "current_group": null,
      "start_time": null,
      "recorded": [
        {"number": 1, "name": "Avon HS", "file": "01_Avon-HS.mp4", "size_mb": 245},
        {"number": 2, "name": "Jefferson HS", "file": "02_Jefferson-HS.mp4", "size_mb": 312}
      ]
    },
    "sw": {
      "stream_url": "https://www.flomarching.com/live/67890",
      "format": "bv+ba",
      "counter": 1,
      "status": "recording",
      "current_group": "Colony HS",
      "start_time": 1712764800,
      "recorded": []
    }
  }
}
```

## tmux Layout

One tmux session `flosports-rec` with a window per active channel:

```
Window 0 (sa):  yt-dlp recording Scholastic A stream
Window 1 (sw):  yt-dlp recording Scholastic World stream
Window 2 (iw):  yt-dlp recording Independent World stream
```

- Attach: `tmux attach -t flosports-rec`
- Switch windows: `Ctrl+b n` (next) / `Ctrl+b p` (previous)
- Window names match channel names for easy identification

## Edge Cases

- **Stream goes down mid-recording:** yt-dlp exits; stop detects this, finalizes what was captured, and alerts the operator.
- **Disk space:** setup checks available disk. Warns if less than 5 GB free.
- **Cookies expire:** yt-dlp fails with auth error. Re-export cookies and re-run setup.
- **Special characters in group name:** Sanitized to hyphens. `"Jefferson HS (SRA)"` becomes `Jefferson-HS-SRA`.
- **Double start on same channel:** If channel status is already `recording`, refuses and warns. Run `stop` first.
- **Max channels:** Warns if adding more than 3 channels (system limit for simultaneous streams).
- **Interrupted session:** Session state is persisted after each operation. Counter and file list survive restarts.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `ERROR: cookies` | Re-export cookies to `~/.wrenvps/flosports/cookies.txt` |
| Split files not merging | Ensure `ffmpeg` is on PATH; check disk space |
| tmux session exists | Kill old session: `tmux kill-session -t flosports-rec` |
| Wrong format quality | Re-run setup with `--format id` after checking `yt-dlp -F url` |
| yt-dlp outdated | Update: `pip install -U yt-dlp` |
| Channel window missing | Re-run setup for that channel to recreate the tmux window |
| Port 8765 in use | Run `serve-down` first, or check `lsof -i :8765` |
| ufw rule not added | Run with sudo, or manually: `sudo ufw allow 8765/tcp` |
