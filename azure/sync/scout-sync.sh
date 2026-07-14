#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Mac-side sync between Scout's memory bank and the cloud store (Azure Files).
# Runs only when your Mac is on; the nightly consolidation itself happens in
# Azure regardless. Two verbs:
#
#   scout-sync.sh push   local-snapshot.json   # upload Scout memories -> cloud inbox
#   scout-sync.sh pull   out-export.json       # download cloud curated facts -> apply in Scout
#
# The Scout automation calls `push` after dumping m_list_memories to a local
# snapshot.json, and `pull` to fetch the curated diff, which the agent then
# reconciles into the bank with m_remember / m_forget.
#
# Requires: az login, and these env vars (printed by deploy.sh):
#   SGM_STORAGE   storage account name
#   SGM_SHARE     file share name (default: memory)
#   SGM_RG        resource group (to fetch the key)
# ---------------------------------------------------------------------------
set -euo pipefail

: "${SGM_STORAGE:?set SGM_STORAGE (see deploy.sh output)}"
SGM_SHARE="${SGM_SHARE:-memory}"
: "${SGM_RG:?set SGM_RG (resource group)}"

KEY="$(az storage account keys list -n "$SGM_STORAGE" -g "$SGM_RG" --query '[0].value' -o tsv)"

verb="${1:-}"; file="${2:-}"
case "$verb" in
  push)
    [ -f "$file" ] || { echo "snapshot file not found: $file" >&2; exit 1; }
    az storage file upload --account-name "$SGM_STORAGE" --account-key "$KEY" \
      -s "$SGM_SHARE" --source "$file" --path "inbox/snapshot.json" -o none
    echo "pushed $file -> $SGM_SHARE/inbox/snapshot.json"
    ;;
  pull)
    out="${file:-export-harness.json}"
    az storage file download --account-name "$SGM_STORAGE" --account-key "$KEY" \
      -s "$SGM_SHARE" --path "outbox/export-harness.json" --dest "$out" -o none
    echo "pulled $SGM_SHARE/outbox/export-harness.json -> $out"
    ;;
  run-now)
    : "${SGM_JOB:=job-scout-dream}"
    az containerapp job start -n "$SGM_JOB" -g "$SGM_RG" -o none
    echo "triggered cloud dream job $SGM_JOB"
    ;;
  *)
    echo "usage: $0 {push <snapshot.json> | pull [out.json] | run-now}" >&2
    exit 2
    ;;
esac
