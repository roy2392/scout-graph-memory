# Proposal: Graph + forgetting-curve consolidation ("dream") for Scout memory

**Status:** Draft for discussion · **Audience:** Memora / Loki memory team (Marcin Roman,
Stanisław Wilczyński, Carmen Pfeil, Caroline Reinig, Dmytro Baglai, Dino Ilic — by commit history on
`electron/memora`, `electron/loki`, `electron/memory`) · **Author:** Peter Qian · **Date:** 2026-06-20

> TL;DR — Scout's memory bank, as the user experiences it, grows monotonically and is injected
> wholesale into context. That dilutes attention and lets duplicates and stale point-in-time facts
> pile up. We built and have been running a working **graph + vector store with a nightly
> "dream" consolidation pass** (forgetting curve, dedup/merge, entity-graph weave, hard entry budget)
> that keeps a bank **small, connected, and mostly de-duplicated**. This doc summarizes what we
> learned, maps it onto Memora's current design, and asks: is any of this already on the Memora
> roadmap, and would a graph + consolidation layer be worth collaborating on?

---

## 1. What we observed (the problem)

Scout injects the memory bank into context. So retrieval quality is, first-order, the model's
**attention over the injected text** — and that has two failure modes that get worse with bank size:

1. **Unbounded growth.** Every `m_remember` adds an entry; nothing ages out. Past a few hundred
   entries the bank blows the injection budget and dilutes attention ("lost in the middle").
2. **Disconnected, duplicated facts.** The same fact gets re-saved in slightly different words;
   point-in-time status ("X is blocked this week") never expires; and facts that share a subject
   aren't linked, so neither attention nor a graph walk can hop between them.

This is independent of how good the *retrieval* is — it's a property of the *bank* itself.

## 2. What Memora already does (our reading of the code)

We read `electron/memora/*` and `electron/loki/*`. Memora is already substantially more than
"text + RAG":

| Capability | Where | Notes |
| --- | --- | --- |
| GraphQL memory service via Loki transport | `electron/loki/client.ts`, `electron/memora/client.ts` | per-user `lokiUrl` from config (`host-routing.ts`) |
| Server-side **extraction** | `ContextExtractionResult` | raw context in → server-assigned memories out |
| **Semantic retrieval** | `SEMANTIC_RETRIEVE_QUERY`, `memorySave` similarity scores | vector similarity already exists server-side |
| Categories | `memoryType`: `factual` / `episodic` / `procedural` | maps to Scout `fact` / `context` / `decision` |
| Relevance tiers | `relevanceTier`: `ALWAYS_ON` / `CONTEXTUAL` | a salience/importance signal already exists |
| Cues | `cues[]` | per-memory retrieval hints |
| Shadow rollout | `ShadowingMemoraStore`, `EnableMemora` flight | dual-write while migrating off the legacy store |
| Delete propagation | tombstones, 30-day prune (`28-onedrive-memory-storage.md`) | matches our tombstone model |

So Memora has **extraction, semantic retrieval, categories, a salience tier, and tombstones**. That's
a strong base and overlaps several of our concepts already.

### What we did **not** find (the gap this proposal is about)

No code or doc reference to any of:

