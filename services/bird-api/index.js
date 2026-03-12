/**
 * HTTP wrapper around the bird CLI (@steipete/bird).
 * Exposes /profile, /timeline, /search for X/Twitter read-only access.
 * AUTH_TOKEN and CT0 must be set in env.
 */
import { exec } from "node:child_process";
import { promisify } from "node:util";
import express from "express";

const execAsync = promisify(exec);

const app = express();
const PORT = parseInt(process.env.PORT || "18791", 10);

async function runBird(args) {
  const { stdout, stderr } = await execAsync(`bird ${args} --plain`, {
    env: process.env,
    timeout: 60_000,
  });
  return stderr && stderr.trim() ? `${stdout}\n\n[stderr]\n${stderr}` : stdout;
}

app.get("/health", (req, res) => {
  res.json({ ok: true, service: "bird-api" });
});

app.get("/profile", async (req, res) => {
  const handle = req.query.handle?.trim();
  if (!handle) {
    return res.status(400).json({ ok: false, error: "Missing handle" });
  }
  try {
    const out = await runBird(`about ${handle.startsWith("@") ? handle : "@" + handle}`);
    res.json({ ok: true, output: out });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message || String(err) });
  }
});

app.get("/timeline", async (req, res) => {
  const handle = req.query.handle?.trim();
  const limit = Math.min(100, Math.max(1, parseInt(req.query.limit || "20", 10) || 20));
  if (!handle) {
    return res.status(400).json({ ok: false, error: "Missing handle" });
  }
  const user = handle.startsWith("@") ? handle : "@" + handle;
  try {
    const out = await runBird(`user-tweets ${user} -n ${limit}`);
    res.json({ ok: true, output: out });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message || String(err) });
  }
});

app.get("/search", async (req, res) => {
  const q = req.query.q?.trim() || req.query.query?.trim();
  const limit = Math.min(50, Math.max(1, parseInt(req.query.limit || "10", 10) || 10));
  if (!q) {
    return res.status(400).json({ ok: false, error: "Missing q" });
  }
  try {
    const out = await runBird(`search "${q.replace(/"/g, '\\"')}" -n ${limit}`);
    res.json({ ok: true, output: out });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message || String(err) });
  }
});

app.listen(PORT, "0.0.0.0", () => {
  console.log(`bird-api listening on :${PORT}`);
});
