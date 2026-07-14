#!/usr/bin/env bash
# Nightly cloud dream — runs the consolidation engine against memory.db on the
# mounted Azure Files share. Gate commands (verify-sync, doctor) may exit 3; we
# log and continue so the store is always exported for the next Scout sync.
set -uo pipefail

export AGENT_MEMORY_DIR="${AGENT_MEMORY_DIR:-/data}"
export MEMORY_MODEL_CACHE="${MEMORY_MODEL_CACHE:-/app/model-cache}"
export MEMORY_VIZ="${MEMORY_VIZ:-$AGENT_MEMORY_DIR/memory-graph.html}"

INBOX="$AGENT_MEMORY_DIR/inbox"
OUTBOX="$AGENT_MEMORY_DIR/outbox"
SNAP="$INBOX/snapshot.json"
mkdir -p "$INBOX" "$OUTBOX"

log() { echo "[cloud-dream $(date -u +%FT%TZ)] $*"; }
run() { log "$*"; node lib/dream.js "$@"; }

log "AGENT_MEMORY_DIR=$AGENT_MEMORY_DIR  DB=${MEMORY_DB:-$AGENT_MEMORY_DIR/memory.db}"

# 1) Ensure schema exists (idempotent).
node lib/dream.js init >/dev/null 2>&1 || true

# 2) INGEST + VERIFY the snapshot Scout pushed (if any). Never destructive.
if [ -f "$SNAP" ]; then
  run ingest-harness --file "$SNAP" || log "ingest-harness returned non-zero"
  if node lib/dream.js verify-sync --file "$SNAP"; then
    log "verify-sync OK (db superset of harness)"
  else
    log "WARNING verify-sync failed — continuing with maintenance only"
  fi
else
  log "no inbox/snapshot.json — running maintenance only"
fi

# 3) CONSOLIDATE math: decay / reactivate / evaporate / housekeeping, then weave.
run dream  || log "dream returned non-zero"
run weave  || log "weave returned non-zero"

# 4) Health report (non-fatal; we still export).
if node lib/dream.js doctor; then log "doctor healthy"; else log "WARNING doctor unhealthy"; fi

# 5) PROJECT: write curated facts + viz to the outbox for Scout to pull.
node lib/dream.js export-harness > "$OUTBOX/export-harness.json" \
  && log "wrote $OUTBOX/export-harness.json" || log "export-harness failed"
run export-viz || log "export-viz failed"

# 6) Timestamped run marker for observability.
date -u +%FT%TZ > "$OUTBOX/last-run.txt"
log "done"
