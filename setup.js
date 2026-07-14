"use strict";

// One-command bootstrap for the agent-memory engine.
//   node setup.js
//
// - verifies the native + ESM dependencies are installed (run `npm install` first)
// - creates the per-user data dir and initializes a fresh memory.db (full schema)
// - warms the local embedding model (first run downloads ~90MB once, then cached)
// - prints the data locations and next steps
//
// Everything is path-portable via config.js (override with AGENT_MEMORY_DIR etc.).

const fs = require("fs");
const path = require("path");
const cfg = require("./config");

function ok(m) { console.log("  \u2713 " + m); }
function info(m) { console.log("    " + m); }

async function main() {
  console.log("agent-memory setup\n");

  // 1) Dependencies present?
  const missing = [];
  for (const dep of ["better-sqlite3", "sqlite-vec", "@huggingface/transformers"]) {
    try { require.resolve(dep); }
    catch { missing.push(dep); }
  }
  if (missing.length) {
    console.error("  \u2717 Missing dependencies: " + missing.join(", "));
    console.error("    Run `npm install` in this folder first, then re-run `npm run setup`.");
    process.exit(1);
  }
  ok("dependencies present (better-sqlite3, sqlite-vec, @huggingface/transformers)");

  // 2) Data dir + fresh database (schema via dream.js openDb).
  fs.mkdirSync(cfg.DATA_DIR, { recursive: true });
  ok("data dir: " + cfg.DATA_DIR);

  const Database = require("better-sqlite3");
  const sqliteVec = require("sqlite-vec");
  const { ensureSchema } = require("./lib/schema");
  const db = new Database(cfg.DB_PATH);
  sqliteVec.load(db);
  db.pragma("journal_mode = WAL");
  ensureSchema(db);
  const counts = {
    nodes: db.prepare("SELECT count(*) c FROM nodes").get().c,
    edges: db.prepare("SELECT count(*) c FROM edges").get().c,
  };
  db.close();
  ok(`database ready: ${cfg.DB_PATH} (nodes=${counts.nodes}, edges=${counts.edges})`);

  // 3) Warm the embedding model (downloads once into the cache dir).
  process.stdout.write("    warming embedding model (" + cfg.MODEL + ") \u2026 first run downloads once\n");
  try {
    const { embedOne } = require("./lib/embed");
    const v = await embedOne("agent memory bootstrap");
    ok(`embedding model ready (${v.length}-dim, cache: ${cfg.MODEL_CACHE})`);
  } catch (e) {
    console.error("  \u2717 model warm-up failed: " + e.message);
    console.error("    (needs network on first run; re-run setup once online)");
    process.exit(1);
  }

  console.log("\nReady. Next steps:");
  info("1. Export your agent's memories to a snapshot JSON: [{ id, fact, category }]");
  info("2. node lib/dream.js ingest-harness --file snapshot.json");
  info("3. node lib/dream.js dream && node lib/dream.js weave && node lib/dream.js doctor");
  info("4. node lib/dream.js export-viz   # renders " + cfg.VIZ_OUT);
  info("5. node lib/recall.js --query \"<question>\"   # vector + graph recall");
  console.log("\nSee README.md for the full nightly loop and host-agent integration.");
}

main().catch((e) => { console.error("SETUP ERROR:", e); process.exit(1); });
