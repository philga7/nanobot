---
name: twitter
description: Read X.com (Twitter) profiles and tweets via the bird CLI (no official API).
homepage: https://github.com/steipete/bird
metadata: {"nanobot":{"emoji":"🐦","requires":{"bins":["bird"]}}}
---

# X / Twitter (bird CLI)

Use the **exec** tool to run the `bird` CLI for read-only X.com (Twitter) access: profiles, tweets, and timelines. Bird uses X's undocumented web API with cookie-based auth.

**Install**: `npm install -g @steipete/bird` (or ensure `bird` is on PATH in your environment).

**Auth**: Bird requires cookie-based authentication. Configure it per environment (e.g. env or config file). See the [bird repo](https://github.com/steipete/bird) for setup. Do not use for automated posting — read-only use is safer.

## Commands (use via exec)

**Profile** — show user profile and recent info:
```bash
bird profile @handle
```

**Read tweets** — timeline or user's recent tweets:
```bash
bird read @handle
```

**Search** (if supported by your bird version):
```bash
bird search "query"
```

**Mentions / other** — check bird help for current commands:
```bash
bird --help
```

Prefer read-only commands. Posting/replies can trigger rate limits or blocks on automated use.
