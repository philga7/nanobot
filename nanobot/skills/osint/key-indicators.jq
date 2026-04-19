# Input: full brief JSON. Args: --argjson desk_api [], --argjson geo_filter null|object,
#   --arg pdb_mode "0"|"1" (optional; default "0"). When "1", PDB intel fields are populated
#   and indicator_lines/data_status are empty for deliver.sh to use pdb_* fields only.
# Output: { "indicator_lines": [...], "data_status": "Data: ..."|null,
#   "pdb_key_indicator_lines": [...], "pdb_promoted_sections": [{topic, lines: [...]}],
#   "pdb_data_notes": "..."|null }

def trunc(s):
  (s | tostring | if length > 200 then .[0:200] + "..." else . end);

def healthy(v):
  ((v.status // "") | (. == "degraded" or . == "checked") | not)
  and ((v.degraded // false) | not)
  and (if (v | has("error")) and (v.error | type == "string") and (v.error != "") then false else true end);

def desk_ok($k):
  ($desk_api | length) == 0 or ($desk_api | index($k) != null);

# Miles between WGS84 points (lat, lon degrees).
def hav_mi($lat1; $lon1; $lat2; $lon2):
  (($lat2 - $lat1) * 0.017453292519943295 / 2) as $dphi
  | (($lon2 - $lon1) * 0.017453292519943295 / 2) as $dlam
  | ($lat1 * 0.017453292519943295) as $phi1
  | ($lat2 * 0.017453292519943295) as $phi2
  | (($dphi | sin) * ($dphi | sin) + ($phi1 | cos) * ($phi2 | cos) * (($dlam | sin) * ($dlam | sin))) as $a
  | (if $a > 1 then 1 elif $a < 0 then 0 else $a end)
  | (2 * 3959 * (. | sqrt | asin));

def in_radius($lat; $lon; $gf):
  ($gf.center // null) as $c
  | if $gf == null or $c == null or ($c | length) < 2 then false
    else
      ($c[0] | tonumber) as $clat
      | ($c[1] | tonumber) as $clon
      | (($gf.radius_miles // 100) | tonumber) as $rm
      | if $lat == null or $lon == null then false
        else hav_mi($lat; $lon; $clat; $clon) <= $rm
        end
    end;

def area_geo_match($area; $gf):
  ($area // "" | ascii_downcase) as $ad
  | (($gf.states // []) | length > 0) as $hs
  | (
      if $hs then
        (($gf.states // []) | map(ascii_downcase | gsub("\\s+"; "") | "\\b" + . + "\\b") | join("|")) as $pat
        | if $pat == "" then false else ($ad | test($pat; "i")) end
      else false end
    )
  or (
      (($gf.counties // [])[] | ascii_downcase) as $co
      | ($ad | contains($co))
    );

def num(v): try (v | tonumber) catch null;

def geo_alert_ok($a; $gf):
  if $gf == null then true
  else
    (area_geo_match($a.area; $gf))
    or (in_radius(num($a.centroid_lat); num($a.centroid_lon); $gf))
  end;

def filter_noaa($v):
  if $geo_filter == null then $v
  else ($v | .alerts = [(.alerts // [])[] | select(geo_alert_ok(.; $geo_filter))])
  end;

def filter_firms($v):
  if $geo_filter == null then $v
  else
    ($v
      | .hotspots = [
          (.hotspots // [])[]
          | select(
              num(.latitude) as $la
              | num(.longitude) as $lo
              | in_radius($la; $lo; $geo_filter)
            )
        ]
      | .count = (.hotspots | length))
  end;

def filter_safecast($v):
  if $geo_filter == null then $v
  else
    ($v
      | .measurements = [
          (.measurements // [])[]
          | select(
              num(.latitude) as $la
              | num(.longitude) as $lo
              | in_radius($la; $lo; $geo_filter)
            )
        ]
      | .count = (.measurements | length))
  end;

# FIRMS/Safecast use headline rows above, not aggregated here.
def count_only_keys:
  ["opensky", "maritime", "kiwisdr", "comtrade", "usaspending", "patents", "epa", "gscpi", "cloudflare", "reddit", "telegram", "ofac", "opensanctions", "celestrak", "space", "reliefweb"];

def pdb_mode_on: (($pdb_mode // "0") == "1");

def count_label($k):
  ({
    opensky: "OpenSky",
    maritime: "Maritime",
    kiwisdr: "KiwiSDR",
    safecast: "Safecast",
    firms: "FIRMS",
    comtrade: "COMTRADE",
    usaspending: "USAspending",
    patents: "Patents",
    epa: "EPA",
    gscpi: "GSCPI",
    cloudflare: "Cloudflare",
    reddit: "Reddit",
    telegram: "Telegram",
    ofac: "OFAC",
    opensanctions: "OpenSanctions",
    celestrak: "Celestrak",
    space: "Space",
    reliefweb: "ReliefWeb",
    gdelt: "GDELT"
  }[$k] // ($k | ascii_upcase));

# PDB Data Notes: short phrases for count-only style sources (see deliver.sh PDB spec).
def pdb_data_note_phrase($k; $n):
  (if $n == null then empty
   elif ($k == "gdelt") then "GDELT \($n) articles"
   elif ($k == "acled") then "ACLED \($n) events"
   elif ($k == "opensky") then "OpenSky \($n) flights"
   elif ($k == "maritime") then "Maritime \($n) tracks"
   elif ($k == "kiwisdr") then "KiwiSDR \($n) hops"
   elif ($k == "comtrade") then "COMTRADE \($n) rows"
   elif ($k == "usaspending") then "USAspending \($n) awards"
   elif ($k == "patents") then "Patents \($n) filings"
   elif ($k == "epa") then "EPA \($n) readings"
   elif ($k == "gscpi") then "GSCPI \($n)"
   elif ($k == "cloudflare") then "Cloudflare \($n) radar points"
   elif ($k == "reddit") then "Reddit \($n) posts"
   elif ($k == "telegram") then "Telegram \($n) messages"
   elif ($k == "ofac") then "OFAC \($n) rows"
   elif ($k == "opensanctions") then "OpenSanctions \($n) rows"
   elif ($k == "celestrak") then "Celestrak \($n) objects"
   elif ($k == "space") then "Space \($n) items"
   elif ($k == "reliefweb") then "ReliefWeb \($n) items"
   else "\(count_label($k)) \($n)" end);

def arrowize_line($line):
  if ($line | type) != "string" then ($line | tostring)
  elif ($line | test("^• \\[")) then
    ($line | capture("^• \\[(?<label>[^\\]]+)\\] (?<tail>.*)$") | "→ " + .label + ": " + .tail)
  else $line end;

def source_row($k; $v):
  if $k == "gold_api" or $k == "forecast_models" then empty
  elif $k == "yfinance" and ($v.markets | type == "object") and (($v.markets | length) > 0) then
    {
      order: 10,
      line: ("• [YFinance] " + trunc(
        [ $v.markets | to_entries[]
          | .key + " $" + (.value.price | tostring) + " ("
            + (if .value.change_pct >= 0 then "+" else "" end)
            + (.value.change_pct | tostring) + "%)"
        ] | join(" | ")
      ))
    }
  elif $k == "fred" then
    [
      ($v.series // {}) | to_entries[] | select((.value | length) > 0)
      | .key as $sid | .value[0] as $obs
      | (
          if $sid == "DFF" then "Fed Funds"
          elif $sid == "UNRATE" then "Unemployment"
          elif $sid == "CPIAUCSL" then "CPI"
          elif $sid == "T10Y2Y" then "10Y-2Y"
          elif $sid == "VIXCLS" then "VIX"
          elif $sid == "MORTGAGE30US" then "30Y Fixed"
          elif $sid == "MORTGAGE15US" then "15Y Fixed"
          else $sid end
        ) as $lab
      | if $sid == "MORTGAGE30US" or $sid == "MORTGAGE15US" then
          $lab + ": " + ($obs.value | tostring) + "%"
        else
          $lab + ": " + ($obs.value | tostring) + " (" + ($obs.date // "") + ")"
        end
    ] as $fparts
    | if ($fparts | length) == 0 then empty
      else { order: 20, line: ("• [FRED] " + trunc($fparts | join(" | "))) }
      end
  elif $k == "treasury" then
    [
      (if (($v.interest_rates // []) | length) > 0 then
        "Rate: \($v.interest_rates[0].security_desc // "") \($v.interest_rates[0].avg_interest_rate_amt // "")%"
      else empty end),
      (if (($v.debt // []) | length) > 0 then
        "Debt $\($v.debt[0].tot_pub_debt_out_amt // "?")"
      else empty end)
    ] | map(select(. != null and (. != ""))) | join(" | ") as $t
    | if $t == "" then empty
      else { order: 21, line: ("• [Treasury] " + trunc($t)) }
      end
  elif $k == "eia" and (($v.data // []) | length > 0) and (($v.count // 1) > 0) then
    {
      order: 22,
      line: ("• [EIA] " + trunc(
        [ ($v.data // [])[0:3][] | "\(.product // "") \(.area // ""): \(.value) \(.units // "")" ] | join(" | ")
      ))
    }
  elif $k == "bls" and (($v.series // []) | length > 0) then
    [
      ($v.series // [])[] | .id as $id | (.data // [])[0] as $d
      | select($d != null)
      | (
          if $id == "LNS14000000" then "Unemployment"
          elif $id == "CUUR0000SA0" then "CPI"
          elif $id == "CES0000000001" then "Payroll"
          else $id end
        ) as $lab
      | $lab + ": " + ($d.value | tostring) + " (" + ($d.period // "") + " " + ($d.year | tostring) + ")"
    ] as $bparts
    | if ($bparts | length) == 0 then empty
      else { order: 23, line: ("• [BLS] " + trunc($bparts | join(" | "))) }
      end
  elif $k == "cisa_kev" then
    ($v | .vulnerabilities // []) as $vulns
    | if ($vulns | length) == 0 then empty
      else
        ($vulns | length) as $cn
        | {
            order: 30,
            line: ("• [CISA KEV] " + trunc(
              "\($cn) in feed: "
                + ([ $vulns[0:3][]
                    | "\(.cveID) (\(.product // .vendorProject // ""))"
                  ] | join(", "))
            ))
          }
      end
  elif $k == "noaa" then
    (filter_noaa($v)) as $nv
    | if (($nv.alerts // []) | length) == 0 then empty
      else
        {
          order: 40,
          line: ("• [NOAA] " + trunc(
            "\(($nv.alerts | length)) alerts: "
              + ([ ($nv.alerts // [])[0:4][]
                  | "\(.event // .headline) - \(.area // "") (\(.severity // ""))"
                ] | join(" | "))
          ))
        }
      end
  elif $k == "who" and (($v.outbreaks // []) | length > 0) then
    {
      order: 41,
      line: ("• [WHO] " + trunc(
        "\(($v.outbreaks | length)): " + ([ ($v.outbreaks // [])[0:3][] | .title ] | join("; "))
      ))
    }
  elif $k == "nasa" and (($v.active_missions // []) | length > 0) then
    {
      order: 42,
      line: ("• [NASA] " + trunc(
        [ ($v.active_missions // [])[0:4][] | "\(.name) (\(.status))" ] | join(" | ")
      ))
    }
  elif $k == "bluesky" and (($v.topics // []) | length > 0) then
    {
      order: 50,
      line: ("• [Bluesky] " + trunc([ ($v.topics // [])[0:5][] | .topic ] | join(", ")))
    }
  elif $k == "gdelt" and (($v.articles // []) | length > 0) then
    (($v.query // "doc") | tostring | if length > 70 then .[0:70] + "..." else . end) as $q
    | {
        order: 36,
        line: (
          "• [GDELT] "
          + trunc(
              "\(($v.articles | length)) articles (\($q)): "
                + ([ ($v.articles // [])[0:3][] | (.title // .url // "?") ] | join(" | "))
            )
        )
      }
  elif $k == "acled" and (($v.count // 0) > 0) then
    { order: 55, line: trunc("• [ACLED] " + ($v.count | tostring) + " events") }
  elif $k == "firms" then
    (filter_firms($v)) as $fv
    | if (($fv.hotspots // []) | length) == 0 or (($fv.count // 0) == 0) then empty
      else
        {
          order: 43,
          line: ("• [FIRMS] " + trunc("\($fv.count) hotspots within filter (sample: "
            + ([ ($fv.hotspots // [])[0:2][]
                | "\(.latitude),\(.longitude)"
              ] | join(" | "))
            + ")"))
        }
      end
  elif $k == "safecast" then
    (filter_safecast($v)) as $sv
    | if (($sv.measurements // []) | length) == 0 or (($sv.count // 0) == 0) then empty
      else
        {
          order: 44,
          line: ("• [Safecast] " + trunc("\($sv.count) readings: "
            + ([ ($sv.measurements // [])[0:3][]
                | "\(.value)\(.unit // "") @\(.latitude),\(.longitude)"
              ] | join(" | "))))
        }
      end
  elif (count_only_keys | index($k) != null) and (($v.count // 0) > 0) then
    { order: 80, kind: "count", key: $k, count: $v.count }
  elif (($v.count // null) != null) and (($v.count | type) == "number") and ($v.count > 0) then
    { order: 85, kind: "count", key: $k, count: $v.count }
  else
    empty
  end;

. as $brief
| [ (.sources // {}) | to_entries[]
  | .key as $k | .value as $v
  | select(healthy($v))
  | select(desk_ok($k))
  | source_row($k; $v)
  | . + {src: $k}
]
| sort_by(.order)
| if pdb_mode_on then
    . as $rows
    | ($rows | map(select(.kind == "count"))) as $counts
    | ($rows | map(select((.line != null) and (.kind != "count")))) as $lined
    | (
        [
          $lined[]
          | select(
              .src == "yfinance" or .src == "fred" or .src == "treasury" or .src == "eia"
              or .src == "bls" or .src == "nasa" or .src == "bluesky" or .src == "safecast"
            )
          | arrowize_line(.line)
        ]
      ) as $pdb_keys
    | (
        [
          ($lined[] | select(.src == "cisa_kev") | {topic: "Cybersecurity", line: arrowize_line(.line)}),
          ($lined[] | select(.src == "noaa") | {topic: "Weather / Alerts", line: arrowize_line(.line)}),
          ($lined[] | select(.src == "who") | {topic: "Health", line: arrowize_line(.line)}),
          ($lined[] | select(.src == "firms") | {topic: "Wildfire", line: arrowize_line(.line)})
        ]
        | group_by(.topic)
        | map({topic: .[0].topic, lines: [.[].line]})
      ) as $pdb_promos
    | (
        [
          ($counts[] | pdb_data_note_phrase(.key; .count)),
          (if (($brief.sources.gdelt.articles // []) | length) > 0 then
             pdb_data_note_phrase("gdelt"; ($brief.sources.gdelt.articles | length))
           else empty end),
          (if (($brief.sources.acled.count // 0) > 0) then
             pdb_data_note_phrase("acled"; $brief.sources.acled.count)
           else empty end)
        ]
        | map(select((. != null) and (. != "")))
        | unique
        | join(" · ")
      ) as $pdb_dn
    | {
        indicator_lines: [],
        data_status: null,
        pdb_key_indicator_lines: $pdb_keys,
        pdb_promoted_sections: $pdb_promos,
        pdb_data_notes: (if ($pdb_dn | length) == 0 then null else $pdb_dn end)
      }
  else
    (map(select(.kind == "count"))
      | map("\(count_label(.key)) \(.count)")
      | join(" | ")
    ) as $ds
    | {
        indicator_lines: (map(select(.line != null)) | map(.line)),
        data_status: (if ($ds | length) == 0 then null else trunc("Data: " + $ds) end),
        pdb_key_indicator_lines: [],
        pdb_promoted_sections: [],
        pdb_data_notes: null
      }
  end
