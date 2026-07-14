#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Phase 1 deploy: nightly cloud "dream" on Azure Container Apps Job + Azure Files.
#
#   ./azure/deploy.sh
#
# Idempotent: safe to re-run. Requires `az login` and Bash. Docker NOT required
# (the image is built in the cloud with ACR Tasks). Run from the repo root.
# ---------------------------------------------------------------------------
set -euo pipefail

# ---- Config (override via env) --------------------------------------------
LOCATION="${LOCATION:-centralus}"
RG="${RG:-rg-scout-graph-memory}"
ENVIRONMENT="${ENVIRONMENT:-cae-scout-memory}"
JOB="${JOB:-job-scout-dream}"
SHARE="${SHARE:-memory}"
# Cron in Container Apps Jobs is UTC. 0 0 * * * == 03:00 Asia/Jerusalem in summer
# DST (UTC+3); in winter (UTC+2) it lands at 02:00 local. Adjust if you care.
CRON="${CRON:-0 0 * * *}"
IMAGE_TAG="${IMAGE_TAG:-scout-dream:latest}"

# Globally-unique names get a short deterministic suffix from the subscription id.
SUB_ID="$(az account show --query id -o tsv)"
SUFFIX="$(echo -n "$SUB_ID$RG" | shasum | cut -c1-6)"
STORAGE="${STORAGE:-stscoutmem${SUFFIX}}"
ACR="${ACR:-acrscoutmem${SUFFIX}}"

echo "Subscription : $(az account show --query name -o tsv) ($SUB_ID)"
echo "Region       : $LOCATION"
echo "Resource grp : $RG"
echo "Storage      : $STORAGE / share '$SHARE'"
echo "ACR          : $ACR"
echo "Job          : $JOB   (cron '$CRON' UTC)"
echo

# ---- 0) Providers + extension ---------------------------------------------
echo "==> Registering resource providers (idempotent)…"
az provider register -n Microsoft.App --wait
az provider register -n Microsoft.OperationalInsights --wait
az provider register -n Microsoft.ContainerRegistry --wait
az extension add --name containerapp --upgrade -y >/dev/null 2>&1 || true

# ---- 1) Resource group -----------------------------------------------------
echo "==> Resource group…"
az group create -n "$RG" -l "$LOCATION" -o none

# ---- 2) Storage account + file share --------------------------------------
echo "==> Storage account + file share…"
az storage account create -n "$STORAGE" -g "$RG" -l "$LOCATION" \
  --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 -o none
STORAGE_KEY="$(az storage account keys list -n "$STORAGE" -g "$RG" --query '[0].value' -o tsv)"
az storage share-rm create --storage-account "$STORAGE" -g "$RG" -n "$SHARE" --quota 5 -o none
# Seed inbox/outbox directories.
az storage directory create --account-name "$STORAGE" --account-key "$STORAGE_KEY" -s "$SHARE" -n inbox  -o none 2>/dev/null || true
az storage directory create --account-name "$STORAGE" --account-key "$STORAGE_KEY" -s "$SHARE" -n outbox -o none 2>/dev/null || true

# ---- 3) Container registry + build image (cloud build) --------------------
echo "==> Container registry…"
az acr create -n "$ACR" -g "$RG" -l "$LOCATION" --sku Basic --admin-enabled true -o none
echo "==> Building image with ACR Tasks (no local Docker needed)…"
az acr build -r "$ACR" -t "$IMAGE_TAG" -f azure/Dockerfile . -o none
ACR_SERVER="$(az acr show -n "$ACR" -g "$RG" --query loginServer -o tsv)"
ACR_USER="$(az acr credential show -n "$ACR" --query username -o tsv)"
ACR_PASS="$(az acr credential show -n "$ACR" --query 'passwords[0].value' -o tsv)"

# ---- 4) Container Apps environment + linked Azure Files storage ------------
echo "==> Container Apps environment…"
az containerapp env create -n "$ENVIRONMENT" -g "$RG" -l "$LOCATION" -o none
echo "==> Linking Azure Files to the environment…"
az containerapp env storage set -n "$ENVIRONMENT" -g "$RG" \
  --storage-name memoryshare \
  --azure-file-account-name "$STORAGE" \
  --azure-file-account-key "$STORAGE_KEY" \
  --azure-file-share-name "$SHARE" \
  --access-mode ReadWrite -o none

# ---- 5) Container Apps Job (scheduled) with the share mounted at /data -----
echo "==> Creating/updating the scheduled job…"
if az containerapp job show -n "$JOB" -g "$RG" -o none 2>/dev/null; then
  az containerapp job update -n "$JOB" -g "$RG" \
    --image "$ACR_SERVER/$IMAGE_TAG" \
    --cron-expression "$CRON" -o none
else
  az containerapp job create -n "$JOB" -g "$RG" --environment "$ENVIRONMENT" \
    --trigger-type Schedule --cron-expression "$CRON" \
    --replica-timeout 1800 --replica-retry-limit 1 --parallelism 1 --replica-completion-count 1 \
    --image "$ACR_SERVER/$IMAGE_TAG" \
    --cpu 0.5 --memory 1.0Gi \
    --registry-server "$ACR_SERVER" --registry-username "$ACR_USER" --registry-password "$ACR_PASS" \
    -o none
fi

# Mount the Azure Files share at /data (via spec patch — the CLI has no direct flag
# for job volumes). JSON is valid YAML, so we patch with stdlib json (no pyyaml dep).
echo "==> Mounting the share at /data…"
TMP_JSON="$(mktemp)"
az containerapp job show -n "$JOB" -g "$RG" -o json > "$TMP_JSON"
python3 - "$TMP_JSON" <<'PY'
import sys, json
p = sys.argv[1]
d = json.load(open(p))
tmpl = d["properties"]["template"]
tmpl["volumes"] = [{"name": "memory", "storageType": "AzureFile", "storageName": "memoryshare"}]
for c in tmpl["containers"]:
    c["volumeMounts"] = [{"volumeName": "memory", "mountPath": "/data"}]
json.dump(d, open(p, "w"))
PY
az containerapp job update -n "$JOB" -g "$RG" --yaml "$TMP_JSON" -o none
rm -f "$TMP_JSON"

echo
echo "Deployed. Trigger a one-off run now with:"
echo "   az containerapp job start -n $JOB -g $RG"
echo "Tail logs with:"
echo "   az containerapp job execution list -n $JOB -g $RG -o table"
echo
echo "Store these for the Mac-side sync (azure/sync/scout-sync.sh):"
echo "   export SGM_STORAGE=$STORAGE"
echo "   export SGM_SHARE=$SHARE"
echo "   export SGM_RG=$RG"
