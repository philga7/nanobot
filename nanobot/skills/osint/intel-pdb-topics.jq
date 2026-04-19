# stdin: normalized brief JSON (same shape deliver.sh uses after brief_json normalization).
# --argjson weights: topic key → numeric weight (already ×10 floored like deliver.sh).
# --argjson promoted_sections: [{topic, lines: [...]}] from key-indicators PDB (optional []).
# --arg desk: "intel" | "balikatan" | ...
# Output: { "topic_sections": "...", "georgia_section": "..." }
# topic_sections: PDB topic blocks (RSS + Twitter merged, Georgia excluded on intel desk).
# georgia_section: lines only (no header); empty string if none.

def nonempty(s): ((s // "") | tostring | test("^\\s*$") | not);

def pretty_topic($k):
  if $k == "Other" then "Other"
  else
    ($k | gsub("_"; " ") | gsub("/"; " / ") | split(" ")
      | map(if length == 0 then "" else (.[0:1] | ascii_upcase) + .[1:] end)
      | join(" "))
  end;

def best_topic($text; $weights):
  ($weights | to_entries
    | map(. as $e | select(($text | ascii_downcase | test($e.key; "i"))) | {key: $e.key, w: $e.value})
  ) as $m
  | if ($m | length) == 0 then {key: "Other", w: 0}
    else ($m | max_by(.w))
    end;

def is_georgia_rss($r):
  (($r.title // "") + " " + ($r.headline // "") + " " + ($r.description // "") + " " + ($r.summary // "")
    | ascii_downcase) as $b
  | (
      (($r.category // "") | test("georgia"; "i"))
      or (($r.source // "") | test("capitol-beat|ga-pundit|georgia-recorder|georgia-recorder-local|gpb-georgia|ajc|gpb|georgia"; "i"))
      or (($r.feed // "") | test("capitol-beat|ga-pundit|georgia-recorder|georgia-recorder-local|gpb-georgia|ajc|gpb|georgia"; "i"))
      or ($b | test("georgia|atlanta|kemp|warnock|ossoff|fani willis|ajc|gpb|gop"; "i"))
    );

def trunc(s; $n):
  ((s // "") | tostring | if length > $n then .[0:$n] + "..." else . end);

def ts_num($t):
  if $t == null or $t == "" then 0
  else (try ($t | tostring | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) catch 0)
  end;

def rss_rows:
  (.rss // [])
  | map(
      . as $r
      | ($r.title // $r.headline // $r.text // "") as $tx
      | select(nonempty($tx))
      | ($r.source // $r.feed // "RSS") as $src
      | ($r.published // $r.pubDate // $r.pub_date // $r.date // $r.fetched_at // "") as $ts
      | best_topic($tx; $weights) as $bt
      | $r + {
          _kind: "rss",
          _text: $tx,
          _src: $src,
          _topic: $bt.key,
          _w: $bt.w,
          _geo: (is_georgia_rss($r)),
          _ts: (ts_num($ts))
        }
    );

def tw_rows:
  (.twitter // [])
  | map(
      . as $t
      | ($t.text // $t.content // "") as $tx
      | select(nonempty($tx))
      | ("@" + (($t.handle // $t.user // $t.screen_name // "unknown") | tostring | ltrimstr("@"))) as $hdl
      | ($t.created_at // $t.date // $t.fetched_at // "") as $ts
      | best_topic($tx; $weights) as $bt
      | $t + {
          _kind: "tw",
          _text: $tx,
          _src: $hdl,
          _topic: $bt.key,
          _w: $bt.w,
          _geo: false,
          _ts: (ts_num($ts))
        }
    );

def fmt_line($src; $tit):
  "→ " + ($src | tostring) + ": " + $tit;

def promo_agg($topicname):
  ($topicname | ascii_downcase) as $tl
  | ($weights | to_entries
    | map(. as $e | select(
        ($tl | test($e.key; "i"))
        or ($e.key | ascii_downcase | contains($tl))
        or ($tl | contains($e.key | ascii_downcase))
      ))
    | map(.value) | add) // (($topicname | length) + 40);

def slug_topic($t):
  ($t | tostring | ascii_downcase | gsub("[^a-z0-9]+"; ""));

(
  [rss_rows[], tw_rows[]]
  | if $desk == "intel" then map(if ._kind == "rss" and ._geo then empty else . end) else . end
) as $pool
| (if $desk == "intel" then [(.rss // [])[] | select(is_georgia_rss(.)) | . as $r | ($r.title // $r.headline // $r.text // "") as $tx | select(nonempty($tx)) | fmt_line(($r.source // $r.feed // "RSS"); trunc($tx; 150))] | unique | .[0:5] else [] end) as $geo_lines
| ($pool | group_by(._topic)) as $groups
| ($groups
    | map({
        topic: .[0]._topic,
        agg: (map(._w) | add // 0),
        lines: (
          sort_by(-._w, -._ts)
          | unique_by(._text)
          | .[0:8]
          | map(
              if ._kind == "rss" then fmt_line(._src; trunc(._text; 150))
              else fmt_line(._src; trunc(._text; 200))
              end
            )
        )
      })
    | sort_by(-.agg)
  ) as $rss_sorted
| (
    ($promoted_sections // [])
    | map({topic, agg: promo_agg(.topic), lines: (.lines // [])})
  ) as $promo_blocks
| (
    ($rss_sorted + $promo_blocks)
    | map(. + {slug: slug_topic(.topic)})
    | group_by(.slug)
    | map({
        topic: (. | map(.topic) | unique | max_by(length)),
        agg: (map(.agg) | add),
        lines: (map(.lines) | flatten | unique)
      })
    | sort_by(-.agg)
  ) as $sorted
| {
    topic_sections: (
      $sorted
      | map(select((.lines | length) > 0))
      | map(
          "**" + pretty_topic(.topic) + "**\n"
            + "[Agent: write 1-2 sentence narrative summary]\n"
            + (.lines | join("\n"))
        )
      | join("\n\n")
    ),
    georgia_section: (
      if ($geo_lines | length) == 0 then ""
      else "[Agent: write 1-2 sentence summary]\n" + ($geo_lines | join("\n"))
      end
    )
  }
