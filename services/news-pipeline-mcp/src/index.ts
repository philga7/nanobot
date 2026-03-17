import { readFile, writeFile, mkdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join } from "node:path";
import os from "node:os";

import { Server, StdioServerTransport } from "@modelcontextprotocol/server";

type NewsJobId = "breaking-news-sweep" | "intel-signals-sweep" | string;

type DeliveryMode = "autoPost" | "previewOnly" | "returnOnly";

interface DeliveryPolicy {
  mode: DeliveryMode;
  channels?: string[];
  ntfy?: boolean;
}

interface NewsItem {
  title: string;
  url: string;
  snippet: string;
  score: number;
  reasons: string[];
  flags: string[];
  seenBefore: boolean;
  source: "searxng" | "bird" | "system";
}

interface HistoryEntry {
  lastSeen: string;
  jobId: string;
  /** Channel names this URL was posted to (e.g. #breaking-news, #intel-signals). Merged across jobs. */
  channels?: string[];
}

interface HistoryStore {
  [url: string]: HistoryEntry;
}

function getBaseDir(): string {
  return (
    process.env.NANOBOT_BASE_DIR ||
    process.env.OPENCLAW_BASE_DIR ||
    "/root/.openclaw"
  );
}

function getSearxngBaseUrl(): string {
  return (process.env.SEARXNG_BASE_URL || "http://searxng:8080").replace(/\/+$/, "");
}

function getWrenNewsDir(): string {
  const homeDir = process.env.HOME || os.homedir();
  const defaultDir = join(homeDir, ".wrenvps", "news-pipeline");
  return (process.env.WRENVPS_NEWS_DIR || defaultDir).replace(/\/+$/, "");
}

const FILE_PRIORITY_TOPICS = "priority-topics.md";
const FILE_GEORGIA_PRIORITY = "georgia-priority.md";
const FILE_GEORGIA_SOURCES = "georgia-sources.md";
const FILE_STANDARD_SOURCES = "standard-sources.md";
const FILE_METALS_BASELINE = "metals-baseline.json";

const BIRD_API_BASE_URL =
  (process.env.BIRD_API_BASE_URL || "http://localhost:18791").replace(/\/+$/, "");
const BIRD_API_TIMELINE_PATH = "/timeline";

const GOLD_API_BASE_URL =
  (process.env.GOLD_API_BASE_URL || "https://gold-api.com").replace(/\/+$/, "");
const GOLD_API_ASSETS_PATH = "/assets";

function getNewsDataDir(): string {
  const candidate =
    process.env.NEWS_DATA_DIR ||
    (existsSync(join(process.cwd(), "data")) ? join(process.cwd(), "data") : null) ||
    join(getBaseDir(), "news");
  return candidate.replace(/\/+$/, "");
}

