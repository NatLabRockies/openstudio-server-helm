#!/usr/bin/env bash
# Pre-install cleanup guard: removes leftover openstudio-server artifacts
# before helm install proceeds. Independent of the pre-delete hook.
# DESTRUCTIVE: force-deletes the release's pods and the nfs-pvc / nfs-pvc-data
# PVCs and their PVs (all data on them is lost).
# Usage: scripts/pre-install-cleanup.sh [--yes] [namespace] [release]
set -euo pipefail
ASSUME_YES=false
if [ "${1:-}" = "--yes" ]; then ASSUME_YES=true; shift; fi
NS="${1:-openstudio-server}"
REL="${2:-openstudio-server}"

if [ "$ASSUME_YES" != "true" ]; then
  read -r -p "This force-deletes pods and NFS PVCs/PVs for '$REL' in '$NS'. Type 'yes' to continue: " confirm
  [ "$confirm" = "yes" ] || { echo "Aborted."; exit 1; }
fi

echo "[pre-install-guard] Checking namespace '$NS' for leftover '$REL' artifacts..."

LEFTOVER_PODS=$(kubectl get pod -n "$NS" -l "release=$REL" -o name 2>/dev/null || true)
if [ -n "$LEFTOVER_PODS" ]; then
  echo "[pre-install-guard] Force-deleting leftover pods:"
  echo "$LEFTOVER_PODS"
  kubectl delete pod -n "$NS" -l "release=$REL" --force --grace-period=0 --ignore-not-found=true
fi

LEFTOVER_PVC=$(kubectl get pvc -n "$NS" nfs-pvc -o name 2>/dev/null || true)
if [ -n "$LEFTOVER_PVC" ]; then
  echo "[pre-install-guard] Deleting leftover PVC nfs-pvc..."
  kubectl delete pvc -n "$NS" nfs-pvc --ignore-not-found=true
fi
LEFTOVER_PVC2=$(kubectl get pvc -n "$NS" nfs-pvc-data -o name 2>/dev/null || true)
if [ -n "$LEFTOVER_PVC2" ]; then
  echo "[pre-install-guard] Deleting leftover PVC nfs-pvc-data..."
  kubectl delete pvc -n "$NS" nfs-pvc-data --ignore-not-found=true
fi

LEFTOVER_PV=$(kubectl get pv -o json 2>/dev/null | python3 -c "
import sys, json
pv_list = json.load(sys.stdin).get('items', [])
leftover = []
for pv in pv_list:
    claim_meta = pv.get('spec', {}).get('claimRef', {})
    claim_name = claim_meta.get('name', '')
    claim_ns = claim_meta.get('namespace', '')
    # Only delete PVs whose claim is nfs-pvc or nfs-pvc-data in the target namespace
    if claim_name in ('nfs-pvc', 'nfs-pvc-data') and claim_ns == '$NS':
        leftover.append(pv['metadata']['name'])
print(' '.join(leftover))
" || true)
if [ -n "$LEFTOVER_PV" ]; then
  echo "[pre-install-guard] Patching/removing leftover PV(s): $LEFTOVER_PV"
  for pv in $LEFTOVER_PV; do
    kubectl patch pv "$pv" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
    kubectl delete pv "$pv" --ignore-not-found=true || true
  done
fi

echo "[pre-install-guard] Checking namespace '$NS' termination state..."
NS_PHASE=$(kubectl get ns "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
if [ "$NS_PHASE" = "Terminating" ]; then
  echo "[pre-install-guard] WARNING: namespace '$NS' is Terminating. Consider manual cleanup before install."
fi

echo "[pre-install-guard] Pre-install guard complete."
