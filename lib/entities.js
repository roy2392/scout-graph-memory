"use strict";

// Entity layer for the dream weave: builds an entity vocabulary (with aliases),
// extracts entities from fact text, and computes co-mention links fact -> entity.
// High precision by design: matches existing entity hubs + email-bound persons + IDs.
// The vector layer (in dream.js) guarantees connectivity for anything this misses.

const ENTITY_PREFIXES = [
  "person", "team", "org", "system", "topic", "incident", "release",
  "pr", "msrc", "heuristic", "artifact", "decision", "thread",
];

// Capitalized bigrams that are NOT people (products/orgs/phrases seen in this domain).
const NON_PERSON = new Set([
  "power query", "power bi", "data integration", "direct query", "logic apps",
  "spring grove", "shared master", "container pusher", "mashup provider",
  "gateway release", "usage billing", "semantic models", "global config",
  "fabric dataflows", "mapping dataflow", "bug bash", "org restriction",
  "customer reported", "release manager", "fork candidate", "action required",
  "engineering managers", "global discover", "azure security", "security operations",
  "service feature", "direct reports", "release coordination", "release decision",
  "release test", "test conversion", "release train", "connection storage",
  "data import", "modernizing data", "fabric lakehouse", "fabric flight",
  "potential fork", "partner architect", "senior leadership", "lakehouse model",
  "private microsoft", "microsoft teams", "microsoft signature", "shared sql",
  "british south", "canada central", "india central", "south among",
]);

// Single tokens that are never a person's name (so "Pipeline Actions", "Orchestration Team" etc. are rejected).
const NON_NAME_WORDS = new Set([
  "team", "teams", "project", "projects", "actions", "action", "pipeline", "orchestration",
  "product", "review", "summer", "microsoft", "power", "query", "data", "integration",
  "gateway", "release", "mashup", "desktop", "provider", "dataflows", "dataflow", "lakehouse",
  "fabric", "billing", "usage", "compute", "partitioned", "incremental", "refresh", "connector",
  "connectors", "online", "service", "services", "security", "operations", "shared", "master",
  "container", "pusher", "global", "config", "logic", "apps", "semantic", "models", "model",
  "direct", "reports", "report", "engineering", "managers", "manager", "north", "south", "east",
  "west", "central", "brazil", "canada", "india", "uk", "the", "and", "with", "from", "bug", "bash",
]);

const isLikelyName = (a, b) => {
  const x = a.toLowerCase(); const y = b.toLowerCase();
  if (NON_NAME_WORDS.has(x) || NON_NAME_WORDS.has(y)) return false;
  if (NON_PERSON.has(`${x} ${y}`)) return false;
  return a.length >= 2 && b.length >= 2;
};

function normalize(s) {
  return (s || "").toLowerCase().replace(/[^a-z0-9 ]+/g, " ").replace(/\s+/g, " ").trim();
}

function labelOf(sig) {
  const i = sig.indexOf(":");
  return (i >= 0 ? sig.slice(i + 1) : sig).replace(/-/g, " ");
}

function typeOf(sig) {
  const i = sig.indexOf(":");
  return i >= 0 ? sig.slice(0, i) : "";
}

// Surface forms an entity can appear as in fact text.
function formsFor(sig) {
  const type = typeOf(sig);
  const label = normalize(labelOf(sig));
  const forms = new Set([label]);
  if (type === "person") {
    const parts = label.split(" ").filter(Boolean);
    if (parts.length >= 2) {
      forms.add(parts[0]);                          // first name
      forms.add(parts[parts.length - 1]);           // last name
    }
  }
  if (["incident", "msrc", "pr", "release"].includes(type)) {
    // numeric/id tokens
    const ids = label.match(/[0-9][0-9.]+/g) || [];
    ids.forEach((x) => forms.add(x));
  }
  // drop ultra-short/ambiguous forms
  return [...forms].filter((f) => f && f.length >= 3);
}

// Build the vocabulary from existing entity-kind nodes.
// entityRows: [{signature}]
function buildVocab(entityRows) {
  const vocab = [];
  for (const r of entityRows) {
    vocab.push({ sig: r.signature, type: typeOf(r.signature), forms: formsFor(r.signature) });
  }
  return vocab;
}

const slug = (s) => normalize(s).replace(/\s+/g, "-").slice(0, 48);

