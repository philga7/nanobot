import { execFile } from "node:child_process";
import { promisify } from "node:util";

import {
  Server,
  StdioServerTransport,
  CallToolRequestSchema,
  ListToolsRequestSchema
} from "@modelcontextprotocol/server";
import { z } from "zod";

const execFileAsync = promisify(execFile);

const TOOLS = [
  {
    name: "bird_profile",
    description: "Get profile info and recent tweets for an X handle using the bird CLI.",
    inputSchema: {
      type: "object",
      properties: {
        handle: {
          type: "string",
          description: "X/Twitter handle, e.g. '@cipher'"
        }
      },
      required: ["handle"]
    }
  },
  {
    name: "bird_timeline",
    description: "Get recent timeline tweets for an X handle using the bird CLI.",
    inputSchema: {
      type: "object",
      properties: {
        handle: {
          type: "string",
          description: "X/Twitter handle, e.g. '@cipher'"
        },
        limit: {
          type: "integer",
          description: "Max tweets to return (1–100)",
          minimum: 1,
          maximum: 100
        }
      },
      required: ["handle"]
    }
  },
  {
    name: "bird_search",
    description: "Search X/Twitter via the bird CLI.",
    inputSchema: {
      type: "object",
      properties: {
        query: {
          type: "string",
          description: "Search query"
        },
        limit: {
          type: "integer",
          description: "Max results to return (1–100)",
          minimum: 1,
          maximum: 100
        }
      },
      required: ["query"]
    }
  }
] as const;

const ProfileArgs = z.object({
  handle: z.string().min(1)
});

const TimelineArgs = z.object({
  handle: z.string().min(1),
  limit: z.number().int().min(1).max(100).optional()
});

const SearchArgs = z.object({
  query: z.string().min(1),
  limit: z.number().int().min(1).max(100).optional()
});

async function runBird(args: string[]): Promise<string> {
  const { stdout, stderr } = await execFileAsync("bird", args, {
    env: process.env
  });

  if (stderr && stderr.trim()) {
    return `${stdout}\n\n[stderr]\n${stderr}`;
  }

  return stdout;
}

async function main(): Promise<void> {
  const server = new Server(
    { name: "bird-mcp", version: "0.1.0" },
    { capabilities: { tools: {} } }
  );

  server.setRequestHandler(ListToolsRequestSchema, async () => {
    return { tools: TOOLS as any };
  });

  server.setRequestHandler(CallToolRequestSchema, async (request: any) => {
    const { name, arguments: rawArgs } = request.params;

    try {
      if (name === "bird_profile") {
        const { handle } = ProfileArgs.parse(rawArgs ?? {});
        const out = await runBird(["profile", handle]);
        return { content: [{ type: "text", text: out }] };
      }

      if (name === "bird_timeline") {
        const { handle, limit } = TimelineArgs.parse(rawArgs ?? {});
        const args = ["read", handle];
        if (limit) {
          args.push("--limit", String(limit));
        }
        const out = await runBird(args);
        return { content: [{ type: "text", text: out }] };
      }

      if (name === "bird_search") {
        const { query, limit } = SearchArgs.parse(rawArgs ?? {});
        const args = ["search", query];
        if (limit) {
          args.push("--limit", String(limit));
        }
        const out = await runBird(args);
        return { content: [{ type: "text", text: out }] };
      }

      return {
        content: [
          {
            type: "text",
            text: `Unknown tool: ${name}`
          }
        ]
      };
    } catch (err: any) {
      const message = err?.message ?? String(err);
      return {
        content: [
          {
            type: "text",
            text: `bird-mcp error for ${name}: ${message}`
          }
        ]
      };
    }
  });

  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err) => {
  console.error("bird-mcp fatal error:", err);
  process.exit(1);
});

