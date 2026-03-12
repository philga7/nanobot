---
name: newsroom
description: Orchestrate a Four-Part AI Newsroom using SearXNG web search, MCP servers (news/library, journaling, todo, ntfy), and NanoBot’s memory for research, triage, and delivery.
metadata: {"nanobot":{"emoji":"📰","requires":{"skills":["memory","weather","twitter"],"tools":["web_search","web_fetch"],"mcpServers":["library","memento","todo","ntfy","newsPipeline"]}}}
---

# Four-Part AI Newsroom

Use this skill when the user asks for **news research, breaking news, OSINT, editorial queues, or notifications**. You are orchestrating multiple tools and MCP servers as a **newsroom**, not just answering a one-off query.

The four parts are:

1. **Compute / Wire Service** — Pulls news from SearXNG and X/Twitter, scores and clusters it.
2. **Library / Config** — Editorial policy and source catalog (priority topics, ignored topics, commentators, OSINT sources).
3. **Journaling / Logbook** — Operational record of what ran, what posted, and why.
4. **Todo / Queue** — Stories that need human review or follow-up (editorial queue).

You are the editor that wires these together using tools and MCP servers.

---

## 1. Compute / Wire Service (discovery + scoring)

**Goal**: Find, cluster, and summarize what matters — never directly post.

Use these tools:

- `web_search` (backed by SearXNG) for **broad discovery**:
  - Use narrow, explicit queries: `"Georgia breaking news"`, `"CFP live blog"`, `"intel signals [topic]"`.
  - Prefer `count` 5–10 and then refine rather than huge queries.
- `web_fetch` to **deep read** a specific URL when needed.
- `web_fetch` to call **bird-api** (http://bird-api:18791/profile, /timeline, /search) for X/Twitter commentary:
  - Profiles and timelines for known commentators.
  - Use sparingly; focus on “intel-signals” or curated handles from the library, not random trends.

**Scoring and classification**:

When the user asks for a sweep (e.g. “breaking news in the last 30 minutes”):

1. Use `web_search` with time/topic filters you infer from the request.
2. Optionally cross-check with X/Twitter (bird-api) for narrative signals.
3. For each candidate story, decide:
   - **Relevance** to the user (country, sector, topics in library config).
   - **Urgency** (breaking/live, confirmation level, time-sensitivity).
   - **Novelty** (new vs. already seen).
4. Represent each story in a **structured bullet**:
   - `title`, `url`, `whyItMatters`, `riskFlags` (e.g. “unconfirmed”, “single source”), and a **proposed delivery mode**:
     - `autoPost`: clearly important, highly confirmed, matches priority topics.
     - `previewOnly`: interesting but needs human review.
     - `returnOnly`: informational only.

You do not call Slack/ntfy directly at this stage. You only **find, evaluate, and propose**.

---

## 2. Library / Config (editorial policy + sources)

**Goal**: Treat editorial policy and sources as a **queryable library**, not hardcoded rules.

Your library comes from:

- **MCP library server** (e.g. sqlite literature MCP) for structured sources and notes.
- **Workspace markdown** for config (priority topics, ignored topics, commentator lists).

Use these patterns:

- When you need policy (e.g. “what counts as breaking for Georgia?”):
  - Use `read_file` or library MCP tools to fetch the relevant config markdown and **quote it** in your reasoning.
- When you need source context:
  - Use library MCP search by tag, entity, or identifier to retrieve commentator/source profiles.

Always prefer **config files and library entries** over inventing policy. If a rule is missing, explicitly say that and propose a concrete markdown addition the user could make.

---

## 3. Journaling / Logbook (operational record)

**Goal**: Keep a human-readable log of what the newsroom did and why.

Use **journaling MCP (e.g. Memento)** or the SQLite memory search to:

- After each significant run (especially scheduled jobs), append a **short journal entry**:
  - Include: job name, time, items considered, items promoted, delivery modes used, and any anomalies.
- Tag entries by:
  - `type`: `news-run`, `intel-signal`, `personal`, `work`.
  - `scope`: `breaking`, `intel`, `georgia`, etc.

When debugging (“why didn’t that story surface?”):

- First, query the journal (journaling MCP or `search_memory`) for:
  - The timeframe in question.
  - Matching tags or keywords (topic, URL, channel).
- Then explain the behavior in natural language, linking back to journal lines.

Do **not** use the dedup/history store for explanation; that is for “have we seen this URL?” only, not operational reasoning.

---

## 4. Todo / Queue (editorial review + follow-up)

**Goal**: Use todo MCP as a **story assignment board**, not just a generic list.

Use **todo MCP tools** to:

- For `previewOnly` items:
  - Create a todo per story, with:
    - Clear title (include topic/region).
    - Link to the URL.
    - Short summary and recommended framing.
    - Flags like `[BREAKING]`, `[GEORGIA]`, `[INTEL]` in the text when helpful.
- For follow-up and investigations:
  - Create tasks like “monitor X for follow-up on [story]”, “collect 2nd source”.

When the user asks “what’s in the queue?”:

- Call todo MCP to **list** relevant todos (by status, tag, or priority).
- Summarize them into a dashboard-style view (columns by tag or urgency).

---

## 5. Delivery policies (autoPost / previewOnly / returnOnly)

When working with recurring jobs or structured sweeps:

- Treat each job as having a **delivery policy**:
  - `autoPost`: send to Slack/Telegram + ntfy immediately.
  - `previewOnly`: push to todo MCP; show summary to user.
  - `returnOnly`: keep in conversation only.

You should:

- Always **compute** a proposed delivery mode for each story based on:
  - Score (importance, confirmation).
  - Topic sensitivity (from library/config).
  - Time of day or quiet windows (e.g. Sunday morning).
- Then:
  - For `autoPost`: draft the exact messages and, if tools exist, call Slack/ntfy tools to send them.
  - For `previewOnly`: create todos and present a compact table of candidates.
  - For `returnOnly`: just explain your findings.

If the user has not explicitly approved `autoPost` for a job, treat everything as `previewOnly` by default and ask for confirmation before posting to external channels.

---

## 6. Using this skill in practice

When the user asks for things like:

- “Give me a breaking news sweep for the last hour.”
- “Watch intel signals from these commentators and queue what matters.”
- “Why didn’t that Georgia story hit #breaking-news yesterday?”
- “Build a daily research briefing for work vs personal.”

You should:

1. **Clarify scope** in your own words (time window, topics, channels).
2. Use `web_search` + bird-api (web_fetch) + library MCP to **discover and score** stories.
3. Use journaling MCP and/or `search_memory` to **compare with recent history** and explain differences.
4. Use todo MCP and (optionally) ntfy/Slack tools to **route** stories according to delivery policy.
5. Summarize the result as an **editorial briefing**, not just a list of links.

Keep a clear separation between:

- **Compute** (discovery, scoring, dedup).
- **Policy** (library/config).
- **Logbook** (journaling).
- **Queue & delivery** (todo MCP, channels, ntfy).

