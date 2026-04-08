#!/usr/bin/env bash
# NASA Mission Tracker — active missions, upcoming launches, recent news
# Sources: NASA News RSS (https://www.nasa.gov/feed/)
# No API key required — public RSS feed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/../cache"
mkdir -p "$CACHE_DIR"
SOURCE="nasa"
CACHE_FILE="${CACHE_DIR}/${SOURCE}.json"
CACHE_MAX_AGE=900

force=false
[[ "${1:-}" == "--force" ]] && force=true

if [[ "$force" == "false" && -f "$CACHE_FILE" ]]; then
  file_age=$(( $(date +%s) - $(stat -f %m "$CACHE_FILE" 2>/dev/null || stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0) ))
  if (( file_age < CACHE_MAX_AGE )); then
    cat "$CACHE_FILE"
    exit 0
  fi
fi

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Fetch NASA RSS feed
rss_raw=$(curl -sf --max-time 12 \
  -H "User-Agent: Mozilla/5.0 (compatible; nanobot-osint/1.0)" \
  "https://www.nasa.gov/feed/" 2>/dev/null) || {
  http_status=$(curl -sI --max-time 10 \
    -H "User-Agent: Mozilla/5.0 (compatible; nanobot-osint/1.0)" \
    "https://www.nasa.gov/feed/" 2>/dev/null | head -1 | awk '{print $2}' || echo "000")
  result=$(jq -nc --arg ts "$ts" --arg hs "$http_status" '{
    source: "nasa",
    error: "RSS fetch failed",
    http_status: $hs,
    fetched_at: $ts
  }')
  echo "$result" | tee "$CACHE_FILE"
  exit 0
}

# Write RSS to temp file so Python can read it without stdin conflict
rss_tmp=$(mktemp /tmp/nasa_rss_XXXXXX.xml)
trap 'rm -f "$rss_tmp"' EXIT
echo "$rss_raw" > "$rss_tmp"

# Write Python parser to a temp file (avoids heredoc-stdin conflict with python3 -)
py_tmp=$(mktemp /tmp/nasa_parser_XXXXXX.py)
trap 'rm -f "$rss_tmp" "$py_tmp"' EXIT

cat > "$py_tmp" << 'PYEOF'
import sys, json, re
from xml.etree import ElementTree as ET
from email.utils import parsedate_to_datetime
from datetime import timezone

MISSION_RE = re.compile(
    r'Artemis|ISS|International Space Station|Crew Dragon|Starliner|SLS|'
    r'Space Launch System|Orion|[Ll]aunch|liftoff|flyby|fly-by|EVA|'
    r'splashdown|SpaceX|Boeing|Gateway|lunar|[Mm]oon|[Mm]ars|Hubble|'
    r'Webb|JWST|astronaut|cosmonaut|Perseverance|Ingenuity|Curiosity'
)

rss_file = sys.argv[1]
with open(rss_file, 'r', encoding='utf-8', errors='replace') as f:
    raw = f.read()

# Strip XML namespace declarations so ElementTree can parse without ns prefixes
raw_clean = re.sub(r'\s+xmlns(?::[^=]+)?="[^"]*"', '', raw)
raw_clean = re.sub(r'<(/?)\w+:', '<\\1', raw_clean)

try:
    root = ET.fromstring(raw_clean)
except ET.ParseError as e:
    print(json.dumps({"error": f"XML parse error: {e}"}))
    sys.exit(0)

items = root.findall('.//item')
results = []
for item in items:
    def txt(tag):
        el = item.find(tag)
        return (el.text or '').strip() if el is not None else ''

    title = txt('title')
    link = txt('link')
    pub_date_raw = txt('pubDate')
    description = txt('description')
    # Strip HTML tags and HTML entities from description
    description = re.sub(r'<[^>]+>', '', description)
    description = re.sub(r'&#\d+;|&\w+;', ' ', description).strip()[:250]

    if not title:
        continue
    if not MISSION_RE.search(title + ' ' + description):
        continue

    iso_date = pub_date_raw
    try:
        dt = parsedate_to_datetime(pub_date_raw)
        iso_date = dt.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    except Exception:
        pass

    results.append({'title': title, 'link': link, 'date': iso_date, 'description': description})

for r in results[:30]:
    print(json.dumps(r))
PYEOF

# Parse RSS with Python3 (handles CDATA, namespaces, and multi-line XML reliably)
parsed_items=$(python3 "$py_tmp" "$rss_tmp" 2>/dev/null) || {
  result=$(jq -nc --arg ts "$ts" '{
    source: "nasa",
    error: "RSS parse failed",
    fetched_at: $ts
  }')
  echo "$result" | tee "$CACHE_FILE"
  exit 0
}

