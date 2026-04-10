def trunc(s):
  (s | tostring | if length > 200 then .[0:200] + "..." else . end);

def healthy(v):
  ((v.status // "") | (. == "degraded" or . == "checked") | not)
  and ((v.degraded // false) | not)
  and (if (v | has("error")) and (v.error | type == "string") and (v.error != "") then false else true end);

def count_only_keys:
  ["opensky", "maritime", "kiwisdr", "safecast", "firms", "comtrade", "usaspending", "patents", "epa", "gscpi", "cloudflare", "reddit", "telegram", "ofac", "opensanctions", "celestrak", "space", "reliefweb"];

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
    reliefweb: "ReliefWeb"
  }[$k] // ($k | ascii_upcase));

[ (.sources // {}) | to_entries[]
  | .key as $k | .value as $v
  | select($k != "gdelt")
  | select(healthy($v))
  | if $k == "yfinance" and ($v.markets | type == "object") and (($v.markets | length) > 0) then
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
          else $sid end
        ) as $lab
      | $lab + ": " + ($obs.value | tostring) + " (" + ($obs.date // "") + ")"
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
  elif $k == "cisa_kev" and (($v.vulnerabilities // []) | length > 0) then
    (($v.vulnerabilities | length)) as $cn
    | {
        order: 30,
        line: ("• [CISA KEV] " + trunc(
          "\($cn) in feed: "
            + ([ ($v.vulnerabilities // [])[0:3][]
                | "\(.cveID) (\(.product // .vendorProject // ""))"
              ] | join(", "))
        ))
      }
  elif $k == "noaa" and (($v.alerts // []) | length > 0) and (($v.count // 1) > 0) then
    {
      order: 40,
      line: ("• [NOAA] " + trunc(
        "\(($v.alerts | length)) alerts: "
          + ([ ($v.alerts // [])[0:4][]
              | "\(.event // .headline) - \(.area // "") (\(.severity // ""))"
            ] | join(" | "))
      ))
    }
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
  elif $k == "acled" and (($v.count // 0) > 0) then
    { order: 55, line: trunc("• [ACLED] " + ($v.count | tostring) + " events") }
  elif (count_only_keys | index($k) != null) and (($v.count // 0) > 0) then
    { order: 80, line: trunc("• [" + count_label($k) + "] " + (($v.count | tostring) + " records")) }
  elif (($v.count // null) != null) and (($v.count | type) == "number") and ($v.count > 0) then
    { order: 85, line: trunc("• [\($k | ascii_upcase)] " + (($v.count | tostring) + " records")) }
  else
    empty
  end
  | select(. != null)
]
| sort_by(.order)
| .[].line
