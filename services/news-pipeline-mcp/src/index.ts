import { readFile, writeFile, mkdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join } from "node:path";

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
  source: "searxng";
}

interface HistoryEntry {
  lastSeen: string;
  jobId: string;
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

  return results.slice(0, maxItems).map((r, idx) => {
    const title = String(r.title ?? "");
    const url = String(r.url ?? "");
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

    if (!title || !url) {
      flags.push("incomplete");
    }

    return {
      title,
      url,
      snippet,
      score,
      reasons,
      flags,
      seenBefore: false,
      source: "searxng" as const
    };
  });
}

function chooseDeliveryPolicy(jobId: NewsJobId): DeliveryPolicy {
  if (jobId === "breaking-news-sweep") {
    return {
      mode: "autoPost",
      channels: ["#breaking-news"],
      ntfy: true
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

  const updatedHistory: HistoryStore = { ...history };
  const ts = nowIso();
  for (const item of deduped) {
    if (!item.url) continue;
    updatedHistory[item.url] = { lastSeen: ts, jobId: "breaking-news-sweep" };
  }

  return { items: deduped, updatedHistory };
}

async function runIntelSignalsSweep(
  params: Record<string, unknown>,
  history: HistoryStore
): Promise<{ items: NewsItem[]; updatedHistory: HistoryStore }> {
  // For now, reuse a narrower searxng search; later this can incorporate bird/library.
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

  const updatedHistory: HistoryStore = { ...history };
  const ts = nowIso();
  for (const item of deduped) {
    if (!item.url) continue;
    updatedHistory[item.url] = { lastSeen: ts, jobId: "intel-signals-sweep" };
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

  const deliveryPolicy = chooseDeliveryPolicy(jobId);

  const suggestedActions = items
    .filter((it) => it.score >= 6 && !!it.url)
    .map((it) => ({
      action: deliveryPolicy.mode === "autoPost" ? "post" : "review",
      url: it.url,
      title: it.title,
      score: it.score,
      channel: deliveryPolicy.channels?.[0] ?? null
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
    for (const entry of Object.values(history)) {
      const jobId = entry.jobId || "(unknown)";
      byJob[jobId] = (byJob[jobId] || 0) + 1;
    }
    return {
      total,
      byJob
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

