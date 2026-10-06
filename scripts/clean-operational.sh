#!/usr/bin/env bash
# clean-operational.sh — Clear old project/analysis/datapoint data
# Keeps persistent volumes intact; deletes contents only.

set -euo pipefail

NAMESPACE="${NAMESPACE:-openstudio-server}"
RELEASE="${RELEASE:-openstudio-server}"
VALUES_FILE="${1:-}"
# shellcheck source=lib/nfs_health.sh
source "$(dirname "$0")/lib/nfs_health.sh"

DB_USER=""
DB_PASS=""
REDIS_PASS=""

if [[ -n "$VALUES_FILE" && -f "$VALUES_FILE" ]]; then
  echo "Reading credentials from values file: $VALUES_FILE"
  if command -v yq >/dev/null 2>&1; then
    DB_USER=$(yq '.db.username // ""' "$VALUES_FILE" | tr -d '"')
    DB_PASS=$(yq '.db.password // ""' "$VALUES_FILE" | tr -d '"')
    REDIS_PASS=$(yq '.redis.password // ""' "$VALUES_FILE" | tr -d '"')
  else
    # Python fallback (python3 + pyyaml preferred, else basic parsing)
    DB_USER=$(python3 -c "
import yaml,sys
try:
  v=yaml.safe_load(open('$VALUES_FILE'))
  print(v.get('db',{}).get('username') or '')
except: print('')
" 2>/dev/null)
    DB_PASS=$(python3 -c "
import yaml,sys
try:
  v=yaml.safe_load(open('$VALUES_FILE'))
  p=v.get('db',{}).get('password')
  print(p if p else '')
except: print('')
" 2>/dev/null)
    REDIS_PASS=$(python3 -c "
import yaml,sys
try:
  v=yaml.safe_load(open('$VALUES_FILE'))
  p=v.get('redis',{}).get('password')
  print(p if p else '')
except: print('')
" 2>/dev/null)
  fi
fi

# Fallback removed: script requires values file for credentials
if [[ -z "${DB_USER:-}" || -z "${DB_PASS:-}" || -z "${REDIS_PASS:-}" ]]; then
  echo ""
  echo "ERROR: Database or Redis credentials are missing from the values file (or file not provided)."
  echo "This script no longer uses hardcoded default passwords."
  echo "Please run again with the values file used for this deployment, for example:"
  echo ""
  echo "  $0 openstack/values-openstack.yaml   # (example: openstack deployment)"
  echo "  $0 aws/values-aws.yaml                 # (example: aws deployment)"
  echo "  $0 openstudio-server/values.yaml      # (example: default chart values)"
  echo ""
  echo "Or provide the path to your deployment's values YAML (e.g. openstudio-server/values.yaml, aws/values-aws.yaml)."
  exit 1
fi

echo "=== Operational Clean: ${RELEASE} in namespace ${NAMESPACE} ==="
echo "Usage: $0 [values-file.yaml]  (optional: path to Helm values file for DB/Redis passwords)"
echo "This will DELETE CONTENTS inside the running pods (NFS, MongoDB, Redis)."
echo "Persistent volumes themselves will NOT be deleted."
echo ""
read -p "Confirm namespace [${NAMESPACE}]: " input_ns
NAMESPACE="${input_ns:-$NAMESPACE}"
read -p "Confirm release [${RELEASE}]: " input_rel
RELEASE="${input_rel:-$RELEASE}"

echo ""
echo "=== Targets ==="
echo "1. NFS mount (/mnt/openstudio) — delete old project/result directories"
echo "2. MongoDB (db pod) — drop old collections/databases"
echo "3. Redis (redis pod) — flush queued jobs/state"
echo ""
read -p "Proceed? (yes/no): " confirm
if [[ "$confirm" != "yes" ]]; then
  echo "Aborted."
  exit 1
fi

# 0. Preflight: a stale NFS mount on web-background/rserve (after an NFS pod restart) makes every
# analysis finish with 0 datapoints, so make sure all NFS clients are healthy before and after cleaning.
echo "=== Preflight: PriorityClasses and NFS clients ==="
check_priority_classes || { echo "Recreate the PriorityClasses (helm upgrade) and rerun." >&2; exit 1; }
ensure_nfs_clients_healthy || { echo "NFS clients are not healthy; aborting clean." >&2; exit 1; }

# 1. NFS — list and delete files/dirs under /mnt/openstudio
echo "=== Cleaning NFS (/mnt/openstudio) ==="
WEB_POD=$(kubectl get pod -n "$NAMESPACE" -l app=web -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "${WEB_POD:-}" ]]; then
  echo "Web pod: $WEB_POD"
  echo "Contents under /mnt/openstudio:"
  kubectl exec -n "$NAMESPACE" "$WEB_POD" -c web -- sh -c 'ls -la /mnt/openstudio 2>/dev/null || echo "(empty or not mounted)"'
  echo "Deleting contents (skipping .nfs files)..."
  kubectl exec -n "$NAMESPACE" "$WEB_POD" -c web -- sh -c 'find /mnt/openstudio/log -mindepth 1 -not -name ".nfs*" -delete 2>/dev/null || true; echo "log done"'
  kubectl exec -n "$NAMESPACE" "$WEB_POD" -c web -- sh -c 'find /mnt/openstudio/server/assets/analyses -maxdepth 3 -mindepth 3 -not -path "*.nfs*" -delete 2>/dev/null || true; echo "analyses done"'
  # Background cleanup for large directories (data_points) to avoid exec timeouts.
  # Per-datapoint dirs are removed in parallel (NFS unlink round trips make a single rm very slow).
  # The NFS_CLEAN_JOB marker lets re-runs detect an already-running job instead of racing a second one.
  NFS_CLEAN_TIMEOUT_MIN="${NFS_CLEAN_TIMEOUT_MIN:-60}"
  NFS_RUNNING_CHECK='ps -eo args 2>/dev/null | grep -q "[N]FS_CLEAN_JOB"'
  if kubectl exec -n "$NAMESPACE" "$WEB_POD" -c web -- sh -c "$NFS_RUNNING_CHECK"; then
    echo "NFS cleanup job already running in $WEB_POD; waiting for it instead of starting another."
  else
    kubectl exec -n "$NAMESPACE" "$WEB_POD" -c web -- sh -c 'nohup sh -c "NFS_CLEAN_JOB=1; find /mnt/openstudio/server/assets -mindepth 2 -maxdepth 2 -print0 2>/dev/null | xargs -0 -r -n 20 -P 8 rm -rf; rm -rf /mnt/openstudio/server/assets/* /mnt/openstudio/server/* 2>/dev/null; mkdir -p /mnt/openstudio/server/assets /mnt/openstudio/server/R; chmod 2777 /mnt/openstudio/server /mnt/openstudio/server/assets /mnt/openstudio/server/R" > /dev/null 2>&1 </dev/null &'
  fi
  # The deletion above is backgrounded; wait for it so it cannot race new submissions.
  echo "Waiting for background NFS cleanup to finish (timeout ${NFS_CLEAN_TIMEOUT_MIN} min; set NFS_CLEAN_TIMEOUT_MIN to change)..."
  bg_done=0
  start_ts=$(date +%s)
  deadline=$((start_ts + NFS_CLEAN_TIMEOUT_MIN * 60))
  while (( $(date +%s) < deadline )); do
    if kubectl exec -n "$NAMESPACE" "$WEB_POD" -c web -- sh -c "$NFS_RUNNING_CHECK && exit 1; test -d /mnt/openstudio/server/R && test -d /mnt/openstudio/server/assets" >/dev/null 2>&1; then
      bg_done=1
      break
    fi
    echo "  ...still cleaning ($(( ($(date +%s) - start_ts) / 60 )) min elapsed)"
    sleep 15
  done
  if [[ "$bg_done" != 1 ]]; then
    echo "ERROR: background NFS cleanup did not finish within ${NFS_CLEAN_TIMEOUT_MIN} minutes; aborting before Mongo/Redis cleanup." >&2
    echo "The job keeps running in $WEB_POD. Re-run this script later (it will wait for the running job)," >&2
    echo "or raise NFS_CLEAN_TIMEOUT_MIN." >&2
    exit 1
  fi
  # Rails runs as nobody and must be able to recreate assets/ subfolders on upload.
  # server/R is only created at server-image startup; Rserve writes LHS sample plots there and
  # every LHS analysis fails with 0 datapoints if it is missing.
  echo "Post-clean:"
  kubectl exec -n "$NAMESPACE" "$WEB_POD" -c web -- sh -c 'ls -la /mnt/openstudio 2>/dev/null || echo "(empty)"'
else
  echo "No web pod found in namespace $NAMESPACE."
fi

# 2. MongoDB — drop collections/databases
echo ""
echo "=== Cleaning MongoDB (db) ==="
DB_POD=$(kubectl get pod -n "$NAMESPACE" -l app=db -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "${DB_POD:-}" ]]; then
  echo "DB pod: $DB_POD"
  echo "Collections/databases found:"
  kubectl exec -n "$NAMESPACE" "$DB_POD" -c mongo-db -- mongosh --username "$DB_USER" --password "$DB_PASS" --authenticationDatabase admin --eval 'db.getMongo().getDBNames()' --quiet || echo "(connection failed or no data)"
  echo "Dropping collections/databases..."
  kubectl exec -n "$NAMESPACE" "$DB_POD" -c mongo-db -- mongosh --username "$DB_USER" --password "$DB_PASS" --authenticationDatabase admin --eval 'db.getMongo().getDBNames().forEach(function(d){ if(d !== "admin" && d !== "local" && d !== "config") { db.getSiblingDB(d).dropDatabase(); print("Dropped: " + d); } })' --quiet || echo "No collections dropped"
  # dropDatabase removes the Mongoid indexes, which start-server only builds at web startup.
  # Without them every analysis POST scans the variables collection and submissions slow to minutes each.
  if [[ -n "${WEB_POD:-}" ]]; then
    echo "Recreating Mongoid indexes..."
    kubectl exec -n "$NAMESPACE" "$WEB_POD" -c web -- sh -c 'cd /opt/openstudio/server && bundle exec rake db:mongoid:create_indexes' || echo "WARNING: index creation failed; run 'bundle exec rake db:mongoid:create_indexes' in the web pod or restart it"
  fi
else
  echo "No db pod found in namespace $NAMESPACE."
fi

# 3. Redis — flush queued jobs/state
echo ""
echo "=== Cleaning Redis (redis) ==="
REDIS_POD=$(kubectl get pod -n "$NAMESPACE" -l app=redis -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "${REDIS_POD:-}" ]]; then
  echo "Redis pod: $REDIS_POD"
  echo "Flushing DB..."
  kubectl exec -n "$NAMESPACE" "$REDIS_POD" -c redis -- env PASS="$REDIS_PASS" sh -c 'redis-cli -a "$PASS" FLUSHDB' || echo "Flush failed (may need auth or DB empty)"
  echo "Flushing all (optional backup step)..."
  kubectl exec -n "$NAMESPACE" "$REDIS_POD" -c redis -- env PASS="$REDIS_PASS" sh -c 'redis-cli -a "$PASS" FLUSHALL' || echo "FlushALL failed"
else
  echo "No redis pod found in namespace $NAMESPACE."
fi

echo ""
echo "=== Post-clean verification ==="
ensure_nfs_clients_healthy || { echo "ERROR: NFS clients unhealthy after clean; do NOT submit until fixed." >&2; exit 1; }
for d in web-background rserve; do
  kubectl exec -n "$NAMESPACE" "deploy/$d" -- test -d /mnt/openstudio/server/R \
    || { echo "ERROR: /mnt/openstudio/server/R missing as seen from $d" >&2; exit 1; }
done

echo ""
echo "=== Clean complete ==="
echo "Persistent volumes (PVs/PVCs) were NOT deleted — only contents cleared."
