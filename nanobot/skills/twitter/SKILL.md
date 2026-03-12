---
name: twitter
description: Search X.com (Twitter) and read timelines via the bird-api HTTP service (bird CLI).
homepage: https://github.com/steipete/bird
metadata: {"nanobot":{"emoji":"🐦","requires":{"tools":["web_fetch"]}}}
---

# X / Twitter (bird-api)

Use **web_fetch** to call the bird-api HTTP service (http://bird-api:18791) for read-only X.com (Twitter) access.

Endpoints:
- `GET /profile?handle=@foo` — account info (bird about)
- `GET /timeline?handle=@foo&limit=20` — user timeline (bird user-tweets)
- `GET /search?q=query&limit=10` — search tweets (bird search)
- `GET /health` — liveness check

Bird uses cookie auth. Configure `AUTH_TOKEN` and `CT0` in the bird-api container env (see .env.wrenair).
