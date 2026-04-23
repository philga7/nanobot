# stdin: brief JSON (rss/twitter arrays)
# --argjson w: raw topic weights object
# --argjson mainstream / alternative / fringe: source handle strings (lowercase)
# --argjson topicless: min composite score when no topic keyword matches

def nonempty(s): ((s // "") | tostring | test("^\\s*$") | not);

def topic_w(t):
  ((t // "") | tostring | ascii_downcase) as $tl
  | ($w | to_entries | map(. as $e | select($tl | contains($e.key | ascii_downcase)) | $e.value) | add // 0);

def src_lc($row):
  (
    if ($row | type) == "object" and (($row | has("text")) or ($row | has("content"))) then
      ($row.handle // $row.user // $row.screen_name // "unknown") | tostring | ltrimstr("@")
    else
      ($row.source // $row.feed // "rss") | tostring
    end
  ) | ascii_downcase;

def tier_s($src):
  ($src | ascii_downcase) as $s
  | if ($mainstream | index($s)) != null then 6
    elif ($alternative | index($s)) != null then 3
    elif ($fringe | index($s)) != null then 1
    else 3
    end;

def is_live_rss($t):
  (($t // "") | tostring | test("^(Watch[[:space:]]+)?Live[[:space:]]*\\|"; "i"));

def is_live_tw($t):
  (($t // "") | tostring | test("^(BREAKING:|LIVE:|🚨)"));

def item_score_rss($row):
  ($row.title // $row.headline // $row.text // "") as $tx
  | topic_w($tx) as $tw
  | (if is_live_rss($tx) then 2 else 0 end) as $lv
  | ($tw * 1.5) + tier_s(src_lc($row)) + $lv + 2;

def item_score_tw($row):
  ($row.text // $row.content // "") as $tx
  | topic_w($tx) as $tw
  | (if is_live_tw($tx) then 2 else 0 end) as $lv
  | ($tw * 1.5) + tier_s(src_lc($row)) + $lv + 2;

.rss |= map(
  . as $row
  | ($row.title // $row.headline // $row.text // "") as $tx
  | select(nonempty($tx))
  | topic_w($tx) as $tw
  | select($tw > 0.00001 or (item_score_rss($row) >= $topicless))
  | $row
)
| .twitter |= map(
  . as $row
  | ($row.text // $row.content // "") as $tx
  | select(nonempty($tx))
  | topic_w($tx) as $tw
  | select($tw > 0.00001 or (item_score_tw($row) >= $topicless))
  | $row
)
