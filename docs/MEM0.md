# Mem0 OSS: embedder and LLM configuration

Our Mem0 stack uses a **custom server** (`services/mem0-api/main.py`) that supports **env vars** and an optional **config file**, so you can set embedder/LLM in Docker or `.env` without calling POST /configure.

## 1. Default (OpenAI)

- Put `OPENAI_API_KEY` in `.env`.
- The server uses:
  - **LLM**: OpenAI `gpt-4.1-nano-2025-04-14`
  - **Embedder**: OpenAI `text-embedding-3-small`

No other config needed.

## 2. Env-based (Ollama or other providers)

Set these in `.env` or in `docker-compose.mem0.yml` under `mem0.environment`:

| Env var | Default | Description |
|--------|---------|-------------|
| `MEM0_EMBEDDER_PROVIDER` | `openai` | `openai` or `ollama` |
| `MEM0_EMBEDDER_MODEL` | `text-embedding-3-small` | e.g. `mxbai-embed-large`, `nomic-embed-text` |
| `MEM0_EMBEDDER_DIMS` | `1536` | Embedding dimension (e.g. **1024** for mxbai-embed-large, **768** for nomic) |
| `MEM0_LLM_PROVIDER` | `openai` | `openai` or `ollama` |
| `MEM0_LLM_MODEL` | `gpt-4.1-nano-2025-04-14` | e.g. `llama3.2` for Ollama |
| `OLLAMA_BASE_URL` | `http://host.docker.internal:11434` | Default Ollama URL for both embedder and LLM when not overridden. |
| `MEM0_EMBEDDER_OLLAMA_BASE_URL` | (same as `OLLAMA_BASE_URL`) | Override only for the embedder (e.g. local `http://host.docker.internal:11434`). |
| `MEM0_LLM_OLLAMA_BASE_URL` | (same as `OLLAMA_BASE_URL`) | Override only for the LLM (e.g. `https://ollama.com` for Ollama Cloud). |

**Example: Ollama for both (e.g. mxbai-embed-large)**

In `.env`:

```bash
MEM0_EMBEDDER_PROVIDER=ollama
MEM0_EMBEDDER_MODEL=mxbai-embed-large
MEM0_EMBEDDER_DIMS=1024
MEM0_LLM_PROVIDER=ollama
MEM0_LLM_MODEL=llama3.2
OLLAMA_BASE_URL=http://host.docker.internal:11434
```

Or uncomment and set the same vars in `docker-compose.mem0.yml` under the `mem0` service. No POST /configure needed; config is applied at startup.

**Local embedder + Ollama Cloud LLM**

Use a local Ollama for embeddings and Ollama Cloud for the LLM by setting separate base URLs:

- **Embedder** (local): `MEM0_EMBEDDER_OLLAMA_BASE_URL=http://host.docker.internal:11434` (or your local Ollama).
- **LLM** (Ollama Cloud): `MEM0_LLM_OLLAMA_BASE_URL=https://ollama.com` and set your cloud model in `MEM0_LLM_MODEL`.

Example in `.env`:

```bash
MEM0_EMBEDDER_PROVIDER=ollama
MEM0_EMBEDDER_MODEL=mxbai-embed-large
MEM0_EMBEDDER_DIMS=1024
MEM0_EMBEDDER_OLLAMA_BASE_URL=http://host.docker.internal:11434

MEM0_LLM_PROVIDER=ollama
MEM0_LLM_MODEL=llama3.2
MEM0_LLM_OLLAMA_BASE_URL=https://ollama.com
```

If Ollama Cloud requires an API key, the Mem0 Ollama provider may need it in the config (e.g. via request headers). If the env-built config doesn’t support auth, use **MEM0_CONFIG_FILE** with a full config that includes your cloud API key in the `llm.config` section (see Mem0 docs for the exact key name).

## 3. Config file (optional)

For full control (e.g. custom vector_store or graph_store), you can pass a **single config file** that replaces the env-built config:

- Set **`MEM0_CONFIG_FILE`** to the path of a JSON or YAML file inside the container (e.g. `/app/config/mem0_config.yaml`).
- Mount the file in docker-compose, e.g.:
  ```yaml
  mem0:
    environment:
      - MEM0_CONFIG_FILE=/app/config/mem0_config.yaml
    volumes:
      - ./mem0_config.yaml:/app/config/mem0_config.yaml:ro
  ```
- The file must contain the full Mem0 config (vector_store, graph_store, llm, embedder, history_db_path). See Mem0 docs for the shape. For YAML you need PyYAML in the image (our Dockerfile does not add it by default; use JSON or add `RUN pip install pyyaml` if you need YAML).

If `MEM0_CONFIG_FILE` is set but the file is missing, the server falls back to the env-built config.

## 4. POST /configure (runtime override)

You can still call **POST http://localhost:8888/configure** with a full JSON config at any time. That replaces the in-memory config until the container restarts. Useful for one-off overrides or when you don’t want to rebuild/restart.

## Summary

| What | Where |
|------|--------|
| Postgres / Neo4j | Env in `docker-compose.mem0.yml` (already set). |
| Default (OpenAI) | `OPENAI_API_KEY` in `.env`. |
| Embedder / LLM | **Env vars** (see table above) or **MEM0_CONFIG_FILE** (full config file) or **POST /configure** (runtime JSON). |