/** Parse non-empty lines from markdown/text; strip list markers and leading #. */
function parseLinesFromFile(content: string): string[] {
  return content
    .split(/\r?\n/)
    .map((line) => line.replace(/^\s*[-*#]\s*|\s*#+\s*$|^\d+\.\s*/g, "").trim())
    .filter((line) => line.length > 0);
}

async function loadPriorityTopics(): Promise<string[]> {
  const dataDir = getNewsDataDir();
  const path = join(dataDir, FILE_PRIORITY_TOPICS);
  if (!existsSync(path)) return [];
  try {
    const raw = await readFile(path, "utf-8");
    return parseLinesFromFile(raw);
  } catch {
    return [];
  }
}

async function loadMajorEvents(): Promise<string[]> {
  const dataDir = getNewsDataDir();
  const path = join(dataDir, "major-events.md");
  if (!existsSync(path)) return [];
  try {
    const raw = await readFile(path, "utf-8");
    return parseLinesFromFile(raw).map((s) => s.toLowerCase());
  } catch {
    return [];
  }
}

async function loadGeorgiaPriorityTopics(): Promise<string[]> {
  const dir = getWrenNewsDir();
  const path = join(dir, FILE_GEORGIA_PRIORITY);
  if (!existsSync(path)) return [];
  try {
    const raw = await readFile(path, "utf-8");
    return parseLinesFromFile(raw);
  } catch {
    return [];
  }
}

async function loadGeorgiaSources(): Promise<string[]> {
  const dir = getWrenNewsDir();
  const georgiaPath = join(dir, FILE_GEORGIA_SOURCES);
  const standardPath = join(dir, FILE_STANDARD_SOURCES);
  const handles: string[] = [];

  if (existsSync(georgiaPath)) {
    try {
      const raw = await readFile(georgiaPath, "utf-8");
      handles.push(...parseLinesFromFile(raw));
    } catch {
      // ignore
    }
  }

  if (existsSync(standardPath)) {
    try {
      const raw = await readFile(standardPath, "utf-8");
      handles.push(...parseLinesFromFile(raw));
    } catch {
      // ignore
    }
  }

  return Array.from(new Set(handles));
}

function isGeorgiaTopicText(
  title: string,
  snippet: string,
  georgiaTopics: string[]
): boolean {
  if (georgiaTopics.length === 0) return false;
  const haystack = `${title}\n${snippet}`;
  return georgiaTopics.some((topic) => {
    if (!topic) return false;
    try {
      const re = new RegExp(topic, "i");
      return re.test(haystack);
    } catch {
      return haystack.toLowerCase().includes(topic.toLowerCase());
    }
  });
}

async function isGeorgiaTopic(
  title: string,
  snippet: string
): Promise<boolean> {
  const georgiaTopics = await loadGeorgiaPriorityTopics();
  return isGeorgiaTopicText(title, snippet, georgiaTopics);
}

async function fetchBirdTimelines(): Promise<NewsItem[]> {
  const handles = await loadGeorgiaSources();
  if (handles.length === 0) {
    return [];
  }

  const limited = handles.slice(0, 10);
  const items: NewsItem[] = [];

  for (const handle of limited) {
    const url = `${BIRD_API_BASE_URL}${BIRD_API_TIMELINE_PATH}?handle=${encodeURIComponent(
      handle
    )}`;
    try {
      const res = await fetch(url, { method: "GET" });
      if (!res.ok) continue;
      const body: any = await res.json();
      const tweets: any[] = Array.isArray(body?.tweets) ? body.tweets : [];
      for (const tweet of tweets) {
        const text = String(tweet.text ?? "");
        const tweetUrl = String(tweet.url ?? "");
        const { score, reasons, flags } = await parseTweetScore(text);
        items.push({
          title: text.slice(0, 120),
          url: tweetUrl,
          snippet: text,
          score,
          reasons,
          flags,
          seenBefore: false,
          source: "bird"
        });
      }
    } catch {
      // best-effort; skip failures
      continue;
    }
  }

  return items;
}

async function parseTweetScore(
  text: string
): Promise<{ score: number; reasons: string[]; flags: string[] }> {
  const [priorityTopics, majorEvents] = await Promise.all([
    loadPriorityTopics(),
    loadMajorEvents()
  ]);

  const reasons: string[] = [];
  const flags: string[] = [];
  let score = 5;

  const upper = text.toUpperCase();
  if (upper.includes("BREAKING")) {
    score += 3;
    reasons.push("Tweet contains 'BREAKING'");
  }
  if (upper.includes("LIVE")) {
    score += 1.5;
    reasons.push("Tweet contains 'LIVE'");
  }

  if (
    majorEvents.length > 0 &&
    majorEvents.some((k) => text.toLowerCase().includes(k))
  ) {
    score += 2;
    reasons.push("Major event keyword (tweet)");
  }

  if (
    priorityTopics.length > 0 &&
    priorityTopics.some((t) => text.includes(t))
  ) {
    score *= 1.5;
    reasons.push("Priority topic (tweet)");
  }

  if (!text.trim()) {
    flags.push("incomplete");
  }

  return { score, reasons, flags };
}

type MetalsBaseline = Record<string, number>;

type MetalsDelta = {
  symbol: string;
  baseline: number;
  current: number;
  changePct: number;
};

async function loadMetalsBaseline(): Promise<MetalsBaseline | null> {
  const dir = getWrenNewsDir();
  const path = join(dir, FILE_METALS_BASELINE);
  if (!existsSync(path)) return null;
  try {
    const raw = await readFile(path, "utf-8");
    return JSON.parse(raw) as MetalsBaseline;
  } catch {
    return null;
  }
}

async function fetchCurrentMetals(): Promise<MetalsBaseline | null> {
  const url = `${GOLD_API_BASE_URL}${GOLD_API_ASSETS_PATH}`;
  try {
    const res = await fetch(url, { method: "GET" });
    if (!res.ok) return null;
    const text = await res.text();
    // Placeholder: callers can refine this to parse real JSON when wiring the API.
    // For now, we do not attempt to parse HTML; return null so callers treat it as no-change.
    void text;
    return null;
  } catch {
    return null;
  }
}

async function checkMetalsChange(): Promise<{
  alert: boolean;
  deltas: MetalsDelta[];
}> {
  const baseline = await loadMetalsBaseline();
  const current = await fetchCurrentMetals();
  if (!baseline || !current) {
    return { alert: false, deltas: [] };
  }

  const deltas: MetalsDelta[] = [];
  for (const [symbol, basePrice] of Object.entries(baseline)) {
    const cur = current[symbol];
    if (typeof cur !== "number" || basePrice === 0) continue;
    const changePct = ((cur - basePrice) / basePrice) * 100;
    deltas.push({ symbol, baseline: basePrice, current: cur, changePct });
  }

  const alert = deltas.some((d) => Math.abs(d.changePct) >= 5);
  return { alert, deltas };
}

async function checkCFPBadge(url: string): Promise<{ breaking: boolean; live: boolean }> {
  if (!url.includes("citizenfreepress.com")) {
    return { breaking: false, live: false };
  }
  try {
    const res = await fetch(url);
    const html = await res.text();
    const breaking =
      html.includes("breaking-badge") || html.includes("BREAKING");
    const live = html.includes("live-badge") || html.includes("LIVE");
    return { breaking, live };
  } catch {
    return { breaking: false, live: false };
  }
}

async function ensureDir(path: string): Promise<void> {
  if (!existsSync(path)) {
    await mkdir(path, { recursive: true });
  }
}

async function loadHistory(): Promise<HistoryStore> {
  const baseDir = getBaseDir();
  const historyPath = join(baseDir, "news_history.json");
  if (!existsSync(historyPath)) {
    return {};
  }
  try {
    const raw = await readFile(historyPath, "utf-8");
    return JSON.parse(raw) as HistoryStore;
  } catch {
    return {};
  }
}

async function saveHistory(history: HistoryStore): Promise<void> {
  const baseDir = getBaseDir();
  await ensureDir(baseDir);
  const historyPath = join(baseDir, "news_history.json");
  await writeFile(historyPath, JSON.stringify(history, null, 2), "utf-8");
}

function nowIso(): string {
  return new Date().toISOString();
}

async function searxngSearch(query: string, maxItems: number): Promise<NewsItem[]> {
  const [priorityTopics, majorEvents, georgiaTopics] = await Promise.all([
    loadPriorityTopics(),
    loadMajorEvents(),
    loadGeorgiaPriorityTopics()
  ]);

  const baseUrl = getSearxngBaseUrl();
  const url = `${baseUrl}/search?q=${encodeURIComponent(
    query
  )}&format=json&categories=news&language=en`;

  const res = await fetch(url, { method: "GET" });
  if (!res.ok) {
    throw new Error(`SearXNG search failed (${res.status}) for query: ${query}`);
  }
  const data: any = await res.json();
  const results: any[] = Array.isArray(data.results) ? data.results : [];
  const sliced = results.slice(0, maxItems);
  const items: NewsItem[] = [];

  for (let idx = 0; idx < sliced.length; idx++) {
    const r = sliced[idx];
    const title = String(r.title ?? "");
    const itemUrl = String(r.url ?? "");
    const snippet = String(r.content ?? r.snippet ?? "");

    const reasons: string[] = [];
    const flags: string[] = [];
    let score = 5 - idx * 0.1; // base score by rank

    const upperTitle = title.toUpperCase();
    if (upperTitle.includes("BREAKING")) {
      score += 3;
      reasons.push("Title contains 'BREAKING'");
    }
    if (upperTitle.includes("LIVE")) {
      score += 1.5;
      reasons.push("Title contains 'LIVE'");
    }
    if (
      majorEvents.length > 0 &&
      majorEvents.some((k) => title.toLowerCase().includes(k))
    ) {
      score += 2;
      reasons.push("Major event keyword");
    }
    if (
      priorityTopics.length > 0 &&
      priorityTopics.some((t) => title.includes(t) || snippet.includes(t))
    ) {
      score *= 1.5;
      reasons.push("Priority topic");
    }

    const georgia = isGeorgiaTopicText(title, snippet, georgiaTopics);
    if (georgia) {
      flags.push("georgia-topic");
      reasons.push("Georgia priority topic");
    }

    if (!title || !itemUrl) {
      flags.push("incomplete");
    }

    const item: NewsItem = {
      title,
      url: itemUrl,
      snippet,
      score,
      reasons,
      flags,
      seenBefore: false,
      source: "searxng"
    };

    if (itemUrl.includes("citizenfreepress.com")) {
      const badges = await checkCFPBadge(itemUrl);
      if (badges.breaking) {
        item.score += 4;
        item.reasons.push("CFP BREAKING badge");
      }
      if (badges.live) {
        item.score += 3;
        item.reasons.push("CFP LIVE badge");
      }
    }

    items.push(item);
  }

  return items;
}

function chooseDeliveryPolicy(
  jobId: NewsJobId,
  items: NewsItem[]
): DeliveryPolicy {
  if (jobId === "breaking-news-sweep") {
    return {
      mode: "autoPost",
      // ntfy is job-level; enable if we have at least one breaking-level item.
      ntfy: items.some((it) => it.score >= 10)
    };
  }
  if (jobId === "intel-signals-sweep") {
    return {
      mode: "previewOnly",
      channels: ["#intel-signals"],
      ntfy: false
    };
  }
  return { mode: "returnOnly" };
}

async function runBreakingNewsSweep(
  params: Record<string, unknown>,
  history: HistoryStore
): Promise<{ items: NewsItem[]; updatedHistory: HistoryStore }> {
  const topicsParam = params.topics;
  const topics =
    Array.isArray(topicsParam) && topicsParam.length > 0
      ? (topicsParam as string[])
      : ["breaking news", "live updates", "top stories"];

  const maxItems = typeof params.maxItems === "number" ? params.maxItems : 15;

  const allItems: NewsItem[] = [];
  for (const topic of topics) {
    try {
      const items = await searxngSearch(topic, maxItems);
      allItems.push(...items);
    } catch (e) {
      // If one query fails, continue with others
      allItems.push({
        title: `Error querying SearXNG for: ${topic}`,
        url: "",
        snippet: String(e instanceof Error ? e.message : e),
        score: 0,
        reasons: ["error"],
        flags: ["error"],
        seenBefore: false,
        source: "searxng"
      });
    }
  }

  // Precious metals check vs baseline; add a synthetic alert item if +/-5% change detected.
  try {
    const metals = await checkMetalsChange();
    if (metals.alert) {
      allItems.push({
        title: "Precious metals move exceeds +/-5% vs baseline",
        url: "",
        snippet: JSON.stringify(
          metals.deltas,
          (_, value) =>
            typeof value === "number" ? Number(value.toFixed(2)) : value,
          2
        ),
        score: 10,
        reasons: ["Precious metals change alert"],
        flags: ["metals-alert"],
        seenBefore: false,
        source: "system"
      });
    }
  } catch {
    // best-effort; ignore failures
  }

  // Deduplicate by URL and mark seenBefore
  const byUrl = new Map<string, NewsItem>();
  for (const item of allItems) {
    if (!item.url) continue;
    const existing = byUrl.get(item.url);
    if (!existing || item.score > existing.score) {
      const seen = history[item.url] != null;
      byUrl.set(item.url, { ...item, seenBefore: seen });
    }
  }

  const deduped = Array.from(byUrl.values()).sort((a, b) => b.score - a.score);

  const policy = chooseDeliveryPolicy("breaking-news-sweep", deduped);
  const jobChannels = policy.channels ?? [];
  const updatedHistory: HistoryStore = { ...history };
  const ts = nowIso();
  for (const item of deduped) {
    if (!item.url) continue;
    const existing = history[item.url];
    const channels = existing?.channels?.length
      ? [...new Set([...existing.channels, ...jobChannels])]
      : jobChannels;
    updatedHistory[item.url] = {
      lastSeen: ts,
      jobId: "breaking-news-sweep",
      channels: channels.length ? channels : undefined
    };
  }

  return { items: deduped, updatedHistory };
}

async function runIntelSignalsSweep(
  params: Record<string, unknown>,
  history: HistoryStore
): Promise<{ items: NewsItem[]; updatedHistory: HistoryStore }> {
  // Reuse a narrower SearXNG search and incorporate bird timelines.
  const topicsParam = params.topics;
  const topics =
    Array.isArray(topicsParam) && topicsParam.length > 0
      ? (topicsParam as string[])
      : ["intel signals", "analysis", "geopolitics commentary"];

  const maxItems = typeof params.maxItems === "number" ? params.maxItems : 10;

  const allItems: NewsItem[] = [];
  for (const topic of topics) {
    try {
      const items = await searxngSearch(topic, maxItems);
      // Bias scores lower than breaking sweep
      for (const it of items) {
        it.score -= 1;
        it.reasons.push("intel-signals sweep");
      }
      allItems.push(...items);
    } catch (e) {
      allItems.push({
        title: `Error querying SearXNG for: ${topic}`,
        url: "",
        snippet: String(e instanceof Error ? e.message : e),
        score: 0,
        reasons: ["error"],
        flags: ["error"],
        seenBefore: false,
        source: "searxng"
      });
    }
  }

  // Bird timelines for intel signals
  try {
    const birdItems = await fetchBirdTimelines();
    for (const it of birdItems) {
      it.score -= 1;
      it.reasons.push("intel-signals tweet");
    }
    allItems.push(...birdItems);
  } catch {
    // best-effort
  }

  const byUrl = new Map<string, NewsItem>();
  for (const item of allItems) {
    if (!item.url) continue;
    const existing = byUrl.get(item.url);
    if (!existing || item.score > existing.score) {
      const seen = history[item.url] != null;
      byUrl.set(item.url, { ...item, seenBefore: seen });
    }
  }

  const deduped = Array.from(byUrl.values()).sort((a, b) => b.score - a.score);

  const policy = chooseDeliveryPolicy("intel-signals-sweep", deduped);
  const jobChannels = policy.channels ?? [];
  const updatedHistory: HistoryStore = { ...history };
  const ts = nowIso();
  for (const item of deduped) {
    if (!item.url) continue;
    const existing = history[item.url];
    const channels = existing?.channels?.length
      ? [...new Set([...existing.channels, ...jobChannels])]
      : jobChannels;
    updatedHistory[item.url] = {
      lastSeen: ts,
      jobId: "intel-signals-sweep",
      channels: channels.length ? channels : undefined
    };
  }

  return { items: deduped, updatedHistory };
}

type NewsRunJobArgs = {
  jobId?: string;
  dryRun?: boolean;
  params?: Record<string, unknown>;
};

type NewsPreviewBreakingArgs = {
  dryRun?: boolean;
  params?: Record<string, unknown>;
};

type NewsGetConfigArgs = {
  includeJobs?: boolean;
};

type NewsGetHistoryStatusArgs = {
  url?: string;
  summary?: boolean;
};

function resolveSuggestedChannel(
  jobId: NewsJobId,
  item: NewsItem,
  basePolicy: DeliveryPolicy
): string | null {
  const isGeorgia = item.flags.includes("georgia-topic");

  if (isGeorgia) {
    if (item.score >= 10) {
      // Georgia-based topic that qualifies as breaking news.
      return "#breaking-news";
    }
    return "#georgia-news";
  }

   if (jobId === "breaking-news-sweep") {
     // Per-item routing based on score.
     if (item.score >= 10) {
       return "#breaking-news";
     }
     return "#news";
   }

  if (jobId === "intel-signals-sweep") {
    return "#intel-signals";
  }

  return basePolicy.channels?.[0] ?? null;
}

async function handleRunJob(args: NewsRunJobArgs) {
  const jobId = (args.jobId ?? "(missing)") as NewsJobId;
  const dryRun = args.dryRun ?? true;
  const params = (args.params ?? {}) as Record<string, unknown>;

  const history = await loadHistory();
  let items: NewsItem[] = [];
  let updatedHistory: HistoryStore = history;

  if (jobId === "breaking-news-sweep") {
    const res = await runBreakingNewsSweep(params, history);
    items = res.items;
    updatedHistory = res.updatedHistory;
  } else if (jobId === "intel-signals-sweep") {
    const res = await runIntelSignalsSweep(params, history);
    items = res.items;
    updatedHistory = res.updatedHistory;
  } else {
    return {
      jobId,
      dryRun,
      params,
      status: "unknown-job",
      message:
        "news-pipeline-mcp knows only 'breaking-news-sweep' and 'intel-signals-sweep' right now."
    };
  }

  if (!dryRun) {
    await saveHistory(updatedHistory);
  }

  const deliveryPolicy = chooseDeliveryPolicy(jobId, items);

  const suggestedActions = items
    .filter((it) => it.score >= 6 && !!it.url)
    .map((it) => ({
      action: deliveryPolicy.mode === "autoPost" ? "post" : "review",
      url: it.url,
      title: it.title,
      score: it.score,
      channel: resolveSuggestedChannel(jobId, it, deliveryPolicy)
    }));

  return {
    jobId,
    dryRun,
    params,
    status: "ok" as const,
    message: `Ran job '${jobId}' against SearXNG at ${getSearxngBaseUrl()} with ${items.length} items.`,
    items,
    suggestedActions,
    deliveryPolicy
  };
}

async function handlePreviewBreaking(
  args: NewsPreviewBreakingArgs
): Promise<ReturnType<typeof handleRunJob>> {
  // Force breaking-news-sweep and dryRun=true
  return handleRunJob({
    jobId: "breaking-news-sweep",
    dryRun: true,
    params: args.params ?? {}
  });
}

async function handleGetConfig(args: NewsGetConfigArgs) {
  const baseDir = getBaseDir();
  const result: Record<string, unknown> = {
    baseDir
  };

  if (args.includeJobs) {
    const cronPath = join(baseDir, "cron", "jobs.json");
    if (existsSync(cronPath)) {
      try {
        const raw = await readFile(cronPath, "utf-8");
        result.jobs = JSON.parse(raw);
      } catch {
        result.jobs = null;
      }
    } else {
      result.jobs = null;
    }
  }

  return result;
}

async function handleGetHistoryStatus(args: NewsGetHistoryStatusArgs) {
  const history = await loadHistory();

  if (args.url) {
    return {
      url: args.url,
      entry: history[args.url] ?? null
    };
  }

  if (args.summary) {
    const total = Object.keys(history).length;
    const byJob: Record<string, number> = {};
    const byChannel: Record<string, number> = {};
    for (const entry of Object.values(history)) {
      const jobId = entry.jobId || "(unknown)";
      byJob[jobId] = (byJob[jobId] || 0) + 1;
      for (const ch of entry.channels ?? []) {
        byChannel[ch] = (byChannel[ch] || 0) + 1;
      }
    }
    return {
      total,
      byJob,
      byChannel
    };
  }

  return {
    total: Object.keys(history).length
  };
}

const TOOLS = [
  {
    name: "news_run_job",
    description:
      "Run a named news job (e.g. 'breaking-news-sweep', 'intel-signals-sweep') using SearXNG and a simple scoring/dedup pipeline.",
    inputSchema: {
      type: "object",
      properties: {
        jobId: {
          type: "string",
          description: "Identifier of the news job to run, e.g. 'breaking-news-sweep'."
        },
        dryRun: {
          type: "boolean",
          description: "If true, do not mutate any history or state.",
          default: true
        },
        params: {
          type: "object",
          description:
            "Additional job-specific parameters (e.g. topics, maxItems, timeWindowMinutes).",
          additionalProperties: true
        }
      },
      required: ["jobId"]
    }
  },
  {
    name: "news_preview_breaking_news",
    description:
      "Run the breaking-news pipeline in preview mode (never mutates history) and return structured results.",
    inputSchema: {
      type: "object",
      properties: {
        dryRun: {
          type: "boolean",
          description:
            "If true, do not mutate any history or state. This tool always runs with dryRun=true.",
          default: true
        },
        params: {
          type: "object",
          description:
            "Additional job-specific parameters (e.g. topics, maxItems, timeWindowMinutes).",
          additionalProperties: true
        }
      }
    }
  },
  {
    name: "news_get_config",
    description:
      "Return a structured view of the news pipeline config (e.g. cron job delivery policies).",
    inputSchema: {
      type: "object",
      properties: {
        includeJobs: {
          type: "boolean",
          description: "If true, include cron job delivery policies from cron/jobs.json.",
          default: true
        }
      }
    }
  },
  {
    name: "news_get_history_status",
    description:
      "Inspect the dedup history store for a specific URL or return aggregate statistics.",
    inputSchema: {
      type: "object",
      properties: {
        url: {
          type: "string",
          description: "URL to check in the history store."
        },
        summary: {
          type: "boolean",
          description: "If true, return aggregate statistics about the history file.",
          default: false
        }
      }
    }
  }
] as const;

async function main(): Promise<void> {
  const server = new Server(
    { name: "news-pipeline-mcp", version: "0.2.0" },
    {
      capabilities: {
        tools: {},
        resources: {},
        prompts: {},
        roots: {},
        logging: {}
      }
    }
  );

  server.setRequestHandler("tools/list" as any, async () => {
    // Basic debug logging to see MCP handshake flow
    console.error("[news-pipeline-mcp] tools/list called");
    return { tools: TOOLS as any };
  });

  // Optional MCP methods: some clients may probe these even if we don't
  // advertise capabilities. Register lightweight handlers keyed by method
  // strings to avoid "Method not found" during initialization.
  server.setRequestHandler("resources/list" as any, async () => {
    console.error("[news-pipeline-mcp] resources/list called");
    return { resources: [], nextCursor: null as any };
  });

  server.setRequestHandler("prompts/list" as any, async () => {
    console.error("[news-pipeline-mcp] prompts/list called");
    return { prompts: [], nextCursor: null as any };
  });

  server.setRequestHandler("roots/list" as any, async () => {
    console.error("[news-pipeline-mcp] roots/list called");
    return { roots: [], nextCursor: null as any };
  });

  server.setRequestHandler("tools/call" as any, async (request: any) => {
    const { name, arguments: rawArgs } = request.params;
    const args = (rawArgs ?? {}) as {
      jobId?: string;
      dryRun?: boolean;
      params?: Record<string, unknown>;
      includeJobs?: boolean;
      url?: string;
      summary?: boolean;
    };

    console.error("[news-pipeline-mcp] tools/call:", name);

    if (name === "news_run_job") {
      const result = await handleRunJob({
        jobId: args.jobId,
        dryRun: args.dryRun,
        params: args.params
      });
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(result, null, 2)
          }
        ]
      };
    }

    if (name === "news_preview_breaking_news") {
      const result = await handlePreviewBreaking({
        dryRun: true,
        params: args.params
      });
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(result, null, 2)
          }
        ]
      };
    }

    if (name === "news_get_config") {
      const cfg = await handleGetConfig({
        includeJobs: args.includeJobs
      });
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(cfg, null, 2)
          }
        ]
      };
    }

    if (name === "news_get_history_status") {
      const res = await handleGetHistoryStatus({
        url: args.url,
        summary: args.summary
      });
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(res, null, 2)
          }
        ]
      };
    }

    return {
      content: [{ type: "text", text: `Unknown tool: ${name}` }]
    };
  });

  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err) => {
  console.error("news-pipeline-mcp fatal error:", err);
  process.exit(1);
});

