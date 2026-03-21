# News pipeline JSON (examples)

The pipeline reads config from **`NEWS_PIPELINE_DIR`**, default:

`~/.wrenvps/news-pipeline/`

**Populate that directory** by copying (or symlinking) these files:

```bash
mkdir -p ~/.wrenvps/news-pipeline/history
cp services/news_pipeline/examples/*.json ~/.wrenvps/news-pipeline/
```

Then edit in place:

- **`topics.json`** — your preferred topics + weights, ignored topics
- **`jobs.*.json`** — sources, Slack channels, bird handles, SearXNG queries, weather locations
- **`scoring.json`** — thresholds, templates, routing, and `tuning` coefficients

Optional: point the pipeline elsewhere:

```bash
export NEWS_PIPELINE_DIR=/path/to/your/news-pipeline
```

**Running:** Schedule via cron; run with `--deliver` to post to Slack/ntfy. Dedupe uses `history/*_history.json` (7-day TTL).

```bash
# Example: breaking desk every 15 min
*/15 6-23 * * * cd /path/to/nanobot && NEWS_PIPELINE_DIR=~/.wrenvps/news-pipeline .venv/bin/python -m services.news_pipeline --deliver
```

History and delivery journal are written under `$NEWS_PIPELINE_DIR/history/` at runtime.