# Check for python-level error JSON on first line
first_line=$(echo "$parsed_items" | head -1)
if echo "$first_line" | jq -e '.error' >/dev/null 2>&1; then
  err_msg=$(echo "$first_line" | jq -r '.error')
  result=$(jq -nc --arg ts "$ts" --arg em "$err_msg" '{
    source: "nasa",
    error: $em,
    fetched_at: $ts
  }')
  echo "$result" | tee "$CACHE_FILE"
  exit 0
fi

if [[ -z "$parsed_items" ]]; then
  result=$(jq -nc --arg ts "$ts" '{
    source: "nasa",
    error: "No mission-relevant items found in RSS feed",
    fetched_at: $ts
  }')
  echo "$result" | tee "$CACHE_FILE"
  exit 0
fi

# Convert newline-delimited JSON into a jq array
all_items=$(echo "$parsed_items" | jq -sc '.')

# recent_news: top 10 items
recent_news=$(echo "$all_items" | jq -c '[.[:10][] | {title, date, link}]' 2>/dev/null || echo '[]')

# upcoming_launches: items with launch-related title keywords
upcoming_launches=$(echo "$all_items" | jq -c '[
  .[] | select(
    (.title | ascii_downcase | test("launch|liftoff|launch attempt|launch window|launch date|launch target"))
  ) | {
    mission: .title,
    date: .date,
    link: .link,
    vehicle: (
      if (.title | test("SLS|Space Launch System")) then "SLS"
      elif (.title | test("[Ff]alcon 9|[Ff]alcon [Hh]eavy")) then "Falcon 9/Heavy"
      elif (.title | test("[Vv]ulcan")) then "Vulcan Centaur"
      elif (.title | test("[Nn]ew [Gg]lenn")) then "New Glenn"
      elif (.title | test("[Aa]tlas")) then "Atlas V"
      elif (.title | test("[Ss]tarship")) then "Starship"
      else "TBD"
      end
    ),
    pad: "TBD"
  }
] | .[:5]' 2>/dev/null || echo '[]')

# active_missions: group by mission name, consolidate key_events
active_missions=$(echo "$all_items" | jq -c '
  def tag_mission:
    if test("Artemis") then "Artemis"
    elif test("ISS|International Space Station") then "ISS"
    elif test("Crew Dragon") then "Crew Dragon"
    elif test("Starliner") then "Starliner"
    elif test("Webb|JWST") then "James Webb Space Telescope"
    elif test("Hubble") then "Hubble Space Telescope"
    elif test("[Mm]ars|Perseverance|Ingenuity|Curiosity") then "Mars Missions"
    elif test("Gateway") then "Lunar Gateway"
    elif test("Orion") then "Orion"
    else null
    end;
  [.[] | . + {_tag: (.title | tag_mission)}]
  | [.[] | select(._tag != null)]
  | group_by(._tag)
  | [.[] | {
      name: .[0]._tag,
      type: (
        if   .[0]._tag == "Artemis"                   then "crewed_lunar"
        elif .[0]._tag == "ISS"                        then "space_station"
        elif .[0]._tag == "Crew Dragon"                then "crewed_orbital"
        elif .[0]._tag == "Starliner"                  then "crewed_orbital"
        elif .[0]._tag == "James Webb Space Telescope" then "space_telescope"
        elif .[0]._tag == "Hubble Space Telescope"     then "space_telescope"
        elif .[0]._tag == "Mars Missions"              then "planetary"
        elif .[0]._tag == "Lunar Gateway"              then "lunar_station"
        elif .[0]._tag == "Orion"                      then "crewed_lunar"
        else "mission"
        end
      ),
      status: "active",
      news_count: length,
      latest_update: (.[0].date // ""),
      link: (.[0].link // ""),
      key_events: [.[:5][] | {date: .date, event: .title}]
    }]
  | .[:8]
' 2>/dev/null || echo '[]')

# Assemble final output
result=$(jq -nc \
  --arg ts "$ts" \
  --argjson am "$active_missions" \
  --argjson ul "$upcoming_launches" \
  --argjson rn "$recent_news" \
  '{
    source: "nasa",
    fetched_at: $ts,
    active_missions: $am,
    upcoming_launches: $ul,
    recent_news: $rn
  }') || {
  result=$(jq -nc --arg ts "$ts" '{
    source: "nasa",
    error: "Final JSON assembly failed",
    fetched_at: $ts
  }')
  echo "$result" | tee "$CACHE_FILE"
  exit 0
}

echo "$result" | tee "$CACHE_FILE"