- an explicit **graph of edges between memories** (entity hubs; "these N memories are about the same
  person/system/incident");
- a **forgetting curve** — decay of relevance over time with class-dependent half-lives;
- **eviction / an entry budget** — a target or cap on bank size with pressure-adaptive pruning;
- **batch consolidation** — periodic dedup/merge of overlapping memories into fewer, richer ones.

These may exist server-side and simply not be visible in the client. **That's our first question for
the team** (§6).

## 3. What we built (and have been running nightly)

A self-contained engine — local SQLite + `sqlite-vec` for the vector index, on-device embeddings —
plus two skills (`dream`, `graph-recall`). It is a working reference implementation, not a product.

**Data model — two node kinds:**
- **fact** — an atomic memory; carries a forgetting-curve `strength`; projects back to the bank.
- **entity** — a connector hub (`person:` / `team:` / `system:` / `incident:` / …); no decay; never a
  memory itself; exists so facts about the same subject are linked. (Conceptually close to Memora's
  `cues`, but promoted to first-class graph nodes.)

**Edges:** `fact —mentions→ entity` (the backbone), `fact —related_to→ fact` (corroborated: shared
entity **and** vector-similar), `fact —similar_to→ fact` (low-confidence vector-only), plus
structural and `supersedes` lineage.

**The nightly "dream" (the novel part):** a batch pass that runs three verbs —

1. **FORGET** — decay every fact on a class half-life (salient 365d / semantic 180d / episodic 3d);
   reactivate subjects that recur; **evaporate** faded episodics (tombstone). Decay-gated so a
   memory is never dropped the night it appears.
2. **MERGE** — surface duplicate/overlapping clusters (vector-similar **and** shared entity); collapse
   into one richer canonical memory (count down, information kept). This is the primary budget lever.
3. **WEAVE** — extract entities and link every fact so there are **zero islands**; guarantees the
   graph walk and attention can always hop between related facts.

**Entry budget.** Target ~250 entries; pressure-adaptive — the fuller the bank, the more aggressively
it fades and merges. (Our numbers are tuned to a harness that injects everything; a server that
retrieves a top-k subset would pick a different target, but the *mechanism* transfers.)

**Neuroscience basis (kept honest, not hand-wavy):** schema-accelerated consolidation (Tse/Morris —
a fact that slots into an established entity schema consolidates faster and decays slower);
episodic→semantic promotion by repetition; salience as an *encoding-time importance tag*, never a
frequency count.

It also ships a 3D semantic-nebula visualization of the store (layout by embedding PCA) for
inspection — useful for debugging what consolidation is doing.

## 4. How it maps onto Memora

The good news: our concepts line up with Memora's existing schema, so this is additive, not a rewrite.

| Ours | Memora today | Fit |
| --- | --- | --- |
| fact class: salient / semantic / episodic | `memoryType` + `relevanceTier` | direct — reuse both |
| entity hub | `cues[]` | promote cues to linkable nodes |
| `related_to` / `similar_to` edges | similarity scores exist; no stored edges | add an edge table / graph projection |
| forgetting curve (decay) | — | new: a `strength`/`lastReactivated` field + a decay job |
| MERGE consolidation | server-side extraction exists | extend extraction to dedup across existing memories |
| nightly dream | — | new: a scheduled server-side batch (or a client skill, interim) |
| entry budget | — | new: a per-bank target + pressure-adaptive prune |

## 5. Two ways this could land

**Option A — server-side in Memora (the right long-term home).** Consolidation belongs where the
data and extraction already live. A nightly (or rolling) job over each bank: decay relevance, dedup
into canonical memories, and persist entity edges. `relevanceTier` becomes an output of consolidation
rather than a static tag. This is a Memora-team feature; we'd contribute the algorithm, the
neuroscience rationale, the reference implementation, and evaluation help.

**Option B — client-side skill (interim, available today).** Our `dream` + `graph-recall` skills run
the loop using the existing `m_remember` / `m_forget` / `m_list_memories` tools, with a local
vector store. This works now and is a way to **A/B the idea before committing server work** — but it
duplicates state and needs a local embedder (see dependency note below), so it's a stopgap, not the
destination.

We recommend **A**, with **B** as an optional experiment to de-risk it.

### Dependency note (important for first-party)

Our reference impl embeds with `@huggingface/transformers` (downloads MiniLM weights from
huggingface.co on first run). That's fine for a personal tool but **not acceptable as a first-party
runtime dependency** (external egress + model-weight redistribution review). For any productization
the embedder must be **pluggable** — and on the server side it's moot, because Memora already computes
similarity, so consolidation would reuse Memora's existing embeddings rather than ship a new model.

## 6. Questions for the Memora team

1. **Is graph / forgetting / consolidation already on the roadmap?** We may be reinventing something
   you've designed. If so, we'd love to compare notes and contribute.
2. **Where does memory physically live and consolidate?** We see the Loki-hosted GraphQL endpoint and
   server-side extraction — is there already a batch/rolling job per bank where decay + dedup could
   slot in?
3. **Does Memora bound bank size today** (eviction, a cap, relevance-based pruning), or does it grow
   monotonically and rely on top-k retrieval to stay within budget?
4. **Could extraction emit edges?** It already returns structured memories; emitting entity links
   (or promoting `cues` to shared nodes) would give the graph for free.
5. **Is `relevanceTier` static or recomputed?** Our salience model and your tiers seem to be the same
   idea; could consolidation drive the tier?

## 7. Prior art (so we're grounded)

This space is active. Vectorize.io's **Hindsight** (open source, benchmarked SOTA on LongMemEval)
independently arrived at the same thesis — graph + vector + biomimetic memory classes + consolidated
"observations". Two takeaways: (1) the broad direction is validated by an outside SOTA system; (2)
their consolidation **refines and preserves** history, whereas our distinctive lever is **active
forgetting + a hard budget**, which is the right fit for an *inject-everything* client like Scout.
Hindsight is a Postgres + external-LLM-API server; the relevant lesson for Scout is the *design*, not
the deployment.

## 8. Ask

A 30-minute conversation: walk the Memora team through this, learn the current intent and server
design, and decide whether a graph + consolidation layer is worth a joint spike. We bring a working
reference implementation, an evaluation harness idea (LongMemEval-style), and the willingness to do
the work.
