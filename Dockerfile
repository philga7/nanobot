FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim

# Install Node.js 20 for the WhatsApp bridge
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates gnupg git && \
    mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends nodejs && \
    apt-get purge -y gnupg && \
    apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Python dependencies first (cached layer)
COPY pyproject.toml README.md LICENSE ./
RUN mkdir -p nanobot bridge && touch nanobot/__init__.py && \
    uv pip install --system --no-cache . && \
    rm -rf nanobot bridge

# Copy the full source and install
COPY nanobot/ nanobot/
COPY bridge/ bridge/
COPY services/mcp-ts-sdk/ services/mcp-ts-sdk/
COPY services/bird-mcp/ services/bird-mcp/
COPY services/library-mcp/ services/library-mcp/
COPY services/news-pipeline-mcp/ services/news-pipeline-mcp/
RUN uv pip install --system --no-cache .

# Build the MCP TypeScript SDK (vendored)
# We only need the server package for downstream MCP services, so avoid
# building the entire workspace to reduce memory usage during Docker builds.
WORKDIR /app/services/mcp-ts-sdk
RUN corepack enable && pnpm install && pnpm --filter @modelcontextprotocol/server build

# Build the WhatsApp bridge
WORKDIR /app/bridge
RUN npm install && npm run build

# X.com / Twitter read-only CLI for exec tool
RUN npm install -g @steipete/bird

# Build the bird MCP server
WORKDIR /app/services/bird-mcp
RUN npm install && npm run build

# Build the news-pipeline MCP server
WORKDIR /app/services/news-pipeline-mcp
RUN npm install && npm run build

# Install FastMCP runtime for the library MCP server
WORKDIR /app/services/library-mcp
RUN uv pip install --system --no-cache fastmcp

    WORKDIR /app

# Create config directory
RUN mkdir -p /root/.nanobot

# Gateway default port
EXPOSE 18790

ENTRYPOINT ["nanobot"]
CMD ["status"]