// Extract NEW entities from a fact's text that deserve their own hub.
// Returns [{sig, type, forms}]. Conservative for precision.
function extractEntities(fact) {
  const out = [];
  const text = fact || "";
  const addPerson = (a, b, extraForms = []) => {
    if (!isLikelyName(a, b)) return;
    const full = `${a} ${b}`;
    out.push({ sig: `person:${slug(full)}`, type: "person",
      forms: [...new Set([normalize(full), a.toLowerCase(), b.toLowerCase(), ...extraForms])].filter((f) => f.length >= 3) });
  };

  // Email-bound persons: "Name Name (xxx@microsoft.com)" -> strong person signal.
  let m;
  const emailRe = /([A-Z][a-z]+)\s+([A-Z][a-z]+)\s*\(([a-z0-9._-]+)@/g;
  while ((m = emailRe.exec(text))) addPerson(m[1], m[2], [m[3].toLowerCase()]);

  // Persons in subject-verb position: "Name Name <verb>".
  const verbs = "is|was|works|reports|submitted|contributes|sends|coordinates|confirmed|reported|drives|driving|leads|shared|requested|removed|posting|participating|acting|drove|coordinating|joining|joins|supporting|focus|focuses";
  const personVerbRe = new RegExp(`\\b([A-Z][a-z]+)\\s+([A-Z][a-z]+)\\s+(?:${verbs})\\b`, "g");
  while ((m = personVerbRe.exec(text))) addPerson(m[1], m[2]);

  // Collaborator / list patterns: capture name sequences after trigger words and split them.
  // e.g. "working with Noelle Li and Sindhu Bharadwaj", "involving Sid Jayadevan and X", "by A, B, and C".
  const trigger = "with|involving|by|between|from|join|welcome|owners?|reviewers?|cc|alongside|including|and";
  const nameSeqRe = new RegExp(`\\b(?:${trigger})\\s+((?:[A-Z][a-z]+\\s+[A-Z][a-z]+)(?:\\s*(?:,|and|,\\s*and)\\s*[A-Z][a-z]+\\s+[A-Z][a-z]+)*)`, "g");
  while ((m = nameSeqRe.exec(text))) {
    const seq = m[1];
    const names = seq.match(/[A-Z][a-z]+\s+[A-Z][a-z]+/g) || [];
    for (const nm of names) { const [a, b] = nm.split(/\s+/); addPerson(a, b); }
  }

  // Generic name list anywhere: 2+ consecutive "First Last" separated by comma/and
  // (catches parenthetical lists like "team (Rama Rayudu, Hanying Feng, Shriram Hemaraj)").
  // isLikelyName() filters out product/org phrases (their tokens are in NON_NAME_WORDS).
  const listRe = /([A-Z][a-z]+\s+[A-Z][a-z]+)((?:\s*,\s*and\s+|\s*,\s*|\s+and\s+)[A-Z][a-z]+\s+[A-Z][a-z]+)+/g;
  while ((m = listRe.exec(text))) {
    const names = m[0].match(/[A-Z][a-z]+\s+[A-Z][a-z]+/g) || [];
    for (const nm of names) { const [a, b] = nm.split(/\s+/); addPerson(a, b); }
  }

  // Generic "Name Name and Name Name" co-occurrence (both are people).
  const pairRe = /\b([A-Z][a-z]+)\s+([A-Z][a-z]+)\s+and\s+([A-Z][a-z]+)\s+([A-Z][a-z]+)\b/g;
  while ((m = pairRe.exec(text))) { addPerson(m[1], m[2]); addPerson(m[3], m[4]); }

  // IDs.
  const addId = (re, type) => {
    let mm; const r = new RegExp(re, "g");
    while ((mm = r.exec(text))) out.push({ sig: `${type}:${mm[1]}`.toLowerCase(), type, forms: [mm[1].toLowerCase()] });
  };
  addId("incident\\s+(\\d{6,})", "incident");
  addId("\\bIcM#?(\\d{6,})", "incident");
  addId("\\bMSRC\\s*(\\d{4,})", "msrc");
  addId("\\bPR\\s*(\\d{6,})", "pr");
  addId("\\b(\\d{9})\\b", "incident"); // bare 9-digit = incident id in this domain

  // dedup by sig
  const seen = new Map();
  for (const e of out) {
    if (!seen.has(e.sig)) seen.set(e.sig, e);
    else seen.get(e.sig).forms = [...new Set([...seen.get(e.sig).forms, ...e.forms])];
  }
  return [...seen.values()];
}

// Co-mention: which vocab entities appear in a fact's text (word-boundary, case-insensitive).
function coMentions(factText, vocab) {
  const text = ` ${normalize(factText)} `;
  const hits = [];
  for (const v of vocab) {
    for (const f of v.forms) {
      if (text.includes(` ${f} `)) { hits.push(v.sig); break; }
    }
  }
  return [...new Set(hits)];
}

module.exports = { ENTITY_PREFIXES, buildVocab, extractEntities, coMentions, formsFor, typeOf, labelOf, normalize, slug };
